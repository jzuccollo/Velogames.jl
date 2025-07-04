"""
## `gettable`

This function downloads and parses the rider data from the Velogames and PCS websites.

The function returns a DataFrame with the columns of the first table on the page. It also adds a (hopefully) unique key for each rider based on their name.
"""
function gettable(pageurl::String)
    page = TableScraper.scrape_tables(pageurl)
    riderdf = DataFrames.DataFrame(page[1])

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

This function downloads and parses the rider rankings for a specific category from the PCS website.

Returns a DataFrame with cached data retrieval.
"""
function getpcsranking(gender::String, category::String;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    # Input validation
    @assert gender in ["we", "me"] "Invalid gender: $gender. Must be 'we' or 'me'."
    @assert category in ["individual", "one-day-races", "gc-ranking", "sprinters", "climbers", "time-trial"] "Invalid category: $category. Must be one of: 'individual', 'one-day-races', 'gc-ranking', 'sprinters', 'climbers', 'time-trial'."

    # Build URL
    baseurl = "https://www.procyclingstats.com/rankings/"
    rankingurl = joinpath(baseurl, gender, category)

    function fetch_pcs_ranking(url, params)
        page = gettable(url)
        return page[:, [:rank, :rider, :team, :points, :riderkey]]
    end

    # Parameters for cache key
    params = Dict("gender" => gender, "category" => category)

    return cached_fetch(fetch_pcs_ranking, rankingurl, params;
        cache_config=cache_config, force_refresh=force_refresh)
end

"""
## `getpcsraceranking`

This function downloads and parses the rider rankings for a specific race from the PCS website.

Returns a DataFrame with cached data retrieval.
"""
function getpcsraceranking(pageurl::String;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    function fetch_race_ranking(url, params)
        # download the page and parse the table
        riderdf = gettable(url)

        # drop any rows with missing or empty values in the riderkey column
        riderdf = dropmissing(riderdf, :riderkey)
        riderdf = filter(row -> !isempty(row.riderkey), riderdf)

        # rename columns
        rename!(riderdf, "pcs-ranking" => :pcsrank)
        rename!(riderdf, "points" => :pcspoints)

        # convert pcsrank to Int64, assigning 1000 if value is "-" or ""
        riderdf[!, :pcsrank] = [x == "-" || x == "" ? 1000 : parse(Int64, x) for x in riderdf[!, :pcsrank]]

        # add 1/pcs-ranking to points to avoid ties
        riderdf[!, :pcspoints] = riderdf[!, :pcspoints] .+ 1 ./ riderdf[!, :pcsrank]

        return riderdf
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
            error("Could not find expected points data structure on PCS page for $ridername")
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