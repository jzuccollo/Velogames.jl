using HTTP, DataFrames, TableScraper, Cascadia, Gumbo, CategoricalArrays, Unicode

const PCS_RANKING_URLS = Dict(
    :overall => "https://www.procyclingstats.com/rankings.php",
    :oneday => "https://www.procyclingstats.com/rankings/me/one-day-races",
    :gc => "https://www.procyclingstats.com/rankings/me/gc-ranking",
    :sprint => "https://www.procyclingstats.com/rankings/me/sprinters",
    :mountain => "https://www.procyclingstats.com/rankings/me/climbers",
    :tt => "https://www.procyclingstats.com/rankings/me/time-trial",
)

"""
`create_key` creates a unique key for each rider based on their name.
"""
create_key(arr) =
    map(arr) do x
        s = replace(x, r"[^a-zA-Z0-9_]" => "")
        join(
            sort(
                collect(
                    Unicode.normalize(s, stripmark = true, stripcc = true, casefold = true),
                ),
            ),
        )
    end

"""
## `gettable`

This function downloads and parses the rider data from the Velogames and PCS websites.

The function returns a DataFrame with the columns of the first table on the page. It also adds a (hopefully) unique key for each rider based on their name.
"""
function gettable(pageurl::AbstractString)
    page = scrape_tables(pageurl)
    rider_df = DataFrame(page[1])

    # lowercase the column names and remove spaces
    rename!(rider_df, lowercase.(replace.(names(rider_df), " " => "", "#" => "rank")))
    # rename score to points if it exists
    if hasproperty(rider_df, :score)
        rename!(rider_df, :score => :points)
    end
    # cast the cost and vgpoints columns to Int64 if they exist
    for col in [:cost, :points, :rank]
        if hasproperty(rider_df, col)
            rider_df[!, col] = parse.(Int64, rider_df[!, col])
        end
    end

    # add a riderkey column based on the name
    rider_df.riderkey = create_key(rider_df.rider)
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
    rider_df = scrape_tables(pageurl)

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
    page = gettable(PCS_RANKING_URLS[category])

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
        for class in unique(rider_df.class)
            rider_df[!, class] = rider_df.class .== class
        end
    end

    # calculate the value of the rider
    rider_df.value = rider_df.points ./ rider_df.cost

    return rider_df
end
