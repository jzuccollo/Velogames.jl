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
function _add_team_cap!(model, x, df::DataFrame, max_per_team::Integer)
    if max_per_team > 0
        for team in unique(df.team)
            team_keys = df.riderkey[df.team .== team]
            JuMP.@constraint(model, sum(x[k] for k in team_keys) <= max_per_team)
        end
    end
    return model
end

"""
    _add_nogood_cuts!(model, x, exclude, team_size)

Forbid each previously-selected roster in `exclude` (a vector of riderkey lists)
via a no-good cut `sum(x[k] for k in team) <= team_size - 1`. Re-solving the model
with the accumulated cuts then yields the next-best *distinct* team, which is how
k-best enumeration works (HiGHS has no native solution pool). `x` must be indexed
by riderkey.
"""
function _add_nogood_cuts!(model, x, exclude::Vector{Vector{String}}, team_size::Integer)
    for team in exclude
        JuMP.@constraint(model, sum(x[k] for k in team) <= team_size - 1)
    end
    return model
end

"""
    _add_force_constraints!(model, x, force_in, force_out)

Pin individual riders in (`x[k] == 1`) or out (`x[k] == 0`) of the solution. Used
by the structural-fork analysis to find the best team *with* vs *without* a given
rider (or forced to include a pair of GC leaders). `x` must be indexed by riderkey.
"""
function _add_force_constraints!(
    model,
    x,
    force_in::Vector{String},
    force_out::Vector{String},
)
    for k in force_in
        JuMP.@constraint(model, x[k] == 1)
    end
    for k in force_out
        JuMP.@constraint(model, x[k] == 0)
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
    max_per_team::Integer = 0,
    exclude::Vector{Vector{String}} = Vector{String}[],
    force_in::Vector{String} = String[],
    force_out::Vector{String} = String[],
)
    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[inputdf.riderkey], Bin)
    JuMP.@objective(model, Max, inputdf[!, points]' * x) # maximise the total score
    JuMP.@constraint(model, inputdf[!, cost]' * x <= totalcost) # cost must be <= totalcost
    JuMP.@constraint(model, sum(x) == n) # exactly n riders must be chosen
    _add_team_cap!(model, x, inputdf, max_per_team)
    _add_nogood_cuts!(model, x, exclude, n)
    _add_force_constraints!(model, x, force_in, force_out)
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
    max_per_team::Integer = 0,
    exclude::Vector{Vector{String}} = Vector{String}[],
    force_in::Vector{String} = String[],
    force_out::Vector{String} = String[],
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
    _add_nogood_cuts!(model, x, exclude, n)
    _add_force_constraints!(model, x, force_in, force_out)
    JuMP.optimize!(model)
    if JuMP.termination_status(model) != JuMP.OPTIMAL
        @warn("The model was not solved correctly.")
        return nothing
    end
    return JuMP.value.(x)
end

"""
    _kbest_team_keys(df, build_model_fn, points_col; team_size, max_per_team, n_alternatives)
        -> Vector{Vector{String}}

Enumerate up to `n_alternatives` distinct best teams on `points_col` by iterated
no-good cuts: solve, record the roster, forbid that exact roster (`exclude`),
re-solve. Reuses `build_model_fn`, so the budget / class / per-team constraints
are honoured automatically on every solve. Returns riderkey lists ranked
best-first (index 1 is the global optimum on `points_col`; each later entry has a
weakly lower objective). Stops early when the model becomes infeasible.
"""
function _kbest_team_keys(
    df::DataFrame,
    build_model_fn::Function,
    points_col::Symbol;
    team_size::Integer,
    max_per_team::Integer,
    n_alternatives::Integer,
)
    excluded = Vector{Vector{String}}()
    for _ = 1:max(1, n_alternatives)
        result = build_model_fn(
            df,
            team_size,
            points_col,
            :cost;
            totalcost = 100,
            max_per_team = max_per_team,
            exclude = excluded,
        )
        result === nothing && break
        keys = String[k for k in df.riderkey if JuMP.value(result[k]) > 0.5]
        isempty(keys) && break
        push!(excluded, keys)
    end
    return excluded
end

"""
    _resample_core!(df, sim_vg_points, build_model_fn; team_size, max_per_team, risk_aversion, n_alternatives)
        -> (df, top_teams)

Shared tail of the resampled-optimisation pipeline, once the per-draw VG-points
matrix (`sim_vg_points`, n_riders × n_resamples) is known. Accumulates downside
risk via Welford, optimises each draw to tally selection frequency, writes the
`:selection_frequency`, `:expected_vg_points` and `:downside_semi_dev` columns,
then enumerates the `n_alternatives` best distinct teams on risk-adjusted points
(k-best via no-good cuts) and returns them ranked best-first. The per-draw
optimise is RNG-free, so building the matrix upfront (one-day) or via
`simulate_stage_race` (stage) yields identical results.
"""
function _resample_core!(
    df::DataFrame,
    sim_vg_points::Matrix{Float64},
    build_model_fn::Function;
    team_size::Integer,
    max_per_team::Integer,
    risk_aversion::Float64,
    n_alternatives::Integer = 20,
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

    # Deterministic optimisation on risk-adjusted expected points. Per-resample
    # team-frequency tracking is too noisy (hundreds of unique compositions with ~150
    # riders), so we optimise on points that account for both Jensen's inequality
    # and uncertainty bias. Rather than a single solve, enumerate the `n_alternatives`
    # best distinct teams (k-best via no-good cuts): the near-optimal set sits within
    # a whisker of the best in EVG, so surfacing it lets the report expose the
    # interchangeable "filler" slots and the structural either/or decisions.
    df[!, :_final_pts] = risk_adjusted_pts
    key_lists = _kbest_team_keys(
        df,
        build_model_fn,
        :_final_pts;
        team_size = team_size,
        max_per_team = max_per_team,
        n_alternatives = n_alternatives,
    )
    select!(df, Not(:_final_pts))

    # Build each team from the cleaned df (so no internal :_final_pts column leaks
    # into the rendered tables); teams stay ranked best-first.
    top_teams = [filter(row -> row.riderkey in Set(keys), df) for keys in key_lists]
    return df, top_teams
end

"""
    resample_optimise!(df, scoring, build_model_fn; n_resamples=500, rng, max_per_team=0)

Resampled optimisation: draw noisy strengths, score VG points for that draw,
optimise per draw to compute selection frequencies and expected points that
account for Jensen's inequality (scoring floor at position 31+). A final
deterministic optimisation on the resampled expected points selects the team.

Uses Student's t-distribution with `simulation_df` degrees of freedom for
heavy-tailed noise (set `simulation_df=nothing` for Gaussian).

Returns `(df, top_teams, sim_vg_points)` where:
- `df` gains columns `:selection_frequency` and `:expected_vg_points`
- `top_teams` is a `Vector{DataFrame}` of the `n_alternatives` best distinct teams,
  ranked best-first (k-best enumeration via no-good cuts); `top_teams[1]` is the
  optimal team
- `sim_vg_points` is a `Matrix{Float64}` (n_riders × n_resamples) of per-draw VG points
"""
function resample_optimise!(
    df::DataFrame,
    scoring::ScoringTable,
    build_model_fn::Function;
    team_size::Integer = 6,
    n_resamples::Int = 500,
    rng::AbstractRNG = Random.default_rng(),
    max_per_team::Integer = 0,
    risk_aversion::Float64 = 0.5,
    n_alternatives::Integer = 20,
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
    # (`_resample_core!`) is deterministic.
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

    df, top_teams = _resample_core!(
        df,
        sim_vg_points,
        build_model_fn;
        team_size = team_size,
        max_per_team = max_per_team,
        risk_aversion = risk_aversion,
        n_alternatives = n_alternatives,
    )
    return df, top_teams, sim_vg_points
end


# ---------------------------------------------------------------------------
# GT VG points-propensity layer (Option B prototype, July 2026)
# ---------------------------------------------------------------------------

"""
    gt_propensity_factors(riderkeys, evg_raw, gt_vg_history_df, current_year;
                          shrinkage=2.0, decay=0.8, floor=30.0) -> Vector{Float64}

Learn each rider's persistent **points-propensity** log-factor `f_i` from the
residual between their REAL historical grand-tour VG totals and the model's
role-blind, ability-implied prediction. Unlike Option A (a strength nudge), this
operates at the VG-points level and is deliberately **two-sided**:

- `r_{i,e}` — the rider's real VG total in past edition `e` (from
  `gt_vg_history_df`, one row per rider-edition).
- `p_i` = `evg_raw[i]` — the model's ability-implied expected VG points for this
  rider (the role-BLIND prediction; when Option A is on this is the A-lifted
  prediction, so B captures only the residual A leaves — see below).
- `f_i` = `s_i · Σ_e w_e·log((r_{i,e}+floor)/(p_i+floor)) / Σ_e w_e`

with recency weight `w_e = decay^years_ago` and partial-pool shrink
`s_i = W_i/(W_i+shrinkage)`, `W_i = Σ_e w_e`. The adjusted EVG is
`p_i·exp(f_i)`, i.e. a log-space convex combination of the model's prediction
and the rider's historical realised total, with weight on history growing with
edition count. Break-hunters (`r≫p`) get `f>0`; locked domestiques (`r≪p`)
`f<0`; leaders (`r≈p`) `f≈0`; riders with no GT history get `f=0` (unchanged).

`floor` (a baseline-participation VG constant) both regularises the log-ratio
away from ±∞ for near-zero `r`/`p` and caps the magnitude for cheap riders.
`shrinkage` is heavy on purpose — this is small-data (~1-3 editions/rider).

**Temporal-integrity approximation.** `p_i` is the CURRENT-race ability-implied
EVG used as the baseline for every past edition, rather than a rigorous
per-edition `p_{i,e}` reconstructed from ≤e-1 data (which would need archived
as-of-date startlists/costs/odds for each past edition — largely unavailable).
This assumes ability is roughly stable across editions (recency weighting
down-weights old ones). It captures the PERSISTENT multiplicative role factor,
which is the signal we want; edition-specific ability drift is the residual
leakage. See roadmap.md "GT VG points-propensity layer (Option B prototype)".
"""
function gt_propensity_factors(
    riderkeys::Vector{String},
    evg_raw::Vector{Float64},
    gt_vg_history_df::Union{DataFrame,Nothing},
    current_year::Int;
    shrinkage::Float64 = 2.0,
    decay::Float64 = 0.8,
    floor::Float64 = 30.0,
)
    n = length(riderkeys)
    factors = zeros(Float64, n)
    (gt_vg_history_df === nothing || nrow(gt_vg_history_df) == 0) && return factors

    hist = Dict{String,Vector{Tuple{Float64,Int}}}()
    for row in eachrow(gt_vg_history_df)
        (ismissing(row.year) || ismissing(row.score)) && continue
        push!(
            get!(hist, row.riderkey, Tuple{Float64,Int}[]),
            (max(0.0, Float64(row.score)), current_year - Int(row.year)),
        )
    end

    for i = 1:n
        h = get(hist, riderkeys[i], Tuple{Float64,Int}[])
        isempty(h) && continue
        p = max(0.0, evg_raw[i])
        wsum = 0.0
        lrsum = 0.0
        for (r, years_ago) in h
            w = decay^max(0, years_ago)
            lrsum += w * log((r + floor) / (p + floor))
            wsum += w
        end
        wsum <= 0.0 && continue
        m = lrsum / wsum
        s = wsum / (wsum + shrinkage)   # partial-pool shrink toward f=0
        factors[i] = s * m
    end
    return factors
end


"""
    resample_optimise_stage!(df, stages, stage_strengths, scoring, build_model_fn; kwargs...)
        -> (DataFrame, Vector{DataFrame}, Matrix{Float64}, StageRaceDiagnostics)

Resampled optimisation for stage races: runs `simulate_stage_race` to get
per-draw total VG points, then optimises team selection per draw.

Returns `(df, top_teams, sim_vg_points, diagnostics)` where df gains
`:selection_frequency` and `:expected_vg_points`, `top_teams` is the
`n_alternatives` best distinct teams ranked best-first (k-best via no-good cuts),
and `diagnostics` carries per-stage and per-classification position counts that
reports surface as podium / top-K probabilities.
"""
function resample_optimise_stage!(
    df::DataFrame,
    stages::Vector{StageProfile},
    stage_strengths::Dict{Symbol,Vector{Float64}},
    scoring::StageRaceScoringTable,
    build_model_fn::Function;
    team_size::Integer = 9,
    n_resamples::Int = 500,
    cross_stage_alpha::Float64 = 0.7,
    gc_strengths::Vector{Float64} = Float64[],
    rng::AbstractRNG = Random.default_rng(),
    max_per_team::Integer = 0,
    risk_aversion::Float64 = 0.5,
    n_alternatives::Integer = 20,
    sim_config::StageSimConfig = DEFAULT_STAGE_SIM_CONFIG,
)
    uncertainties = Float64.(df.uncertainty)
    teams = String.(df.team)

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
    )

    df, top_teams = _resample_core!(
        df,
        sim_vg_points,
        build_model_fn;
        team_size = team_size,
        max_per_team = max_per_team,
        risk_aversion = risk_aversion,
        n_alternatives = n_alternatives,
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

# ---------------------------------------------------------------------------
# Near-optimal team analysis (filler pool + structural forks, report-facing)
# ---------------------------------------------------------------------------

"""
    compute_filler_pool(top_teams) -> (core_df, filler_df, n_teams)

Decompose a k-best near-optimal team set into its two decision layers:

- `core_df` — riders present in **every** one of the `top_teams` (the locked
  picks). Taken from `top_teams[1]` so it carries the full prediction columns.
- `filler_df` — riders present in **some but not all** teams: the interchangeable
  slots. Gains a `:frequency` column (in how many of the near-optimal teams the
  rider appears) and is sorted by frequency, then cost, then EVG.

`n_teams` is `length(top_teams)`. This is the "menu" a fantasy manager actually
chooses from once the optimiser has fixed the expensive core.
"""
function compute_filler_pool(top_teams::Vector{DataFrame})
    isempty(top_teams) && return (DataFrame(), DataFrame(), 0)
    n = length(top_teams)
    key_sets = [Set(String.(t.riderkey)) for t in top_teams]
    core = intersect(key_sets...)

    freq = Dict{String,Int}()
    for ks in key_sets, k in ks
        freq[k] = get(freq, k, 0) + 1
    end

    core_df = filter(row -> row.riderkey in core, top_teams[1])

    all_rows = unique(vcat(top_teams...), :riderkey)
    filler_keys = Set(k for (k, c) in freq if c < n)
    filler_df = filter(row -> row.riderkey in filler_keys, all_rows)
    if nrow(filler_df) > 0
        filler_df[!, :frequency] = [freq[k] for k in filler_df.riderkey]
        sort!(filler_df, [:frequency, :cost, :expected_vg_points], rev = true)
    end
    return (core_df, filler_df, n)
end

"""Solve `build_model_fn` on `points_col` and return `(riderkeys, objective)`.

`objective` is the summed `points_col` over the chosen riders; `(String[], -Inf)`
if infeasible. `force_in`/`force_out` pin riders in or out (structural forks)."""
function _solve_team(
    df::DataFrame,
    build_model_fn::Function,
    points_col::Symbol;
    team_size::Integer,
    max_per_team::Integer,
    force_in::Vector{String} = String[],
    force_out::Vector{String} = String[],
)
    result = build_model_fn(
        df,
        team_size,
        points_col,
        :cost;
        totalcost = 100,
        max_per_team = max_per_team,
        force_in = force_in,
        force_out = force_out,
    )
    result === nothing && return (String[], -Inf)
    keyset = Set(String[k for k in df.riderkey if JuMP.value(result[k]) > 0.5])
    obj = sum(row[points_col] for row in eachrow(df) if row.riderkey in keyset)
    return (collect(keyset), obj)
end

"""
    compute_structural_forks(predicted, build_model_fn; team_size, max_per_team,
                             points_col=:expected_vg_points, n_forks=5) -> (forks, shape)

Surface the major either/or roster decisions in the optimal team, each with the
EVG it puts at stake and its knock-on.

For every rider in the global optimum (best team on `points_col`) it re-solves
with that rider **banned** (`force_out`) and reports:
- `delta` — EVG lost by dropping the rider (global best minus best-without),
- `comes_in` — the riders that enter to spend the freed budget (name/cost/evg).
The pivotal picks (expensive leaders) dominate this ranking; `forks` is the top
`n_forks` by `delta`.

`shape` (when `:strength_gc` is present) is the genuinely structural fork: the two
strongest-GC riders. It compares the best team forced to carry **both** leaders
against the best team carrying **at most one** (`max(best-without-g1,
best-without-g2)`), reporting which shape wins and by how much EVG. `nothing`
when GC strengths are unavailable or the comparison is infeasible.
"""
function compute_structural_forks(
    predicted::DataFrame,
    build_model_fn::Function;
    team_size::Integer,
    max_per_team::Integer,
    points_col::Symbol = :expected_vg_points,
    n_forks::Integer = 5,
)
    meta = Dict(
        String(row.riderkey) => (
            rider = row.rider,
            team = row.team,
            cost = row.cost,
            evg = row[points_col],
        ) for row in eachrow(predicted)
    )

    global_keys, global_obj = _solve_team(
        predicted,
        build_model_fn,
        points_col;
        team_size = team_size,
        max_per_team = max_per_team,
    )
    global_set = Set(global_keys)

    forks = NamedTuple[]
    for k in global_keys
        without_keys, without_obj = _solve_team(
            predicted,
            build_model_fn,
            points_col;
            team_size = team_size,
            max_per_team = max_per_team,
            force_out = String[k],
        )
        delta = global_obj - without_obj
        comes_in = [
            (rider = meta[c].rider, cost = meta[c].cost, evg = meta[c].evg) for
            c in setdiff(Set(without_keys), global_set)
        ]
        sort!(comes_in, by = r -> -r.cost)
        push!(
            forks,
            (
                riderkey = k,
                rider = meta[k].rider,
                team = meta[k].team,
                cost = meta[k].cost,
                evg = meta[k].evg,
                delta = delta,
                comes_in = comes_in,
            ),
        )
    end
    sort!(forks, by = f -> -f.delta)
    forks = collect(first(forks, min(n_forks, length(forks))))

    shape = nothing
    if :strength_gc in propertynames(predicted) && nrow(predicted) >= 2
        gc_order = sortperm(Float64.(predicted.strength_gc), rev = true)
        g1 = String(predicted.riderkey[gc_order[1]])
        g2 = String(predicted.riderkey[gc_order[2]])
        _, both_obj = _solve_team(
            predicted,
            build_model_fn,
            points_col;
            team_size = team_size,
            max_per_team = max_per_team,
            force_in = String[g1, g2],
        )
        _, o1_obj = _solve_team(
            predicted,
            build_model_fn,
            points_col;
            team_size = team_size,
            max_per_team = max_per_team,
            force_out = String[g1],
        )
        _, o2_obj = _solve_team(
            predicted,
            build_model_fn,
            points_col;
            team_size = team_size,
            max_per_team = max_per_team,
            force_out = String[g2],
        )
        atmost_obj = max(o1_obj, o2_obj)
        if isfinite(both_obj) && isfinite(atmost_obj)
            shape = (
                leader1 = meta[g1].rider,
                leader2 = meta[g2].rider,
                both_evg = both_obj,
                atmost_evg = atmost_obj,
                winner = both_obj >= atmost_obj ? :both : :one,
                delta = abs(both_obj - atmost_obj),
            )
        end
    end

    return (forks = forks, shape = shape)
end
