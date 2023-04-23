using DataFrames
using Cascadia
using Gumbo
using CategoricalArrays
using Unicode

"""
## `getvelogamesriders`

This function downloads and parses the rider data from the Velogames website.

The function returns a DataFrame with the following columns:

* `name` - the name of the rider
* `team` - the team the rider rides for
* `startlist` - the startlists the rider is on
* `cost` - the cost of the rider
* `score` - the number of points scored by the rider in this competition
* `value` - the number of points scored per unit cost
"""
function getvelogamesriders(pageurl::String)
    page = parsehtml(read(download(pageurl), String))
    rider_table = eachmatch(sel"table", page.root)[1]
    rider_names = String[]
    rider_startlist = String[]
    rider_team = String[]
    rider_costs = Int64[]
    rider_scores = Int64[]
    for rider_row in eachmatch(sel"tr", rider_table)[2:end]
        rider_cells = eachmatch(sel"td", rider_row)
        push!(rider_names, text(rider_cells[2]))
        push!(rider_startlist, text(rider_cells[4]))
        push!(rider_team, text(rider_cells[3]))
        push!(rider_scores, parse(Int64, text(rider_cells[5])))
        push!(rider_costs, parse(Int64, text(rider_cells[6])))
    end
    rider_df = DataFrame(
        name=rider_names,
        team=categorical(rider_team),
        startlist=categorical(rider_startlist),
        cost=rider_costs,
        score=rider_scores,
        riderkey=create_key(rider_names)
    )

    # add a column of the score per cost
    rider_df.value = rider_df.score ./ rider_df.cost

    # check that the riderkey is unique
    if length(unique(rider_df.riderkey)) != length(rider_df.riderkey)
        error("Rider keys are not unique")
    end

    return rider_df

end


"""
## `getpcsriders`

This function downloads and parses the rider data from the PCS website for a specified race.

The function returns a DataFrame with the following columns:

    * `name` - the name of the rider
    * `team` - the team the rider rides for
    * `placing` - the placing of the rider on the race
    * `score` - the number of points scored by the rider
"""
function getpcsriders(pageurl::String)
    page = parsehtml(read(download(pageurl), String))
    rider_table = eachmatch(sel"table", page.root)[1]
    rider_names = String[]
    rider_team = String[]
    rider_placings = Int64[]
    rider_scores = Int64[]
    for rider_row in eachmatch(sel"tr", rider_table)[2:end]
        rider_cells = eachmatch(sel"td", rider_row)
        push!(rider_names, text(rider_cells[2]))
        push!(rider_team, text(rider_cells[3]))
        push!(rider_placings, parse(Int64, text(rider_cells[4])))
        push!(rider_scores, parse(Int64, text(rider_cells[5])))
    end
    rider_df = DataFrame(
        name=rider_names,
        team=categorical(rider_team),
        placing=rider_placings,
        score=rider_scores
    )

    return rider_df

end

"""
## `getpcsranking`

This function downloads and parses the rider rankings for a specific category from the PCS website.

The function returns a DataFrame with the following columns:

    * `name` - the name of the rider
    * `team` - the team the rider rides for
    * `rank` - the rank of the rider in the category
    * `score` - the number of points scored by the rider
"""
function getpcsranking(category::Symbol)
    rankingurl = (
        overall="https://www.procyclingstats.com/rankings.php",
        oneday="https://www.procyclingstats.com/rankings/me/one-day-races",
        gc="https://www.procyclingstats.com/rankings/me/gc-ranking",
        sprint="https://www.procyclingstats.com/rankings/me/sprinters",
        mountain="https://www.procyclingstats.com/rankings/me/climbers",
        tt="https://www.procyclingstats.com/rankings/me/time-trial",
    )

    # check that the category is valid
    if !(category in keys(rankingurl))
        error("Invalid category: $category")
    end

    # download the page and parse the table
    page = parsehtml(read(download(rankingurl[category]), String))
    rider_table = eachmatch(sel"table", page.root)[1]

    # parse the table to a DataFrame
    rider_rank = Int64[]
    rider_team = String[]
    rider_name = String[]
    rider_points = Int64[]

    for rider_row in eachmatch(Selector("tr"), rider_table)[2:end]
        rider_cells = eachmatch(Selector("td"), rider_row)
        push!(rider_name, text(rider_cells[4]))
        push!(rider_team, text(rider_cells[5]))
        push!(rider_rank, parse(Int64, text(rider_cells[1])))
        push!(rider_points, parse(Int64, text(rider_cells[6])))
    end

    rider_df = DataFrame(
        name=rider_name,
        team=categorical(rider_team),
        rank=rider_rank,
        points=rider_points,
        riderkey=create_key(rider_name)
    )

    # check that the riderkey is unique
    if length(unique(rider_df.riderkey)) != length(rider_df.riderkey)
        error("Rider keys are not unique")
    end

    return rider_df
end

"""
`create_key` creates a unique key for each rider based on their name.
"""
create_key(arr) =
    map(arr) do x
        s = string(x)
        s = Unicode.normalize(s, stripmark=true, stripcc=true, casefold=true)
        s = replace(s, r"[^a-zA-Z0-9_]" => "")
        s = join(sort(collect(s)))
    end