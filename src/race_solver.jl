"""
## `solverace`

This function constructs a team for the specified race.

Inputs:

    * `riderurl::String` - the URL of the rider data on Velogames
    * `racetype::String` - the type of race (oneday, stage). Default is `oneday`
    * `racehash::String` - if race is oneday, what is the startlist hash? Default is `""`
    * `formweight::Float64` - the weight to apply to the form score. Default is `0.5`

The function returns a DataFrame with the following columns:

    * `name` - the name of the rider
    * `team` - the team the rider rides for
"""
function solverace(riderurl::String, racetype::Symbol, racehash::String="", formweight::Number=0.5)
    # get vg rider data
    riderdf = getvgriders(riderurl)
    # filter to riders where startlist == racehash
    startlist = riderdf[riderdf.startlist.==racehash, :]

    # map getpcsriderpts over riderdf to get the points for each rider name
    startlist[!, "pcspts"] = map(x -> getpcsriderpts(x)[x][1], startlist.rider)
    # if length of pcspts Dict is 0, replace with 0
    defaultdict = Dict("gc" => 0, "tt" => 0, "sprint" => 0, "climber" => 0, "oneday" => 0)
    startlist[!, "pcspts"] = map(x -> length(x) == 0 ? defaultdict : x, startlist.pcspts)
    # extract the oneday points from the pcspts column of Dicts
    startlist[!, "pcsptsevent"] = map(x -> x[racetype], startlist.pcspts)
    # calculate the score for each rider
    startlist[!, "score"] = formweight * startlist.points + (1 - formweight) * startlist.pcsptsevent

    # rename the startlist.score column to calcscore and the cost column to vgcost
    rename!(
        startlist,
        :score => :calcscore,
        :cost => :vgcost
    )

    # build the model
    # if racetype == :stage use buildmodelstage, otherwise use buildmodeloneday
    if racetype == :stage
        results = buildmodelstage(startlist)
    else
        results = buildmodeloneday(startlist, 6)
    end
    startlist[!, :chosen] = results.data .> 0.5
    chosenteampost = filter(:chosen => ==(true), startlist)
    chosenteampost[:, [:rider, :team, :cost, :points, :classraw]]
end