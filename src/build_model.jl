"""
    ensure_classification_columns!(df::DataFrame)

Ensures that the DataFrame has binary classification columns for each rider class
(allrounder, sprinter, climber, unclassed). Creates them from the :class or
:classraw column if they don't already exist.

Returns true if all columns exist or were successfully created, false otherwise.
"""
function ensure_classification_columns!(
    df::DataFrame;
    required_classes::Vector{String} = ["allrounder", "sprinter", "climber", "unclassed"],
)
    if !hasproperty(df, :class) && !hasproperty(df, :classraw)
        return false
    end

    # Always (re)build the boolean class columns from the source class string.
    # We can't simply skip when a column of the same name exists: the PCS
    # specialty join in `data_assembly.jl` creates a numeric `:climber` rating
    # column (0-1000+) that collides with the VG-class boolean target. Trusting
    # that pre-existing column would let `df[!, :climber]' * x >= 2` be
    # satisfied by any single high-rated rider rather than two riders with
    # `classraw == "Climber"`.
    src = hasproperty(df, :class) ? df.class : df.classraw
    norm_src = lowercase.(replace.(src, " " => ""))
    for class_name in required_classes
        col_name = Symbol(class_name)
        df[!, col_name] = norm_src .== lowercase(class_name)
    end

    return true
end


