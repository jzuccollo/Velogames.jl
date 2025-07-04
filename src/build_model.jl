"""
    buildmodeloneday(inputdf::DataFrame, n::Integer=6, points::Symbol=:calcscore, cost::Symbol=:vgcost; totalcost::Integer=100)

Build the optimisation model for one-day races in the velogames game.

- `inputdf::DataFrame`: the rider data
- `n::Integer`: number of riders to select (default: 6)
- `points::Symbol`: column name for points/score to maximize (default: :calcscore)
- `cost::Symbol`: column name for rider cost (default: :vgcost)
- `totalcost::Integer`: maximum total cost allowed (default: 100)

Returns the optimization solution values or nothing if no feasible solution exists.
"""
function buildmodeloneday(inputdf::DataFrame, n::Integer=6, points::Symbol=:calcscore, cost::Symbol=:vgcost; totalcost::Integer=100)
    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[inputdf.rider], Bin)
    JuMP.@objective(model, Max, inputdf[!, points]' * x) # maximize the total score
    JuMP.@constraint(model, inputdf[!, cost]' * x <= totalcost) # cost must be <= totalcost
    JuMP.@constraint(model, sum(x) == n) # exactly n riders must be chosen
    optimize!(model)
    if termination_status(model) != OPTIMAL
        @warn("The model was not solved correctly.")
        return
    end
    return JuMP.value.(x)
end


"""
    buildmodelstage(inputdf::DataFrame, n::Integer=9, points::Symbol=:calcscore, cost::Symbol=:vgcost; totalcost::Integer=100)

Build the optimisation model for stage races in the velogames game.

- `inputdf::DataFrame`: the rider data
- `n::Integer`: number of riders to select (default: 9)
- `points::Symbol`: column name for points/score to maximize (default: :calcscore)
- `cost::Symbol`: column name for rider cost (default: :vgcost)
- `totalcost::Integer`: maximum total cost allowed (default: 100)

Returns the optimization solution values or nothing if no feasible solution exists.
"""
function buildmodelstage(inputdf::DataFrame, n::Integer=9, points::Symbol=:calcscore, cost::Symbol=:vgcost; totalcost::Integer=100)
    # Create a working copy to avoid modifying the original data
    df = copy(inputdf)

    # Check if binary classification columns exist, if not create them from 'class' column
    required_cols = ["allrounder", "sprinter", "climber", "unclassed"]
    missing_cols = setdiff(required_cols, names(df))

    if !isempty(missing_cols)
        # Try to create binary columns from 'class' column
        if hasproperty(df, :class)
            for class_name in required_cols
                col_name = Symbol(class_name)
                if !(string(col_name) in names(df))
                    df[!, col_name] = (df.class .== class_name)
                end
            end
            # Re-check if we successfully created all required columns
            missing_cols = setdiff(required_cols, names(df))
        end

        # If still missing columns, fall back to one-day model
        if !isempty(missing_cols)
            @warn "Missing required columns for stage race: $missing_cols. Using one-day model instead."
            return buildmodeloneday(inputdf, n, points, cost; totalcost=totalcost)
        end
    end

    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.rider], Bin)
    JuMP.@objective(model, Max, df[!, points]' * x) # maximise the total score
    JuMP.@constraint(model, df[!, cost]' * x <= totalcost) # cost must be <= totalcost
    JuMP.@constraint(model, sum(x) == n) # exactly n riders must be chosen
    JuMP.@constraint(model, df[!, :allrounder]' * x >= 2) # at least 2 must be all rounders
    JuMP.@constraint(model, df[!, :sprinter]' * x >= 1) # at least 1 must be a sprinter
    JuMP.@constraint(model, df[!, :climber]' * x >= 2) # at least 2 must be climbers
    JuMP.@constraint(model, df[!, :unclassed]' * x >= 3) # at least 3 must be unclassed
    JuMP.optimize!(model)
    if termination_status(model) != OPTIMAL
        @warn("The model was not solved correctly.")
        return
    end
    return JuMP.value.(x)
end