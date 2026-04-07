"""
Extended PCS (ProCyclingStats) scraping functions for race-specific historical data.

Uses `scrape_pcs_table()` and `find_column()` from pcs_scraper.jl for resilient
column resolution — when PCS renames a column, add one string to the alias list.
"""

"""
## `getpcsraceresults`

Downloads and parses the finishing results for a specific race edition from the PCS website.

URL pattern: `https://www.procyclingstats.com/race/{slug}/{year}/result`

Uses `scrape_pcs_table` + `find_column` to parse the static HTML results table.
The `div.svg_shield` breakaway indicator is only present in JavaScript-rendered HTML
(browser), not in raw HTTP responses, so `in_breakaway` is always `false` and
`breakaway_km` is always `missing`. The empirical breakaway model in
`predict_expected_points` falls back to field-average rates as a result.

Returns a DataFrame with the following columns:

    * `position` - finishing position (Int); DNF/DNS riders are assigned position 999
    * `rider` - rider name
    * `team` - team name
    * `riderkey` - normalised rider key created via `createkey(rider)`
    * `in_breakaway` - true if rider was in a breakaway for >50% of race distance
    * `breakaway_km` - km spent in the break (Union{Float64,Missing}; missing if shield has no title)

# Arguments
- `pcs_race_slug` - the PCS race slug, e.g. `"tour-de-france"` or `"liege-bastogne-liege"`
- `year` - the edition year, e.g. `2023`

# Keyword Arguments
- `force_refresh` - bypass the cache and fetch fresh data (default: `false`)
- `cache_config` - cache configuration (default: `DEFAULT_CACHE`)

# Example
```julia
getpcsraceresults("trofeo-laigueglia", 2026)
```
"""
function getpcsraceresults(
    pcs_race_slug::String,
    year::Int;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)

    pageurl = "https://www.procyclingstats.com/race/$(pcs_race_slug)/$(year)/result"

    function fetch_race_results(url, params)
        # Parse directly with Gumbo to extract rider names from <a href="rider/..."> links.
        # The PCS results table concatenates rider name + team name in one cell (full cell text),
        # so scrape_pcs_table gives wrong rider names; the link text is always the clean rider name.
        # div.svg_shield breakaway indicators are only present in JavaScript-rendered HTML, not
        # in raw HTTP responses, so in_breakaway is always false.
        _empty_results() = DataFrame(
            position = Int[],
            rider = String[],
            team = String[],
            riderkey = String[],
            in_breakaway = Bool[],
            breakaway_km = Union{Float64,Missing}[],
        )

        response = try
            HTTP.get(url, ["User-Agent" => "Mozilla/5.0 (compatible; VelogamesBot/1.0)"])
        catch e
            if e isa HTTP.Exceptions.StatusError
                @warn "HTTP $(e.status) for $url — caching empty result"
                return _empty_results()
            end
            error("Failed to fetch $url: $e")
        end
        page = Gumbo.parsehtml(String(response.body))
        tables = collect(eachmatch(sel"table", page.root))
        isempty(tables) && return _empty_results()
        rows = collect(eachmatch(sel"tr", tables[1]))[2:end]  # skip header

        positions = Int[]
        riders = String[]
        teams = String[]

        for row in rows
            cells = collect(eachmatch(sel"td", row))
            isempty(cells) && continue
            rider_links = filter(
                l -> startswith(getattr(l, "href", ""), "rider/"),
                collect(eachmatch(sel"a", row)),
            )
            isempty(rider_links) && continue
            rider_name = strip(nodeText(rider_links[1]))
            team_links = filter(
                l -> startswith(getattr(l, "href", ""), "team/"),
                collect(eachmatch(sel"a", row)),
            )
            team_name = isempty(team_links) ? "" : strip(nodeText(team_links[1]))
            pos_text = strip(nodeText(cells[1]))
            pos = something(tryparse(Int, pos_text), DNF_POSITION)
            push!(positions, pos)
            push!(riders, rider_name)
            push!(teams, team_name)
        end

        isempty(riders) && return _empty_results()

        result = DataFrame(
            position = positions,
            rider = riders,
            team = teams,
            riderkey = createkey.(riders),
            in_breakaway = falses(length(riders)),
            breakaway_km = Vector{Union{Float64,Missing}}(fill(missing, length(riders))),
        )
        result = filter(row -> !isempty(row.riderkey), result)
        result = unique(result, :riderkey)
        return result[
            :,
            [:position, :rider, :team, :riderkey, :in_breakaway, :breakaway_km],
        ]
    end

    params = Dict("slug" => pcs_race_slug, "year" => string(year))
    return cached_fetch(
        fetch_race_results,
        pageurl,
        params;
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end


function _extract_rider_slugs(pageurl::String)::Dict{String,String}
    slug_map = Dict{String,String}()
    response =
        HTTP.get(pageurl, ["User-Agent" => "Mozilla/5.0 (compatible; VelogamesBot/1.0)"])
    pagehtml = Gumbo.parsehtml(String(response.body))
    for link in eachmatch(Selector("a"), pagehtml.root)
        href = get(link.attributes, "href", "")
        m = match(r"(?:^|/)rider/([a-z0-9-]+)", href)
        m === nothing && continue
        rider_name = String(strip(nodeText(link)))
        isempty(rider_name) && continue
        key = createkey(rider_name)
        isempty(key) && continue
        slug_map[key] = m.captures[1]
    end
    return slug_map
end

function getpcsracestartlist(
    pcs_race_slug::String,
    year::Int;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)

    pageurl = "https://www.procyclingstats.com/race/$(pcs_race_slug)/$(year)/startlist/startlist-quality"

    function fetch_startlist(url, params)
        df = scrape_pcs_table(url)

        rider_col = find_column(df, PCS_RIDER_ALIASES)
        points_col = find_column(df, PCS_POINTS_ALIASES)
        rank_col =
            find_column(df, ["pcs-ranking", "pcsranking", "pcsrank", PCS_RANK_ALIASES...])
        team_col = find_column(df, PCS_TEAM_ALIASES)

        rider_col === nothing && error(
            "No rider column found in startlist from $url. " *
            "Columns: $(names(df)). " *
            "Add the new column name to PCS_RIDER_ALIASES in src/pcs_scraper.jl",
        )

        # Build standardized result DataFrame
        result = DataFrame()
        result.rider = String.(df[!, rider_col])

        # PCS ranking (may be "pcs-ranking", "rank", "#", etc.)
        result.pcsrank = if rank_col !== nothing
            map(df[!, rank_col]) do val
                s = strip(string(val))
                parsed = tryparse(Int, s)
                parsed !== nothing ? parsed : UNRANKED_POSITION
            end
        else
            @warn "No PCS ranking column found in startlist from $url; pcsrank will be $UNRANKED_POSITION"
            fill(UNRANKED_POSITION, nrow(df))
        end

        # PCS points
        result.pcspoints = if points_col !== nothing
            map(df[!, points_col]) do val
                val isa Float64 && return val
                s = strip(string(val))
                parsed = tryparse(Float64, s)
                parsed !== nothing ? parsed : 0.0
            end
        else
            @warn "No PCS points column found in startlist from $url; pcspoints will be 0.0"
            fill(0.0, nrow(df))
        end

        result.team = team_col !== nothing ? String.(df[!, team_col]) : fill("", nrow(df))
        result.riderkey = createkey.(result.rider)

        # Extract actual PCS profile slugs from rider links on the page
        result.pcs_slug = try
            slug_map = _extract_rider_slugs(url)
            [get(slug_map, key, "") for key in result.riderkey]
        catch e
            @debug "Could not extract PCS slugs from startlist: $e"
            fill("", nrow(result))
        end

        # Drop rows with empty riderkey
        result = filter(row -> !isempty(row.riderkey), result)
        result = unique(result, :riderkey)

        return result[:, [:rider, :team, :pcsrank, :pcspoints, :riderkey, :pcs_slug]]
    end

    params = Dict("slug" => pcs_race_slug, "year" => string(year))
    return cached_fetch(
        fetch_startlist,
        pageurl,
        params;
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end


"""
## `getpcsraceform`

Downloads and parses PCS form scores for riders on a race startlist.

URL: `https://www.procyclingstats.com/race/{slug}/{year}/startlist/form`

The form page ranks starters by recent results across all races (last ~6 weeks).
Only the top ~40-60 riders by form appear; riders not listed simply don't receive
the signal. The Points column uses a valuebar widget but `nodeText` extracts the
numeric value correctly.

Returns a DataFrame with columns:

    * `rider` - rider name
    * `form_score` - PCS form points (Float64)
    * `riderkey` - normalised rider key

# Arguments
- `pcs_race_slug` - the PCS race slug, e.g. `"omloop-het-nieuwsblad"`
- `year` - the edition year, e.g. `2026`

# Keyword Arguments
- `force_refresh` - bypass the cache and fetch fresh data (default: `false`)
- `cache_config` - cache configuration (default: `DEFAULT_CACHE`)
"""
function getpcsraceform(
    pcs_race_slug::String,
    year::Int;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)

    pageurl = "https://www.procyclingstats.com/race/$(pcs_race_slug)/$(year)/startlist/form"

    function fetch_form(url, params)
        df = scrape_pcs_table(url)

        rider_col = find_column(df, PCS_RIDER_ALIASES)
        points_col = find_column(df, PCS_POINTS_ALIASES)

        rider_col === nothing && error(
            "No rider column found in form page from $url. " *
            "Columns: $(names(df)). " *
            "Add the new column name to PCS_RIDER_ALIASES in src/pcs_scraper.jl",
        )

        result = DataFrame()
        result.rider = String.(df[!, rider_col])

        result.form_score = if points_col !== nothing
            map(df[!, points_col]) do val
                val isa Float64 && return val
                s = strip(string(val))
                parsed = tryparse(Float64, s)
                parsed !== nothing ? parsed : 0.0
            end
        else
            @warn "No points column found in form page from $url; form_score will be 0.0"
            fill(0.0, nrow(df))
        end

        result.riderkey = createkey.(result.rider)

        result = filter(row -> !isempty(row.riderkey), result)
        result = unique(result, :riderkey)

        return result[:, [:rider, :form_score, :riderkey]]
    end

    params = Dict("slug" => pcs_race_slug, "year" => string(year))
    return cached_fetch(
        fetch_form,
        pageurl,
        params;
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end


"""
## `getpcsriderseasons`

Scrapes year-by-year PCS ranking points from a rider's profile page.

The rider profile page contains a summary table (the second `<table>`) with
columns for year, PCS points, and PCS ranking. This function extracts that
table to provide cross-season trajectory data.

Returns a DataFrame with columns:

    * `year` - season year (Int)
    * `pcs_points` - PCS ranking points for that season (Float64)
    * `pcs_rank` - PCS ranking position for that season (Int)

# Arguments
- `pcs_slug` - the PCS rider slug, e.g. `"antonio-tiberi"`

# Keyword Arguments
- `force_refresh` - bypass the cache and fetch fresh data (default: `false`)
- `cache_config` - cache configuration (default: `DEFAULT_CACHE`)
"""
function getpcsriderseasons(
    pcs_slug::String;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    pageurl = "https://www.procyclingstats.com/rider/$(pcs_slug)"

    function fetch_seasons(url, params)
        response = try
            HTTP.get(url, ["User-Agent" => "Mozilla/5.0 (compatible; VelogamesBot/1.0)"])
        catch e
            if e isa HTTP.Exceptions.StatusError && e.status in (400, 403, 404)
                return DataFrame(year = Int[], pcs_points = Float64[], pcs_rank = Int[])
            end
            rethrow()
        end

        page = parsehtml(String(response.body))

        # The season summary is the second table on the profile page
        tables = collect(eachmatch(sel"table", page.root))
        if length(tables) < 2
            @warn "No season summary table found on $url"
            return DataFrame(year = Int[], pcs_points = Float64[], pcs_rank = Int[])
        end

        season_table = tables[2]
        rows = collect(eachmatch(sel"tr", season_table))

        years = Int[]
        points = Float64[]
        ranks = Int[]

        for row in rows
            cells = collect(eachmatch(sel"td, th", row))
            length(cells) >= 3 || continue

            cell_texts = [strip(nodeText(c)) for c in cells]

            yr = tryparse(Int, cell_texts[1])
            yr === nothing && continue

            pts = tryparse(Float64, cell_texts[2])
            pts === nothing && continue

            rnk = tryparse(Int, cell_texts[3])
            rnk === nothing && (rnk = UNRANKED_POSITION)

            push!(years, yr)
            push!(points, pts)
            push!(ranks, rnk)
        end

        return DataFrame(year = years, pcs_points = points, pcs_rank = ranks)
    end

    params = Dict("slug" => pcs_slug)
    return cached_fetch(
        fetch_seasons,
        pageurl,
        params;
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end


"""
## `getpcsriderseasons_batch`

Batch version — get season-by-season PCS points for multiple riders.
Returns a single DataFrame with an additional `riderkey` column.
"""
function getpcsriderseasons_batch(
    rider_slugs::Dict{String,String};
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    all_dfs = DataFrame[]

    for (riderkey, slug) in rider_slugs
        try
            df = getpcsriderseasons(
                slug;
                force_refresh = force_refresh,
                cache_config = cache_config,
            )
            if nrow(df) > 0
                df[!, :riderkey] .= riderkey
                push!(all_dfs, df)
            end
        catch e
            @warn "Failed to fetch seasons for $riderkey ($slug): $e"
        end
    end

    return isempty(all_dfs) ?
           DataFrame(
        year = Int[],
        pcs_points = Float64[],
        pcs_rank = Int[],
        riderkey = String[],
    ) : vcat(all_dfs...; cols = :union)
end


"""
## `getpcsracehistory`

Convenience function that fetches finishing results for a race across multiple years
and combines them into a single DataFrame.

Internally calls `getpcsraceresults` for each requested year. Years for which data
cannot be retrieved are skipped with a warning rather than raising an error.

Returns a DataFrame with all columns from `getpcsraceresults` plus:

    * `year` - the race edition year (Int)

# Arguments
- `pcs_race_slug` - the PCS race slug, e.g. `"paris-roubaix"`
- `years` - vector of edition years to retrieve, e.g. `[2021, 2022, 2023]`

# Keyword Arguments
- `force_refresh` - bypass the cache and fetch fresh data for all years (default: `false`)
- `cache_config` - cache configuration (default: `DEFAULT_CACHE`)

# Example
```julia
getpcsracehistory("paris-roubaix", [2021, 2022, 2023, 2024])
```
"""
function getpcsracehistory(
    pcs_race_slug::String,
    years::Vector{Int};
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)

    all_results = DataFrame()

    for year in years
        try
            year_df = getpcsraceresults(
                pcs_race_slug,
                year;
                force_refresh = force_refresh,
                cache_config = cache_config,
            )
            year_df[!, :year] = fill(year, nrow(year_df))
            all_results = vcat(all_results, year_df; cols = :union)
        catch e
            @warn "Failed to fetch results for $pcs_race_slug $year: $e"
        end
    end

    if nrow(all_results) == 0
        error("""
        No results retrieved for $pcs_race_slug across years: $years.

        Check that the race slug is correct and that the years requested have
        results pages on PCS (https://www.procyclingstats.com/race/$pcs_race_slug).
        """)
    end

    # Move year column to the front for readability
    col_order = [:year, :position, :rider, :team, :riderkey, :in_breakaway, :breakaway_km]
    present_core = [c for c in col_order if c in Symbol.(names(all_results))]
    extra_cols = [c for c in Symbol.(names(all_results)) if c ∉ col_order]
    all_results = all_results[:, [present_core; extra_cols]]

    return all_results
end

"""
    load_pcs_breakaway_stats(dir::String) -> DataFrame

Parse manually downloaded PCS "most attack kms" MHTML files to extract
per-rider breakaway km by season.

Expects `.mhtml` files saved from
`https://www.procyclingstats.com/statistics/start/most-attack-kms`
(one per season). The year is extracted from the page title.

Returns a DataFrame with columns: `rider`, `riderkey`, `year`, `breakaway_km`.
"""
function load_pcs_breakaway_stats(dir::String)::DataFrame
    mhtml_files = filter(f -> endswith(lowercase(f), ".mhtml"), readdir(dir))
    isempty(mhtml_files) && error("No .mhtml files found in $dir")

    all_data = DataFrame[]
    for filename in mhtml_files
        filepath = joinpath(dir, filename)
        raw = read(filepath, String)

        # Decode quoted-printable: =XX hex escapes and soft line breaks (=\n)
        html = replace(raw, "=\r\n" => "", "=\n" => "")
        html = replace(html, r"=([0-9A-Fa-f]{2})" => s -> string(Char(parse(UInt8, s[2:3], base=16))))

        # Extract year from title
        year_match = match(r"season\s+(\d{4})", html)
        year_match === nothing && error("Cannot determine year from $filename")
        year = parse(Int, year_match.captures[1])

        # Parse HTML and find the first table ("By rider")
        page = Gumbo.parsehtml(html)
        tables = collect(eachmatch(sel"table", page.root))
        isempty(tables) && error("No tables found in $filename")
        rider_table = tables[1]

        rows = collect(eachmatch(sel"tr", rider_table))
        riders = String[]
        km_values = Float64[]

        for row in rows
            cells = collect(eachmatch(sel"td", row))
            length(cells) < 3 && continue

            # Rider name from <a href="rider/..."> link
            rider_links = filter(
                l -> occursin("rider/", getattr(l, "href", "")),
                collect(eachmatch(sel"a", row)),
            )
            isempty(rider_links) && continue
            pcs_name = strip(nodeText(rider_links[1]))

            # Flip "LASTNAME Firstname" → "Firstname Lastname"
            rider_name = _flip_pcs_name(pcs_name)

            # Breakaway km from the last cell
            km_text = strip(nodeText(cells[end]))
            km = tryparse(Float64, km_text)
            km === nothing && continue

            push!(riders, rider_name)
            push!(km_values, km)
        end

        isempty(riders) && @warn "No rider data extracted from $filename"
        isempty(riders) && continue

        df = DataFrame(
            rider = riders,
            riderkey = createkey.(riders),
            year = fill(year, length(riders)),
            breakaway_km = km_values,
        )
        push!(all_data, df)
    end

    isempty(all_data) && error("No breakaway data extracted from any file in $dir")
    return vcat(all_data...)
end

"""
    _flip_pcs_name(pcs_name) -> String

Convert PCS "LASTNAME Firstname" format to "Firstname Lastname".
Handles multi-word surnames (all-caps prefix) and multi-word first names.
"""
function _flip_pcs_name(pcs_name::AbstractString)::String
    parts = split(strip(pcs_name))
    isempty(parts) && return pcs_name
    # Find where the uppercase surname ends
    surname_end = 0
    for (i, part) in enumerate(parts)
        if all(c -> isuppercase(c) || !isletter(c), part)
            surname_end = i
        else
            break
        end
    end
    surname_end == 0 && return pcs_name
    surname_end >= length(parts) && return pcs_name

    surname_parts = parts[1:surname_end]
    firstname_parts = parts[surname_end+1:end]
    # Titlecase the surname parts
    surname = join(titlecase.(lowercase.(surname_parts)), " ")
    firstname = join(firstname_parts, " ")
    return "$firstname $surname"
end
