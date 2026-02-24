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
end

"""Default Bayesian hyperparameters."""
const DEFAULT_BAYESIAN_CONFIG = BayesianConfig(
    4.0,   # pcs_variance: prior variance for PCS specialty score
    3.0,   # vg_variance: observation variance for VG season points
    1.0,   # hist_base_variance: base variance for race history observations
    0.5,   # hist_decay_rate: additional variance per year of age
    1.5,   # vg_hist_base_variance: base variance for VG race history
    0.5,   # vg_hist_decay_rate: additional variance per year for VG history
    0.5,   # odds_variance: observation variance for betting odds signal
    1.5,   # oracle_variance: observation variance for Cycling Oracle signal
    2.0,   # odds_normalisation: heuristic divisor to scale log-odds to z-score range.
    # With ~150 starters, a 10% favourite produces log(0.1 / 0.0067) ≈ 2.7,
    # which / 2.0 gives ~1.35 — a reasonable "1.35 SD above average" strength signal.
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
    posterior = BayesianPosterior(pcs_score, config.pcs_variance)

    # --- Update with VG season points ---
    # VG points reflect current season form. Moderate precision.
    mean_before = posterior.mean
    if vg_points != 0.0
        posterior = bayesian_update(posterior, vg_points, config.vg_variance)
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
    end
    shift_oracle = posterior.mean - mean_before

    # --- Update with betting odds ---
    # Odds-implied probability is the market's posterior. Very precise when available.
    mean_before = posterior.mean
    if odds_implied_prob > 0.0
        baseline_prob = 1.0 / n_starters
        odds_strength = log(odds_implied_prob / baseline_prob) / config.odds_normalisation
        posterior = bayesian_update(posterior, odds_strength, config.odds_variance)
    end
    shift_odds = posterior.mean - mean_before

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

"""
    simulate_race(strengths::Vector{Float64}, uncertainties::Vector{Float64};
                  n_sims::Int=10000, rng::AbstractRNG=Random.default_rng()) -> Matrix{Int}

Simulate a race `n_sims` times using Monte Carlo.

For each simulation, adds Gaussian noise (scaled by each rider's uncertainty)
to their strength score, then ranks riders by noisy strength (highest = 1st place).

Returns a `n_riders x n_sims` matrix where entry [i, s] is rider i's finishing
position in simulation s.
"""
function simulate_race(
    strengths::Vector{Float64},
    uncertainties::Vector{Float64};
    n_sims::Int = 10000,
    rng::AbstractRNG = Random.default_rng(),
)
    n_riders = length(strengths)
    @assert length(uncertainties) == n_riders "Length mismatch: strengths and uncertainties"

    positions = Matrix{Int}(undef, n_riders, n_sims)
    noisy_strengths = Vector{Float64}(undef, n_riders)

    for s = 1:n_sims
        # Add noise to each rider's strength
        for i = 1:n_riders
            noisy_strengths[i] = strengths[i] + uncertainties[i] * randn(rng)
        end
        # Rank: highest noisy strength = position 1
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
    estimate_breakaway_points(strengths::Vector{Float64}, uncertainties::Vector{Float64},
                               scoring::ScoringTable; n_sims::Int=10000,
                               rng::AbstractRNG=Random.default_rng()) -> Vector{Float64}

Estimate expected breakaway points using heuristics.

The Superclasico awards breakaway points at 4 sectors (50% distance, 50km, 20km, 10km).
A "leading group" is <= 20 riders with >5s gap.

Heuristic approach:
- **Late sectors (20km, 10km)**: riders likely to be in the front group are the
  top ~20 finishers. Use simulation to estimate P(top 20).
- **Early sectors (50%, 50km)**: breakaway riders tend to be moderate-strength
  riders (strong enough to be in the race, but not favourites who sit in the peloton).
  Use a heuristic based on strength rank.

Sector allocation per simulated finishing position:
- Position 1-14:  2 late sectors (20km, 10km)                   = 2 sectors
- Position 15-19: 2 late + 1 early sector (50% distance)        = 3 sectors
- Position 20:    2 late + 2 early sectors (50% + 50km)          = 4 sectors max
- Position 21-30: 1 late (20km) + 2 early sectors (50% + 50km)  = 3 sectors
- Position 31-50: 2 early sectors (50% + 50km)                   = 2 sectors
- Position 51-60: 1 early sector (50% distance)                  = 1 sector
- Position 61+:   0 sectors

Note the sharp jump at position 20, where riders gain a 4th sector. This is a known
simplification; actual breakaway behaviour is hard to predict from historical data alone.
"""
function estimate_breakaway_points(
    strengths::Vector{Float64},
    uncertainties::Vector{Float64},
    scoring::ScoringTable;
    n_sims::Int = 10000,
    rng::AbstractRNG = Random.default_rng(),
)
    n_riders = length(strengths)
    sim = simulate_race(strengths, uncertainties; n_sims = n_sims, rng = rng)

    breakaway_pts = zeros(Float64, n_riders)
    points_per_sector = scoring.breakaway_points

    for s = 1:n_sims
        for i = 1:n_riders
            pos = sim[i, s]
            sectors_in = 0

            # Late sectors (20km and 10km to go): front group probability
            # Riders in top 20 are likely in the front group at these points
            if pos <= 20
                sectors_in += 2  # 20km and 10km sectors
            elseif pos <= 30
                sectors_in += 1  # Maybe in front group for 20km sector
            end

            # Early sectors (50% and 50km to go): breakaway probability
            # Aggressive riders ranked 15th-60th most likely to be in a breakaway
            # Favourites (top 10) sit in the peloton; weak riders can't get in a break
            if 15 <= pos <= 60
                sectors_in += 1  # Reasonable chance of being in early break
            end
            if 20 <= pos <= 50
                sectors_in += 1  # Higher chance for mid-pack aggressive riders
            end

            breakaway_pts[i] += sectors_in * points_per_sector
        end
    end

    return breakaway_pts ./ n_sims
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
- `expected_vg_points` - total expected VG points
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
        # Field size for strength conversion: classics ~175, grand tours ~175 finishers
        history_field_size = max(n_starters, 175)
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
    sim_positions = simulate_race(strengths, uncertainties; n_sims = n_sims, rng = rng)

    # --- Compute expected points ---
    teams = String.(df.team)

    # Finish + assist points from main simulation
    evg = expected_vg_points(sim_positions, teams, scoring)

    # Breakaway points: only for one-day races (stage race scoring already includes these)
    breakaway = zeros(n_riders)
    if race_type == :oneday
        breakaway = estimate_breakaway_points(
            strengths,
            uncertainties,
            scoring;
            n_sims = n_sims,
            rng = rng,
        )
    end

    # Decompose finish and assist points for reporting
    pos_probs = position_probabilities(sim_positions; max_position = 30)
    finish_pts = [expected_finish_points(pos_probs[i, :], scoring) for i = 1:n_riders]
    assist_pts = evg .- finish_pts

    # Total expected VG points
    total_evg = evg .+ breakaway

    # --- Add results to DataFrame ---
    df[!, :strength] = round.(strengths, digits = 3)
    df[!, :uncertainty] = round.(uncertainties, digits = 3)
    df[!, :expected_vg_points] = round.(total_evg, digits = 1)
    df[!, :expected_finish_pts] = round.(finish_pts, digits = 1)
    df[!, :expected_assist_pts] = round.(assist_pts, digits = 1)
    df[!, :expected_breakaway_pts] = round.(breakaway, digits = 1)

    # --- Signal availability flags (for reporting data source coverage) ---
    df[!, :has_pcs] = [pcs_z[i] != 0.0 for i = 1:n_riders]
    df[!, :has_race_history] = [haskey(history_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_vg_history] = [haskey(vg_history_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_odds] = [haskey(odds_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_oracle] = [haskey(oracle_lookup, df.riderkey[i]) for i = 1:n_riders]

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
    )
end
