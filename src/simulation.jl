"""
Monte Carlo race simulation and Bayesian strength estimation.

This module converts rider data from multiple sources into expected Velogames
points through:
1. Bayesian strength estimation (combining PCS, race history, VG, odds)
2. Monte Carlo simulation of finishing positions
3. Expected VG points computation from simulated positions
"""

# ---------------------------------------------------------------------------
# Bayesian strength estimation
# ---------------------------------------------------------------------------

"""
    BayesianPosterior

Result of Bayesian strength estimation: a normal distribution parameterised
by mean and variance.
"""
struct BayesianPosterior
    mean::Float64
    variance::Float64
end

"""
    StrengthEstimate

Extended result of `estimate_rider_strength`: the final posterior plus the
mean shift contributed by each signal source. Each `shift_*` field records
how much that signal moved the posterior mean relative to the mean before
that update step.
"""
struct StrengthEstimate
    mean::Float64
    variance::Float64
    shift_pcs::Float64
    shift_vg::Float64
    shift_form::Float64
    shift_trajectory::Float64
    shift_history::Float64
    shift_vg_history::Float64
    shift_oracle::Float64
    shift_qualitative::Float64
    shift_odds::Float64
end

"""
    BayesianConfig

Hyperparameters for Bayesian rider strength estimation.

An uninformative prior (mean=0, `prior_variance`) is updated sequentially
by PCS specialty and other signals. Lower variance means the signal is
treated as more precise.

The posterior mean is a precision-weighted average, where precision = 1/variance. So:

    - Doubling the variance halves the precision, which halves that signal's weight in the weighted average — so yes, it contributes roughly half as much to the posterior mean.
    - But "half as much" is relative to the other signals' precisions. The actual influence of any one signal depends on the ratio of its precision to the sum of all precisions (prior + all observations so far).
"""
@kwdef struct BayesianConfig
    pcs_variance::Float64 = 7.9
    vg_variance::Float64 = 1.4
    form_variance::Float64 = 0.9
    trajectory_variance::Float64 = 3.5
    hist_base_variance::Float64 = 3.0
    hist_decay_rate::Float64 = 3.2
    vg_hist_base_variance::Float64 = 4.8
    vg_hist_decay_rate::Float64 = 1.3
    odds_variance::Float64 = 0.3
    oracle_variance::Float64 = 0.5
    qualitative_base_variance::Float64 = 2.0
    # Heuristic divisor to scale log-odds to z-score range.
    # With ~150 starters, a 10% favourite produces log(0.1 / 0.0067) ≈ 2.7,
    # which / 2.0 gives ~1.35 — a reasonable "1.35 SD above average" strength signal.
    odds_normalisation::Float64 = 2.0
    # Equicorrelation discount for correlated signals.
    # With n signals at pairwise correlation ρ, effective precision is
    # Στ_i / (1 + ρ(n-1)) instead of Στ_i. Prevents over-concentration of
    # posterior for favourites who have many correlated signal sources.
    signal_correlation::Float64 = 0.1
    # Scales vg_variance early in the season when few riders have points.
    # Effective variance = vg_variance * (1 + penalty * (1 - frac_nonzero)).
    # At opening weekend (~10% with points): ~6.6. Late season (~80%): ~2.4.
    vg_season_penalty::Float64 = 1.3
    prior_variance::Float64 = 100.0  # uninformative prior (SD=10 on z-score scale)
    # --- Absence floors ---
    # When a signal covers the field but a rider is missing, absence is
    # informative. `floor_signals` controls which signals apply this logic.
    # All floor observations use `floor_variance_multiplier × base_variance`
    # (less precise than direct observations).
    #
    # Two floor mechanisms:
    #   :odds, :oracle — market-based: absent riders share the residual
    #       probability mass (data-driven, varies per race).
    #   :form, :qualitative — fixed: absent riders get `absence_floor_strength`
    #       as a z-score observation (same for every race, tunable below).
    floor_signals::Set{Symbol} = Set([:odds, :oracle])
    floor_variance_multiplier::Float64 = 2.0
    absence_floor_strength::Float64 = -0.5
end

"""Default Bayesian hyperparameters."""
const DEFAULT_BAYESIAN_CONFIG = BayesianConfig()

"""
    bayesian_update(prior::BayesianPosterior, observation::Float64, obs_variance::Float64) -> BayesianPosterior

Update a normal prior with a single observation (normal-normal conjugate update).

The posterior mean is a precision-weighted average of the prior mean and the
observation. The posterior variance is the harmonic mean of the prior and
observation variances.
"""
function bayesian_update(
    prior::BayesianPosterior,
    observation::Float64,
    obs_variance::Float64,
)
    prior_precision = 1.0 / prior.variance
    obs_precision = 1.0 / obs_variance
    post_precision = prior_precision + obs_precision
    post_mean =
        (prior_precision * prior.mean + obs_precision * observation) / post_precision
    post_variance = 1.0 / post_precision
    return BayesianPosterior(post_mean, post_variance)
end

