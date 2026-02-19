"""
Extended PCS (ProCyclingStats) scraping functions for race-specific historical data.

Uses `scrape_pcs_table()` and `find_column()` from pcs_scraper.jl for resilient
column resolution — when PCS renames a column, add one string to the alias list.
"""

"""
## `getpcsraceresults`

Downloads and parses the finishing results for a specific race edition from the PCS website.

URL pattern: `https://www.procyclingstats.com/race/{slug}/{year}`

Uses `scrape_pcs_table(url; min_rows=20)` to skip the 10-row summary table and
get the full results. Uses `find_column()` with alias lists for resilient column matching.

Returns a DataFrame with the following columns:

    * `position` - finishing position (Int); DNF/DNS riders are assigned position 999
    * `rider` - rider name
    * `team` - team name
    * `riderkey` - normalised rider key created via `createkey(rider)`

# Arguments
- `pcs_race_slug` - the PCS race slug, e.g. `"tour-de-france"` or `"liege-bastogne-liege"`
- `year` - the edition year, e.g. `2023`

# Keyword Arguments
- `force_refresh` - bypass the cache and fetch fresh data (default: `false`)
- `cache_config` - cache configuration (default: `DEFAULT_CACHE`)

# Example
```julia
getpcsraceresults("tour-de-france", 2023)
```
"""
function getpcsraceresults(pcs_race_slug::String, year::Int;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    # The main race page only shows a 10-row summary; full results are at /result
    pageurl = "https://www.procyclingstats.com/race/$(pcs_race_slug)/$(year)/result"

    function fetch_race_results(url, params)
        # Use min_rows=20 to skip any small summary/nav tables
        df = scrape_pcs_table(url; min_rows=20)

        rider_col = find_column(df, PCS_RIDER_ALIASES)
        rank_col = find_column(df, PCS_RANK_ALIASES)
        team_col = find_column(df, PCS_TEAM_ALIASES)

        rider_col === nothing && error(
            "No rider column found in race results from $url. " *
            "Columns: $(names(df)). " *
            "Add the new column name to PCS_RIDER_ALIASES in src/pcs_scraper.jl")

        # Build standardized result DataFrame
        result = DataFrame()

        # PCS full results pages concatenate the team name onto the rider name
        # (e.g. "Tratnik JanTeam Visma | Lease a Bike"). Clean by stripping
        # the team suffix when we have a separate team column.
        raw_riders = String.(df[!, rider_col])
        if team_col !== nothing
            raw_teams = String.(df[!, team_col])
            result.rider = map(zip(raw_riders, raw_teams)) do (r, t)
                if !isempty(t) && endswith(r, t)
                    # Use ncodeunits for byte-safe slicing of UTF-8 strings
                    cut = ncodeunits(r) - ncodeunits(t)
                    return String(strip(String(codeunits(r)[1:cut])))
                end
                return r
            end
        else
            result.rider = raw_riders
        end

        # Parse position values; non-numeric strings (DNF, DNS, OTL, DSQ,
        # ABD, etc.) become 999 to keep them in the DataFrame but
        # distinguishable from finishers.
        if rank_col !== nothing
            result.position = map(df[!, rank_col]) do val
                s = strip(string(val))
                parsed = tryparse(Int, s)
                parsed !== nothing ? parsed : 999
            end
        else
            @warn "No position column found in race results from $url; position will be set to 999"
            result.position = fill(999, nrow(df))
        end

        result.team = team_col !== nothing ? String.(df[!, team_col]) : fill("", nrow(df))
        result.riderkey = createkey.(result.rider)

        # Drop rows with empty riderkey
        result = filter(row -> !isempty(row.riderkey), result)
        result = unique(result, :riderkey)

        return result[:, [:position, :rider, :team, :riderkey]]
    end

    params = Dict("slug" => pcs_race_slug, "year" => string(year))
    return cached_fetch(fetch_race_results, pageurl, params;
        cache_config=cache_config, force_refresh=force_refresh)
end


"""
## `getpcsracestartlist`

Downloads and parses the confirmed startlist (with PCS quality/ranking data) for a
specific race edition from the PCS website.

The function targets the startlist-quality page, which exposes a well-structured table:

    URL: `https://www.procyclingstats.com/race/{slug}/{year}/startlist/startlist-quality`

Uses `scrape_pcs_table()` and `find_column()` for resilient column resolution.

Returns a DataFrame with the following columns:

    * `rider` - rider name
    * `team` - team name
    * `pcsrank` - PCS individual ranking (Int; unranked riders are assigned 9999)
    * `pcspoints` - PCS ranking points (Float64)
    * `riderkey` - normalised rider key created via `createkey(rider)`

# Arguments
- `pcs_race_slug` - the PCS race slug, e.g. `"tour-de-france"`
- `year` - the edition year, e.g. `2024`

# Keyword Arguments
- `force_refresh` - bypass the cache and fetch fresh data (default: `false`)
- `cache_config` - cache configuration (default: `DEFAULT_CACHE`)

# Example
```julia
getpcsracestartlist("tour-de-france", 2024)
```
"""
function getpcsracestartlist(pcs_race_slug::String, year::Int;
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    pageurl = "https://www.procyclingstats.com/race/$(pcs_race_slug)/$(year)/startlist/startlist-quality"

    function fetch_startlist(url, params)
        df = scrape_pcs_table(url)

        rider_col = find_column(df, PCS_RIDER_ALIASES)
        points_col = find_column(df, PCS_POINTS_ALIASES)
        rank_col = find_column(df, ["pcs-ranking", "pcsranking", "pcsrank",
                                     PCS_RANK_ALIASES...])
        team_col = find_column(df, PCS_TEAM_ALIASES)

        rider_col === nothing && error(
            "No rider column found in startlist from $url. " *
            "Columns: $(names(df)). " *
            "Add the new column name to PCS_RIDER_ALIASES in src/pcs_scraper.jl")

        # Build standardized result DataFrame
        result = DataFrame()
        result.rider = String.(df[!, rider_col])

        # PCS ranking (may be "pcs-ranking", "rank", "#", etc.)
        result.pcsrank = if rank_col !== nothing
            map(df[!, rank_col]) do val
                s = strip(string(val))
                parsed = tryparse(Int, s)
                parsed !== nothing ? parsed : 9999
            end
        else
            @warn "No PCS ranking column found in startlist from $url; pcsrank will be 9999"
            fill(9999, nrow(df))
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

        # Drop rows with empty riderkey
        result = filter(row -> !isempty(row.riderkey), result)
        result = unique(result, :riderkey)

        return result[:, [:rider, :team, :pcsrank, :pcspoints, :riderkey]]
    end

    params = Dict("slug" => pcs_race_slug, "year" => string(year))
    return cached_fetch(fetch_startlist, pageurl, params;
        cache_config=cache_config, force_refresh=force_refresh)
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
function getpcsracehistory(pcs_race_slug::String, years::Vector{Int};
    force_refresh::Bool=false,
    cache_config::CacheConfig=DEFAULT_CACHE)

    all_results = DataFrame()

    for year in years
        try
            year_df = getpcsraceresults(pcs_race_slug, year;
                force_refresh=force_refresh, cache_config=cache_config)
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
    col_order = [:year, :position, :rider, :team, :riderkey]
    present_core = [c for c in col_order if c in Symbol.(names(all_results))]
    extra_cols = [c for c in Symbol.(names(all_results)) if c ∉ col_order]
    all_results = all_results[:, [present_core; extra_cols]]

    return all_results
end