"""
    _add_class_constraints!(model, x, df, has_classes)

Add the VG Sixes stage-race classification minimums (2 all-rounders, 1 sprinter,
2 climbers, 3 unclassed; the 9th rider is a free wildcard) when class columns are
present. `x` must be indexed by `df.riderkey`.
"""
function _add_class_constraints!(model, x, df::DataFrame, has_classes::Bool)
    if has_classes
        JuMP.@constraint(model, df[!, :allrounder]' * x >= 2)
        JuMP.@constraint(model, df[!, :sprinter]' * x >= 1)
        JuMP.@constraint(model, df[!, :climber]' * x >= 2)
        JuMP.@constraint(model, df[!, :unclassed]' * x >= 3)
    end
    return model
end

"""
    _add_team_cap!(model, x, df, max_per_team)

Cap the number of riders selected from any single team at `max_per_team`
(0 = uncapped). `x` must be indexed by `df.riderkey`.
"""
function _add_team_cap!(model, x, df::DataFrame, max_per_team::Int)
    if max_per_team > 0
        for team in unique(df.team)
            team_keys = df.riderkey[df.team .== team]
            JuMP.@constraint(model, sum(x[k] for k in team_keys) <= max_per_team)
        end
    end
    return model
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
    _add_team_cap!(model, x, inputdf, max_per_team)
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

Enforces VG Sixes classification constraints: 2 all-rounders, 2 climbers,
1 sprinter, 3 unclassed riders, and 1 wildcard. The wildcard slot may be any
class — implemented as `sum(x) == 9` with class minimums summing to 8, so the
optimiser can put the 9th rider in whichever class it likes.

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

    has_classes = ensure_classification_columns!(df)

    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.riderkey], Bin)
    JuMP.@objective(model, Max, df[!, points]' * x)
    JuMP.@constraint(model, df[!, cost]' * x <= totalcost)
    JuMP.@constraint(model, sum(x) == n)
    _add_class_constraints!(model, x, df, has_classes)
    _add_team_cap!(model, x, df, max_per_team)
    JuMP.optimize!(model)
    if JuMP.termination_status(model) != JuMP.OPTIMAL
        @warn("The model was not solved correctly.")
        return nothing
    end
    return JuMP.value.(x)
end

"""
    _resample_core(df, sim_vg_points, build_model_fn; team_size, max_per_team, risk_aversion)
        -> (df, top_teams)

Shared tail of the resampled-optimisation pipeline, once the per-draw VG-points
matrix (`sim_vg_points`, n_riders × n_resamples) is known. Accumulates downside
risk via Welford, optimises each draw to tally selection frequency, writes the
`:selection_frequency`, `:expected_vg_points` and `:downside_semi_dev` columns,
then runs a final deterministic optimise on risk-adjusted points and returns the
chosen team. The per-draw optimise is RNG-free, so building the matrix upfront
(one-day) or via `simulate_stage_race` (stage) yields identical results.
"""
function _resample_core(
    df::DataFrame,
    sim_vg_points::Matrix{Float64},
    build_model_fn::Function;
    team_size::Int,
    max_per_team::Int,
    risk_aversion::Float64,
)
    n_riders, n_resamples = size(sim_vg_points)
    selection_counts = zeros(Int, n_riders)
    vg_points_sum = vec(sum(sim_vg_points, dims = 2))
    n_successful = 0

    # Welford accumulators for downside semi-deviation (risk-adjusted scoring)
    welford_mean = zeros(Float64, n_riders)
    m2_down = zeros(Float64, n_riders)

    resample_df = copy(df)

    for r = 1:n_resamples
        sim_pts = sim_vg_points[:, r]

        for i = 1:n_riders
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
            resample_df,
            team_size,
            :_resample_pts,
            :cost;
            totalcost = 100,
            max_per_team = max_per_team,
        )
        result === nothing && continue
        n_successful += 1

        for (i, key) in enumerate(df.riderkey)
            if JuMP.value(result[key]) > 0.5
                selection_counts[i] += 1
            end
        end
    end

    # Expected VG points and risk-adjusted scoring: penalise riders whose high
    # expected points come from volatile outcomes (many zeroes, occasional big
    # scores). Uses downside coefficient of variation for a scale-invariant penalty.
    expected_pts = vg_points_sum ./ n_resamples
    downside_semi_dev = sqrt.(m2_down ./ n_resamples)
    cv_down =
        [ep > 0 ? dsd / ep : 0.0 for (ep, dsd) in zip(expected_pts, downside_semi_dev)]
    risk_adjusted_pts = expected_pts ./ (1.0 .+ risk_aversion .* cv_down)

    df[!, :selection_frequency] = round.(selection_counts ./ n_resamples, digits = 3)
    df[!, :expected_vg_points] = round.(expected_pts, digits = 1)
    df[!, :downside_semi_dev] = round.(downside_semi_dev, digits = 1)

    @info "Resampled optimisation: $n_successful/$n_resamples successful"

    # Final deterministic optimisation on risk-adjusted expected points. Per-resample
    # team-frequency tracking is too noisy (hundreds of unique compositions with ~150
    # riders), so we optimise once on points that account for both Jensen's inequality
    # and uncertainty bias.
    df[!, :_final_pts] = risk_adjusted_pts
    top_teams = DataFrame[]
    final_result = build_model_fn(
        df,
        team_size,
        :_final_pts,
        :cost;
        totalcost = 100,
        max_per_team = max_per_team,
    )
    if final_result !== nothing
        final_keys = Set(k for k in df.riderkey if JuMP.value(final_result[k]) > 0.5)
        final_team = filter(row -> row.riderkey in final_keys, df)
        push!(top_teams, final_team)
    end

    select!(df, Not(:_final_pts))
    return df, top_teams
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
    team_size::Int = 6,
    n_resamples::Int = 500,
    rng::AbstractRNG = Random.default_rng(),
    max_per_team::Int = 0,
    risk_aversion::Float64 = 0.5,
    breakaway_rates::Vector{Float64} = Float64[],
    breakaway_mean_sectors::Vector{Float64} = Float64[],
    simulation_df::Union{Int,Nothing} = nothing,
)
    n_riders = nrow(df)
    strengths = Float64.(df.strength)
    uncertainties = Float64.(df.uncertainty)
    teams = String.(df.team)

    # Build the per-draw VG-points matrix: draw noisy strengths, rank to positions,
    # and score each draw. RNG is consumed only here; the optimisation tail
    # (`_resample_core`) is deterministic.
    sim_vg_points = Matrix{Float64}(undef, n_riders, n_resamples)
    noisy_strengths = Vector{Float64}(undef, n_riders)

    for r = 1:n_resamples
        # 1. Draw noisy strengths from posterior
        for i = 1:n_riders
            noise = simulation_df === nothing ? randn(rng) : _rand_t(rng, simulation_df)
            noisy_strengths[i] = strengths[i] + uncertainties[i] * noise
        end

        # 2. Convert to finishing positions via sortperm
        order = sortperm(noisy_strengths, rev = true)
        positions = Vector{Int}(undef, n_riders)
        for (pos, rider_idx) in enumerate(order)
            positions[rider_idx] = pos
        end

        # 3. Score VG points for this draw (finish + assist + breakaway)
        sim_pts = zeros(Float64, n_riders)
        _score_vg_draw!(
            sim_pts,
            positions,
            teams,
            scoring;
            breakaway_rates = breakaway_rates,
            mean_sectors = breakaway_mean_sectors,
            rng = rng,
        )
        sim_vg_points[:, r] = sim_pts
    end

    df, top_teams = _resample_core(
        df,
        sim_vg_points,
        build_model_fn;
        team_size = team_size,
        max_per_team = max_per_team,
        risk_aversion = risk_aversion,
    )
    return df, top_teams, sim_vg_points
end


"""
    resample_optimise_stage(df, stages, stage_strengths, scoring, build_model_fn; kwargs...)
        -> (DataFrame, Vector{DataFrame}, Matrix{Float64}, StageRaceDiagnostics)

Resampled optimisation for stage races: runs `simulate_stage_race` to get
per-draw total VG points, then optimises team selection per draw.

Returns `(df, top_teams, sim_vg_points, diagnostics)` where df gains
`:selection_frequency` and `:expected_vg_points`, and `diagnostics` carries
per-stage and per-classification position counts that reports surface as
podium / top-K probabilities.
"""
function resample_optimise_stage(
    df::DataFrame,
    stages::Vector{StageProfile},
    stage_strengths::Dict{Symbol,Vector{Float64}},
    scoring::StageRaceScoringTable,
    build_model_fn::Function;
    team_size::Int = 9,
    n_resamples::Int = 500,
    cross_stage_alpha::Float64 = 0.7,
    gc_strengths::Vector{Float64} = Float64[],
    rng::AbstractRNG = Random.default_rng(),
    max_per_team::Int = 0,
    risk_aversion::Float64 = 0.5,
    sim_config::StageSimConfig = DEFAULT_STAGE_SIM_CONFIG,
)
    uncertainties = Float64.(df.uncertainty)
    teams = String.(df.team)
    # Rider classes drive the attrition hazard (A2). Prefer :classraw, fall back
    # to :class; empty when neither is present (attrition then disabled).
    rider_classes =
        :classraw in propertynames(df) ? String.(df.classraw) :
        :class in propertynames(df) ? String.(df.class) : String[]

    # Run all simulations at once. simulate_stage_race always returns
    # (vg_points, diagnostics); we surface diagnostics for per-stage podium
    # and classification top-K probabilities in reports.
    sim_vg_points, diagnostics = simulate_stage_race(
        stages,
        stage_strengths,
        uncertainties,
        teams,
        scoring;
        n_sims = n_resamples,
        cross_stage_alpha = cross_stage_alpha,
        gc_strengths = gc_strengths,
        rng = rng,
        sim_config = sim_config,
        rider_classes = rider_classes,
    )

    df, top_teams = _resample_core(
        df,
        sim_vg_points,
        build_model_fn;
        team_size = team_size,
        max_per_team = max_per_team,
        risk_aversion = risk_aversion,
    )
    return df, top_teams, sim_vg_points, diagnostics
end


"""
    minimise_cost_stage(inputdf::DataFrame, target_score::Real, n::Integer=9, points::Symbol=:points, cost::Symbol=:cost; totalcost::Integer=100)

Minimise team cost while achieving at least the target score.
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

    has_classes = ensure_classification_columns!(df)

    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.riderkey], Bin)
    JuMP.@objective(model, Min, df[!, cost]' * x)
    JuMP.@constraint(model, df[!, points]' * x >= target_score + 1)
    JuMP.@constraint(model, sum(x) == n)
    _add_class_constraints!(model, x, df, has_classes)
    JuMP.optimize!(model)
    if JuMP.termination_status(model) != JuMP.OPTIMAL
        @warn("The cost minimisation model was not solved correctly.")
        return nothing
    end
    return JuMP.value.(x)
end

# ---------------------------------------------------------------------------
# Hindsight-optimal and cheapest-winning team selection (report retrospectives)
# ---------------------------------------------------------------------------

"""
    compute_optimal_team(df) -> Union{DataFrame, Nothing}

Find the hindsight-optimal one-day team (6 riders, cost <= 100) from actual results.
"""
function compute_optimal_team(df::DataFrame)
    result = build_model_oneday(df, 6, :score, :cost; totalcost = 100)
    result === nothing && return nothing
    chosen_keys = Set(k for k in df.riderkey if result[k] > 0.5)
    return filter(row -> row.riderkey in chosen_keys, df)
end

"""
    compute_cheapest_winning_team(df, target_score) -> Union{DataFrame, Nothing}

Find the minimum-cost one-day team that beats `target_score`.
"""
function compute_cheapest_winning_team(df::DataFrame, target_score::Real)
    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.riderkey], Bin)
    JuMP.@objective(model, Min, df.cost' * x)
    JuMP.@constraint(model, df.score' * x >= target_score + 1)
    JuMP.@constraint(model, sum(x) == 6)
    JuMP.optimize!(model)
    if JuMP.termination_status(model) != JuMP.OPTIMAL
        return nothing
    end
    chosen_keys = Set(k for k in df.riderkey if JuMP.value(x[k]) > 0.5)
    return filter(row -> row.riderkey in chosen_keys, df)
end

"""
    compute_optimal_stage_team(df) -> Union{DataFrame, Nothing}

Find the hindsight-optimal stage race team (9 riders, class constraints, cost <= 100).
"""
function compute_optimal_stage_team(df::DataFrame)
    result = build_model_stage(df, 9, :score, :cost; totalcost = 100)
    result === nothing && return nothing
    chosen_keys = Set(k for k in df.riderkey if result[k] > 0.5)
    return filter(row -> row.riderkey in chosen_keys, df)
end

"""
    compute_cheapest_winning_stage_team(df, target_score) -> Union{DataFrame, Nothing}

Find the minimum-cost 9-rider team that beats `target_score` with class constraints.
"""
function compute_cheapest_winning_stage_team(df::DataFrame, target_score::Real)
    result = minimise_cost_stage(df, target_score, 9, :score, :cost)
    result === nothing && return nothing
    chosen_keys = Set(k for k in df.riderkey if result[k] > 0.5)
    return filter(row -> row.riderkey in chosen_keys, df)
end
