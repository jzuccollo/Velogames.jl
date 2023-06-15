"""
## `solve_race`

This function constructs a team for the specified race.

Inputs:

    * `rider_url::String` - the URL of the rider data on Velogames
    * `race_type::String` - the type of race (oneday, stage). Default is `oneday`
    * `race_hash::String` - if race is oneday, what is the startlist hash? Default is `""`
    * `form_weight::Float64` - the weight to apply to the form score. Default is `0.5`

The function returns a DataFrame with the following columns:

    * `name` - the name of the rider
    * `team` - the team the rider rides for
"""
function solve_race(rider_url::AbstractString, race_type::Symbol, race_hash::AbstractString="", form_weight::Float64=0.5)
    # get vg rider data
    rider_df = getvgriders(rider_url)
    # filter to riders where startlist == race_hash
    startlist = rider_df[rider_df.startlist.==race_hash, :]

    # map getpcsriderpts over rider_df to get the points for each rider name
    startlist[!, "pcspts"] = map(x -> getpcsriderpts(x)[x][1], startlist.rider)
    # if length of pcspts Dict is 0, replace with 0
    default_dict = Dict("gc" => 0, "tt" => 0, "sprint" => 0, "climber" => 0, "oneday" => 0)
    startlist[!, "pcspts"] = map(x -> length(x) == 0 ? default_dict : x, startlist.pcspts)
    # extract the oneday points from the pcspts column of Dicts
    startlist[!, "pcspts_event"] = map(x -> x[race_type], startlist.pcspts)
    # calculate the score for each rider
    startlist[!, "score"] = form_weight * startlist.points + (1 - form_weight) * startlist.pcspts_event

    # rename the startlist.score column to calc_score and the cost column to vgcost
    rename!(
        startlist,
        :score => :calc_score,
        :cost => :vgcost
    )

    # build the model
    # if race_type == :stage use build_model_stage, otherwise use build_model_oneday
    if race_type == :stage
        results = build_model_stage(startlist)
    else
        results = build_model_oneday(startlist, 6)
    end
    startlist[!, :chosen] = results.data .> 0.5
    chosen_team_post = filter(:chosen => ==(true), startlist)
    chosen_team_post[:, [:rider, :team, :cost, :points, :class_raw]]
end