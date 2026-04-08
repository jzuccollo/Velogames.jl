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
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE,
)

    pageurl = "https://www.procyclingstats.com/race/$(pcs_race_slug)/$(year)/result"

    function fetch_race_results(url, params)
        # Parse directly with Gumbo to extract rider names from <a href="rider/..."> links.
        # The PCS results table concatenates rider name + team name in one cell (full cell text),
        # so scrape_pcs_table gives wrong rider names; the link text is always the clean rider name.
        # div.svg_shield breakaway indicators are only present in JavaScript-rendered HTML, not
        # in raw HTTP responses, so in_breakaway is always false.
        _empty_results() = DataFrame(
            position=Int[],
            rider=String[],
            team=String[],
            riderkey=String[],
            in_breakaway=Bool[],
            breakaway_km=Union{Float64,Missing}[],
        )

        # Try /result first (one-day races), fall back to /gc (stage races)
        page = nothing
        for attempt_url in [url, replace(url, "/result" => "/gc")]
            response = try
                HTTP.get(attempt_url, ["User-Agent" => "Mozilla/5.0 (compatible; VelogamesBot/1.0)"])
            catch e
                e isa HTTP.Exceptions.StatusError && continue
                error("Failed to fetch $attempt_url: $e")
            end
            candidate = Gumbo.parsehtml(String(response.body))
            if !isempty(collect(eachmatch(sel"table", candidate.root)))
                page = candidate
                break
            end
        end
        page === nothing && return _empty_results()
        tables = collect(eachmatch(sel"table", page.root))
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
            position=positions,
            rider=riders,
            team=teams,
            riderkey=createkey.(riders),
            in_breakaway=falses(length(riders)),
            breakaway_km=Vector{Union{Float64,Missing}}(fill(missing, length(riders))),
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
        cache_config=cache_config,
        force_refresh=force_refresh,
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
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE,
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
        cache_config=cache_config,
        force_refresh=force_refresh,
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
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE,
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
        cache_config=cache_config,
        force_refresh=force_refresh,
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
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE,
)
    pageurl = "https://www.procyclingstats.com/rider/$(pcs_slug)"

    function fetch_seasons(url, params)
        response = try
            HTTP.get(url, ["User-Agent" => "Mozilla/5.0 (compatible; VelogamesBot/1.0)"])
        catch e
            if e isa HTTP.Exceptions.StatusError && e.status in (400, 403, 404)
                return DataFrame(year=Int[], pcs_points=Float64[], pcs_rank=Int[])
            end
            rethrow()
        end

        page = parsehtml(String(response.body))

        # The season summary is the second table on the profile page
        tables = collect(eachmatch(sel"table", page.root))
        if length(tables) < 2
            @warn "No season summary table found on $url"
            return DataFrame(year=Int[], pcs_points=Float64[], pcs_rank=Int[])
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

        return DataFrame(year=years, pcs_points=points, pcs_rank=ranks)
    end

    params = Dict("slug" => pcs_slug)
    return cached_fetch(
        fetch_seasons,
        pageurl,
        params;
        cache_config=cache_config,
        force_refresh=force_refresh,
    )
end


"""
## `getpcsriderseasons_batch`

Batch version — get season-by-season PCS points for multiple riders.
Returns a single DataFrame with an additional `riderkey` column.
"""
function getpcsriderseasons_batch(
    rider_slugs::Dict{String,String};
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE,
)
    all_dfs = DataFrame[]

    for (riderkey, slug) in rider_slugs
        try
            df = getpcsriderseasons(
                slug;
                force_refresh=force_refresh,
                cache_config=cache_config,
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
        year=Int[],
        pcs_points=Float64[],
        pcs_rank=Int[],
        riderkey=String[],
    ) : vcat(all_dfs...; cols=:union)
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
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE,
)

    all_results = DataFrame()

    for year in years
        try
            year_df = getpcsraceresults(
                pcs_race_slug,
                year;
                force_refresh=force_refresh,
                cache_config=cache_config,
            )
            year_df[!, :year] = fill(year, nrow(year_df))
            all_results = vcat(all_results, year_df; cols=:union)
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
            rider=riders,
            riderkey=createkey.(riders),
            year=fill(year, length(riders)),
            breakaway_km=km_values,
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


# ---------------------------------------------------------------------------
# Stage race PCS scrapers
# ---------------------------------------------------------------------------

