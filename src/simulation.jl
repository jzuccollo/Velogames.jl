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
    shift_vg::Float64
    shift_history::Float64
    shift_vg_history::Float64
    shift_oracle::Float64
    shift_odds::Float64
end

"""
    BayesianConfig

Hyperparameters for Bayesian rider strength estimation.

These control how much weight each signal receives in the posterior.
Lower variance means the signal is treated as more precise.
"""
struct BayesianConfig
    pcs_variance::Float64
    vg_variance::Float64
    hist_base_variance::Float64
    hist_decay_rate::Float64
    vg_hist_base_variance::Float64
    vg_hist_decay_rate::Float64
    odds_variance::Float64
    oracle_variance::Float64
    odds_normalisation::Float64
    signal_correlation::Float64
end

"""Default Bayesian hyperparameters."""
const DEFAULT_BAYESIAN_CONFIG = BayesianConfig(
    5.5,   # pcs_variance: prior variance for PCS specialty score
    1.2,   # vg_variance: observation variance for VG season points
    4.0,   # hist_base_variance: base variance for race history observations (z-scored scale)
    1.2,   # hist_decay_rate: additional variance per year of age
    3.0,   # vg_hist_base_variance: base variance for VG race history
    0.65,  # vg_hist_decay_rate: additional variance per year for VG history
    0.5,   # odds_variance: observation variance for betting odds signal
    1.5,   # oracle_variance: observation variance for Cycling Oracle signal
    2.0,   # odds_normalisation: heuristic divisor to scale log-odds to z-score range.
    # With ~150 starters, a 10% favourite produces log(0.1 / 0.0067) ≈ 2.7,
    # which / 2.0 gives ~1.35 — a reasonable "1.35 SD above average" strength signal.
    0.15,  # signal_correlation: equicorrelation discount for correlated signals.
    # With n signals at pairwise correlation ρ, effective precision is
    # Στ_i / (1 + ρ(n-1)) instead of Στ_i. Prevents over-concentration of
    # posterior for favourites who have many correlated signal sources.
)

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
    pcs_score::Float64 = 0.0,
    race_history::Vector{Float64} = Float64[],
    race_history_years_ago::Vector{Int} = Int[],
    race_history_variance_penalties::Vector{Float64} = Float64[],
    vg_points::Float64 = 0.0,
    vg_race_history::Vector{Float64} = Float64[],
    vg_race_history_years_ago::Vector{Int} = Int[],
    odds_implied_prob::Float64 = 0.0,
    oracle_implied_prob::Float64 = 0.0,
    n_starters::Int = 150,
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
)
    # --- Prior from PCS ---
    # PCS score is our broadest signal. Wide variance reflects general uncertainty.
    prior = BayesianPosterior(pcs_score, config.pcs_variance)
    posterior = prior
    n_signals = 0

    # --- Update with VG season points ---
    # VG points reflect current season form. Moderate precision.
    mean_before = posterior.mean
    if vg_points != 0.0
        posterior = bayesian_update(posterior, vg_points, config.vg_variance)
        n_signals += 1
    end
    shift_vg = posterior.mean - mean_before

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
    end
    shift_oracle = posterior.mean - mean_before

    # --- Update with betting odds ---
    # Odds-implied probability is the market's posterior. Very precise when available.
    mean_before = posterior.mean
    if odds_implied_prob > 0.0
        baseline_prob = 1.0 / n_starters
        odds_strength = log(odds_implied_prob / baseline_prob) / config.odds_normalisation
        posterior = bayesian_update(posterior, odds_strength, config.odds_variance)
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
        shift_vg,
        shift_history,
        shift_vg_history,
        shift_oracle,
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
    n_sims::Int = 10000,
    rng::AbstractRNG = Random.default_rng(),
    simulation_df::Union{Int,Nothing} = nothing,
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
        order = sortperm(noisy_strengths, rev = true)
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
function position_probabilities(sim_positions::Matrix{Int}; max_position::Int = 30)
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

    for s = 1:n_sims
        # --- Finish points ---
        for i = 1:n_riders
            pos = sim_positions[i, s]
            total_points[i] += finish_points_for_position(pos, scoring)
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
                    total_points[i] += scoring.assist_points[top_pos]
                end
            end
        end
    end

    # Average across simulations
    return total_points ./ n_sims
