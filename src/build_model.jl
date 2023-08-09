"""
    buildmodeloneday(riderdf::DataFrame)

Build the optimisation model for the velogames game.

- `riderdf::DataFrame`: the rider data

"""
function buildmodeloneday(inputdf::DataFrame, n::Integer, points::Symbol, cost::Symbol)
    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[inputdf.rider], Bin)
    JuMP.@objective(model, Max, inputdf[!, points]' * x) # maximise the total score
    JuMP.@constraint(model, inputdf[!, cost]' * x <= 100) # cost must be <= 100
    JuMP.@constraint(model, sum(x) == n) # exactly n riders must be chosen
    # @constraint(model, ) # exactly n teams must be chosen
    optimize!(model)
    if termination_status(model) != OPTIMAL
        @warn("The model was not solved correctly.")
        return
    end
    return JuMP.value.(x)
end

"""
    buildmodelstage(riderdf::DataFrame)

Build the optimisation model for the velogames game.

- `riderdf::DataFrame`: the rider data

"""
function buildmodelstage(inputdf::DataFrame)
    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[inputdf.rider], Bin)
    JuMP.@objective(model, Max, inputdf.calcscore' * x) # maximise the total score
    JuMP.@constraint(model, inputdf.cost' * x <= 100) # cost must be <= 100
    JuMP.@constraint(model, sum(x) == 9) # exactly 9 riders must be chosen
    JuMP.@constraint(model, inputdf[!, "allrounder"]' * x >= 2) # at least 2 must be all rounders
    JuMP.@constraint(model, inputdf[!, "sprinter"]' * x >= 1) # at least 1 must be a sprinter
    JuMP.@constraint(model, inputdf[!, "climber"]' * x >= 2) # at least 2 must be climbers
    JuMP.@constraint(model, inputdf[!, "unclassed"]' * x >= 3) # at least 3 must be unclassed
    JuMP.optimize!(model)
    if termination_status(model) != OPTIMAL
        @warn("The model was not solved correctly.")
        return
    end
    return JuMP.value.(x)
end