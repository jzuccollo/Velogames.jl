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
    baseurl = "https://www.procyclingstats.com/rankings/"
    rankingurl = joinpath(baseurl, gender, category)

    # download the page and parse the table
    page = gettable(rankingurl)

    # filter to rank, rider, team, and points
    riderdf = page[:, [:rank, :rider, :team, :points, :riderkey]]

    return riderdf
end

"""
## `getpcsraceranking`

This function downloads and parses the rider rankings for a specific race from the PCS website.

The function returns a DataFrame with the following columns:

    * `rider` - the name of the rider
    * `team` - the team the rider rides for
    * `rank` - the rank of the rider in the category
    * `points` - the number of PCS points scored by the rider
    * `riderkey` - a unique key for each rider based on their name
"""
function getpcsraceranking(pageurl::String)
    # download the page and parse the table
    riderdf = gettable(pageurl)

    # rename column pcs-ranking to pcsrank
    rename!(riderdf, "pcs-ranking" => :pcsrank)

    # convert pcs-ranking to Int64
    riderdf[!, :pcsrank] = parse.(Int64, riderdf[!, :pcsrank])

    # add 1/pcs-ranking to points to avoid ties
    riderdf[!, :pcspoints] = riderdf[!, :pcspoints] .+ 1 ./ riderdf[!, :pcsrank]

    return riderdf
end


"""
## `getvgriders`

This function downloads and parses the rider listing for a specific race from the Velogames website.

The function returns a DataFrame with the following columns:

    * `name` - the name of the rider
    * `team` - the team the rider rides for
    * `rank` - the rank of the rider in the category
    * `score` - the number of points scored by the rider
    * `fetchagain` - a boolean indicating whether to fetch the data again
"""
function getvgriders(pageurl::String; fetchagain::Bool=false)
    filename = split(pageurl, "/")[end]
    if fetchagain
        # download the page and parse the table
        riderdf = gettable(pageurl)

        # normalise class data, if it exists
        if hasproperty(riderdf, :class)
            # lowercase the class column and remove spaces
            rename!(riderdf, :class => :classraw)
            riderdf.class = lowercase.(replace.(riderdf.classraw, " " => ""))
            for class in unique(riderdf.class)
                riderdf[!, class] = riderdf.class .== class
            end
        end

        # calculate the value of the rider
        riderdf.value = riderdf.points ./ riderdf.cost

        # save the data to an Arrow file
        Feather.write(filename * ".feather", riderdf)
    else
        # read the data from the file
        riderdf = Feather.read(filename * ".feather")
    end

    return riderdf
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
function getpcsriderpts(ridername::String)
    regularisedname = normalisename(ridername)
    pageurl = "https://www.procyclingstats.com/rider/" * regularisedname

    page = parsehtml(read(download(pageurl), String))
    ridertable = eachmatch(sel".pnt", page.root)
    rawpts = map(x -> parse(Int, x[1].text), ridertable)
    riderpts = Dict(zip(["oneday", "gc", "tt", "sprint", "climber"], rawpts))
    return Dict(ridername => riderpts)
end


"""
## `getpcsriderhistory`

This function downloads and parses the rider points for a specific rider for each year they are active on the PCS website.

It returns a DataFrame with a row for each year the rider is active on the PCS website and the following columns:

    * `year` - the year the points are for
    * `points` - the total points scored by the rider in that year
    * `rank` - the rank of the rider in that year
"""
function getpcsriderhistory(ridername::String)
    regularisedname = normalisename(ridername)
    pageurl = "https://www.procyclingstats.com/rider/" * regularisedname

    riderpts = DataFrame(scrape_tables(pageurl)[2])
    rename!(riderpts, [:year, :points, :rank])
    return riderpts
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
    riderodds = map(x -> 1 + parse(Float64, split(x, "/")[1]) / parse(Float64, split(x, "/")[2]), riderodds)

    betfairodds = DataFrame(rider=ridernames, odds=riderodds)

    # tweak the rider names for better matching with Velogames
    betfairodds.rider = replace.(betfairodds.rider, "Tom Pidcock" => "Thomas Pidcock")

    # add a riderkey column based on the name
    betfairodds.riderkey = map(x -> createkey(x), betfairodds.rider)
    # check that the riderkey is unique
    @assert length(unique(betfairodds.riderkey)) == length(betfairodds.riderkey) "Rider keys are not unique"

    return betfairodds
end

"""
## `getvgracepoints`

This function retrieves the points scored by riders for a single event.

It returns a DataFrame with the following columns:

    * `name` - the name of the rider
    * `team` - the team the rider rides for
    * `score` - the number of points scored by the rider in that race
"""
function getvgracepoints(pageurl::String)
    # download the page and parse the table
    page = HTTP.get(pageurl)
    pagehtml = Gumbo.parsehtml(String(page.body))

    resultsdf = DataFrame(rider=[], team=[], score=[])

    for entry in eachmatch(Selector("#users li"), pagehtml.root)
        rider = nodeText(eachmatch(Selector(".name"), entry)[1])
        pointsstr = nodeText(eachmatch(Selector(".born"), entry)[1])
        points = parse(Int, match(r"\d+", pointsstr).match)
        team = nodeText(eachmatch(Selector(".born"), entry)[2])

        # append the row to the results DataFrame
        rowdf = DataFrame(rider=[rider], team=[team], score=[points])
        resultsdf = vcat(resultsdf, rowdf)
    end

    # add a riderkey column based on the name
    resultsdf.riderkey = map(x -> createkey(x), resultsdf.rider)

    return resultsdf
end