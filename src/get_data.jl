using HTTP, DataFrames, Cascadia, Gumbo, CategoricalArrays, Unicode

const PCS_RANKING_URLS = Dict(
    :overall => "https://www.procyclingstats.com/rankings.php",
    :oneday => "https://www.procyclingstats.com/rankings/me/one-day-races",
    :gc => "https://www.procyclingstats.com/rankings/me/gc-ranking",
    :sprint => "https://www.procyclingstats.com/rankings/me/sprinters",
    :mountain => "https://www.procyclingstats.com/rankings/me/climbers",
    :tt => "https://www.procyclingstats.com/rankings/me/time-trial"
)

const VG_ROWS = Dict(
    :name => "https://www.procyclingstats.com/rankings.php",
    :team => "https://www.procyclingstats.com/rankings/me/one-day-races",
    :startlist => "https://www.procyclingstats.com/rankings/me/gc-ranking",
    :cost => "https://www.procyclingstats.com/rankings/me/sprinters",
    :score => "https://www.procyclingstats.com/rankings/me/climbers",
    :tt => "https://www.procyclingstats.com/rankings/me/time-trial"
)

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
function getvelogamesriders(pageurl::AbstractString)
    page = HTTP.get(pageurl) |> String |> parsehtml
    rider_table = eachmatch(sel"table", page.root)[1]

    rider_df = DataFrame(
        name=String[],
        cost=Int64[],
        team=categorical(String[]),
        score=Int64[],
        startlist=categorical(String[]),
    )

    for rider_row in eachmatch(sel"tr", rider_table)[2:end]
        rider_cells = eachmatch(sel"td", rider_row)
        push!(rider_df.score, parse(Int64, text(rider_cells[5])))
        push!(rider_df.name, text(rider_cells[2]))
        push!(rider_df.team, text(rider_cells[3]))
        push!(rider_df.cost, parse(Int64, text(rider_cells[6])))
        push!(rider_df.startlist, text(rider_cells[4]))
    end

    # calculate the value of the rider
    rider_df.value = rider_df.score ./ rider_df.cost

    # add a riderkey column based on the name
    rider_df.riderkey = create_key(rider_df.name)
    # check that the riderkey is unique
    @assert length(unique(rider_df.riderkey)) == length(rider_df.riderkey) "Rider keys are not unique"

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
    # check that the category is valid
    haskey(PCS_RANKING_URLS, category) || error("Invalid category: $category")

    # download the page and parse the table
    page = HTTP.get(PCS_RANKING_URLS[category]).body |> String |> parsehtml
    rider_table = eachmatch(sel"table", page.root)[1]

    # parse the table to a DataFrame
    rider_df = DataFrame(
        rank=Int64[],
        name=String[],
        team=String[],
        points=Int64[]
    )

    for rider_row in eachmatch(sel"tr", rider_table)[2:end]
        rider_cells = eachmatch(sel"td", rider_row)
        push!(rider_df.rank, parse(Int64, text(rider_cells[1])))
        push!(rider_df.name, text(rider_cells[4]))
        push!(rider_df.team, text(rider_cells[5]))
        push!(rider_df.points, parse(Int64, text(rider_cells[6])))
    end

    # add a riderkey column based on the name
    rider_df.riderkey = create_key(rider_df.name)

    # check that the riderkey is unique
    length(unique(rider_df.riderkey)) == length(rider_df.riderkey) || error("Rider keys are not unique")

    return rider_df
end

"""
`create_key` creates a unique key for each rider based on their name.
"""
create_key(arr) =
    map(arr) do x
        s = replace(x, r"[^a-zA-Z0-9_]" => "")
        join(sort(collect(Unicode.normalize(s, stripmark=true, stripcc=true, casefold=true))))
    end