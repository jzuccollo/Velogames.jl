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
            has_points = any(occursin("point", c) || occursin("score", c) for c in cols_lower)
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
        error("Table has suspiciously few rows ($(nrow(riderdf))) from $pageurl. " *
              "Check the URL in your browser.")
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
    rename!(
        riderdf,
        lowercase.(replace.(names(riderdf), " " => "", "#" => "rank"))
    )

    # rename score to points if it exists
    if hasproperty(riderdf, :score)
        rename!(riderdf, :score => :points)
    end

    # cast the cost and rank columns to Int64 if they exist
    for col in [:cost, :rank]
        if hasproperty(riderdf, col)
            riderdf[!, col] = parse.(Int64, riderdf[!, col])
        end
    end

    # cast points column to number
    riderdf[!, :points] = parse.(Float64, riderdf[!, :points])

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
## `getpcsraceriders`

This function downloads and parses the rider data from the PCS website for a specified race.

The function returns a DataFrame with the following columns:

    * `name` - the name of the rider
    * `team` - the team the rider rides for
    * `placing` - the placing of the rider on the race
    * `score` - the number of points scored by the rider
"""
function getpcsraceriders(pageurl::String)
    riderdf = scrape_tables(pageurl)

    return riderdf

end

"""
## `getpcsranking`

Downloads and parses rider rankings for a specific category from PCS.

Uses alias-based column resolution (see `PCS_RIDER_ALIASES` etc. in pcs_scraper.jl)
so that PCS column renames are handled by adding one string to the alias list.

Returns a DataFrame with columns: `rank`, `rider`, `team`, `points`, `riderkey`.
"""
function getpcsranking(gender::String, category::String;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    @assert gender in ["we", "me"] "Invalid gender: $gender. Must be 'we' or 'me'."
    @assert category in ["individual", "one-day-races", "gc-ranking", "sprinters", "climbers", "time-trial"] "Invalid category: $category."

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
            "Add the new column name to PCS_RIDER_ALIASES in src/pcs_scraper.jl")
        points_col === nothing && error(
            "No points column found in PCS rankings from $url. " *
            "Columns: $(names(df)). " *
            "Add the new column name to PCS_POINTS_ALIASES in src/pcs_scraper.jl")

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
    return cached_fetch(fetch_pcs_ranking, rankingurl, params;
        cache_config=cache_config, force_refresh=force_refresh)
end

"""
## `getpcsraceranking`

Downloads and parses rider rankings for a specific race from PCS
(typically a startlist-quality page).

Uses alias-based column resolution for resilience to PCS changes.

Returns a DataFrame with columns including `rider`, `pcsrank`, `pcspoints`, `riderkey`.
"""
function getpcsraceranking(pageurl::String;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    function fetch_race_ranking(url, params)
        df = scrape_pcs_table(url)

        rider_col = find_column(df, PCS_RIDER_ALIASES)
        points_col = find_column(df, PCS_POINTS_ALIASES)
        rank_col = find_column(df, ["pcs-ranking", "pcsranking", "pcsrank",
                                     PCS_RANK_ALIASES...])
        team_col = find_column(df, PCS_TEAM_ALIASES)

        rider_col === nothing && error(
            "No rider column found in PCS race ranking from $url. " *
            "Columns: $(names(df)). " *
            "Add the new column name to PCS_RIDER_ALIASES in src/pcs_scraper.jl")

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

    return cached_fetch(fetch_race_ranking, pageurl, Dict();
        cache_config=cache_config, force_refresh=force_refresh)
end


"""
## `getvgriders`

This function downloads and parses the rider listing for a specific race from the Velogames website.

Returns a DataFrame with cached data retrieval.
"""
function getvgriders(pageurl::String;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE,
    verbose::Bool=true)

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

    return cached_fetch(fetch_vg_data, pageurl, Dict();
        cache_config=cache_config, force_refresh=force_refresh, verbose=verbose)
end


"""
## `getpcsriderpts`

This function downloads and parses the rider points for a specific rider from the PCS website.

Returns a DataFrame with columns: rider, oneday, gc, tt, sprint, climber, riderkey
"""
function getpcsriderpts(ridername::String;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    regularisedname = normalisename(ridername)
    pageurl = "https://www.procyclingstats.com/rider/" * regularisedname

    function fetch_rider_pts(url, params)
        page = parsehtml(read(Downloads.download(url), String))
        # Try new PCS structure: .xvalue class
        value_elements = eachmatch(sel".xvalue", page.root)
        if length(value_elements) < 5
            # Format rider name for suggestions
            name_with_spaces = replace(ridername, "-" => " ")
            name_titlecase = titlecase(name_with_spaces)

            error("""
            ❌ PCS scraping failed for: $ridername

            Expected 5 point values (One-day, GC, TT, Sprint, Climber)
            Found: $(length(value_elements)) values

            🔍 Troubleshooting:

            1. Check the page manually: $url

            2. Try alternative name spellings:
               - "$name_with_spaces"
               - "$name_titlecase"
               - Check rider's full name on PCS

            3. If the page structure changed:
               - The CSS selector may be outdated
               - Current selector: ".xvalue"
               - Update in: src/get_data.jl (line ~210)

            4. If the rider doesn't exist on PCS:
               - Add to exclude_riders list in your notebook
               - Or accept missing PCS data (will use VG data only)

            💡 Quick fix: Set force_refresh=true if this is a caching issue
            """)
        end
        rawpts = map(x -> parse(Int, nodeText(x)), value_elements[1:5])
        return DataFrame(
            rider=[ridername],
            oneday=[rawpts[1]],
            gc=[rawpts[2]],
            tt=[rawpts[3]],
            sprint=[rawpts[4]],
            climber=[rawpts[5]],
            riderkey=[createkey(ridername)]
        )
    end

    params = Dict("rider" => ridername)
    return cached_fetch(fetch_rider_pts, pageurl, params;
        cache_config=cache_config, force_refresh=force_refresh)
end


"""
## `getpcsriderhistory`

