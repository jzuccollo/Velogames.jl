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

"""
    buildmodelhistorical(inputdf::DataFrame, n::Integer=9, points::Symbol=:points, cost::Symbol=:cost; totalcost::Integer=100)

Build the optimization model for historical analysis - maximizes points for a given team size and cost constraint.
This is similar to buildmodelstage but uses actual points scored rather than predicted scores.

- `inputdf::DataFrame`: the rider data with actual points scored
- `n::Integer`: number of riders to select (default: 9)
- `points::Symbol`: column name for actual points scored (default: :points)
- `cost::Symbol`: column name for rider cost (default: :cost)
- `totalcost::Integer`: maximum total cost allowed (default: 100)

Returns the optimization solution values or nothing if no feasible solution exists.
"""
function buildmodelhistorical(inputdf::DataFrame, n::Integer=9, points::Symbol=:points, cost::Symbol=:cost; totalcost::Integer=100)
    # Create a working copy to avoid modifying the original data
    df = copy(inputdf)

    # Check if binary classification columns exist, if not create them from 'class' column
    required_cols = ["allrounder", "sprinter", "climber", "unclassed"]
    missing_cols = setdiff(required_cols, names(df))

    if !isempty(missing_cols)
        for col in missing_cols
            if col == "allrounder"
                df[!, col] = df[!, :class] .== "All rounder"
            elseif col == "sprinter"
                df[!, col] = df[!, :class] .== "Sprinter"
            elseif col == "climber"
                df[!, col] = df[!, :class] .== "Climber"
            elseif col == "unclassed"
                df[!, col] = df[!, :class] .== "Unclassed"
            end
        end
    end

    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.rider], Bin)
    JuMP.@objective(model, Max, df[!, points]' * x) # maximise the total points scored
    JuMP.@constraint(model, df[!, cost]' * x <= totalcost) # cost must be <= totalcost
    JuMP.@constraint(model, sum(x) == n) # exactly n riders must be chosen
    JuMP.@constraint(model, df[!, :allrounder]' * x >= 2) # at least 2 must be all rounders
    JuMP.@constraint(model, df[!, :sprinter]' * x >= 1) # at least 1 must be a sprinter
    JuMP.@constraint(model, df[!, :climber]' * x >= 2) # at least 2 must be climbers
    JuMP.@constraint(model, df[!, :unclassed]' * x >= 3) # at least 3 must be unclassed
    JuMP.optimize!(model)
    if termination_status(model) != OPTIMAL
        @warn("The model was not solved correctly.")
        return nothing
    end
    return JuMP.value.(x)
end

"""
    minimizecostforstage(inputdf::DataFrame, target_score::Real, n::Integer=9, cost::Symbol=:cost; totalcost::Integer=100)

Build the optimization model to minimize cost while achieving at least the target score.
Used for historical analysis to find the cheapest team that would have beaten a certain score.

- `inputdf::DataFrame`: the rider data with actual points scored
- `target_score::Real`: minimum total score the team must achieve
- `n::Integer`: number of riders to select (default: 9)
- `cost::Symbol`: column name for rider cost (default: :cost)
- `totalcost::Integer`: maximum total cost allowed (default: 100)

Returns the optimization solution values or nothing if no feasible solution exists.
"""
function minimizecostforstage(inputdf::DataFrame, target_score::Real, n::Integer=9, cost::Symbol=:cost; totalcost::Integer=100)
    # Create a working copy to avoid modifying the original data
    df = copy(inputdf)

    # Check if binary classification columns exist, if not create them from 'class' column
    required_cols = ["allrounder", "sprinter", "climber", "unclassed"]
    missing_cols = setdiff(required_cols, names(df))

    if !isempty(missing_cols)
        for col in missing_cols
            if col == "allrounder"
                df[!, col] = df[!, :class] .== "All rounder"
            elseif col == "sprinter"
                df[!, col] = df[!, :class] .== "Sprinter"
            elseif col == "climber"
                df[!, col] = df[!, :class] .== "Climber"
            elseif col == "unclassed"
                df[!, col] = df[!, :class] .== "Unclassed"
            end
        end
    end

    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.rider], Bin)
    JuMP.@objective(model, Min, df[!, cost]' * x) # minimize the total cost
    JuMP.@constraint(model, df[!, :points]' * x >= target_score + 1) # score must be > target_score
    JuMP.@constraint(model, sum(x) == n) # exactly n riders must be chosen
    JuMP.@constraint(model, df[!, :allrounder]' * x >= 2) # at least 2 must be all rounders
    JuMP.@constraint(model, df[!, :sprinter]' * x >= 1) # at least 1 must be a sprinter
    JuMP.@constraint(model, df[!, :climber]' * x >= 2) # at least 2 must be climbers
    JuMP.@constraint(model, df[!, :unclassed]' * x >= 3) # at least 3 must be unclassed
    JuMP.optimize!(model)
    if termination_status(model) != OPTIMAL
        @warn("The cost minimization model was not solved correctly.")
        return nothing
    end
    return JuMP.value.(x)
end

"""
    minimisecostforteam(allriderdata::DataFrame, points_col::Symbol, cost_col::Symbol; min_points::Number)

Build and solve a JuMP model to find the minimum cost team that achieves at least `min_points`.
"""
function minimisecostforteam(allriderdata::DataFrame, points_col::Symbol, cost_col::Symbol; min_points::Number)
    n = nrow(allriderdata)
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    @variable(model, x[1:n], Bin)

    # Objective: Minimize the total cost of the team
    @objective(model, Min, sum(x[i] * allriderdata[i, cost_col] for i in 1:n))

    # Constraint: Total points must be at least min_points
    @constraint(model, sum(x[i] * allriderdata[i, points_col] for i in 1:n) >= min_points)

    # Constraint: Exactly 9 riders
    @constraint(model, sum(x) == 9)

    # Class constraints
    @constraint(model, sum(x[i] for i in 1:n if allriderdata[i, :class] == "All rounder") == 2)
    @constraint(model, sum(x[i] for i in 1:n if allriderdata[i, :class] == "Climber") == 2)
    @constraint(model, sum(x[i] for i in 1:n if allriderdata[i, :class] == "Sprinter") == 1)
    @constraint(model, sum(x[i] for i in 1:n if allriderdata[i, :class] == "Unclassed") == 4)

    optimize!(model)

    if termination_status(model) == MOI.OPTIMAL
        return Dict(allriderdata[i, :rider] => value(x[i]) for i in 1:n)
    else
        return nothing
    end
end