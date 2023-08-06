"""
## `gettable`

This function downloads and parses the rider data from the Velogames and PCS websites.

The function returns a DataFrame with the columns of the first table on the page. It also adds a (hopefully) unique key for each rider based on their name.
"""
function gettable(pageurl::String)
    page = scrape_tables(pageurl)
    rider_df = DataFrame(page[1])

    # lowercase the column names and remove spaces
    rename!(rider_df, lowercase.(replace.(names(rider_df), " " => "", "#" => "rank")))
    # rename score to points if it exists
    if hasproperty(rider_df, :score)
        rename!(rider_df, :score => :points)
    end
    # cast the cost and rank columns to Int64 if they exist
    for col in [:cost, :rank]
        if hasproperty(rider_df, col)
            rider_df[!, col] = parse.(Int64, rider_df[!, col])
        end
    end
    # cast points column to number
    rider_df[!, :points] = parse.(Float64, rider_df[!, :points])

    # add a riderkey column based on the name
    rider_df.riderkey = map(x -> create_key(x), rider_df.rider)
    # check that the riderkey is unique
    @assert length(unique(rider_df.riderkey)) == length(rider_df.riderkey) "Rider keys are not unique"

    return rider_df
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
    rider_df = scrape_tables(pageurl)

    return rider_df

end

"""
## `getpcsranking`

This function downloads and parses the rider rankings for a specific category from the PCS website.

The function returns a DataFrame with the following columns:

    * `rider` - the name of the rider
    * `team` - the team the rider rides for
    * `rank` - the rank of the rider in the category
    * `points` - the number of PCS points scored by the rider
    * `riderkey` - a unique key for each rider based on their name
"""
function getpcsranking(gender::String, category::String)
    # check gender in me/we
    @assert gender in ["we", "me"] "Invalid argument: $gender. Must be one of 'we or 'me'."
    # check category
    @assert category in ["individual", "one-day-races", "gc-ranking", "sprinters", "climbers", "time-trial"] "Invalid argument: $category. Must be one of 'individual', 'one-day-races', 'gc-ranking', 'sprinters', 'climbers', 'time-trial'."

    # build the ranking url
    base_url = "https://www.procyclingstats.com/rankings/"
    ranking_url = joinpath(base_url, gender, category)

    # download the page and parse the table
    page = gettable(ranking_url)

    # filter to rank, rider, team, and points
    rider_df = page[:, [:rank, :rider, :team, :points, :riderkey]]

    return rider_df
end


"""
## `getvgriders`

This function downloads and parses the rider listing for a specific race from the Velogames website.

The function returns a DataFrame with the following columns:

    * `name` - the name of the rider
    * `team` - the team the rider rides for
    * `rank` - the rank of the rider in the category
    * `score` - the number of points scored by the rider
"""
function getvgriders(pageurl::String)
    # download the page and parse the table
    rider_df = gettable(pageurl)

    # normalise class data, if it exists
    if hasproperty(rider_df, :class)
        # lowercase the class column and remove spaces
        rename!(rider_df, :class => :class_raw)
        rider_df.class = lowercase.(replace.(rider_df.class_raw, " " => ""))
        for class in unique(rider_df.class)
            rider_df[!, class] = rider_df.class .== class
        end
    end

    # calculate the value of the rider
    rider_df.value = rider_df.points ./ rider_df.cost

    return rider_df
end


"""
## `getpcsriderpts`

This function downloads and parses the rider points for a specific rider from the PCS website.

It returns a Dict with the following values:

    * `oneday` - the points for one day races
    * `gc` - the points for general classification
    * `tt` - the points for time trials
    * `sprint` - the points for sprints
    * `climber` - the points for climbers
"""
function getpcsriderpts(rider_name::String)
    regularised_name = normalise_name(rider_name)
    pageurl = "https://www.procyclingstats.com/rider/" * regularised_name

    page = parsehtml(read(download(pageurl), String))
    rider_table = eachmatch(sel".pnt", page.root)
    raw_pts = map(x -> parse(Int, x[1].text), rider_table)
    rider_pts = Dict(zip(["oneday", "gc", "tt", "sprint", "climber"], raw_pts))
    return Dict(rider_name => rider_pts)
end


"""
## `getpcsriderhistory`

This function downloads and parses the rider points for a specific rider for each year they are active on the PCS website.

It returns a DataFrame with a row for each year the rider is active on the PCS website and the following columns:

    * `year` - the year the points are for
    * `points` - the total points scored by the rider in that year
    * `rank` - the rank of the rider in that year
"""
function getpcsriderhistory(rider_name::String)
    regularised_name = normalise_name(rider_name)
    pageurl = "https://www.procyclingstats.com/rider/" * regularised_name

    rider_pts = DataFrame(scrape_tables(pageurl)[2])
    rename!(rider_pts, [:year, :points, :rank])
    return rider_pts
end

"""
## `getodds`

This function retrieves the odds listings from the Betfair website.

It returns a DataFrame with the following columns:

    * `name` - the name of the rider
    * `odds` - the odds for the rider
"""
function getodds(pageurl::String)
    # download the page and parse the table
    oddspage = HTTP.get(pageurl)
    oddshtml = Gumbo.parsehtml(String(oddspage.body))

    selectors = [".runner-info", ".ui-display-fraction-price"]
    ridertable = [eachmatch(
        Selector(s),
        oddshtml.root
    ) for s in selectors]
    ridernames = [Cascadia.nodeText(r) for r in ridertable[1]]
    riderodds = [Cascadia.nodeText(r) for r in ridertable[2]]

    # strip newlines from fractional odds strings
    riderodds = replace.(riderodds, "\n" => "")
    # calculate decimal odds from strings of the form "1/2"
    riderodds = map(x -> parse(Float64, split(x, "/")[1]) / parse(Float64, split(x, "/")[2]), riderodds)

    betfair_odds = DataFrame(rider=ridernames, odds=riderodds)

    # add a riderkey column based on the name
    betfair_odds.riderkey = map(x -> create_key(x), betfair_odds.rider)
    # check that the riderkey is unique
    @assert length(unique(betfair_odds.riderkey)) == length(betfair_odds.riderkey) "Rider keys are not unique"

    return betfair_odds
end