end

"""
Heuristic breakaway sector count for a given finishing position.

Sector allocation per simulated finishing position:
- Position 1-14:  2 late sectors (20km, 10km)                   = 2 sectors
- Position 15-19: 2 late + 1 early sector (50% distance)        = 3 sectors
- Position 20:    2 late + 2 early sectors (50% + 50km)          = 4 sectors max
- Position 21-30: 1 late (20km) + 2 early sectors (50% + 50km)  = 3 sectors
- Position 31-50: 2 early sectors (50% + 50km)                   = 2 sectors
- Position 51-60: 1 early sector (50% distance)                  = 1 sector
- Position 61+:   0 sectors
"""
function _breakaway_sectors(pos::Int)
    sectors = 0
    if pos <= 20
        sectors += 2
    elseif pos <= 30
        sectors += 1
    end
    if 15 <= pos <= 60
        sectors += 1
    end
    if 20 <= pos <= 50
        sectors += 1
    end
    return sectors
end

"""
    simulate_vg_points(sim_positions, rider_teams, scoring; include_breakaway=false)
        -> (mean_pts, std_pts, downside_std)

Compute per-rider mean, standard deviation, and downside semi-deviation of VG
points across simulations.

Scores each simulation using finish points, assist points, and optionally breakaway
sector points. Uses Welford's online algorithm for numerically stable variance
computation without materialising the full n_riders × n_sims matrix.

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
    include_breakaway::Bool = false,
)
    n_riders, n_sims = size(sim_positions)
    @assert length(rider_teams) == n_riders "Length mismatch: rider_teams"

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

        # --- Breakaway points (one-day only) ---
        if include_breakaway
            for i = 1:n_riders
                sim_pts[i] += _breakaway_sectors(sim_positions[i, s]) * points_per_sector
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
    downside_std =
        [n_sims > 1 ? sqrt(m2_down[i] / (n_sims - 1)) : 0.0 for i = 1:n_riders]
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
    predict_expected_points(rider_df::DataFrame, scoring::ScoringTable;
                            race_history_df=nothing, odds_df=nothing,
                            oracle_df=nothing, vg_history_df=nothing,
                            n_sims::Int=10000, race_type::Symbol=:oneday,
                            rng::AbstractRNG=Random.default_rng(),
                            bayesian_config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG) -> DataFrame

Full prediction pipeline: takes rider data, computes expected VG points for each rider.

## Race types
- `:oneday` — uses PCS one-day specialty as the prior, includes breakaway heuristic
- `:stage` — uses class-aware PCS blending as the prior, higher base uncertainty,
  no breakaway heuristic (stage race points already include these implicitly)

## Required columns in `rider_df`:
- `rider::String`, `team::String`, `riderkey::String`
- `cost::Int` - VG cost
- `points::Float64` - VG season points

## Optional PCS columns (from `getpcsriderpts_batch`):
- `oneday`, `gc`, `tt`, `sprint`, `climber` (all Float64)

## Optional columns for stage races:
- `classraw::String` or `class::String` - rider classification

## Optional DataFrames:
- `race_history_df` — PCS race history with `:position`, `:year`, `:riderkey`,
  and optional `:variance_penalty` (0.0 for exact-race, 1.0 for similar-race)
- `odds_df` — Betfair odds with `:odds`, `:riderkey`
- `oracle_df` — Cycling Oracle predictions with `:win_prob`, `:riderkey`
- `vg_history_df` — VG race points from past editions with `:score`, `:year`, `:riderkey`.
  Scores are z-scored per year before feeding as Bayesian updates.

## Returns
The input DataFrame augmented with:
- `strength`, `uncertainty` - posterior estimates
- `expected_vg_points` - total expected VG points (mean across simulations)
- `std_vg_points` - standard deviation of VG points across simulations
- `downside_std_vg_points` - downside semi-deviation (only below-mean variance)
- `risk_adjusted_vg_points` - `expected_vg_points - risk_aversion * downside_std_vg_points`
- `expected_finish_pts`, `expected_assist_pts`, `expected_breakaway_pts` - components
"""
function predict_expected_points(
    rider_df::DataFrame,
    scoring::ScoringTable;
    race_history_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
    oracle_df::Union{DataFrame,Nothing} = nothing,
    vg_history_df::Union{DataFrame,Nothing} = nothing,
    n_sims::Int = 10000,
    race_type::Symbol = :oneday,
    rng::AbstractRNG = Random.default_rng(),
    bayesian_config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing} = nothing,
    race_date::Union{Date,Nothing} = nothing,
    simulation_df::Union{Int,Nothing} = nothing,
    risk_aversion::Float64 = 0.0,
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

    # --- Estimate strength for each rider ---
    strengths = Vector{Float64}(undef, n_riders)
    uncertainties = Vector{Float64}(undef, n_riders)
    shifts_vg = Vector{Float64}(undef, n_riders)
    shifts_history = Vector{Float64}(undef, n_riders)
    shifts_vg_history = Vector{Float64}(undef, n_riders)
    shifts_oracle = Vector{Float64}(undef, n_riders)
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

        est = estimate_rider_strength(
            pcs_score = pcs_z[i],
            race_history = hist_strengths,
            race_history_years_ago = hist_years,
            race_history_variance_penalties = hist_penalties,
            vg_points = vg_z[i],
            vg_race_history = vg_hist_strengths,
            vg_race_history_years_ago = vg_hist_years,
            odds_implied_prob = odds_prob,
            oracle_implied_prob = oracle_prob,
            n_starters = n_starters,
            config = bayesian_config,
        )

        strengths[i] = est.mean
        uncertainties[i] = sqrt(est.variance)
        shifts_vg[i] = est.shift_vg
        shifts_history[i] = est.shift_history
        shifts_vg_history[i] = est.shift_vg_history
        shifts_oracle[i] = est.shift_oracle
        shifts_odds[i] = est.shift_odds
    end

    # --- Monte Carlo simulation ---
    @info "Running Monte Carlo simulation ($n_sims iterations, $n_riders riders)..."
    sim_positions = simulate_race(
        strengths,
        uncertainties;
        n_sims = n_sims,
        rng = rng,
        simulation_df = simulation_df,
    )

    # --- Compute expected points with per-rider variance ---
    teams = String.(df.team)
    include_breakaway = (race_type == :oneday)

    total_evg, std_pts, downside_std = simulate_vg_points(
        sim_positions,
        teams,
        scoring;
        include_breakaway = include_breakaway,
    )

    # Decompose finish and assist points for reporting
    pos_probs = position_probabilities(sim_positions; max_position = 30)
    finish_pts = [expected_finish_points(pos_probs[i, :], scoring) for i = 1:n_riders]
    evg_no_breakaway = expected_vg_points(sim_positions, teams, scoring)
    assist_pts = evg_no_breakaway .- finish_pts
    breakaway = total_evg .- evg_no_breakaway

    # --- Signal availability flags (for reporting data source coverage) ---
    has_pcs = if :has_pcs_data in propertynames(df)
        Bool.(df.has_pcs_data)
    else
        # Check raw specialty columns — z-scored values are non-zero even for missing riders
        specialty_cols =
            intersect(propertynames(df), [:oneday, :gc, :tt, :sprint, :climber])
        [any(df[i, col] != 0 for col in specialty_cols) for i = 1:n_riders]
    end
    has_race_history = [haskey(history_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_vg_history = [haskey(vg_history_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_odds = [haskey(odds_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_oracle = [haskey(oracle_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_any_signal = has_pcs .| has_race_history .| has_vg_history .| has_odds .| has_oracle

    # Zero out expected points for riders with no informative signals — these are
    # unknown riders whose expected points are driven purely by prior uncertainty.
    # We keep std_pts (and downside_std) intact so that risk aversion properly
    # penalises selecting unknown riders (they are the MOST uncertain, not riskless).
    no_signal_mask = .!has_any_signal
    if any(no_signal_mask)
        no_signal_names = String.(df.rider[no_signal_mask])
        @warn "$(sum(no_signal_mask)) riders have no informative signals — expected points set to 0" riders =
            no_signal_names
        total_evg[no_signal_mask] .= 0.0
        finish_pts[no_signal_mask] .= 0.0
        assist_pts[no_signal_mask] .= 0.0
        breakaway[no_signal_mask] .= 0.0
    end

    # Risk-adjusted VG points: E[pts] - γ * downside_semi_dev[pts]
    # Uses downside semi-deviation (Sortino-style) rather than full SD so that
    # upside variance (chance of scoring big) is not penalised. This is appropriate
    # for the heavily right-skewed VG points distributions.
    # γ=0 recovers pure expected-value optimisation.
    risk_adjusted = total_evg .- risk_aversion .* downside_std

    # --- Add results to DataFrame ---
    df[!, :strength] = round.(strengths, digits = 3)
    df[!, :uncertainty] = round.(uncertainties, digits = 3)
    df[!, :expected_vg_points] = round.(total_evg, digits = 1)
    df[!, :std_vg_points] = round.(std_pts, digits = 1)
    df[!, :downside_std_vg_points] = round.(downside_std, digits = 1)
    df[!, :risk_adjusted_vg_points] = round.(risk_adjusted, digits = 1)
    df[!, :expected_finish_pts] = round.(finish_pts, digits = 1)
    df[!, :expected_assist_pts] = round.(assist_pts, digits = 1)
    df[!, :expected_breakaway_pts] = round.(breakaway, digits = 1)

    df[!, :has_pcs] = has_pcs
    df[!, :has_race_history] = has_race_history
    df[!, :has_vg_history] = has_vg_history
    df[!, :has_odds] = has_odds
    df[!, :has_oracle] = has_oracle
    df[!, :has_any_signal] = has_any_signal

    # --- Per-signal mean shifts (for diagnostics) ---
    df[!, :shift_vg] = round.(shifts_vg, digits = 3)
    df[!, :shift_history] = round.(shifts_history, digits = 3)
    df[!, :shift_vg_history] = round.(shifts_vg_history, digits = 3)
    df[!, :shift_oracle] = round.(shifts_oracle, digits = 3)
    df[!, :shift_odds] = round.(shifts_odds, digits = 3)

    return df
end


"""
    predict_expected_points(data::RaceData, scoring::ScoringTable; kwargs...) -> DataFrame

Convenience method that unpacks `RaceData` fields into the standard kwargs.
"""
function predict_expected_points(
    data::RaceData,
    scoring::ScoringTable;
    n_sims::Int = 10000,
    race_type::Symbol = :oneday,
    rng::AbstractRNG = Random.default_rng(),
    bayesian_config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing} = nothing,
    race_date::Union{Date,Nothing} = nothing,
    simulation_df::Union{Int,Nothing} = nothing,
    risk_aversion::Float64 = 0.0,
)
    predict_expected_points(
        data.rider_df,
        scoring;
        race_history_df = data.race_history_df,
        odds_df = data.odds_df,
        oracle_df = data.oracle_df,
        vg_history_df = data.vg_history_df,
        n_sims = n_sims,
        race_type = race_type,
        rng = rng,
        bayesian_config = bayesian_config,
        race_year = race_year,
        race_date = race_date,
        simulation_df = simulation_df,
        risk_aversion = risk_aversion,
    )
end