"""
    estimate_rider_strength(;
        pcs_score, race_history, race_history_years_ago,
        race_history_variance_penalties, vg_points,
        vg_race_history, vg_race_history_years_ago,
        odds_implied_prob, oracle_implied_prob, n_starters,
        config
    ) -> BayesianPosterior

Estimate a rider's strength for a specific race using Bayesian updating.

Returns a `BayesianPosterior` with mean (strength) and variance (uncertainty).

## Signal hierarchy (from broadest to most specific):
1. **PCS score** (prior): general ability from ProCyclingStats ranking/specialty
2. **VG season points** (broad form): current season Velogames performance
3. **PCS race history** (specific): historical finishing positions in this or similar races
4. **VG race history** (specific): historical VG points from past editions (z-scored per year)
5. **Cycling Oracle** (model prediction): algorithmic win probabilities
6. **Betting odds** (market consensus): if available, the most precise signal

## Data arguments
- `pcs_score`: normalised PCS specialty score (z-scored, mean 0, std 1)
- `race_history`: vector of normalised finishing positions from past editions
  (lower = better; converted to strength via negative rank mapping)
- `race_history_years_ago`: how many years ago each history entry is (for recency weighting)
- `race_history_variance_penalties`: per-entry variance penalty (0.0 for exact-race,
  1.0 for similar-race history). Same length as `race_history`.
- `vg_points`: normalised VG season points (z-scored)
- `vg_race_history`: vector of z-scored VG race points from past editions
- `vg_race_history_years_ago`: how many years ago each VG history entry is
- `odds_implied_prob`: implied win probability from betting odds (0-1, 0 = not available)
- `oracle_implied_prob`: win probability from Cycling Oracle (0-1, 0 = not available)
- `n_starters`: expected number of starters (used to scale odds to strength)
- `config`: `BayesianConfig` controlling variance hyperparameters (default: `DEFAULT_BAYESIAN_CONFIG`)
"""
function estimate_rider_strength(;
    pcs_score::Float64=0.0,
    has_pcs::Bool=true,
    race_history::Vector{Float64}=Float64[],
    race_history_years_ago::Vector{Int}=Int[],
    race_history_variance_penalties::Vector{Float64}=Float64[],
    vg_points::Float64=0.0,
    form_score::Float64=0.0,
    vg_race_history::Vector{Float64}=Float64[],
    vg_race_history_years_ago::Vector{Int}=Int[],
    odds_implied_prob::Float64=0.0,
    oracle_implied_prob::Float64=0.0,
    odds_floor_strength::Float64=0.0,
    oracle_floor_strength::Float64=0.0,
    form_floor_strength::Float64=0.0,
    qualitative_floor_strength::Float64=0.0,
    trajectory_score::Float64=0.0,
    qualitative_adjustments::Vector{Float64}=Float64[],
    qualitative_confidences::Vector{Float64}=Float64[],
    n_starters::Int=150,
    config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
)
    # --- Uninformative prior ---
    # Start from a diffuse prior (mean=0, large variance). All signals,
    # including PCS specialty, update this as observations.
    prior = BayesianPosterior(0.0, config.prior_variance)
    posterior = prior
    n_signals = 0

    # --- Update with PCS specialty ---
    # PCS specialty z-score is the broadest signal: general rider ability.
    # Only applied when the rider has real PCS data (not coalesced-from-missing).
    mean_before = posterior.mean
    if has_pcs
        posterior = bayesian_update(posterior, pcs_score, config.pcs_variance)
        n_signals += 1
    end
    shift_pcs = posterior.mean - mean_before

    # --- Update with VG season points ---
    # VG points reflect current season form. Moderate precision.
    mean_before = posterior.mean
    if vg_points != 0.0
        posterior = bayesian_update(posterior, vg_points, config.vg_variance)
        n_signals += 1
    end
    shift_vg = posterior.mean - mean_before

    # --- Update with PCS form score ---
    # Recent cross-race form from PCS startlist/form page. Captures performance
    # across all races in the last ~6 weeks, filling the gap between broad
    # season points and race-specific history.
    mean_before = posterior.mean
    if form_score != 0.0
        posterior = bayesian_update(posterior, form_score, config.form_variance)
        n_signals += 1
    elseif form_floor_strength != 0.0
        floor_var = config.form_variance * config.floor_variance_multiplier
        posterior = bayesian_update(posterior, form_floor_strength, floor_var)
        n_signals += 1
    end
    shift_form = posterior.mean - mean_before

    # --- Update with trajectory signal ---
    # Captures improving (positive) or declining (negative) riders by comparing
    # current PCS ability to historical race performance. Only applied when
    # the caller has computed a trajectory score (riders with race history).
    mean_before = posterior.mean
    if trajectory_score != 0.0
        posterior = bayesian_update(posterior, trajectory_score, config.trajectory_variance)
        n_signals += 1
    end
    shift_trajectory = posterior.mean - mean_before

    # --- Update with PCS race-specific history ---
    # Each past result in this or similar races is a strong signal.
    # More recent results are more informative (lower variance).
    # Similar-race history gets an additional variance penalty.
    mean_before = posterior.mean
    if length(race_history) != length(race_history_years_ago)
        @warn "race_history ($(length(race_history))) and race_history_years_ago ($(length(race_history_years_ago))) have different lengths; using pairwise minimum"
    end
    penalties = if isempty(race_history_variance_penalties)
        zeros(length(race_history))
    else
        race_history_variance_penalties
    end
    for (i, (hist_strength, years_ago)) in
        enumerate(zip(race_history, race_history_years_ago))
        penalty = i <= length(penalties) ? penalties[i] : 0.0
        hist_var = config.hist_base_variance + config.hist_decay_rate * years_ago + penalty
        posterior = bayesian_update(posterior, hist_strength, hist_var)
        n_signals += 1
    end
    shift_history = posterior.mean - mean_before

    # --- Update with VG race history ---
    # Actual VG points from past editions, z-scored per year. Directly measures
    # the quantity we're optimising, so a strong signal.
    mean_before = posterior.mean
    if length(vg_race_history) != length(vg_race_history_years_ago)
        @warn "vg_race_history ($(length(vg_race_history))) and vg_race_history_years_ago ($(length(vg_race_history_years_ago))) have different lengths"
    end
    for (vg_strength, years_ago) in zip(vg_race_history, vg_race_history_years_ago)
        vg_var = config.vg_hist_base_variance + config.vg_hist_decay_rate * years_ago
        posterior = bayesian_update(posterior, vg_strength, vg_var)
        n_signals += 1
    end
    shift_vg_history = posterior.mean - mean_before

    # --- Update with Cycling Oracle predictions ---
    # Algorithmic win probabilities. Less precise than market odds but covers more races.
    mean_before = posterior.mean
    if oracle_implied_prob > 0.0
        baseline_prob = 1.0 / n_starters
        oracle_strength =
            log(oracle_implied_prob / baseline_prob) / config.odds_normalisation
        posterior = bayesian_update(posterior, oracle_strength, config.oracle_variance)
        n_signals += 1
    elseif oracle_floor_strength != 0.0
        floor_var = config.oracle_variance * config.floor_variance_multiplier
        posterior = bayesian_update(posterior, oracle_floor_strength, floor_var)
        n_signals += 1
    end
    shift_oracle = posterior.mean - mean_before

    # --- Update with qualitative intelligence ---
    # Expert judgements from podcast analysis, news, etc. Each source is a
    # separate observation. Effective variance = base_variance / confidence,
    # so high-confidence intelligence (0.8) gets variance ~3.1 and low (0.3)
    # gets ~8.3 — placing it between oracle and the diffuse prior.
    mean_before = posterior.mean
    if !isempty(qualitative_adjustments)
        for (adj, conf) in zip(qualitative_adjustments, qualitative_confidences)
            if conf > 0.0
                eff_var = config.qualitative_base_variance / conf
                posterior = bayesian_update(posterior, adj, eff_var)
                n_signals += 1
            end
        end
    elseif qualitative_floor_strength != 0.0
        floor_var = config.qualitative_base_variance * config.floor_variance_multiplier
        posterior = bayesian_update(posterior, qualitative_floor_strength, floor_var)
        n_signals += 1
    end
    shift_qualitative = posterior.mean - mean_before

    # --- Update with betting odds ---
    # Odds-implied probability is the market's posterior. Very precise when available.
    mean_before = posterior.mean
    if odds_implied_prob > 0.0
        baseline_prob = 1.0 / n_starters
        odds_strength = log(odds_implied_prob / baseline_prob) / config.odds_normalisation
        posterior = bayesian_update(posterior, odds_strength, config.odds_variance)
        n_signals += 1
    elseif odds_floor_strength != 0.0
        floor_var = config.odds_variance * config.floor_variance_multiplier
        posterior = bayesian_update(posterior, odds_floor_strength, floor_var)
        n_signals += 1
    end
    shift_odds = posterior.mean - mean_before

    # --- Equicorrelation precision discount ---
    # Signals are correlated (all measure "rider quality"), so summing precisions
    # overstates certainty. Under exchangeable correlation ρ, the effective
    # precision of n observations is Στ_i / (1 + ρ(n-1)).
    ρ = config.signal_correlation
    if n_signals > 1 && ρ > 0
        prior_prec = 1.0 / prior.variance
        post_prec = 1.0 / posterior.variance
        obs_prec = post_prec - prior_prec
        discount = 1.0 + ρ * (n_signals - 1)
        eff_obs_prec = obs_prec / discount
        # Recover precision-weighted observation mean from the naive posterior
        obs_mean = (posterior.mean * post_prec - prior.mean * prior_prec) / obs_prec
        eff_prec = prior_prec + eff_obs_prec
        posterior = BayesianPosterior(
            (prior_prec * prior.mean + eff_obs_prec * obs_mean) / eff_prec,
            1.0 / eff_prec,
        )
    end

    return StrengthEstimate(
        posterior.mean,
        posterior.variance,
        shift_pcs,
        shift_vg,
        shift_form,
        shift_trajectory,
        shift_history,
        shift_vg_history,
        shift_oracle,
        shift_qualitative,
        shift_odds,
    )
