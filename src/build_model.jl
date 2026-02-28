"""
    build_model_oneday(inputdf::DataFrame, n::Integer=6, points::Symbol=:expected_vg_points, cost::Symbol=:cost; totalcost::Integer=100)

Build the optimisation model for one-day races in the velogames game.

- `inputdf::DataFrame`: the rider data
- `n::Integer`: number of riders to select (default: 6)
- `points::Symbol`: column name for points/score to maximise (default: :expected_vg_points)
- `cost::Symbol`: column name for rider cost (default: :cost)
- `totalcost::Integer`: maximum total cost allowed (default: 100)

Returns the optimisation solution values or nothing if no feasible solution exists.
"""
function build_model_oneday(
    inputdf::DataFrame,
    n::Integer = 6,
    points::Symbol = :expected_vg_points,
    cost::Symbol = :cost;
    totalcost::Integer = 100,
    max_per_team::Int = 0,
)
    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[inputdf.riderkey], Bin)
    JuMP.@objective(model, Max, inputdf[!, points]' * x) # maximise the total score
    JuMP.@constraint(model, inputdf[!, cost]' * x <= totalcost) # cost must be <= totalcost
    JuMP.@constraint(model, sum(x) == n) # exactly n riders must be chosen
    if max_per_team > 0
        for team in unique(inputdf.team)
            team_keys = inputdf.riderkey[inputdf.team .== team]
            JuMP.@constraint(model, sum(x[k] for k in team_keys) <= max_per_team)
        end
    end
    JuMP.optimize!(model)
    if JuMP.termination_status(model) != JuMP.OPTIMAL
        @warn("The model was not solved correctly.")
        return nothing
    end
    return JuMP.value.(x)
end


"""
    build_model_stage(inputdf::DataFrame, n::Integer=9, points::Symbol=:expected_vg_points, cost::Symbol=:cost; totalcost::Integer=100)

Build the optimisation model for stage races in the velogames game.
Enforces VG Sixes classification constraints: at least 2 all-rounders, 2 climbers,
1 sprinter, and 3 unclassed riders.

Also used for historical analysis of stage races by passing actual points and cost
columns (e.g. `build_model_stage(df, 9, :points, :cost)`).

Returns the optimisation solution values or nothing if no feasible solution exists.
"""
function build_model_stage(
    inputdf::DataFrame,
    n::Integer = 9,
    points::Symbol = :expected_vg_points,
    cost::Symbol = :cost;
    totalcost::Integer = 100,
    max_per_team::Int = 0,
)
    df = copy(inputdf)

    if !ensure_classification_columns!(df)
        @warn "Missing classification columns for stage race model"
        return nothing
    end

    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.riderkey], Bin)
    JuMP.@objective(model, Max, df[!, points]' * x)
    JuMP.@constraint(model, df[!, cost]' * x <= totalcost)
    JuMP.@constraint(model, sum(x) == n)
    JuMP.@constraint(model, df[!, :allrounder]' * x >= 2)
    JuMP.@constraint(model, df[!, :sprinter]' * x >= 1)
    JuMP.@constraint(model, df[!, :climber]' * x >= 2)
    JuMP.@constraint(model, df[!, :unclassed]' * x >= 3)
    if max_per_team > 0
        for team in unique(df.team)
            team_keys = df.riderkey[df.team .== team]
            JuMP.@constraint(model, sum(x[k] for k in team_keys) <= max_per_team)
        end
    end
    JuMP.optimize!(model)
    if JuMP.termination_status(model) != JuMP.OPTIMAL
        @warn("The model was not solved correctly.")
        return nothing
    end
    return JuMP.value.(x)
end

"""
    minimise_cost_stage(inputdf::DataFrame, target_score::Real, n::Integer=9, points::Symbol=:points, cost::Symbol=:cost; totalcost::Integer=100)

Minimise team cost whilst achieving at least the target score.
Used for historical analysis to find the cheapest team that would have beaten a given benchmark.

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
    df = copy(inputdf)

    if !ensure_classification_columns!(df)
        @warn "Missing classification columns for cost minimisation"
        return nothing
    end

    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.riderkey], Bin)
    JuMP.@objective(model, Min, df[!, cost]' * x)
    JuMP.@constraint(model, df[!, points]' * x >= target_score + 1)
    JuMP.@constraint(model, sum(x) == n)
    JuMP.@constraint(model, df[!, :allrounder]' * x >= 2)
    JuMP.@constraint(model, df[!, :sprinter]' * x >= 1)
    JuMP.@constraint(model, df[!, :climber]' * x >= 2)
    JuMP.@constraint(model, df[!, :unclassed]' * x >= 3)
    JuMP.optimize!(model)
    if JuMP.termination_status(model) != JuMP.OPTIMAL
        @warn("The cost minimisation model was not solved correctly.")
        return nothing
    end
    return JuMP.value.(x)
end