"""
    getpcs_stage_profiles(pcs_slug, year; cache_config, force_refresh) -> Vector{StageProfile}

Scrape stage metadata from PCS for a grand tour.

Two-pass scraping:
1. Race overview (`/race/{slug}/{year}`) for stage list and profile codes
2. Individual stage pages (`/race/{slug}/{year}/stage-{n}`) for ProfileScore,
   vertical meters, and gradient data.

Returns a vector of `StageProfile` structs, or an empty vector if scraping fails.
"""
function getpcs_stage_profiles(
    pcs_slug::String,
    year::Int;
    cache_config::CacheConfig=DEFAULT_CACHE,
    force_refresh::Bool=false,
)
    overview_url = "https://www.procyclingstats.com/race/$pcs_slug/$year"

    function fetch_profiles(url, params)
        response = try
            HTTP.get(url, ["User-Agent" => "Mozilla/5.0 (compatible; VelogamesBot/1.0)"])
        catch e
            if e isa HTTP.Exceptions.StatusError
                @warn "HTTP $(e.status) for $url"
                return DataFrame()
            end
            error("Failed to fetch $url: $e")
        end
        page = Gumbo.parsehtml(String(response.body))

        # Find the stage list table (look for a table with stage links)
        tables = collect(eachmatch(sel"table", page.root))
        stages = StageProfile[]

        # Parse stage rows from overview tables
        for tbl in tables
            rows = collect(eachmatch(sel"tr", tbl))
            for row in rows
                links = collect(eachmatch(sel"a", row))
                stage_link = nothing
                for l in links
                    href = getattr(l, "href", "")
                    if occursin(r"stage-\d+", href)
                        stage_link = l
                        break
                    end
                end
                stage_link === nothing && continue

                href = getattr(stage_link, "href", "")
                m = match(r"stage-(\d+)", href)
                m === nothing && continue
                stage_num = parse(Int, m.captures[1])

                stage_name = strip(nodeText(stage_link))

                # Detect ITT/TTT from stage name
                name_upper = uppercase(stage_name)
                is_itt = occursin("ITT", name_upper) || occursin("TIME TRIAL", name_upper)
                is_ttt = occursin("TTT", name_upper) || occursin("TEAM TIME TRIAL", name_upper)

                # Extract profile code from span.icon.profile
                profile_spans = collect(eachmatch(sel"span", row))
                profile_code = ""
                for sp in profile_spans
                    cls = getattr(sp, "class", "")
                    m_profile = match(r"p(\d)", cls)
                    if m_profile !== nothing
                        profile_code = "p" * m_profile.captures[1]
                        break
                    end
                end

                # Extract distance from cells
                cells = collect(eachmatch(sel"td", row))
                distance = 0.0
                for cell in cells
                    txt = strip(nodeText(cell))
                    m_km = match(r"^(\d+\.?\d*)\s*$", txt)
                    if m_km !== nothing
                        val = tryparse(Float64, m_km.captures[1])
                        if val !== nothing && 5.0 < val < 300.0
                            distance = val
                        end
                    end
                end

                # Classify stage type
                stage_type = if is_ttt
                    :ttt
                elseif is_itt
                    :itt
                elseif profile_code == "p1"
                    :flat
                elseif profile_code in ("p2", "p3")
                    :hilly
                elseif profile_code in ("p4", "p5")
                    :mountain
                else
                    :hilly  # default
                end
                # Override p4 ITTs
                if profile_code == "p4" && is_itt
                    stage_type = :itt
                end

                push!(stages, StageProfile(
                    stage_num, stage_type, distance, 0, 0, 0.0, 0, 0,
                    stage_type in (:itt, :ttt) ? 0 : 1, false,
                ))
            end
        end

        isempty(stages) && return DataFrame()

        # Sort by stage number and deduplicate
        sort!(stages, by=s -> s.stage_number)
        unique!(s -> s.stage_number, stages)

        # Pass 2: fetch individual stage pages for detailed metadata
        enriched = StageProfile[]
        for s in stages
            stage_url = "https://www.procyclingstats.com/race/$pcs_slug/$year/stage-$(s.stage_number)"
            ps, vert, gradient, n_hc, n_cat1 = _fetch_stage_details(stage_url)
            is_summit = gradient > 3.0
            push!(enriched, StageProfile(
                s.stage_number, s.stage_type, s.distance_km > 0 ? s.distance_km : 180.0,
                ps, vert, gradient, n_hc, n_cat1,
                s.n_intermediate_sprints, is_summit,
            ))
        end

        # Return as a DataFrame for caching (converted back to Vector{StageProfile} after)
        return DataFrame(
            stage_number=[s.stage_number for s in enriched],
            stage_type=[String(s.stage_type) for s in enriched],
            distance_km=[s.distance_km for s in enriched],
            profile_score=[s.profile_score for s in enriched],
            vertical_meters=[s.vertical_meters for s in enriched],
            gradient_final_km=[s.gradient_final_km for s in enriched],
            n_hc_climbs=[s.n_hc_climbs for s in enriched],
            n_cat1_climbs=[s.n_cat1_climbs for s in enriched],
            n_intermediate_sprints=[s.n_intermediate_sprints for s in enriched],
            is_summit_finish=[s.is_summit_finish for s in enriched],
        )
    end

    params = Dict("slug" => pcs_slug, "year" => string(year), "type" => "stage_profiles")
    df = cached_fetch(
        fetch_profiles, overview_url, params;
        cache_config=cache_config, force_refresh=force_refresh,
    )

    nrow(df) == 0 && return StageProfile[]

    # Convert DataFrame back to Vector{StageProfile}
    return [
        StageProfile(
            row.stage_number,
            Symbol(row.stage_type),
            row.distance_km,
            row.profile_score,
            row.vertical_meters,
            row.gradient_final_km,
            row.n_hc_climbs,
            row.n_cat1_climbs,
            row.n_intermediate_sprints,
            row.is_summit_finish,
        )
        for row in eachrow(df)
    ]