end

"""
    position_to_strength(position::Int, n_starters::Int) -> Float64

Convert a finishing position to a strength score (z-score-like).
Position 1 maps to a high positive score, position n_starters maps to a low negative score.
Uses logit transform of fractional rank, clamped to (0, 1) for safety.
This gives ~2.5 for position 1 in a 150-rider race, ~-2.5 for last.
"""
function position_to_strength(position::Int, n_starters::Int)
    # Fractional rank: 0 (best) to 1 (worst)
    frac = position / (n_starters + 1)
    # Clamp to (0.001, 0.999) to prevent log domain errors when
    # historical positions exceed the current field size
    frac = clamp(frac, 0.001, 0.999)
    return -log(frac / (1.0 - frac))  # logit transform
end

# ---------------------------------------------------------------------------
# Monte Carlo race simulation
# ---------------------------------------------------------------------------

function _rand_t(rng::AbstractRNG, df::Int)
    z = randn(rng)
    v = sum(randn(rng)^2 for _ = 1:df)
    return z * sqrt(df / v)
end

"""
    simulate_race(strengths, uncertainties; n_sims, rng, simulation_df) -> Matrix{Int}

Simulate a race `n_sims` times using Monte Carlo.

For each simulation, adds noise (scaled by each rider's uncertainty)
to their strength score, then ranks riders by noisy strength (highest = 1st place).
Uses Student's t-distribution with `simulation_df` degrees of freedom for
heavy-tailed noise (set `simulation_df=nothing` for Gaussian).

Returns a `n_riders x n_sims` matrix where entry [i, s] is rider i's finishing
position in simulation s.
"""
function simulate_race(
    strengths::Vector{Float64},
    uncertainties::Vector{Float64};
    n_sims::Int=10000,
    rng::AbstractRNG=Random.default_rng(),
    simulation_df::Union{Int,Nothing}=nothing,
)
    n_riders = length(strengths)
    @assert length(uncertainties) == n_riders "Length mismatch: strengths and uncertainties"

    positions = Matrix{Int}(undef, n_riders, n_sims)
    noisy_strengths = Vector{Float64}(undef, n_riders)

    for s = 1:n_sims
        for i = 1:n_riders
            noise = simulation_df === nothing ? randn(rng) : _rand_t(rng, simulation_df)
            noisy_strengths[i] = strengths[i] + uncertainties[i] * noise
        end
        order = sortperm(noisy_strengths, rev=true)
        for (pos, rider_idx) in enumerate(order)
            positions[rider_idx, s] = pos
        end
    end

    return positions
end

"""
    position_probabilities(sim_positions::Matrix{Int}; max_position::Int=30) -> Matrix{Float64}

Convert simulation results to probability distributions over positions.

Returns a `n_riders x max_position` matrix where entry [i, k] is the probability
that rider i finishes in position k.
"""
function position_probabilities(sim_positions::Matrix{Int}; max_position::Int=30)
    n_riders, n_sims = size(sim_positions)
    probs = zeros(Float64, n_riders, max_position)

    for i = 1:n_riders
        for s = 1:n_sims
            pos = sim_positions[i, s]
            if 1 <= pos <= max_position
                probs[i, pos] += 1.0
            end
        end
        probs[i, :] ./= n_sims
    end

    return probs
end

# ---------------------------------------------------------------------------
# Expected VG points from simulations
# ---------------------------------------------------------------------------

"""
    expected_vg_points(sim_positions::Matrix{Int}, rider_teams::Vector{String},
                       scoring::ScoringTable) -> Vector{Float64}

Compute expected Velogames points for each rider from Monte Carlo simulation results.

Includes:
- **Finish points**: based on simulated finishing position (top 30 score)
- **Assist points**: awarded when a teammate finishes top 3

Returns a vector of expected VG points per rider.
"""
function expected_vg_points(
    sim_positions::Matrix{Int},
    rider_teams::Vector{String},
    scoring::ScoringTable,
)
    n_riders, n_sims = size(sim_positions)
    @assert length(rider_teams) == n_riders "Length mismatch: rider_teams"

    total_points = zeros(Float64, n_riders)

    # Welford accumulators for downside semi-deviation
    welford_mean = zeros(Float64, n_riders)
    m2_down = zeros(Float64, n_riders)
    sim_pts = zeros(Float64, n_riders)

    for s = 1:n_sims
        # --- Finish points ---
        for i = 1:n_riders
            pos = sim_positions[i, s]
            sim_pts[i] = Float64(finish_points_for_position(pos, scoring))
        end

        # --- Assist points ---
        # Find which riders finished 1st, 2nd, 3rd in this simulation
        top3_riders = Int[]
        top3_positions = Int[]
        for i = 1:n_riders
            pos = sim_positions[i, s]
            if pos <= 3
                push!(top3_riders, i)
                push!(top3_positions, pos)
            end
        end

        # Award assist points to teammates of top-3 finishers
        for (top_rider, top_pos) in zip(top3_riders, top3_positions)
            top_team = rider_teams[top_rider]
            for i = 1:n_riders
                if i != top_rider && rider_teams[i] == top_team
                    sim_pts[i] += scoring.assist_points[top_pos]
                end
            end
        end

        # Accumulate totals and Welford downside tracking
        for i = 1:n_riders
            total_points[i] += sim_pts[i]
            delta = sim_pts[i] - welford_mean[i]
            welford_mean[i] += delta / s
            delta2 = sim_pts[i] - welford_mean[i]
            if sim_pts[i] < welford_mean[i]
                m2_down[i] += delta * delta2
            end
        end
    end

    mean_pts = total_points ./ n_sims
    downside_semi_dev = sqrt.(m2_down ./ n_sims)
    return mean_pts, downside_semi_dev