This function downloads and parses the rider points for a specific rider for each year they are active on the PCS website.

Returns a DataFrame with cached data retrieval.
"""
function getpcsriderhistory(ridername::String;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    regularisedname = normalisename(ridername)
    pageurl = "https://www.procyclingstats.com/rider/" * regularisedname

    function fetch_rider_history(url, params)
        riderpts = DataFrame(scrape_tables(url)[2])
        rename!(riderpts, [:year, :points, :rank])
        return riderpts
    end

    params = Dict("rider" => ridername)
    return cached_fetch(fetch_rider_history, pageurl, params;
        cache_config=cache_config, force_refresh=force_refresh)
end

"""
## `getodds`

This function retrieves the odds listings from the Betfair website.

Returns a DataFrame with cached data retrieval.
"""
function getodds(pageurl::String;
    headers::Dict=Dict("User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3"),
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    function fetch_odds(url, params)
        used_headers = get(params, "headers", headers)

        oddspage = HTTP.get(url, used_headers)
        oddshtml = Gumbo.parsehtml(String(oddspage.body))

        selectors = [".runner-info", ".ui-display-fraction-price"]
        ridertable = [eachmatch(Selector(s), oddshtml.root) for s in selectors]
        ridernames = [Cascadia.nodeText(r) for r in ridertable[1]]
        riderodds = [Cascadia.nodeText(r) for r in ridertable[2]]

        # Process odds
        riderodds = replace.(riderodds, "\n" => "")
        riderodds = map(x -> 1 + parse(Float64, split(x, "/")[1]) / parse(Float64, split(x, "/")[2]), riderodds)

        betfairodds = DataFrame(rider=ridernames, odds=riderodds)
        betfairodds.rider = replace.(betfairodds.rider, "Tom Pidcock" => "Thomas Pidcock")
        betfairodds.riderkey = map(x -> createkey(x), betfairodds.rider)

        @assert length(unique(betfairodds.riderkey)) == length(betfairodds.riderkey) "Rider keys are not unique"

        return betfairodds
    end

    # Include headers in cache key since they affect the result
    params = Dict("headers" => headers)
    return cached_fetch(fetch_odds, pageurl, params;
        cache_config=cache_config, force_refresh=force_refresh)
end

"""
## `getvgracepoints`

This function retrieves the points scored by riders for a single event.

Returns a DataFrame with cached data retrieval.
"""
function getvgracepoints(pageurl::String;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    function fetch_race_points(url, params)
        page = HTTP.get(url)
        pagehtml = Gumbo.parsehtml(String(page.body))

        resultsdf = DataFrame(rider=[], team=[], score=[])

        for entry in eachmatch(Selector("#users li"), pagehtml.root)
            rider = nodeText(eachmatch(Selector(".name"), entry)[1])
            pointsstr = nodeText(eachmatch(Selector(".born"), entry)[1])
            points = parse(Int, match(r"\d+", pointsstr).match)
            team = nodeText(eachmatch(Selector(".born"), entry)[2])

            rowdf = DataFrame(rider=[rider], team=[team], score=[points])
            resultsdf = vcat(resultsdf, rowdf)
        end

        resultsdf.riderkey = map(x -> createkey(x), resultsdf.rider)
        return resultsdf
    end

    return cached_fetch(fetch_race_points, pageurl, Dict();
        cache_config=cache_config, force_refresh=force_refresh)
end

"""
## `getpcsriderpts_batch`

Batch version - get points for multiple riders efficiently.
Returns a DataFrame with all riders' points, including rows with missing values for failed requests.
"""
function getpcsriderpts_batch(ridernames::Vector{String};
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    all_pts = DataFrame()

    for rider in ridernames
        try
            rider_pts = getpcsriderpts(rider; force_refresh=force_refresh, cache_config=cache_config)
            all_pts = vcat(all_pts, rider_pts)
        catch e
            @warn "Failed to get points for $rider: $e"
            # Add row with missing values
            missing_row = DataFrame(
                rider=[rider],
                oneday=[missing],
                gc=[missing],
                tt=[missing],
                sprint=[missing],
                climber=[missing],
                riderkey=[createkey(rider)]
            )
            all_pts = vcat(all_pts, missing_row)
        end
    end

    # Remove any empty column name (fixes join issues)
    if "" in names(all_pts)
        select!(all_pts, Not(""))
    end

    return all_pts
end