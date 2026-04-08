"""
    ensure_classification_columns!(df::DataFrame)

Ensures that the DataFrame has binary classification columns for each rider class
(allrounder, sprinter, climber, unclassed). Creates them from the :class or
:classraw column if they don't already exist.

Returns true if all columns exist or were successfully created, false otherwise.
"""
function ensure_classification_columns!(
    df::DataFrame;
    required_classes::Vector{String}=["allrounder", "sprinter", "climber", "unclassed"],
)
    if !hasproperty(df, :class) && !hasproperty(df, :classraw)
        return false
    end

    for class_name in required_classes
        col_name = Symbol(class_name)

        if string(col_name) in names(df)
            continue
        end

        if hasproperty(df, :class)
            df[!, col_name] =
                lowercase.(replace.(df.class, " " => "")) .== lowercase(class_name)
        else
            df[!, col_name] =
                lowercase.(replace.(df.classraw, " " => "")) .== lowercase(class_name)
        end
    end

    return true
end


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
    n::Integer=6,
    points::Symbol=:expected_vg_points,
    cost::Symbol=:cost;
    totalcost::Integer=100,
    max_per_team::Int=0,
)
    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[inputdf.riderkey], Bin)
    JuMP.@objective(model, Max, inputdf[!, points]' * x) # maximise the total score
    JuMP.@constraint(model, inputdf[!, cost]' * x <= totalcost) # cost must be <= totalcost
    JuMP.@constraint(model, sum(x) == n) # exactly n riders must be chosen
    if max_per_team > 0
        for team in unique(inputdf.team)
            team_keys = inputdf.riderkey[inputdf.team.==team]
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
    n::Integer=9,
    points::Symbol=:expected_vg_points,
    cost::Symbol=:cost;
    totalcost::Integer=100,
    max_per_team::Int=0,
)
    df = copy(inputdf)

    has_classes = ensure_classification_columns!(df)

    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.riderkey], Bin)
    JuMP.@objective(model, Max, df[!, points]' * x)
    JuMP.@constraint(model, df[!, cost]' * x <= totalcost)
    JuMP.@constraint(model, sum(x) == n)
    if has_classes
        JuMP.@constraint(model, df[!, :allrounder]' * x >= 2)
        JuMP.@constraint(model, df[!, :sprinter]' * x >= 1)
        JuMP.@constraint(model, df[!, :climber]' * x >= 2)
        JuMP.@constraint(model, df[!, :unclassed]' * x >= 3)
    end
    if max_per_team > 0
        for team in unique(df.team)
            team_keys = df.riderkey[df.team.==team]
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
    resample_optimise(df, scoring, build_model_fn; n_resamples=500, rng, max_per_team=0)

Resampled optimisation: draw noisy strengths, score VG points for that draw,
optimise per draw to compute selection frequencies and expected points that
account for Jensen's inequality (scoring floor at position 31+). A final
deterministic optimisation on the resampled expected points selects the team.

Uses Student's t-distribution with `simulation_df` degrees of freedom for
heavy-tailed noise (set `simulation_df=nothing` for Gaussian).

Returns `(df, top_teams, sim_vg_points)` where:
- `df` gains columns `:selection_frequency` and `:expected_vg_points`
- `top_teams` is a `Vector{DataFrame}` containing the optimal team
- `sim_vg_points` is a `Matrix{Float64}` (n_riders × n_resamples) of per-draw VG points
"""
function resample_optimise(
    df::DataFrame,
    scoring::ScoringTable,
    build_model_fn::Function;
    team_size::Int=6,
    n_resamples::Int=500,
    rng::AbstractRNG=Random.default_rng(),
    max_per_team::Int=0,
    risk_aversion::Float64=0.5,
    breakaway_rates::Vector{Float64}=Float64[],
    breakaway_mean_sectors::Vector{Float64}=Float64[],
    simulation_df::Union{Int,Nothing}=nothing,
)
    n_riders = nrow(df)
    strengths = Float64.(df.strength)
    uncertainties = Float64.(df.uncertainty)
    teams = String.(df.team)

    # Track how often each rider is selected and accumulate VG points per resample
    selection_counts = zeros(Int, n_riders)
    vg_points_sum = zeros(Float64, n_riders)
    sim_vg_points = Matrix{Float64}(undef, n_riders, n_resamples)
    n_successful = 0

    # Welford accumulators for downside semi-deviation (risk-adjusted scoring)
    welford_mean = zeros(Float64, n_riders)
    m2_down = zeros(Float64, n_riders)

    noisy_strengths = Vector{Float64}(undef, n_riders)
    resample_df = copy(df)

    for r = 1:n_resamples
        # 1. Draw noisy strengths from posterior
        for i = 1:n_riders
            noise = simulation_df === nothing ? randn(rng) : _rand_t(rng, simulation_df)
            noisy_strengths[i] = strengths[i] + uncertainties[i] * noise
        end

        # 2. Convert to finishing positions via sortperm
        order = sortperm(noisy_strengths, rev=true)
        positions = Vector{Int}(undef, n_riders)
        for (pos, rider_idx) in enumerate(order)
            positions[rider_idx] = pos
        end

        # 3. Score VG points for this draw (finish + assist)
        sim_pts = zeros(Float64, n_riders)
        for i = 1:n_riders
            sim_pts[i] = Float64(finish_points_for_position(positions[i], scoring))
        end
        # Assist points: teammates of top-3 finishers
        for i = 1:n_riders
            if positions[i] <= 3
                top_team = teams[i]
                for j = 1:n_riders
                    if j != i && teams[j] == top_team
                        sim_pts[j] += scoring.assist_points[positions[i]]
                    end
                end
            end
        end

        # Breakaway sector points (Bernoulli draw per rider)
        if !isempty(breakaway_rates)
            for i = 1:n_riders
                if breakaway_rates[i] > 0.0 && rand(rng) < breakaway_rates[i]
                    sim_pts[i] += breakaway_mean_sectors[i] * scoring.breakaway_points
                end
            end
        end

        # Accumulate for expected VG points calculation and Welford variance tracking
        for i = 1:n_riders
            sim_vg_points[i, r] = sim_pts[i]
            vg_points_sum[i] += sim_pts[i]
            delta = sim_pts[i] - welford_mean[i]
            welford_mean[i] += delta / r
            delta2 = sim_pts[i] - welford_mean[i]
            if sim_pts[i] < welford_mean[i]
                m2_down[i] += delta * delta2
            end
        end

        # 4. Optimise for this draw's realised points
        resample_df[!, :_resample_pts] = sim_pts
        result = build_model_fn(
            resample_df,
            team_size,
            :_resample_pts,
            :cost;
            totalcost=100,
            max_per_team=max_per_team,
        )
        result === nothing && continue
        n_successful += 1

        # Record selected riders
        for (i, key) in enumerate(df.riderkey)
            if JuMP.value(result[key]) > 0.5
                selection_counts[i] += 1
            end
        end
    end

    # Compute expected VG points as mean across resamples
    expected_pts = vg_points_sum ./ n_resamples

    # Risk-adjusted scoring: penalise riders whose high expected points come
    # from volatile outcomes (many zeroes, occasional big scores).
    # Uses downside coefficient of variation for scale-invariant penalty.
    downside_semi_dev = sqrt.(m2_down ./ n_resamples)
    cv_down =
        [ep > 0 ? dsd / ep : 0.0 for (ep, dsd) in zip(expected_pts, downside_semi_dev)]
    risk_adjusted_pts = expected_pts ./ (1.0 .+ risk_aversion .* cv_down)

    df[!, :selection_frequency] = round.(selection_counts ./ n_resamples, digits=3)
    df[!, :expected_vg_points] = round.(expected_pts, digits=1)
    df[!, :downside_semi_dev] = round.(downside_semi_dev, digits=1)

    @info "Resampled optimisation: $n_successful/$n_resamples successful"

    # Final optimisation using risk-adjusted expected VG points.
    # Per-resample team-frequency tracking is too noisy (hundreds of unique
    # compositions with ~150 riders), so we optimise once on the risk-adjusted
    # points that account for both Jensen's inequality and uncertainty bias.
    df[!, :_final_pts] = risk_adjusted_pts
    top_teams = DataFrame[]
    final_result = build_model_fn(
        df,
        team_size,
        :_final_pts,
        :cost;
        totalcost=100,
        max_per_team=max_per_team,
    )
    if final_result !== nothing
        final_keys = Set(k for k in df.riderkey if JuMP.value(final_result[k]) > 0.5)
        final_team = filter(row -> row.riderkey in final_keys, df)
        push!(top_teams, final_team)
    end

    select!(df, Not(:_final_pts))
    return df, top_teams, sim_vg_points
end


"""
    resample_optimise_stage(df, stages, stage_strengths, scoring, build_model_fn; kwargs...)
        -> (DataFrame, Vector{DataFrame}, Matrix{Float64})

Resampled optimisation for stage races: runs `simulate_stage_race` to get
per-draw total VG points, then optimises team selection per draw.

Same output shape as `resample_optimise`: returns `(df, top_teams, sim_vg_points)`
where df gains `:selection_frequency` and `:expected_vg_points`.
"""
function resample_optimise_stage(
    df::DataFrame,
    stages::Vector{StageProfile},
    stage_strengths::Dict{Symbol,Vector{Float64}},
    scoring::StageRaceScoringTable,
    build_model_fn::Function;
    team_size::Int=9,
    n_resamples::Int=500,
    cross_stage_alpha::Float64=0.7,
    rng::AbstractRNG=Random.default_rng(),
    max_per_team::Int=0,
    risk_aversion::Float64=0.5,
)
    n_riders = nrow(df)
    uncertainties = Float64.(df.uncertainty)
    teams = String.(df.team)

    # Run all simulations at once
    sim_vg_points = simulate_stage_race(
        stages, stage_strengths, uncertainties, teams, scoring;
        n_sims=n_resamples, cross_stage_alpha=cross_stage_alpha, rng=rng,
    )

    # Track selection frequency and accumulate points
    selection_counts = zeros(Int, n_riders)
    vg_points_sum = vec(sum(sim_vg_points, dims=2))
    n_successful = 0

    # Welford accumulators for downside semi-deviation
    welford_mean = zeros(Float64, n_riders)
    m2_down = zeros(Float64, n_riders)

    resample_df = copy(df)

    for r in 1:n_resamples
        sim_pts = sim_vg_points[:, r]

        # Welford online variance for downside risk
        for i in 1:n_riders
            delta = sim_pts[i] - welford_mean[i]
            welford_mean[i] += delta / r
            delta2 = sim_pts[i] - welford_mean[i]
            if sim_pts[i] < welford_mean[i]
                m2_down[i] += delta * delta2
            end
        end

        # Optimise for this draw's realised points
        resample_df[!, :_resample_pts] = sim_pts
        result = build_model_fn(
            resample_df, team_size, :_resample_pts, :cost;
            totalcost=100, max_per_team=max_per_team,
        )
        result === nothing && continue
        n_successful += 1

        for (i, key) in enumerate(df.riderkey)
            if JuMP.value(result[key]) > 0.5
                selection_counts[i] += 1
            end
        end
    end

    # Compute expected VG points and risk-adjusted scoring
    expected_pts = vg_points_sum ./ n_resamples
    downside_semi_dev = sqrt.(m2_down ./ n_resamples)
    cv_down = [ep > 0 ? dsd / ep : 0.0 for (ep, dsd) in zip(expected_pts, downside_semi_dev)]
    risk_adjusted_pts = expected_pts ./ (1.0 .+ risk_aversion .* cv_down)

    df[!, :selection_frequency] = round.(selection_counts ./ n_resamples, digits=3)
    df[!, :expected_vg_points] = round.(expected_pts, digits=1)
    df[!, :downside_semi_dev] = round.(downside_semi_dev, digits=1)

    @info "Resampled stage optimisation: $n_successful/$n_resamples successful"

    # Final deterministic optimisation on risk-adjusted expected points
    df[!, :_final_pts] = risk_adjusted_pts
    top_teams = DataFrame[]
    final_result = build_model_fn(
        df, team_size, :_final_pts, :cost;
        totalcost=100, max_per_team=max_per_team,
    )
    if final_result !== nothing
        final_keys = Set(k for k in df.riderkey if JuMP.value(final_result[k]) > 0.5)
        final_team = filter(row -> row.riderkey in final_keys, df)
        push!(top_teams, final_team)
    end

    select!(df, Not(:_final_pts))
    return df, top_teams, sim_vg_points
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
    n::Integer=9,
    points::Symbol=:points,
    cost::Symbol=:cost;
    totalcost::Integer=100,
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
