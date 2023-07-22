"""
    build_model_oneday(rider_df::DataFrame)

Build the optimisation model for the velogames game.

- `rider_df::DataFrame`: the rider data

"""
function build_model_oneday(input_df::DataFrame, n::Integer, points::Symbol, cost::Symbol)
    model = Model(HiGHS.Optimizer)
    @variable(model, x[input_df.rider], Bin)
    @objective(model, Max, input_df[!, points]' * x) # maximise the total score
    @constraint(model, input_df[!, cost]' * x <= 100) # cost must be <= 100
    @constraint(model, sum(x) == n) # exactly n riders must be chosen
    # @constraint(model, ) # exactly n teams must be chosen
    optimize!(model)
    if termination_status(model) != OPTIMAL
        @warn("The model was not solved correctly.")
        return
    end
    return value.(x)
end

"""
    build_model_stage(rider_df::DataFrame)

Build the optimisation model for the velogames game.

- `rider_df::DataFrame`: the rider data

"""
function build_model_stage(input_df::DataFrame)
    model = Model(HiGHS.Optimizer)
    @variable(model, x[input_df.rider], Bin)
    @objective(model, Max, input_df.calc_score' * x) # maximise the total score
    @constraint(model, input_df.cost' * x <= 100) # cost must be <= 100
    @constraint(model, sum(x) == 9) # exactly 9 riders must be chosen
    @constraint(model, input_df[!, "allrounder"]' * x >= 2) # at least 2 must be all rounders
    @constraint(model, input_df[!, "sprinter"]' * x >= 1) # at least 1 must be a sprinter
    @constraint(model, input_df[!, "climber"]' * x >= 2) # at least 2 must be climbers
    @constraint(model, input_df[!, "unclassed"]' * x >= 3) # at least 3 must be unclassed
    optimize!(model)
    if termination_status(model) != OPTIMAL
        @warn("The model was not solved correctly.")
        return
    end
    return value.(x)
end