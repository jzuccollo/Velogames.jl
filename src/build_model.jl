using DataFrames
using JuMP
using HiGHS

"""
    build_model(rider_df::DataFrame)

Build the optimisation model for the velogames game.

- `rider_df::DataFrame`: the rider data from `get_rider_data()`

"""
function build_model(input_df::DataFrame)
    model = Model(HiGHS.Optimizer)
    @variable(model, x[input_df.rider], Bin)
    @objective(model, Max, input_df.calc_score' * x) # maximise the total score
    @constraint(model, input_df.vgcost' * x <= 100) # cost must be <= 100
    @constraint(model, sum(x) == 9) # exactly 9 riders must be chosen
    optimize!(model)
    return value.(x)
end
