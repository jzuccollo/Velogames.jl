"""
    build_model_oneday(inputdf::DataFrame, n::Integer=6, points::Symbol=:calcscore, cost::Symbol=:vgcost; totalcost::Integer=100)

Build the optimisation model for one-day races in the velogames game.

- `inputdf::DataFrame`: the rider data
- `n::Integer`: number of riders to select (default: 6)
- `points::Symbol`: column name for points/score to maximise (default: :calcscore)
- `cost::Symbol`: column name for rider cost (default: :vgcost)
- `totalcost::Integer`: maximum total cost allowed (default: 100)

Returns the optimisation solution values or nothing if no feasible solution exists.
"""
function build_model_oneday(
    inputdf::DataFrame,
    n::Integer = 6,
    points::Symbol = :calcscore,
    cost::Symbol = :vgcost;
    totalcost::Integer = 100,
)
    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[inputdf.riderkey], Bin)
    JuMP.@objective(model, Max, inputdf[!, points]' * x) # maximise the total score
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
    build_model_stage(inputdf::DataFrame, n::Integer=9, points::Symbol=:calcscore, cost::Symbol=:vgcost; totalcost::Integer=100)

Build the optimisation model for stage races in the velogames game.
Enforces rider classification constraints: at least 2 all-rounders, 2 climbers,
1 sprinter, and 3 unclassed riders.

Also used for historical analysis of stage races by passing actual points and cost
columns (e.g. `build_model_stage(df, 9, :points, :cost)`).

- `inputdf::DataFrame`: the rider data
- `n::Integer`: number of riders to select (default: 9)
- `points::Symbol`: column name for points/score to maximise (default: :calcscore)
- `cost::Symbol`: column name for rider cost (default: :vgcost)
- `totalcost::Integer`: maximum total cost allowed (default: 100)

Returns the optimisation solution values or nothing if no feasible solution exists.
Returns nothing if classification columns are missing or constraints cannot be satisfied.
"""
function build_model_stage(
    inputdf::DataFrame,
    n::Integer = 9,
    points::Symbol = :calcscore,
    cost::Symbol = :vgcost;
    totalcost::Integer = 100,
)
    # Create a working copy to avoid modifying the original data
    df = copy(inputdf)

    # Use centralised classification logic
    if !ensure_classification_columns!(df)
        @warn "Missing classification columns for stage race model — cannot enforce class constraints"
        return nothing
    end

    # Validate constraints are satisfiable
    if !validate_classification_constraints(df)
        @warn "Not enough riders in each class to satisfy stage race constraints"
        return nothing
    end

    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.riderkey], Bin)
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
    minimise_cost_stage(inputdf::DataFrame, target_score::Real, n::Integer=9, points::Symbol=:points, cost::Symbol=:cost; totalcost::Integer=100)

Minimise team cost whilst achieving at least the target score.
Used for historical analysis to find the cheapest team that would have beaten a given benchmark.

- `inputdf::DataFrame`: the rider data with actual points scored
- `target_score::Real`: minimum total score the team must achieve
- `n::Integer`: number of riders to select (default: 9)
- `points::Symbol`: column name for points/score to constrain (default: :points)
- `cost::Symbol`: column name for rider cost (default: :cost)
- `totalcost::Integer`: maximum total cost allowed (default: 100)

Returns the optimisation solution values or nothing if no feasible solution exists.
"""
function minimise_cost_stage(
    inputdf::DataFrame,
    target_score::Real,
    n::Integer = 9,
    points::Symbol = :points,
    cost::Symbol = :cost;
    totalcost::Integer = 100,
)
    # Create a working copy to avoid modifying the original data
    df = copy(inputdf)

    # Use centralised classification logic
    if !ensure_classification_columns!(df)
        @warn "Cannot create classification columns for cost minimisation"
        return nothing
    end

    # Validate constraints are satisfiable
    if !validate_classification_constraints(df)
        @warn "Not enough riders in each class to satisfy constraints"
        return nothing
    end

    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.riderkey], Bin)
    JuMP.@objective(model, Min, df[!, cost]' * x) # minimise the total cost
    JuMP.@constraint(model, df[!, points]' * x >= target_score + 1) # score must be > target_score
    JuMP.@constraint(model, sum(x) == n) # exactly n riders must be chosen
    JuMP.@constraint(model, df[!, :allrounder]' * x >= 2) # at least 2 must be all rounders
    JuMP.@constraint(model, df[!, :sprinter]' * x >= 1) # at least 1 must be a sprinter
    JuMP.@constraint(model, df[!, :climber]' * x >= 2) # at least 2 must be climbers
    JuMP.@constraint(model, df[!, :unclassed]' * x >= 3) # at least 3 must be unclassed
    JuMP.optimize!(model)
    if termination_status(model) != OPTIMAL
        @warn("The cost minimisation model was not solved correctly.")
        return nothing
    end
    return JuMP.value.(x)
end