end

"""
    breakaway_sectors_from_km(breakaway_km, total_distance_km) -> Int

Count the number of VG breakaway sectors a rider earns based on how far they
were in the break and the total race distance.

VG awards points at four sector checkpoints:
- 50% of total distance
- 50 km to go
- 20 km to go
- 10 km to go

A rider earns a sector point for each checkpoint they were still ahead of the
peloton, i.e. where `breakaway_km >= checkpoint > 0`.
"""
function breakaway_sectors_from_km(breakaway_km::Float64, total_distance_km::Float64)::Int
    total_distance_km <= 0.0 && return 0
    checkpoints = [
        0.5 * total_distance_km,
        total_distance_km - 50.0,
        total_distance_km - 20.0,
        total_distance_km - 10.0,
    ]
    return count(cp -> cp > 0.0 && breakaway_km >= cp, checkpoints)
end

"""
    simulate_vg_points(sim_positions, rider_teams, scoring; breakaway_rates, mean_sectors, rng)
        -> (mean_pts, std_pts, downside_std)

Compute per-rider mean, standard deviation, and downside semi-deviation of VG
points across simulations.

Scores each simulation using finish points, assist points, and optionally breakaway
sector points. Uses Welford's online algorithm for numerically stable variance
computation without materialising the full n_riders × n_sims matrix.

When `breakaway_rates` is non-empty, each rider gets a Bernoulli draw per
simulation: if the draw succeeds (probability = `breakaway_rates[i]`), they
earn `mean_sectors[i] * scoring.breakaway_points` additional points.

The downside semi-deviation only accumulates squared deviations for simulations
where the rider scores *below* the running mean, so upside variance (scoring
unexpectedly well) is not penalised. This is appropriate for the heavily
right-skewed VG points distributions where most variance is upside.

Returns `(mean_pts, std_pts, downside_std)` vectors of length n_riders.
"""
function simulate_vg_points(
    sim_positions::Matrix{Int},
    rider_teams::Vector{String},
    scoring::ScoringTable;
    breakaway_rates::Vector{Float64}=Float64[],
    mean_sectors::Vector{Float64}=Float64[],
    rng::AbstractRNG=Random.default_rng(),
)
    n_riders, n_sims = size(sim_positions)
    @assert length(rider_teams) == n_riders "Length mismatch: rider_teams"

    use_breakaway = !isempty(breakaway_rates) && length(breakaway_rates) == n_riders
    points_per_sector = scoring.breakaway_points

    # Welford's online mean and variance
    mean_pts = zeros(Float64, n_riders)
    m2 = zeros(Float64, n_riders)  # sum of squared deviations from current mean
    m2_down = zeros(Float64, n_riders)  # downside only: squared deviations when below mean
    sim_pts = Vector{Float64}(undef, n_riders)

    for s = 1:n_sims
        # --- Finish points ---
        for i = 1:n_riders
            sim_pts[i] = Float64(finish_points_for_position(sim_positions[i, s], scoring))
        end

        # --- Assist points ---
        for i = 1:n_riders
            pos = sim_positions[i, s]
            if pos <= 3
                top_team = rider_teams[i]
                for j = 1:n_riders
                    if j != i && rider_teams[j] == top_team
                        sim_pts[j] += scoring.assist_points[pos]
                    end
                end
            end
        end

        # --- Breakaway points (one-day only, empirical Bernoulli) ---
        if use_breakaway
            for i = 1:n_riders
                if breakaway_rates[i] > 0.0 && rand(rng) < breakaway_rates[i]
                    sim_pts[i] += mean_sectors[i] * points_per_sector
                end
            end
        end

        # --- Welford update ---
        for i = 1:n_riders
            delta = sim_pts[i] - mean_pts[i]
            mean_pts[i] += delta / s
            delta2 = sim_pts[i] - mean_pts[i]
            m2[i] += delta * delta2
            # Downside semi-deviation: only accumulate when below the running mean
            if sim_pts[i] < mean_pts[i]
                m2_down[i] += delta * delta2
            end
        end
    end

    std_pts = [n_sims > 1 ? sqrt(m2[i] / (n_sims - 1)) : 0.0 for i = 1:n_riders]
    downside_std = [n_sims > 1 ? sqrt(m2_down[i] / (n_sims - 1)) : 0.0 for i = 1:n_riders]
    return (mean_pts, std_pts, downside_std)
end

# ---------------------------------------------------------------------------
# Class-aware strength estimation for stage races
# ---------------------------------------------------------------------------

"""
Class-aware PCS specialty blending weights for stage races.

Each rider classification maps to a weighted blend of PCS specialty columns,
reflecting how that type of rider contributes VG points across a grand tour.
"""
const STAGE_RACE_PCS_WEIGHTS = Dict(
    "allrounder" =>
        Dict(:gc => 0.5, :tt => 0.25, :climber => 0.25, :sprint => 0.0, :oneday => 0.0),
    "climber" =>
        Dict(:gc => 0.15, :tt => 0.15, :climber => 0.7, :sprint => 0.0, :oneday => 0.0),
    "sprinter" =>
        Dict(:gc => 0.2, :tt => 0.2, :climber => 0.0, :sprint => 0.3, :oneday => 0.3),
    "unclassed" =>
        Dict(:gc => 0.3, :tt => 0.15, :climber => 0.15, :sprint => 0.0, :oneday => 0.4),
)