end

"""Fetch detailed metadata for a single stage page."""
function _fetch_stage_details(stage_url::String)
    ps = 0
    vert = 0
    gradient = 0.0
    n_hc = 0
    n_cat1 = 0

    response = try
        HTTP.get(stage_url, ["User-Agent" => "Mozilla/5.0 (compatible; VelogamesBot/1.0)"])
    catch e
        @debug "Failed to fetch stage details from $stage_url: $e"
        return ps, vert, gradient, n_hc, n_cat1
    end

    page = Gumbo.parsehtml(String(response.body))

    # Parse <li><div class="title">...</div><div class="value">...</div></li> pattern
    lis = collect(eachmatch(sel"li", page.root))
    for li in lis
        titles = collect(eachmatch(sel"div.title", li))
        values = collect(eachmatch(sel"div.value", li))
        (isempty(titles) || isempty(values)) && continue
        title = replace(lowercase(strip(nodeText(titles[1]))), r"[:\s]+$" => "")
        value = strip(nodeText(values[1]))

        if title == "profilescore" || title == "profile score"
            v = tryparse(Int, replace(value, r"[^\d]" => ""))
            v !== nothing && (ps = v)
        elseif title == "vertical meters" || title == "vert. meters"
            v = tryparse(Int, replace(value, r"[^\d]" => ""))
            v !== nothing && (vert = v)
        elseif occursin("gradient", title) && occursin("final", title)
            m = match(r"([\d.]+)", value)
            m !== nothing && (gradient = parse(Float64, m.captures[1]))
        end
    end

    # Count categorised climbs from the page
    body_text = nodeText(page.root)
    n_hc = length(collect(eachmatch(r"HC\b", body_text)))
    n_cat1 = length(collect(eachmatch(r"Cat\.\s*1\b"i, body_text)))

    return ps, vert, gradient, n_hc, n_cat1
end


"""
    getpcs_stage_results(pcs_slug, year, stage_number; kwargs...) -> DataFrame

Fetch PCS results for a single stage. Same schema as `getpcsraceresults`.

URL pattern: `https://www.procyclingstats.com/race/{slug}/{year}/stage-{n}`
"""
function getpcs_stage_results(
    pcs_slug::String,
    year::Int,
    stage_number::Int;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE,
)
    pageurl = "https://www.procyclingstats.com/race/$pcs_slug/$year/stage-$stage_number"

    function fetch_stage_results(url, params)
        _empty() = DataFrame(
            position=Int[], rider=String[], team=String[],
            riderkey=String[], in_breakaway=Bool[],
            breakaway_km=Union{Float64,Missing}[],
        )

        response = try
            HTTP.get(url, ["User-Agent" => "Mozilla/5.0 (compatible; VelogamesBot/1.0)"])
        catch e
            if e isa HTTP.Exceptions.StatusError
                @warn "HTTP $(e.status) for $url — caching empty result"
                return _empty()
            end
            error("Failed to fetch $url: $e")
        end
        page = Gumbo.parsehtml(String(response.body))
        tables = collect(eachmatch(sel"table", page.root))
        isempty(tables) && return _empty()
        rows = collect(eachmatch(sel"tr", tables[1]))[2:end]

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

        isempty(riders) && return _empty()

        result = DataFrame(
            position=positions, rider=riders, team=teams,
            riderkey=createkey.(riders),
            in_breakaway=falses(length(riders)),
            breakaway_km=Vector{Union{Float64,Missing}}(fill(missing, length(riders))),
        )
        result = filter(row -> !isempty(row.riderkey), result)
        result = unique(result, :riderkey)
        return result[:, [:position, :rider, :team, :riderkey, :in_breakaway, :breakaway_km]]
    end

    params = Dict("slug" => pcs_slug, "year" => string(year), "stage" => string(stage_number))
    return cached_fetch(
        fetch_stage_results, pageurl, params;
        cache_config=cache_config, force_refresh=force_refresh,
    )
end

"""
    getpcs_all_stage_results(pcs_slug, year, n_stages; kwargs...) -> Dict{Int, DataFrame}

Fetch PCS results for all stages. Returns a Dict mapping stage number to results.
Skips stages that fail to fetch.
"""
function getpcs_all_stage_results(
    pcs_slug::String,
    year::Int,
    n_stages::Int;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE,
)
    results = Dict{Int,DataFrame}()
    for s in 1:n_stages
        try
            df = getpcs_stage_results(pcs_slug, year, s;
                force_refresh=force_refresh, cache_config=cache_config)
            if nrow(df) > 0
                results[s] = df
            end
        catch e
            @warn "Failed to fetch stage $s results: $e"
        end
    end
    return results
end
