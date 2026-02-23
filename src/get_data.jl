"""
## `gettable`

Downloads and parses rider data from a **VeloGames** page. Uses VG-specific
heuristics to select the right table (looks for rider/points/cost columns)
and applies VG-specific column processing via `process_vg_table()`.

For PCS pages, use `scrape_pcs_table()` from pcs_scraper.jl instead.
"""
function gettable(pageurl::String)
    tables = scrape_html_tables(pageurl)

    # Try to find the table with VG rider data using heuristics
    riderdf = nothing
    for (i, df) in enumerate(tables)
        try
            cols_lower = lowercase.(names(df))
            has_rider = any(occursin("rider", c) || occursin("name", c) for c in cols_lower)
            has_points =
                any(occursin("point", c) || occursin("score", c) for c in cols_lower)
            has_cost = any(occursin("cost", c) || occursin("price", c) for c in cols_lower)
            reasonable_size = nrow(df) >= 10 && nrow(df) <= 500

            if has_rider && (has_points || has_cost) && reasonable_size
                @debug "Using table $i from $pageurl ($(nrow(df)) rows)"
                riderdf = df
                break
            end
        catch e
            @debug "Failed to check table $i" exception=e
            continue
        end
    end

    # Fallback to first table if heuristics fail
    if riderdf === nothing
        @warn "Couldn't identify rider table using heuristics, using first table from $pageurl"
        riderdf = tables[1]
    end

    if nrow(riderdf) < 5
        error(
            "Table has suspiciously few rows ($(nrow(riderdf))) from $pageurl. " *
            "Check the URL in your browser.",
        )
    end

    return process_vg_table(riderdf)
end


"""
    process_vg_table(riderdf::DataFrame) -> DataFrame

VeloGames-specific table processing. Lowercases column names, renames score→points,
casts cost/rank/points to numeric types, and adds a riderkey column.

This is for VG pages only. PCS pages use `find_column()` + caller-specific processing.
"""
function process_vg_table(riderdf::DataFrame)
    # lowercase the column names and remove spaces
    rename!(riderdf, lowercase.(replace.(names(riderdf), " " => "", "#" => "rank")))

    # rename score to points if it exists
    if hasproperty(riderdf, :score)
        rename!(riderdf, :score => :points)
    end

    # cast the cost and rank columns to Int64 if they exist
    for col in [:cost, :rank]
        if hasproperty(riderdf, col)
            riderdf[!, col] = [
                let v = tryparse(Int64, string(x))
                    v === nothing ? ((@warn "Cannot parse $col value '$x' as Int"; missing)) : v
                end for x in riderdf[!, col]
            ]
        end
    end

    # cast points column to number
    riderdf[!, :points] = [
        let v = tryparse(Float64, string(x))
            v === nothing ? 0.0 : v
        end for x in riderdf[!, :points]
    ]

    # Process 'selected' column as numeric proportion, if it exists
    if hasproperty(riderdf, :selected)
        riderdf.selected = [
            try
                s = strip(s)
                if occursin("%", s)
                    parse(Float64, replace(s, "%" => "")) / 100
                elseif tryparse(Float64, s) !== nothing
                    parse(Float64, s)
                else
                    missing
                end
            catch
                missing
            end for s in riderdf.selected
        ]
    end

    # add a riderkey column based on the name
    riderdf.riderkey = map(x -> createkey(x), riderdf.rider)

    # drop duplicate riderkeys
    riderdf = unique(riderdf, :riderkey)

    # Remove any empty column name (fixes join issues)
    if "" in names(riderdf)
        select!(riderdf, Not(""))
    end

    # check that the riderkey is unique
    @assert length(unique(riderdf.riderkey)) == length(riderdf.riderkey) "Rider keys are not unique"

    return riderdf
end