"""
    compute_stage_race_pcs_score(row, class::String) -> Float64

Compute a blended PCS score for a rider based on their classification and the
stage race weighting scheme. Falls back to the one-day score if classification
is unknown.
"""
function compute_stage_race_pcs_score(row, class::String)
    weights =
        get(STAGE_RACE_PCS_WEIGHTS, lowercase(class), STAGE_RACE_PCS_WEIGHTS["unclassed"])
    score = 0.0
    for (col, w) in weights
        if w > 0 && col in propertynames(row)
            val = getproperty(row, col)
            score += w * Float64(coalesce(val, 0.0))
        end
    end
    return score
end

# ---------------------------------------------------------------------------
# High-level prediction pipeline
# ---------------------------------------------------------------------------

"""
    estimate_strengths(rider_df, race_type; kwargs...) -> DataFrame

Bayesian strength estimation pipeline: takes rider data from multiple sources
and computes posterior strength and uncertainty for each rider.

## Race types
- `:oneday` — uses PCS one-day specialty as the prior
- `:stage` — uses class-aware PCS blending as the prior

## Returns
The input DataFrame augmented with:
- `strength`, `uncertainty` — posterior estimates
- `has_pcs`, `has_race_history`, etc. — signal availability flags
- `shift_pcs`, `shift_vg`, etc. — per-signal mean shifts (diagnostics)
- `domestique_penalty` — applied domestique discount
"""
function estimate_strengths(
    rider_df::DataFrame;
    race_history_df::Union{DataFrame,Nothing}=nothing,
    odds_df::Union{DataFrame,Nothing}=nothing,
    oracle_df::Union{DataFrame,Nothing}=nothing,
    vg_history_df::Union{DataFrame,Nothing}=nothing,
    qualitative_df::Union{DataFrame,Nothing}=nothing,
    form_df::Union{DataFrame,Nothing}=nothing,
    seasons_df::Union{DataFrame,Nothing}=nothing,
    race_type::Symbol=:oneday,
    bayesian_config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing}=nothing,
    race_date::Union{Date,Nothing}=nothing,
    domestique_discount::Float64=0.0,
    disable_trajectory::Bool=false,
)
    df = copy(rider_df)
    n_riders = nrow(df)

    # --- Normalise input columns ---
    pts_col = :points
    cost_col = :cost

    vg_pts = Float64.(coalesce.(df[!, pts_col], 0.0))
    n_starters = n_riders

    # Z-score normalise VG points
    vg_mean = mean(vg_pts)
    vg_std = std(vg_pts)
    vg_z = vg_std > 0 ? (vg_pts .- vg_mean) ./ vg_std : zeros(n_riders)

    # --- Season-adaptive VG variance ---
    # Early in the season, few riders have VG points, making the signal noisy.
    # Scale vg_variance up when few riders have scored.
    frac_nonzero = count(vg_pts .> 0) / max(length(vg_pts), 1)
    season_scale = 1.0 + bayesian_config.vg_season_penalty * (1.0 - frac_nonzero)
    effective_vg_variance = bayesian_config.vg_variance * season_scale
    effective_config = BayesianConfig(
        pcs_variance=bayesian_config.pcs_variance,
        vg_variance=effective_vg_variance,
        form_variance=bayesian_config.form_variance,
        trajectory_variance=bayesian_config.trajectory_variance,
        hist_base_variance=bayesian_config.hist_base_variance,
        hist_decay_rate=bayesian_config.hist_decay_rate,
        vg_hist_base_variance=bayesian_config.vg_hist_base_variance,
        vg_hist_decay_rate=bayesian_config.vg_hist_decay_rate,
        odds_variance=bayesian_config.odds_variance,
        oracle_variance=bayesian_config.oracle_variance,
        qualitative_base_variance=bayesian_config.qualitative_base_variance,
        odds_normalisation=bayesian_config.odds_normalisation,
        signal_correlation=bayesian_config.signal_correlation,
        vg_season_penalty=bayesian_config.vg_season_penalty,
        prior_variance=bayesian_config.prior_variance,
        floor_variance_multiplier=bayesian_config.floor_variance_multiplier,
        floor_signals=bayesian_config.floor_signals,
        absence_floor_strength=bayesian_config.absence_floor_strength,
    )
    @info "Season-adaptive VG variance: $(round(effective_vg_variance, digits=2)) " *
          "($(round(100 * frac_nonzero, digits=0))% with points, scale=$(round(season_scale, digits=2)))"

    # --- Compute PCS z-scores (race-type-dependent) ---
    pcs_z = zeros(n_riders)
    if race_type == :stage
        # Class-aware blended PCS score for stage races
        class_col =
            :classraw in propertynames(df) ? :classraw :
            :class in propertynames(df) ? :class : nothing
        pcs_raw = zeros(n_riders)
        for i = 1:n_riders
            rider_class =
                class_col !== nothing ? lowercase(string(df[i, class_col])) : "unclassed"
            pcs_raw[i] = compute_stage_race_pcs_score(df[i, :], rider_class)
        end
        pcs_mean = mean(pcs_raw)
        pcs_std = std(pcs_raw)
        pcs_z = pcs_std > 0 ? (pcs_raw .- pcs_mean) ./ pcs_std : zeros(n_riders)
    else
        # One-day: use PCS one-day specialty directly
        if :oneday in propertynames(df)
            pcs_raw = Float64.(coalesce.(df.oneday, 0.0))
            pcs_mean = mean(pcs_raw)
            pcs_std = std(pcs_raw)
            pcs_z = pcs_std > 0 ? (pcs_raw .- pcs_mean) ./ pcs_std : zeros(n_riders)
        end
    end

    # --- Build odds lookup ---
    odds_lookup = Dict{String,Float64}()
    if odds_df !== nothing &&
       :riderkey in propertynames(odds_df) &&
       :odds in propertynames(odds_df)
        raw_probs = 1.0 ./ Float64.(odds_df.odds)
        overround = sum(raw_probs)
        for (i, row) in enumerate(eachrow(odds_df))
            odds_lookup[row.riderkey] = raw_probs[i] / overround
        end
    end

    # --- Build Cycling Oracle lookup ---
    oracle_lookup = Dict{String,Float64}()
    if oracle_df !== nothing &&
       :riderkey in propertynames(oracle_df) &&
       :win_prob in propertynames(oracle_df)
        for row in eachrow(oracle_df)
            oracle_lookup[row.riderkey] = Float64(row.win_prob)
        end
    end

    # --- Compute market-based floor strengths (odds/oracle) ---
    # See BayesianConfig.floor_signals for the two floor mechanisms.
    # Odds/oracle: absent riders share the residual probability mass.
    rider_keys = Set(df.riderkey)
    odds_floor_strength_val = 0.0
    if :odds in effective_config.floor_signals && !isempty(odds_lookup)
        listed_prob = sum(values(odds_lookup))
        n_listed = length(intersect(keys(odds_lookup), rider_keys))
        n_absent = n_riders - n_listed
        if n_absent > 0
            # Residual probability shared among absent riders. If overround
            # leaves no residual, use half the smallest listed probability
            # as a conservative floor (the market priced them below the worst listed).
            residual_prob = 1.0 - listed_prob
            floor_prob = if residual_prob > 0.001
                residual_prob / n_absent
            else
                minimum(values(odds_lookup)) * 0.5
            end
            baseline_prob = 1.0 / n_starters
            odds_floor_strength_val = log(floor_prob / baseline_prob) / effective_config.odds_normalisation
        end
        @info "Odds floor: $n_listed priced, $n_absent with floor (strength=$(round(odds_floor_strength_val, digits=2)))"
    end

    oracle_floor_strength_val = 0.0
    if :oracle in effective_config.floor_signals && !isempty(oracle_lookup)
        listed_prob = sum(values(oracle_lookup))
        n_listed = length(intersect(keys(oracle_lookup), rider_keys))
        n_absent = n_riders - n_listed
        if n_absent > 0
            residual_prob = 1.0 - listed_prob
            floor_prob = if residual_prob > 0.001
                residual_prob / n_absent
            else
                minimum(values(oracle_lookup)) * 0.5
            end
            baseline_prob = 1.0 / n_starters
            oracle_floor_strength_val = log(floor_prob / baseline_prob) / effective_config.odds_normalisation
        end
        @info "Oracle floor: $n_listed listed, $n_absent with floor (strength=$(round(oracle_floor_strength_val, digits=2)))"
    end

    # --- Build qualitative intelligence lookup ---
    # Each entry is (adjustment, confidence) — multiple sources per rider are separate observations
    qualitative_lookup = Dict{String,Vector{Tuple{Float64,Float64}}}()
    if qualitative_df !== nothing &&
       :riderkey in propertynames(qualitative_df) &&
       :adjustment in propertynames(qualitative_df) &&
       :confidence in propertynames(qualitative_df)
        for row in eachrow(qualitative_df)
            key = row.riderkey
            adj = Float64(row.adjustment)
            conf = Float64(row.confidence)
            if !haskey(qualitative_lookup, key)
                qualitative_lookup[key] = Tuple{Float64,Float64}[]
            end
            push!(qualitative_lookup[key], (adj, conf))
        end
    end

    # --- Build PCS form lookup ---
    # Z-score form scores across the field so they're on the same scale as other signals
    form_lookup = Dict{String,Float64}()
    if form_df !== nothing &&
       :riderkey in propertynames(form_df) &&
       :form_score in propertynames(form_df)
        form_raw = Float64.(form_df.form_score)
        form_mean = mean(form_raw)
        form_std = std(form_raw)
        if form_std > 0
            for (i, row) in enumerate(eachrow(form_df))
                form_lookup[row.riderkey] = (form_raw[i] - form_mean) / form_std
            end
        end
    end

    # --- Compute floor strengths for non-market signals ---
    form_floor_strength_val = 0.0
    if :form in effective_config.floor_signals && !isempty(form_lookup)
        form_floor_strength_val = effective_config.absence_floor_strength
        n_with_form = length(intersect(keys(form_lookup), rider_keys))
        @info "Form floor: $n_with_form with form, $(n_riders - n_with_form) with floor (strength=$(round(form_floor_strength_val, digits=2)))"
    end

    qualitative_floor_strength_val = 0.0
    if :qualitative in effective_config.floor_signals && !isempty(qualitative_lookup)
        qualitative_floor_strength_val = effective_config.absence_floor_strength
        n_with_qual = length(intersect(keys(qualitative_lookup), rider_keys))
        @info "Qualitative floor: $n_with_qual with intel, $(n_riders - n_with_qual) with floor (strength=$(round(qualitative_floor_strength_val, digits=2)))"
    end

    # --- Build race history lookup ---
    # Each entry is (strength, years_ago, variance_penalty)
    # Use race_date/race_year when provided (backtesting) to avoid
    # miscalculating years_ago relative to today's date
    current_year = if race_date !== nothing
        Dates.year(race_date)
    elseif race_year !== nothing
        race_year
    else
        Dates.year(Dates.today())
    end
    history_lookup = Dict{String,Vector{Tuple{Float64,Int,Float64}}}()
    if race_history_df !== nothing &&
       :riderkey in propertynames(race_history_df) &&
       :position in propertynames(race_history_df) &&
       :year in propertynames(race_history_df)
        has_penalty = :variance_penalty in propertynames(race_history_df)
        history_field_size = n_starters
        for row in eachrow(race_history_df)
            key = row.riderkey
            pos = row.position
            yr = row.year
            if !ismissing(pos) && !ismissing(yr) && pos > 0 && pos < 900
                years_ago = current_year - yr
                strength = position_to_strength(pos, history_field_size)
                penalty = has_penalty ? Float64(coalesce(row.variance_penalty, 0.0)) : 0.0
                if !haskey(history_lookup, key)
                    history_lookup[key] = Tuple{Float64,Int,Float64}[]
                end
                push!(history_lookup[key], (strength, years_ago, penalty))
            end
        end
        # Z-score strengths per years_ago group so race history is on same scale as other signals
        all_years_ago = Set{Int}()
        for entries in values(history_lookup)
            for (_, ya, _) in entries
                push!(all_years_ago, ya)
            end
        end
        for ya in all_years_ago
            yr_strengths = Float64[
                h[1] for entries in values(history_lookup) for h in entries if h[2] == ya
            ]
            yr_mean = mean(yr_strengths)
            yr_std = std(yr_strengths)
            if yr_std > 0
                for key in keys(history_lookup)
                    history_lookup[key] = [
                        (h[2] == ya ? ((h[1] - yr_mean) / yr_std, h[2], h[3]) : h) for
                        h in history_lookup[key]
                    ]
                end
            end
        end
    end

    # --- Build VG race history lookup ---
    # Z-score VG points per year, then store (z_score, years_ago) per rider
    vg_history_lookup = Dict{String,Vector{Tuple{Float64,Int}}}()
    if vg_history_df !== nothing &&
       :riderkey in propertynames(vg_history_df) &&
       :score in propertynames(vg_history_df) &&
       :year in propertynames(vg_history_df)
        # Z-score per year independently
        for yr in unique(vg_history_df.year)
            year_rows = filter(:year => ==(yr), vg_history_df)
            scores = Float64.(coalesce.(year_rows.score, 0.0))
            yr_mean = mean(scores)
            yr_std = std(scores)
            if yr_std > 0
                for (i, row) in enumerate(eachrow(year_rows))
                    key = row.riderkey
                    z = (scores[i] - yr_mean) / yr_std
                    years_ago = current_year - yr
                    if !haskey(vg_history_lookup, key)
                        vg_history_lookup[key] = Tuple{Float64,Int}[]
                    end
                    push!(vg_history_lookup[key], (z, years_ago))
                end
            end
        end
        @info "VG history lookup: $(length(vg_history_lookup)) riders with historical VG scores"
    end

    # --- Compute trajectory scores ---
    # Career trajectory from cross-season PCS ranking points: are they on the
    # up or down? Compare recent seasons (last 1-2 years) to older seasons
    # (3+ years ago). Riders without multi-season data get 0 (no update).
    trajectory_raw = zeros(n_riders)
    seasons_lookup = Dict{String,DataFrame}()
    if seasons_df !== nothing &&
       :riderkey in propertynames(seasons_df) &&
       :pcs_points in propertynames(seasons_df) &&
       :year in propertynames(seasons_df)
        for g in groupby(seasons_df, :riderkey)
            seasons_lookup[first(g.riderkey)] = DataFrame(g)
        end
    end

    has_trajectory = falses(n_riders)
    for i = 1:n_riders
        key = df.riderkey[i]
        rider_seasons = get(seasons_lookup, key, nothing)
        rider_seasons === nothing && continue
        nrow(rider_seasons) < 2 && continue

        sorted = sort(rider_seasons, :year, rev=true)
        # Recent: last 1-2 seasons; older: 3+ years ago
        recent = filter(r -> r.year >= current_year - 1, sorted)
        older = filter(r -> r.year <= current_year - 3, sorted)

        nrow(recent) == 0 && continue
        nrow(older) == 0 && continue

        trajectory_raw[i] = mean(recent.pcs_points) - mean(older.pcs_points)
        has_trajectory[i] = true
    end

    # Z-score trajectories across riders who have multi-season data
    if count(has_trajectory) > 1
        traj_vals = trajectory_raw[has_trajectory]
        traj_mean = mean(traj_vals)
        traj_std = std(traj_vals)
        if traj_std > 0
            for i = 1:n_riders
                if has_trajectory[i]
                    trajectory_raw[i] = (trajectory_raw[i] - traj_mean) / traj_std
                else
                    trajectory_raw[i] = 0.0
                end
            end
        end
    end

    if disable_trajectory
        trajectory_raw .= 0.0
    end

    # --- PCS availability (needed for estimation) ---
    has_pcs = if :has_pcs_data in propertynames(df)
        Bool.(df.has_pcs_data)
    else
        specialty_cols =
            intersect(propertynames(df), [:oneday, :gc, :tt, :sprint, :climber])
        [any(df[i, col] != 0 for col in specialty_cols) for i = 1:n_riders]
    end

    # --- Estimate strength for each rider ---
    strengths = Vector{Float64}(undef, n_riders)
    uncertainties = Vector{Float64}(undef, n_riders)
    shifts_pcs = Vector{Float64}(undef, n_riders)
    shifts_vg = Vector{Float64}(undef, n_riders)
    shifts_form = Vector{Float64}(undef, n_riders)
    shifts_trajectory = Vector{Float64}(undef, n_riders)
    shifts_history = Vector{Float64}(undef, n_riders)
    shifts_vg_history = Vector{Float64}(undef, n_riders)
    shifts_oracle = Vector{Float64}(undef, n_riders)
    shifts_qualitative = Vector{Float64}(undef, n_riders)
    shifts_odds = Vector{Float64}(undef, n_riders)

    for i = 1:n_riders
        key = df.riderkey[i]

        hist = get(history_lookup, key, Tuple{Float64,Int,Float64}[])
        hist_strengths = Float64[h[1] for h in hist]
        hist_years = Int[h[2] for h in hist]
        hist_penalties = Float64[h[3] for h in hist]

        vg_hist = get(vg_history_lookup, key, Tuple{Float64,Int}[])
        vg_hist_strengths = Float64[h[1] for h in vg_hist]
        vg_hist_years = Int[h[2] for h in vg_hist]

        odds_prob = get(odds_lookup, key, 0.0)
        oracle_prob = get(oracle_lookup, key, 0.0)
        form_val = get(form_lookup, key, 0.0)

        # Floor strengths: applied only to riders absent from the signal source
        odds_floor = haskey(odds_lookup, key) ? 0.0 : odds_floor_strength_val
        oracle_floor = haskey(oracle_lookup, key) ? 0.0 : oracle_floor_strength_val
        form_floor = haskey(form_lookup, key) ? 0.0 : form_floor_strength_val
        qual_floor = haskey(qualitative_lookup, key) ? 0.0 : qualitative_floor_strength_val

        qual_entries = get(qualitative_lookup, key, Tuple{Float64,Float64}[])
        qual_adjs = Float64[q[1] for q in qual_entries]
        qual_confs = Float64[q[2] for q in qual_entries]

        est = estimate_rider_strength(
            pcs_score=pcs_z[i],
            has_pcs=has_pcs[i],
            race_history=hist_strengths,
            race_history_years_ago=hist_years,
            race_history_variance_penalties=hist_penalties,
            vg_points=vg_z[i],
            form_score=form_val,
            trajectory_score=trajectory_raw[i],
            vg_race_history=vg_hist_strengths,
            vg_race_history_years_ago=vg_hist_years,
            odds_implied_prob=odds_prob,
            oracle_implied_prob=oracle_prob,
            odds_floor_strength=odds_floor,
            oracle_floor_strength=oracle_floor,
            form_floor_strength=form_floor,
            qualitative_floor_strength=qual_floor,
            qualitative_adjustments=qual_adjs,
            qualitative_confidences=qual_confs,
            n_starters=n_starters,
            config=effective_config,
        )

        strengths[i] = est.mean
        uncertainties[i] = sqrt(est.variance)
        shifts_pcs[i] = est.shift_pcs
        shifts_vg[i] = est.shift_vg
        shifts_form[i] = est.shift_form
        shifts_trajectory[i] = est.shift_trajectory
        shifts_history[i] = est.shift_history
        shifts_vg_history[i] = est.shift_vg_history
        shifts_oracle[i] = est.shift_oracle
        shifts_qualitative[i] = est.shift_qualitative
        shifts_odds[i] = est.shift_odds
    end

    # --- Domestique discount: penalise non-leaders proportionally to strength gap ---
    domestique_penalties = zeros(n_riders)
    if domestique_discount > 0
        teams_vec = String.(df.team)
        for team in unique(teams_vec)
            team_idx = findall(teams_vec .== team)
            length(team_idx) <= 1 && continue
            leader_strength = maximum(strengths[team_idx])
            for i in team_idx
                gap = leader_strength - strengths[i]
                penalty = domestique_discount * gap
                strengths[i] -= penalty
                domestique_penalties[i] = penalty
            end
        end
        n_penalised = count(domestique_penalties .> 0)
        @info "Applied domestique discount ($domestique_discount) to $n_penalised riders"
    end

    # --- Signal availability flags (for reporting data source coverage) ---
    has_race_history = [haskey(history_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_vg_history = [haskey(vg_history_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_odds = [haskey(odds_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_oracle = [haskey(oracle_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_qualitative = [haskey(qualitative_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_form = [haskey(form_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_seasons = [haskey(seasons_lookup, df.riderkey[i]) for i = 1:n_riders]

    # --- Add results to DataFrame ---
    df[!, :strength] = round.(strengths, digits=3)
    df[!, :uncertainty] = round.(uncertainties, digits=3)

    df[!, :has_pcs] = has_pcs
    df[!, :has_race_history] = has_race_history
    df[!, :has_vg_history] = has_vg_history
    df[!, :has_odds] = has_odds
    df[!, :has_oracle] = has_oracle
    df[!, :has_qualitative] = has_qualitative
    df[!, :has_form] = has_form
    df[!, :has_seasons] = has_seasons

    # --- Per-signal mean shifts (for diagnostics) ---
    df[!, :shift_pcs] = round.(shifts_pcs, digits=3)
    df[!, :shift_vg] = round.(shifts_vg, digits=3)
    df[!, :shift_form] = round.(shifts_form, digits=3)
    df[!, :shift_trajectory] = round.(shifts_trajectory, digits=3)
    df[!, :shift_history] = round.(shifts_history, digits=3)
    df[!, :shift_vg_history] = round.(shifts_vg_history, digits=3)
    df[!, :shift_oracle] = round.(shifts_oracle, digits=3)
    df[!, :shift_qualitative] = round.(shifts_qualitative, digits=3)
    df[!, :shift_odds] = round.(shifts_odds, digits=3)
    df[!, :domestique_penalty] = round.(domestique_penalties, digits=3)

    return df
end


"""
    estimate_strengths(data::RaceData; kwargs...) -> DataFrame

Convenience method that unpacks `RaceData` fields.
"""
function estimate_strengths(
    data::RaceData;
    race_type::Symbol=:oneday,
    bayesian_config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing}=nothing,
    race_date::Union{Date,Nothing}=nothing,
    domestique_discount::Float64=0.0,
    disable_trajectory::Bool=false,
)
    estimate_strengths(
        data.rider_df;
        race_history_df=data.race_history_df,
        odds_df=data.odds_df,
        oracle_df=data.oracle_df,
        vg_history_df=data.vg_history_df,
        qualitative_df=data.qualitative_df,
        form_df=data.form_df,
        seasons_df=data.seasons_df,
        race_type=race_type,
        bayesian_config=bayesian_config,
        race_year=race_year,
        race_date=race_date,
        domestique_discount=domestique_discount,
        disable_trajectory=disable_trajectory,
    )
end


"""
    predict_expected_points(rider_df, scoring; kwargs...) -> DataFrame

Backward-compatible wrapper: estimates strengths then runs MC simulation to
compute expected VG points. Used by backtesting where we need expected points
without team optimisation.
"""
function predict_expected_points(
    rider_df::DataFrame,
    scoring::ScoringTable;
    race_history_df::Union{DataFrame,Nothing}=nothing,
    odds_df::Union{DataFrame,Nothing}=nothing,
    oracle_df::Union{DataFrame,Nothing}=nothing,
    vg_history_df::Union{DataFrame,Nothing}=nothing,
    qualitative_df::Union{DataFrame,Nothing}=nothing,
    form_df::Union{DataFrame,Nothing}=nothing,
    seasons_df::Union{DataFrame,Nothing}=nothing,
    n_sims::Int=10000,
    race_type::Symbol=:oneday,
    rng::AbstractRNG=Random.default_rng(),
    bayesian_config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing}=nothing,
    race_date::Union{Date,Nothing}=nothing,
    simulation_df::Union{Int,Nothing}=nothing,
    risk_aversion::Float64=0.0,
    domestique_discount::Float64=0.0,
    disable_trajectory::Bool=false,
    total_distance_km::Float64=0.0,
)
    df = estimate_strengths(
        rider_df;
        race_history_df=race_history_df,
        odds_df=odds_df,
        oracle_df=oracle_df,
        vg_history_df=vg_history_df,
        qualitative_df=qualitative_df,
        form_df=form_df,
        seasons_df=seasons_df,
        race_type=race_type,
        bayesian_config=bayesian_config,
        race_year=race_year,
        race_date=race_date,
        domestique_discount=domestique_discount,
        disable_trajectory=disable_trajectory,
    )

    # MC simulation for expected points (used by backtesting)
    n_riders = nrow(df)
    strengths = Float64.(df.strength)
    uncertainties = Float64.(df.uncertainty)

    sim_positions = simulate_race(
        strengths,
        uncertainties;
        n_sims=n_sims,
        rng=rng,
        simulation_df=simulation_df,
    )

    teams = String.(df.team)
    evg, dsd = expected_vg_points(sim_positions, teams, scoring)
    df[!, :expected_vg_points] = round.(evg, digits=1)
    df[!, :downside_semi_dev] = round.(dsd, digits=1)

    return df
end

function predict_expected_points(
    data::RaceData,
    scoring::ScoringTable;
    n_sims::Int=10000,
    race_type::Symbol=:oneday,
    rng::AbstractRNG=Random.default_rng(),
    bayesian_config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing}=nothing,
    race_date::Union{Date,Nothing}=nothing,
    simulation_df::Union{Int,Nothing}=nothing,
    risk_aversion::Float64=0.0,
    domestique_discount::Float64=0.0,
    disable_trajectory::Bool=false,
    total_distance_km::Float64=0.0,
)
    predict_expected_points(
        data.rider_df,
        scoring;
        race_history_df=data.race_history_df,
        odds_df=data.odds_df,
        oracle_df=data.oracle_df,
        vg_history_df=data.vg_history_df,
        qualitative_df=data.qualitative_df,
        form_df=data.form_df,
        seasons_df=data.seasons_df,
        n_sims=n_sims,
        race_type=race_type,
        rng=rng,
        bayesian_config=bayesian_config,
        race_year=race_year,
        race_date=race_date,
        simulation_df=simulation_df,
        risk_aversion=risk_aversion,
        domestique_discount=domestique_discount,
        disable_trajectory=disable_trajectory,
        total_distance_km=total_distance_km,
    )
end
