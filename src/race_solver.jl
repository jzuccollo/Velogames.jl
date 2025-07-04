"""
## `solverace`

This function constructs a team for the specified race.

Inputs:

    * `riderurl::String` - the URL of the rider data on Velogames
    * `racetype::Symbol` - the type of race (:oneday, :stage, :gc, :tt, :sprint, :climber). Default is :oneday
    * `racehash::String` - if race is oneday, what is the startlist hash? Default is `""`
    * `formweight::Number` - the weight to apply to the form score. Default is `0.5`

The function returns a DataFrame with the following columns:

    * `rider` - the name of the rider
    * `team` - the team the rider rides for
    * `vgcost` - the cost in VeloGames
    * `vgpoints` - the VeloGames points
    * `classraw` - the rider class
"""
function solverace(riderurl::String, racetype::Symbol=:oneday, racehash::String="", formweight::Number=0.5;
    cache_config::CacheConfig=DEFAULT_CACHE, force_refresh::Bool=false)
    # Input validation
    valid_racetypes = [:oneday, :stage, :gc, :tt, :sprint, :climber]
    if !(racetype in valid_racetypes)
        @warn "Invalid racetype: $racetype. Using :oneday instead."
        racetype = :oneday
    end

    if !(0 <= formweight <= 1)
        throw(ArgumentError("formweight must be between 0 and 1, got $formweight"))
    end

    # Get VG rider data
    riderdf = getvgriders(riderurl; cache_config=cache_config, force_refresh=force_refresh)

    # Filter to riders where startlist == racehash (if specified)
    if isempty(racehash)
        startlist = riderdf
        @info "No racehash specified, using all $(nrow(startlist)) riders"
    else
        startlist = filter(row -> row.startlist == racehash, riderdf)
        if nrow(startlist) == 0
            @warn "No riders found for racehash: $racehash"
            return DataFrame(rider=String[], team=String[], vgcost=Int[], vgpoints=Float64[], classraw=String[])
        end
        @info "Found $(nrow(startlist)) riders for racehash: $racehash"
    end

    # Get PCS rider points
    if nrow(startlist) > 0
        @info "Fetching PCS data for $(nrow(startlist)) riders..."
        rider_names = String.(startlist.rider)
        pcsriderpts = getpcsriderpts_batch(rider_names; cache_config=cache_config, force_refresh=force_refresh)

        if racetype == :stage
            vg_class_to_pcs_col = Dict(
                "All Rounder" => "gc",
                "Climber" => "climber",
                "Sprinter" => "sprint",
                "Unclassed" => "oneday"
            )
            add_pcs_speciality_points!(startlist, pcsriderpts, vg_class_to_pcs_col)
            startlist[!, :pcsptsevent] = coalesce.(startlist.pcs_points, 0.0)
        else # Default to old oneday logic for now
            # Use the specialized PCS points for this rider's class, falling back to oneday
            racetype_col = racetype in names(pcsriderpts) ? racetype : :oneday
            if racetype_col in names(pcsriderpts)
                startlist = leftjoin(startlist, pcsriderpts[:, ["riderkey", string(racetype_col)]], on=:riderkey)
                startlist[!, :pcsptsevent] = coalesce.(startlist[!, racetype_col], 0.0)
            else
                startlist[!, :pcsptsevent] = zeros(Float64, nrow(startlist))
            end
        end
    else
        startlist[!, :pcsptsevent] = Float64[]
    end

    # Calculate the score for each rider
    startlist[!, :calcscore] = formweight * startlist.points + (1 - formweight) * startlist.pcsptsevent

    # Rename cost column for consistency
    rename!(startlist, :cost => :vgcost)

    # Build the model with proper parameters
    if racetype == :stage
        @info "Building stage race optimization model..."
        results = buildmodelstage(startlist, 9, :calcscore, :vgcost; totalcost=100)
    else
        @info "Building one-day race optimization model..."
        results = buildmodeloneday(startlist, 6, :calcscore, :vgcost; totalcost=100)
    end

    # Handle optimization results
    if results === nothing
        @warn "Optimization failed - no feasible solution found"
        return DataFrame(rider=String[], team=String[], vgcost=Int[], vgpoints=Float64[], classraw=String[])
    end

    # Extract chosen riders
    # JuMP returns a DenseAxisArray, convert to Vector in DataFrame order
    chosen_vec = [results[r] for r in startlist.rider]
    startlist[!, :chosen] = chosen_vec .> 0.5
    chosenteam = filter(:chosen => ==(true), startlist)

    if nrow(chosenteam) == 0
        @warn "No riders selected by optimization"
        return DataFrame(rider=String[], team=String[], vgcost=Int[], vgpoints=Float64[], classraw=String[])
    end

    @info "Selected $(nrow(chosenteam)) riders with total cost: $(sum(chosenteam.vgcost))"

    # Return the selected team
    return select(chosenteam, :rider, :team, :vgcost, :points => :vgpoints, :classraw)
end