"""
## `getpcsranking`

Downloads and parses rider rankings for a specific category from PCS.

Uses alias-based column resolution (see `PCS_RIDER_ALIASES` etc. in pcs_scraper.jl)
so that PCS column renames are handled by adding one string to the alias list.

Returns a DataFrame with columns: `rank`, `rider`, `team`, `points`, `riderkey`.
"""
function getpcsranking(
    gender::String,
    category::String;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)

    @assert gender in ["we", "me"] "Invalid gender: $gender. Must be 'we' or 'me'."
    @assert category in [
        "individual",
        "one-day-races",
        "gc-ranking",
        "sprinters",
        "climbers",
        "time-trial",
    ] "Invalid category: $category."

    baseurl = "https://www.procyclingstats.com/rankings/"
    rankingurl = joinpath(baseurl, gender, category)

    function fetch_pcs_ranking(url, params)
        df = scrape_pcs_table(url)

        rider_col = find_column(df, PCS_RIDER_ALIASES)
        points_col = find_column(df, PCS_POINTS_ALIASES)
        rank_col = find_column(df, PCS_RANK_ALIASES)
        team_col = find_column(df, PCS_TEAM_ALIASES)

        rider_col === nothing && error(
            "No rider column found in PCS rankings from $url. " *
            "Columns: $(names(df)). " *
            "Add the new column name to PCS_RIDER_ALIASES in src/pcs_scraper.jl",
        )
        points_col === nothing && error(
            "No points column found in PCS rankings from $url. " *
            "Columns: $(names(df)). " *
            "Add the new column name to PCS_POINTS_ALIASES in src/pcs_scraper.jl",
        )

        result = DataFrame()
        result.rider = String.(df[!, rider_col])
        result.points = map(df[!, points_col]) do val
            parsed = tryparse(Float64, strip(string(val)))
            parsed !== nothing ? parsed : 0.0
        end
        result.team = team_col !== nothing ? String.(df[!, team_col]) : fill("", nrow(df))
        result.rank = if rank_col !== nothing
            map(df[!, rank_col]) do val
                parsed = tryparse(Int, strip(string(val)))
                parsed !== nothing ? parsed : 9999
            end
        else
            fill(9999, nrow(df))
        end
        result.riderkey = createkey.(result.rider)
        result = unique(result, :riderkey)

        return result[:, [:rank, :rider, :team, :points, :riderkey]]
    end

    params = Dict("gender" => gender, "category" => category)
    return cached_fetch(
        fetch_pcs_ranking,
        rankingurl,
        params;
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end

"""
## `getpcsraceranking`

Downloads and parses rider rankings for a specific race from PCS
(typically a startlist-quality page).

Uses alias-based column resolution for resilience to PCS changes.

Returns a DataFrame with columns including `rider`, `pcsrank`, `pcspoints`, `riderkey`.
"""
function getpcsraceranking(
    pageurl::String;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)

    function fetch_race_ranking(url, params)
        df = scrape_pcs_table(url)

        rider_col = find_column(df, PCS_RIDER_ALIASES)
        points_col = find_column(df, PCS_POINTS_ALIASES)
        rank_col =
            find_column(df, ["pcs-ranking", "pcsranking", "pcsrank", PCS_RANK_ALIASES...])
        team_col = find_column(df, PCS_TEAM_ALIASES)

        rider_col === nothing && error(
            "No rider column found in PCS race ranking from $url. " *
            "Columns: $(names(df)). " *
            "Add the new column name to PCS_RIDER_ALIASES in src/pcs_scraper.jl",
        )

        result = DataFrame()
        result.rider = String.(df[!, rider_col])
        result.riderkey = createkey.(result.rider)

        # PCS ranking
        result.pcsrank = if rank_col !== nothing
            map(df[!, rank_col]) do val
                s = strip(string(val))
                parsed = tryparse(Int, s)
                parsed !== nothing ? parsed : 1000
            end
        else
            fill(1000, nrow(df))
        end

        # PCS points + tiebreaker from rank
        result.pcspoints = if points_col !== nothing
            map(df[!, points_col]) do val
                val isa Float64 && return val
                parsed = tryparse(Float64, strip(string(val)))
                parsed !== nothing ? parsed : 0.0
            end
        else
            fill(0.0, nrow(df))
        end
        result.pcspoints .+= 1.0 ./ result.pcsrank

        result.team = team_col !== nothing ? String.(df[!, team_col]) : fill("", nrow(df))

        # Drop rows with missing/empty riderkey
        result = filter(row -> !isempty(row.riderkey), result)
        result = unique(result, :riderkey)

        return result
    end

    return cached_fetch(
        fetch_race_ranking,
        pageurl,
        Dict();
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end


"""
## `getvgriders`

This function downloads and parses the rider listing for a specific race from the Velogames website.

Returns a DataFrame with cached data retrieval.
"""
function getvgriders(
    pageurl::String;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
    verbose::Bool = true,
)

    function fetch_vg_data(url, params)
        riderdf = gettable(url)

        # Process class data if it exists
        if hasproperty(riderdf, :class)
            rename!(riderdf, :class => :classraw)
            riderdf.class = lowercase.(replace.(riderdf.classraw, " " => ""))
        end

        # Clean up team names
        if hasproperty(riderdf, :team)
            riderdf.team = unpipe.(riderdf.team)
        end

        # Calculate rider value
        riderdf.value = riderdf.points ./ riderdf.cost

        return riderdf
    end

    return cached_fetch(
        fetch_vg_data,
        pageurl,
        Dict();
        cache_config = cache_config,
        force_refresh = force_refresh,
        verbose = verbose,
    )
end


"""
## `getpcsriderpts`

This function downloads and parses the rider points for a specific rider from the PCS website.

Returns a DataFrame with columns: rider, oneday, gc, tt, sprint, climber, riderkey
"""
function getpcsriderpts(
    ridername::String;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)

    regularisedname = normalisename(ridername)
    pageurl = "https://www.procyclingstats.com/rider/" * regularisedname

    _missing_rider_df() = DataFrame(
        rider = [ridername],
        oneday = Union{Int,Missing}[missing],
        gc = Union{Int,Missing}[missing],
        tt = Union{Int,Missing}[missing],
        sprint = Union{Int,Missing}[missing],
        climber = Union{Int,Missing}[missing],
        riderkey = [createkey(ridername)],
    )

    function fetch_rider_pts(url, params)
        # Handle HTTP errors (400 for bad URL encoding, 404 for missing page).
        # Return missing values so the negative result is cached.
        response = try
            HTTP.get(url, ["User-Agent" => "Mozilla/5.0 (compatible; VelogamesBot/1.0)"])
        catch e
            if e isa HTTP.Exceptions.StatusError && e.status in (400, 403, 404)
                return _missing_rider_df()
            end
            rethrow()
        end

        page = parsehtml(String(response.body))

        # Check for PCS "page not found" (returns HTTP 200 with error page)
        h1_elements = eachmatch(sel"h1", page.root)
        is_not_found =
            any(occursin("not found", lowercase(nodeText(h))) for h in h1_elements)

        value_elements = eachmatch(sel".xvalue", page.root)

        if is_not_found || length(value_elements) < 5
            if !is_not_found && length(value_elements) > 0
                # Page exists but structure is unexpected — likely a PCS redesign
                @warn "PCS page structure may have changed for $ridername: found $(length(value_elements)) .xvalue elements, expected 5. Check $url"
            end
            return _missing_rider_df()
        end

        rawpts = map(x -> parse(Int, nodeText(x)), value_elements[1:5])
        return DataFrame(
            rider = [ridername],
            oneday = [rawpts[1]],
            gc = [rawpts[2]],
            tt = [rawpts[3]],
            sprint = [rawpts[4]],
            climber = [rawpts[5]],
            riderkey = [createkey(ridername)],
        )
    end

    params = Dict("rider" => ridername)
    return cached_fetch(
        fetch_rider_pts,
        pageurl,
        params;
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end


"""
## `getpcsriderhistory`

This function downloads and parses the rider points for a specific rider for each year they are active on the PCS website.

Returns a DataFrame with cached data retrieval.
"""
function getpcsriderhistory(
    ridername::String;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)

    regularisedname = normalisename(ridername)
    pageurl = "https://www.procyclingstats.com/rider/" * regularisedname

    function fetch_rider_history(url, params)
        tables = scrape_html_tables(url)
        riderpts = tables[2]
        rename!(riderpts, [:year, :points, :rank])
        return riderpts
    end

    params = Dict("rider" => ridername)
    return cached_fetch(
        fetch_rider_history,
        pageurl,
        params;
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end

"""
    getodds(market_id; force_refresh=false, cache_config=DEFAULT_CACHE)

Retrieve betting odds from the Betfair Exchange API for a given market ID.

Find the market ID on the Betfair Exchange website: navigate to cycling, find
the race, and extract the market ID from the URL (e.g. "1.127771425").

Returns a DataFrame with columns: `rider`, `odds`, `riderkey`.
Returns an empty DataFrame if `market_id` is empty or the API call fails.
"""
function getodds(
    market_id::String;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    if isempty(market_id)
        return DataFrame(rider = String[], odds = Float64[], riderkey = String[])
    end

    function fetch_betfair_odds(_url, params)
        return betfair_get_market_odds(params["market_id"])
    end

    return cached_fetch(
        fetch_betfair_odds,
        "betfair://market/$market_id",
        Dict("market_id" => market_id);
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end

"""
    get_cycling_oracle(prediction_url; force_refresh=false, cache_config=DEFAULT_CACHE)

Fetch win probability predictions from Cycling Oracle.

Pass the full blog prediction URL, e.g.
`"https://www.cyclingoracle.com/en/blog/omloop-nieuwsblad-2026-prediction"`.

Returns a DataFrame with columns: `rider` (String), `win_prob` (Float64),
`riderkey` (String). Win probabilities are already normalised (sum to ~1).
Returns an empty DataFrame if the URL is empty or parsing fails.
"""
function get_cycling_oracle(
    prediction_url::String;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    if isempty(prediction_url)
        return DataFrame(rider = String[], win_prob = Float64[], riderkey = String[])
    end

    function fetch_oracle(_url, params)
        url = params["prediction_url"]
        response = HTTP.get(
            url,
            ["User-Agent" => "Mozilla/5.0 (compatible; Velogames.jl)"],
        )
        html = String(response.body)

        # Extract embedded JSON: var riders2D = JSON.parse(`[...]`)
        m = match(r"var riders2D = JSON\.parse\(`(.*?)`\)", html)
        if m === nothing
            @warn "Could not find prediction data in Cycling Oracle page: $url"
            return DataFrame(rider = String[], win_prob = Float64[], riderkey = String[])
        end

        data = JSON3.read(m.captures[1])

        names_out = String[]
        probs_out = Float64[]

        for entry in data
            name = String(get(entry, :col1, get(entry, :searchQuery, "")))
            pct_str = String(get(entry, :winPercentage, ""))
            if isempty(name) || isempty(pct_str)
                continue
            end
            # European decimal format: "35,07" -> 35.07 -> 0.3507
            pct = parse(Float64, replace(pct_str, "," => "."))
            if pct > 0.0
                push!(names_out, name)
                push!(probs_out, pct / 100.0)
            end
        end

        if isempty(names_out)
            @warn "No predictions found in Cycling Oracle page: $url"
            return DataFrame(rider = String[], win_prob = Float64[], riderkey = String[])
        end

        # Normalise to sum to 1 (they should already be close)
        total = sum(probs_out)
        if total > 0
            probs_out .= probs_out ./ total
        end

        df = DataFrame(rider = names_out, win_prob = probs_out)
        df.riderkey = map(createkey, df.rider)

        @info "Fetched Cycling Oracle predictions for $(nrow(df)) riders"
        return df
    end

    return cached_fetch(
        fetch_oracle,
        prediction_url,
        Dict("prediction_url" => prediction_url);
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end

"""
## `getvgracepoints`

This function retrieves the points scored by riders for a single event.

Returns a DataFrame with cached data retrieval.
"""
function getvgracepoints(
    pageurl::String;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)

    function fetch_race_points(url, params)
        page = HTTP.get(url)
        pagehtml = Gumbo.parsehtml(String(page.body))

        resultsdf = DataFrame(rider = [], team = [], score = [])

        for entry in eachmatch(Selector("#users li"), pagehtml.root)
            rider = nodeText(eachmatch(Selector(".name"), entry)[1])
            pointsstr = nodeText(eachmatch(Selector(".born"), entry)[1])
            m = match(r"\d+", pointsstr)
            if m === nothing
                @warn "Cannot parse points from '$pointsstr' for rider '$rider'; skipping"
                continue
            end
            points = tryparse(Int, m.match)
            if points === nothing
                @warn "Cannot parse points value '$(m.match)' as Int for rider '$rider'; skipping"
                continue
            end
            team = nodeText(eachmatch(Selector(".born"), entry)[2])

            rowdf = DataFrame(rider = [rider], team = [team], score = [points])
            resultsdf = vcat(resultsdf, rowdf)
        end

        resultsdf.riderkey = map(x -> createkey(x), resultsdf.rider)
        return resultsdf
    end

    return cached_fetch(
        fetch_race_points,
        pageurl,
        Dict();
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
end

"""
## `getpcsriderpts_batch`

Batch version - get points for multiple riders efficiently.
Returns a DataFrame with all riders' points, including rows with missing values for failed requests.
"""
function getpcsriderpts_batch(
    ridernames::Vector{String};
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
)

    all_pts = DataFrame()
    failed_riders = String[]

    for rider in ridernames
        try
            rider_pts = getpcsriderpts(
                rider;
                force_refresh = force_refresh,
                cache_config = cache_config,
            )
            all_pts = vcat(all_pts, rider_pts)
        catch e
            push!(failed_riders, rider)
            # Add row with missing values
            missing_row = DataFrame(
                rider = [rider],
                oneday = [missing],
                gc = [missing],
                tt = [missing],
                sprint = [missing],
                climber = [missing],
                riderkey = [createkey(rider)],
            )
            all_pts = vcat(all_pts, missing_row)
        end
    end

    if !isempty(failed_riders)
        @warn "PCS fetch failed for $(length(failed_riders))/$(length(ridernames)) riders (network/parse errors)" failed_riders
    end

    # Summary of riders not found on PCS (returned missing from cache or fetch)
    n_missing = count(row -> ismissing(row.oneday), eachrow(all_pts))
    if n_missing > 0
        @info "PCS data: $(length(ridernames) - n_missing)/$(length(ridernames)) riders found, $n_missing missing (not on PCS or fetch error)"
    end

    # Remove any empty column name (fixes join issues)
    if "" in names(all_pts)
        select!(all_pts, Not(""))
    end

    return all_pts
end
