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
        pcs_score, race_history, race_history_years_ago, vg_points,
        odds_implied_prob, n_starters,
        pcs_variance, vg_variance, hist_base_variance, hist_decay_rate,
        odds_variance, odds_normalisation
    ) -> BayesianPosterior

Estimate a rider's strength for a specific race using Bayesian updating.

Returns a `BayesianPosterior` with mean (strength) and variance (uncertainty).

## Signal hierarchy (from broadest to most specific):
1. **PCS score** (prior): general ability from ProCyclingStats ranking/specialty
2. **VG season points** (broad form): current season Velogames performance
3. **Race history** (specific): historical results in this exact race
4. **Betting odds** (market consensus): if available, the most precise signal

## Data arguments
- `pcs_score`: normalised PCS specialty score (z-scored, mean 0, std 1)
- `race_history`: vector of normalised finishing positions from past editions
  (lower = better; converted to strength via negative rank mapping)
- `race_history_years_ago`: how many years ago each history entry is (for recency weighting)
- `vg_points`: normalised VG season points (z-scored)
- `odds_implied_prob`: implied win probability from betting odds (0-1, 0 = not available)
- `n_starters`: expected number of starters (used to scale odds to strength)

## Variance hyperparameters (for calibration/sensitivity analysis)
- `pcs_variance`: prior variance for PCS specialty score (default: 4.0)
- `vg_variance`: observation variance for VG season points (default: 3.0)
- `hist_base_variance`: base variance for race history observations (default: 1.0)
- `hist_decay_rate`: additional variance per year of age (default: 0.5, so 1yr ago = 1.5, 2yr = 2.0)
- `odds_variance`: observation variance for betting odds signal (default: 0.5)
- `odds_normalisation`: divisor to scale log-odds to z-score range (default: 2.0, heuristic)
"""
function estimate_rider_strength(;
    pcs_score::Float64 = 0.0,
    race_history::Vector{Float64} = Float64[],
    race_history_years_ago::Vector{Int} = Int[],
    vg_points::Float64 = 0.0,
    odds_implied_prob::Float64 = 0.0,
    n_starters::Int = 150,
    pcs_variance::Float64 = 4.0,
    vg_variance::Float64 = 3.0,
    hist_base_variance::Float64 = 1.0,
    hist_decay_rate::Float64 = 0.5,
    odds_variance::Float64 = 0.5,
    odds_normalisation::Float64 = 2.0,
)
    # --- Prior from PCS ---
    # PCS score is our broadest signal. Wide variance reflects general uncertainty.
    posterior = BayesianPosterior(pcs_score, pcs_variance)

    # --- Update with VG season points ---
    # VG points reflect current season form. Moderate precision.
    if vg_points != 0.0
        posterior = bayesian_update(posterior, vg_points, vg_variance)
    end

    # --- Update with race-specific history ---
    # Each past result in this specific race is a strong signal.
    # More recent results are more informative (lower variance).
    if length(race_history) != length(race_history_years_ago)
        @warn "race_history ($(length(race_history))) and race_history_years_ago ($(length(race_history_years_ago))) have different lengths; using pairwise minimum"
    end
    for (hist_strength, years_ago) in zip(race_history, race_history_years_ago)
        # Variance increases with age: recent result is precise, old result is fuzzy
        hist_var = hist_base_variance + hist_decay_rate * years_ago
        posterior = bayesian_update(posterior, hist_strength, hist_var)
    end

    # --- Update with betting odds ---
    # Odds-implied probability is the market's posterior. Very precise when available.
    if odds_implied_prob > 0.0
        # Convert implied win probability to a strength score.
        # Use log-odds as a natural strength scale: strong riders have high log-odds.
        baseline_prob = 1.0 / n_starters
        # Strength relative to average: positive = stronger than average
        odds_strength = log(odds_implied_prob / baseline_prob)
        # Normalise to roughly the same scale as z-scores
        odds_strength = odds_strength / odds_normalisation
        posterior = bayesian_update(posterior, odds_strength, odds_variance)
    end

    return posterior
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

The Superclassico awards breakaway points at 4 sectors (50% distance, 50km, 20km, 10km).
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
                            n_sims::Int=10000, race_type::Symbol=:oneday,
                            rng::AbstractRNG=Random.default_rng()) -> DataFrame

Full prediction pipeline: takes rider data, computes expected VG points for each rider.

## Race types
- `:oneday` — uses PCS one-day specialty as the prior, includes breakaway heuristic
- `:stage` — uses class-aware PCS blending as the prior, higher base uncertainty,
  no breakaway heuristic (stage race points already include these implicitly)

## Required columns in `rider_df`:
- `rider::String`, `team::String`, `riderkey::String`
- `cost::Int` or `vgcost::Int` - VG cost
- `points::Float64` or `vgpoints::Float64` - VG season points

## Optional PCS columns (from `getpcsriderpts_batch`):
- `oneday`, `gc`, `tt`, `sprint`, `climber` (all Float64)

## Optional columns for stage races:
- `classraw::String` or `class::String` - rider classification

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
    n_sims::Int = 10000,
    race_type::Symbol = :oneday,
    rng::AbstractRNG = Random.default_rng(),
)
    df = copy(rider_df)
    n_riders = nrow(df)

    # --- Normalise input columns ---
    pts_col =
        :points in propertynames(df) ? :points :
        :vgpoints in propertynames(df) ? :vgpoints : nothing
    cost_col =
        :cost in propertynames(df) ? :cost :
        :vgcost in propertynames(df) ? :vgcost : nothing

    if pts_col === nothing || cost_col === nothing
        error("rider_df must contain :points or :vgpoints, and :cost or :vgcost columns")
    end

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

    # --- Build race history lookup ---
    current_year = Dates.year(Dates.today())
    history_lookup = Dict{String,Vector{Tuple{Float64,Int}}}()
    if race_history_df !== nothing &&
       :riderkey in propertynames(race_history_df) &&
       :position in propertynames(race_history_df) &&
       :year in propertynames(race_history_df)
        # Field size for strength conversion: classics ~175, grand tours ~175 finishers
        history_field_size = max(n_starters, 175)
        for row in eachrow(race_history_df)
            key = row.riderkey
            pos = row.position
            yr = row.year
            if !ismissing(pos) && !ismissing(yr) && pos > 0 && pos < 900
                years_ago = current_year - yr
                strength = position_to_strength(pos, history_field_size)
                if !haskey(history_lookup, key)
                    history_lookup[key] = Tuple{Float64,Int}[]
                end
                push!(history_lookup[key], (strength, years_ago))
            end
        end
    end

    # --- Estimate strength for each rider ---
    strengths = Vector{Float64}(undef, n_riders)
    uncertainties = Vector{Float64}(undef, n_riders)

    for i = 1:n_riders
        key = df.riderkey[i]

        hist = get(history_lookup, key, Tuple{Float64,Int}[])
        hist_strengths = Float64[h[1] for h in hist]
        hist_years = Int[h[2] for h in hist]

        odds_prob = get(odds_lookup, key, 0.0)

        posterior = estimate_rider_strength(
            pcs_score = pcs_z[i],
            race_history = hist_strengths,
            race_history_years_ago = hist_years,
            vg_points = vg_z[i],
            odds_implied_prob = odds_prob,
            n_starters = n_starters,
        )

        strengths[i] = posterior.mean
        uncertainties[i] = sqrt(posterior.variance)
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

    return df
end
