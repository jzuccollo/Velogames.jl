"""
Bayesian strength estimation and Monte Carlo race simulation.

Converts rider data from multiple sources into strength estimates and expected
Velogames points. The pipeline has two stages:

1. **Bayesian strength estimation** — an uninformative prior (mean=0, SD=10) is
   updated sequentially with observations from up to 9 signal sources (PCS
   specialty, VG season points, form, trajectory, race history, VG race history,
   oracle, qualitative intelligence, betting odds). Each observation has a
   variance controlling its precision; lower variance = more influence. The
   posterior mean is a precision-weighted average of all observations.

2. **Monte Carlo simulation** — draws noisy strengths from each rider's
   posterior, ranks them to simulate finishing positions, and maps positions to
   expected VG points via the scoring tables.

## Parameter structure

Signal variances are controlled by three precision scale factors that group
signals by type, plus fixed within-group ratios derived from domain knowledge:

- `market_precision_scale` — odds and oracle (the most precise signals)
- `history_precision_scale` — form, race history, VG history, trajectory
- `ability_precision_scale` — PCS specialty, VG season points (broadest signals)

Effective variance = base_variance × ratio / scale_factor. Setting a scale
factor to 2.0 halves the variance (doubles the precision) of every signal in
that group. The ratios encode the hierarchy within each group (e.g. odds is
more precise than oracle) and should only change if domain knowledge changes.

See `BayesianConfig` for full parameter documentation and `prior_checks.jl`
for tools to validate and tune the configuration.
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
by up to 9 signal sources. Lower variance means the signal is treated as
more precise. The posterior mean is a precision-weighted average, where
precision = 1/variance, so the actual influence of any signal depends on
the ratio of its precision to the sum of all precisions.

## Parameter groups

Parameters are organised into four groups with different roles:

### 1. Tuneable scale factors (adjust these)

Three scale factors control signal group precision. Higher = more precise
(lower variance). Default 1.0 reproduces the original hardcoded variances.

- `market_precision_scale` — odds + oracle (most precise signals)
- `history_precision_scale` — form + race history + VG history + trajectory
- `ability_precision_scale` — PCS specialty + VG season points (broadest)

Effective variance = base_variance × ratio / scale_factor. Use
`check_stylised_facts()` and `sensitivity_sweep()` in `prior_checks.jl`
to validate settings against domain knowledge.

### 2. Base variances and ratios (change only if domain knowledge changes)

These encode the signal hierarchy *within* each group. For example, in the
history group, form (variance 0.9) is more precise than race history
(variance 3.0, ratio 10/3). Adjusting a scale factor moves all signals in
that group together, preserving these ratios.

### 3. Temporal decay rates (set once)

`hist_decay_rate` and `vg_hist_decay_rate` control how quickly historical
results lose relevance: variance = base + decay_rate × years_ago.
`pcs_season_decay` controls how quickly past seasons' PCS points lose weight
when computing the ability signal (half-life ≈ ln(2)/rate seasons).
These are independent of the scale factors because they control *how fast*
signal degrades rather than *how much* to trust the signal source.

### 4. Other parameters

- `odds_normalisation` — scales log-odds to z-score range
- `within_cluster_correlation` / `between_cluster_correlation` — block-correlation
  discount preventing overconfidence when many correlated signals agree
- `vg_season_penalty` — inflates VG variance early in the season
- `prior_variance` — uninformative prior (SD=10, no reason to change)
- Floor parameters — handle absent riders when a signal covers the field
"""
@kwdef struct BayesianConfig
    # --- Three tuneable scale factors ---
    # These control signal group precision. Higher = more precise (lower variance).
    # Default 1.0 reproduces the original hardcoded variances exactly.

    # Market signals: odds, oracle
    market_precision_scale::Float64 = 4.0

    # Historical signals: form, race history, VG history, trajectory
    history_precision_scale::Float64 = 2.0

    # Broad ability signals: PCS specialty, VG season points
    ability_precision_scale::Float64 = 1.0

    # --- Fixed ratios between signals within each group (domain knowledge, not tuned) ---

    # Market: oracle is less precise than odds (increased from 2.0 after
    # 10-race 2026 review showed oracle mean |shift| of 1.7 — disproportionate
    # influence with no measurable rank-ordering benefit over the no-market backtest)
    _odds_to_oracle_ratio::Float64 = 3.5

    # Historical: race history and VG history are noisier than recent form
    _form_to_hist_ratio::Float64 = 3.0
    _form_to_vg_hist_ratio::Float64 = 5.0

    # Ability: VG season points match PCS specialty in precision
    _pcs_to_vg_ratio::Float64 = 1.0

    # --- Temporal decay (independent, not grouped) ---

    hist_decay_rate::Float64 = 3.2
    # Reduced from 1.3: recent-edition VG results are genuinely informative
    # but the old decay made even 1-year-old data imprecise (var 2.5+1.3=3.8)
    vg_hist_decay_rate::Float64 = 0.8
    # PCS season decay: weight = exp(-rate × years_ago). Default 0.7 gives
    # half-life ≈ 1 season (last season ~50%, 2 years ago ~25%, 3 years ago ~12%).
    pcs_season_decay::Float64 = 0.7

    # --- Other parameters ---

    # Divisor to scale log-odds to z-score range, matching the scale of
    # PCS z-scores (~±5) and position_to_strength (~±5). With ~160 starters,
    # a 40% favourite produces log(0.4 / 0.006) / 1.0 ≈ 4.2, comparable to
    # the PCS z-score for top riders.
    odds_normalisation::Float64 = 1.0
    # Block-correlation discount for correlated signals.
    # Signals are grouped into three clusters (market, history, ability).
    # Within each cluster, signals share within_cluster_correlation;
    # between clusters, effective signals share between_cluster_correlation.
    # Prevents over-concentration for favourites with many history observations.
    within_cluster_correlation::Float64 = 0.5
    between_cluster_correlation::Float64 = 0.15
    # Scales vg_variance early in the season when few riders have points.
    # Effective variance = vg_variance * (1 + penalty * (1 - frac_nonzero)).
    # At opening weekend (~10% with points): ~6.6. Late season (~80%): ~2.4.
    vg_season_penalty::Float64 = 1.3
    prior_variance::Float64 = 100.0  # uninformative prior (SD=10 on z-score scale)
    # --- Absence floors ---
    # When a signal covers the field but a rider is missing, absence is
    # informative. `floor_signals` controls which signals apply this logic.
    # Floor observations use per-signal variance multipliers × base_variance
    # (less precise than direct observations).
    #
    # Two floor mechanisms:
    #   :odds, :oracle — market-based: absent riders share the residual
    #       probability mass (data-driven, varies per race).
    #   :form, :qualitative — fixed: absent riders get a per-signal floor
    #       strength as a z-score observation. Stronger floors for sources
    #       with broader coverage (odds > oracle > qualitative).
    floor_signals::Set{Symbol} = Set([:odds, :oracle, :qualitative])
    # Per-signal floor config: (strength, variance_multiplier).
    # Strength is the z-score observation for absent riders.
    # Variance multiplier scales the signal's base variance for floor observations
    # (higher = weaker floor). Sources with broader coverage warrant stronger
    # floors (lower multiplier, more negative strength).
    odds_floor_variance_multiplier::Float64 = 2.0
    oracle_floor_variance_multiplier::Float64 = 2.0
    form_absence_floor::Float64 = -0.5
    form_floor_variance_multiplier::Float64 = 2.0
    qualitative_absence_floor::Float64 = -0.15
    qualitative_floor_variance_multiplier::Float64 = 4.0
    # --- Market discount ---
    # When odds exist for a race, non-market signal variances are multiplied
    # by this factor for ALL riders (race-level, not per-rider). The market
    # incorporates career record, form, and race history, so these signals
    # are largely redundant. A value of 8.0 means non-market signals carry
    # ~1/64 of their usual precision when odds are present.
    market_discount::Float64 = 8.0
end

# --- Accessor functions: compute effective variances from scale factors ---
# Each function returns ratio / scale_factor for the appropriate signal group.
# All code should use these rather than accessing the underscore-prefixed fields directly.
pcs_variance(c::BayesianConfig) = 1.0 / c.ability_precision_scale
vg_variance(c::BayesianConfig) = c._pcs_to_vg_ratio / c.ability_precision_scale
form_variance(c::BayesianConfig) = 1.0 / c.history_precision_scale
hist_base_variance(c::BayesianConfig) = c._form_to_hist_ratio / c.history_precision_scale
vg_hist_base_variance(c::BayesianConfig) =
    c._form_to_vg_hist_ratio / c.history_precision_scale
odds_variance(c::BayesianConfig) = 1.0 / c.market_precision_scale
oracle_variance(c::BayesianConfig) = c._odds_to_oracle_ratio / c.market_precision_scale
qualitative_base_variance(c::BayesianConfig) = 2.0

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
    RiderSignalData

Per-rider signal observations fed to `estimate_rider_strength`. Bundles the
15 signal fields so the boundary between signal assembly and Bayesian estimation
is explicit and type-checked.

`n_starters`, `config`, and `effective_vg_variance` are race-level context and
remain as separate arguments to `estimate_rider_strength`.
"""
@kwdef struct RiderSignalData
    pcs_score::Float64 = 0.0
    has_pcs::Bool = true
    race_history::Vector{Float64} = Float64[]
    race_history_years_ago::Vector{Int} = Int[]
    race_history_variance_penalties::Vector{Float64} = Float64[]
    vg_points::Float64 = 0.0
    form_score::Float64 = 0.0
    vg_race_history::Vector{Float64} = Float64[]
    vg_race_history_years_ago::Vector{Int} = Int[]
    odds_implied_prob::Float64 = 0.0
    oracle_implied_prob::Float64 = 0.0
    odds_floor_strength::Float64 = 0.0
    oracle_floor_strength::Float64 = 0.0
    form_floor_strength::Float64 = 0.0
    qualitative_floor_strength::Float64 = 0.0
    qualitative_adjustments::Vector{Float64} = Float64[]
    qualitative_confidences::Vector{Float64} = Float64[]
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
function estimate_rider_strength(
    signals::RiderSignalData;
    n_starters::Int=150,
    config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    effective_vg_variance::Float64=0.0,  # 0 = use vg_variance(config)
    race_has_market::Bool=false,
)
    (; pcs_score, has_pcs, race_history, race_history_years_ago,
        race_history_variance_penalties, vg_points,
        odds_implied_prob, oracle_implied_prob,
        odds_floor_strength, oracle_floor_strength) = signals
    # --- Uninformative prior ---
    # Start from a diffuse prior (mean=0, large variance). All signals,
    # including PCS specialty, update this as observations.
    prior = BayesianPosterior(0.0, config.prior_variance)
    posterior = prior
    n_signals = 0
    n_ability = 0
    n_history = 0
    n_market = 0

    # --- Market discount ---
    # When odds exist for this race, non-market signals are partially redundant
    # for ALL riders — priced riders have their ability reflected in odds directly,
    # and unpriced riders were implicitly assessed by the market's decision not to
    # price them. Apply the discount at the race level, not per-rider.
    md = race_has_market ? config.market_discount : 1.0

    # --- Update with PCS specialty ---
    # PCS specialty z-score is the broadest signal: general rider ability.
    # Only applied when the rider has real PCS data (not coalesced-from-missing).
    mean_before = posterior.mean
    if has_pcs
        posterior = bayesian_update(posterior, pcs_score, pcs_variance(config) * md)
        n_signals += 1
        n_ability += 1
    end
    shift_pcs = posterior.mean - mean_before

    # --- Update with VG season points ---
    # VG points reflect current season form. Moderate precision.
    mean_before = posterior.mean
    if vg_points != 0.0
        eff_vg_var =
            effective_vg_variance > 0.0 ? effective_vg_variance : vg_variance(config)
        posterior = bayesian_update(posterior, vg_points, eff_vg_var * md)
        n_signals += 1
        n_ability += 1
    end
    shift_vg = posterior.mean - mean_before

    # --- Precision boundary: ability cluster complete ---
    prec_after_ability = 1.0 / posterior.variance

    # --- PCS form score (disabled April 2026) ---
    # Ablation study across 11 prospective races showed near-zero within-tier
    # Spearman ρ (-0.014 bottom, 0.003 middle, 0.106 top). The signal shifts
    # the posterior without improving ordering, adding noise via the block-
    # correlation discount. Data collection and archival continue; the signal
    # can be re-enabled via backtesting's :form flag for future evaluation.
    shift_form = 0.0

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
        hist_var = (hist_base_variance(config) + config.hist_decay_rate * years_ago + penalty) * md
        posterior = bayesian_update(posterior, hist_strength, hist_var)
        n_signals += 1
        n_history += 1
    end
    shift_history = posterior.mean - mean_before

    # --- VG race history (disabled April 2026) ---
    # Ablation study showed near-zero within-tier ρ (0.056 bottom, 0.048
    # middle, -0.071 top) — slightly anti-informative for top riders.
    # Dropping it alongside PCS form improves non-market ρ from 0.509 to
    # 0.528 with consistent direction across all tiers. Data collection
    # and archival continue; re-enable via backtesting's :vg_history flag.
    shift_vg_history = 0.0

    # --- Precision boundary: history cluster complete ---
    prec_after_history = 1.0 / posterior.variance

    # --- Update with Cycling Oracle predictions ---
    # Algorithmic win probabilities. Less precise than market odds but covers more races.
    mean_before = posterior.mean
    if oracle_implied_prob > 0.0
        baseline_prob = 1.0 / n_starters
        oracle_strength =
            log(oracle_implied_prob / baseline_prob) / config.odds_normalisation
        posterior = bayesian_update(posterior, oracle_strength, oracle_variance(config))
        n_signals += 1
        n_market += 1
    elseif oracle_floor_strength != 0.0
        floor_var = oracle_variance(config) * config.oracle_floor_variance_multiplier
        posterior = bayesian_update(posterior, oracle_floor_strength, floor_var)
        n_signals += 1
        n_market += 1
    end
    shift_oracle = posterior.mean - mean_before

    # --- Qualitative intelligence (disabled April 2026) ---
    # Ablation study showed negligible overall impact (ρ 0.505 vs 0.509)
    # and anti-informative direction for top-tier riders (ρ=-0.291, n=60).
    # Sample sizes were small, but the signal clearly contributes nothing
    # positive. Data collection and archival continue for manual analysis;
    # re-enable via backtesting's :qualitative flag.
    shift_qualitative = 0.0

    # --- Update with betting odds ---
    # Odds-implied probability is the market's posterior. Very precise when available.
    mean_before = posterior.mean
    if odds_implied_prob > 0.0
        baseline_prob = 1.0 / n_starters
        odds_strength = log(odds_implied_prob / baseline_prob) / config.odds_normalisation
        posterior = bayesian_update(posterior, odds_strength, odds_variance(config))
        n_signals += 1
        n_market += 1
    elseif odds_floor_strength != 0.0
        floor_var = odds_variance(config) * config.odds_floor_variance_multiplier
        posterior = bayesian_update(posterior, odds_floor_strength, floor_var)
        n_signals += 1
        n_market += 1
    end
    shift_odds = posterior.mean - mean_before

    # --- Block-correlation precision discount ---
    # Signals within each cluster (market, history, ability) are highly correlated;
    # signals across clusters are less so. Apply within-cluster discount first,
    # then between-cluster discount on the effective cluster precisions.
    ρ_w = config.within_cluster_correlation
    ρ_b = config.between_cluster_correlation
    n_total = n_ability + n_history + n_market

    if n_total > 1 && (ρ_w > 0 || ρ_b > 0)
        prior_prec = 1.0 / prior.variance
        post_prec = 1.0 / posterior.variance
        total_obs_prec = post_prec - prior_prec

        # Per-cluster observation precision
        ability_obs_prec = prec_after_ability - prior_prec
        history_obs_prec = prec_after_history - prec_after_ability
        market_obs_prec = post_prec - prec_after_history

        # Within-cluster discount, then collect active clusters
        cluster_precs = Float64[]
        for (n_k, obs_prec_k) in [(n_ability, ability_obs_prec),
            (n_history, history_obs_prec),
            (n_market, market_obs_prec)]
            n_k == 0 && continue
            discount_k = n_k > 1 ? 1.0 + ρ_w * (n_k - 1) : 1.0
            push!(cluster_precs, obs_prec_k / discount_k)
        end

        # Between-cluster discount
        n_clusters = length(cluster_precs)
        eff_obs_prec = if n_clusters > 1
            sum(cluster_precs) / (1.0 + ρ_b * (n_clusters - 1))
        else
            cluster_precs[1]
        end

        # Reconstruct posterior with discounted precision
        obs_mean = (posterior.mean * post_prec - prior.mean * prior_prec) / total_obs_prec
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
    # Clamp symmetrically: positions beyond the field get the same magnitude
    # as first place, ensuring the logit scale is balanced. The lower bound
    # (1/(n+1)) corresponds to 1st place; the upper bound (n/(n+1)) to last.
    bound = 1.0 / (n_starters + 1)
    frac = clamp(frac, bound, 1.0 - bound)
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
# Per-stage grand tour simulation
# ---------------------------------------------------------------------------

"""
    simulate_stage_race(stages, stage_strengths, uncertainties, teams, scoring;
                        n_sims=500, cross_stage_alpha=0.7, rng) -> Matrix{Float64}

Simulate a full grand tour stage by stage and return total VG points per rider
per simulation draw (n_riders × n_sims matrix).

Each draw has persistent rider noise (correlated across stages via `cross_stage_alpha`)
and independent per-stage noise. For each stage, riders are ranked by noisy strength,
scored for stage finish, assists, and daily GC classification. After all stages,
final classification bonuses are awarded.

## v1 simplifications
- In-stage bonuses (HC/Cat1 climb points, intermediate sprints) are skipped
- Breakaway modelling is skipped
- All riders complete all stages (no abandonment)
- Gaussian noise only (Student's t can be added later)
"""
function simulate_stage_race(
    stages::Vector{StageProfile},
    stage_strengths::Dict{Symbol,Vector{Float64}},
    uncertainties::Vector{Float64},
    teams::Vector{String},
    scoring::StageRaceScoringTable;
    n_sims::Int=500,
    cross_stage_alpha::Float64=0.7,
    rng::AbstractRNG=Random.default_rng(),
)
    n_riders = length(uncertainties)
    alpha = cross_stage_alpha
    beta = sqrt(1.0 - alpha^2)  # ensures total noise variance = uncertainty²

    sim_vg_points = zeros(Float64, n_riders, n_sims)

    # Pre-allocate working arrays
    noisy = Vector{Float64}(undef, n_riders)
    positions = Vector{Int}(undef, n_riders)
    rider_noise = Vector{Float64}(undef, n_riders)
    stage_noise = Vector{Float64}(undef, n_riders)
    cumulative_positions = Vector{Int}(undef, n_riders)
    gc_positions = Vector{Int}(undef, n_riders)
    stage_pts = Vector{Float64}(undef, n_riders)

    # Track sprint/KOM classification approximations
    flat_top5_counts = Vector{Int}(undef, n_riders)
    mountain_top5_counts = Vector{Int}(undef, n_riders)

    for sim in 1:n_sims
        # Draw persistent rider noise for this simulation
        for i in 1:n_riders
            rider_noise[i] = randn(rng)
        end

        fill!(cumulative_positions, 0)
        fill!(flat_top5_counts, 0)
        fill!(mountain_top5_counts, 0)

        rider_total_pts = zeros(Float64, n_riders)

        for stage in stages
            stype = stage.stage_type
            strengths = get(stage_strengths, stype, stage_strengths[:hilly])

            # Draw stage-specific noise
            for i in 1:n_riders
                stage_noise[i] = randn(rng)
                noisy[i] = strengths[i] + uncertainties[i] * (alpha * rider_noise[i] + beta * stage_noise[i])
            end

            # Rank by noisy strength (descending) → positions
            order = sortperm(noisy, rev=true)
            for (pos, rider_idx) in enumerate(order)
                positions[rider_idx] = pos
            end

            # Score stage finish points (positions 1-20)
            fill!(stage_pts, 0.0)
            for i in 1:n_riders
                stage_pts[i] = Float64(stage_finish_points_for_position(positions[i], scoring))
            end

            # Stage assist points (teammates of top-3 finishers; skip on ITT/TTT)
            if stype != :itt && stype != :ttt
                for i in 1:n_riders
                    if positions[i] <= 3
                        for j in 1:n_riders
                            if j != i && teams[j] == teams[i]
                                stage_pts[j] += scoring.stage_assist_points[positions[i]]
                            end
                        end
                    end
                end
            end

            # Track cumulative GC standings (sum of positions)
            for i in 1:n_riders
                cumulative_positions[i] += positions[i]
            end

            # Rank by cumulative positions (ascending = lower is better)
            gc_order = sortperm(cumulative_positions)
            for (gc_pos, rider_idx) in enumerate(gc_order)
                gc_positions[rider_idx] = gc_pos
            end

            # Award daily GC points
            for i in 1:n_riders
                stage_pts[i] += daily_gc_points_for_position(gc_positions[i], scoring)
            end

            # GC assist points (teammates of GC top 3; skip on ITT)
            if stype != :itt && stype != :ttt
                for i in 1:n_riders
                    if gc_positions[i] <= 3
                        for j in 1:n_riders
                            if j != i && teams[j] == teams[i]
                                stage_pts[j] += scoring.gc_assist_points[gc_positions[i]]
                            end
                        end
                    end
                end
            end

            # Track sprint/KOM classification approximations
            for i in 1:n_riders
                if positions[i] <= 5
                    if stype == :flat || stype == :hilly
                        flat_top5_counts[i] += 1
                    end
                    if stype == :mountain
                        mountain_top5_counts[i] += 1
                    end
                end
            end

            # Accumulate stage points
            for i in 1:n_riders
                rider_total_pts[i] += stage_pts[i]
            end
        end

        # --- Final classification bonuses ---

        # Final GC
        for i in 1:n_riders
            rider_total_pts[i] += final_gc_points_for_position(gc_positions[i], scoring)
        end

        # Final points classification (approximate: most top-5 flat/hilly finishes)
        sprint_order = sortperm(flat_top5_counts, rev=true)
        for rank in 1:min(10, n_riders)
            rider_idx = sprint_order[rank]
            if flat_top5_counts[rider_idx] > 0
                rider_total_pts[rider_idx] += scoring.final_points_class[rank]
            end
        end

        # Final mountains classification (approximate: most top-5 mountain finishes)
        kom_order = sortperm(mountain_top5_counts, rev=true)
        for rank in 1:min(10, n_riders)
            rider_idx = kom_order[rank]
            if mountain_top5_counts[rider_idx] > 0
                rider_total_pts[rider_idx] += scoring.final_mountains_class[rank]
            end
        end

        # Final team classification (sum of top 3 riders' cumulative positions per team)
        team_set = unique(teams)
        team_cum_scores = Dict{String,Int}()
        for t in team_set
            team_idx = findall(==(t), teams)
            # Sum the 3 lowest cumulative positions (best GC riders)
            sorted_cum = sort(cumulative_positions[team_idx])
            team_cum_scores[t] = sum(sorted_cum[1:min(3, length(sorted_cum))])
        end
        team_ranking = sort(collect(team_cum_scores), by=x -> x.second)
        for rank in 1:min(length(scoring.final_team_class), length(team_ranking))
            t = team_ranking[rank].first
            for i in 1:n_riders
                if teams[i] == t
                    rider_total_pts[i] += scoring.final_team_class[rank]
                end
            end
        end

        # Store total points for this simulation
        for i in 1:n_riders
            sim_vg_points[i, sim] = rider_total_pts[i]
        end
    end

    return sim_vg_points
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
# Stage-type strength modifiers
# ---------------------------------------------------------------------------

"""
Stage-type modifier weights by rider classification.

For each stage type, a class-aware blend of log-transformed, z-scored PCS specialty
columns determines how much a rider's strength is shifted relative to their base
(overall GC) strength. The base strength already incorporates odds, oracle, and all
other Bayesian signals — these modifiers only differentiate by stage type.
"""
const STAGE_TYPE_MODIFIER_WEIGHTS = Dict{Symbol,Dict{String,Vector{Pair{Symbol,Float64}}}}(
    :flat => Dict(
        "allrounder" => [:gc => 0.2, :sprint => 0.4, :oneday => 0.3, :tt => 0.1],
        "climber" => [:gc => 0.3, :sprint => 0.1, :oneday => 0.3, :climber => 0.3],
        "sprinter" => [:gc => 0.05, :sprint => 0.7, :oneday => 0.2, :tt => 0.05],
        "unclassed" => [:gc => 0.2, :sprint => 0.3, :oneday => 0.4, :tt => 0.1],
    ),
    :hilly => Dict(
        "allrounder" => [:gc => 0.3, :sprint => 0.1, :oneday => 0.3, :tt => 0.1, :climber => 0.2],
        "climber" => [:gc => 0.2, :sprint => 0.05, :oneday => 0.2, :tt => 0.1, :climber => 0.45],
        "sprinter" => [:gc => 0.1, :sprint => 0.3, :oneday => 0.35, :tt => 0.1, :climber => 0.15],
        "unclassed" => [:gc => 0.25, :sprint => 0.15, :oneday => 0.35, :tt => 0.1, :climber => 0.15],
    ),
    :mountain => Dict(
        "allrounder" => [:gc => 0.25, :climber => 0.5, :tt => 0.15, :oneday => 0.1],
        "climber" => [:gc => 0.15, :climber => 0.7, :tt => 0.1, :oneday => 0.05],
        "sprinter" => Symbol[],  # fixed penalty, not PCS-derived
        "unclassed" => [:gc => 0.2, :climber => 0.4, :tt => 0.15, :oneday => 0.25],
    ),
    :itt => Dict(
        "allrounder" => [:gc => 0.2, :tt => 0.7, :oneday => 0.1],
        "climber" => [:gc => 0.15, :tt => 0.35, :climber => 0.35, :oneday => 0.15],
        "sprinter" => [:gc => 0.1, :tt => 0.5, :sprint => 0.25, :oneday => 0.15],
        "unclassed" => [:gc => 0.2, :tt => 0.5, :oneday => 0.15, :climber => 0.15],
    ),
)

"""Sprinter fixed penalty on mountain stages (instead of PCS-derived blend)."""
const SPRINTER_MOUNTAIN_PENALTY = -0.5

"""
    compute_stage_type_modifiers(rider_df, base_strengths; modifier_scale=0.5)
        -> Dict{Symbol, Vector{Float64}}

Compute per-stage-type adjusted strengths from base (overall GC) strengths
and PCS specialty profiles.

The base strengths already incorporate odds, oracle, and all Bayesian signals
via `estimate_strengths`. This function differentiates riders by stage type
using their PCS specialty columns (gc, tt, sprint, climber, oneday).

Returns a Dict mapping each stage type to a vector of adjusted strengths
(same length as `base_strengths`).
"""
function compute_stage_type_modifiers(
    rider_df::DataFrame,
    base_strengths::Vector{Float64};
    modifier_scale::Float64=0.5,
)
    n_riders = length(base_strengths)
    specialty_cols = [:gc, :tt, :sprint, :climber, :oneday]

    # Determine which riders have PCS data
    has_pcs = if :has_pcs_data in propertynames(rider_df)
        Bool.(rider_df.has_pcs_data)
    elseif :has_pcs in propertynames(rider_df)
        Bool.(rider_df.has_pcs)
    else
        available = intersect(propertynames(rider_df), specialty_cols)
        [any(rider_df[i, col] != 0 for col in available) for i in 1:n_riders]
    end

    # Log-transform and z-score each PCS specialty column
    # (following the one-day pattern: raw scores are heavily right-skewed)
    z_scores = Dict{Symbol,Vector{Float64}}()
    for col in specialty_cols
        if col in propertynames(rider_df)
            raw = Float64.(coalesce.(rider_df[!, col], 0.0))
            logged = log1p.(max.(raw, 0.0))
            μ = mean(logged)
            σ = std(logged)
            z_scores[col] = σ > 0 ? (logged .- μ) ./ σ : zeros(n_riders)
        else
            z_scores[col] = zeros(n_riders)
        end
    end

    # Determine rider classifications
    class_col = :classraw in propertynames(rider_df) ? :classraw :
                :class in propertynames(rider_df) ? :class : nothing
    classes = if class_col !== nothing
        [lowercase(string(rider_df[i, class_col])) for i in 1:n_riders]
    else
        fill("unclassed", n_riders)
    end

    # Compute modifier for each stage type
    result = Dict{Symbol,Vector{Float64}}()
    for stage_type in [:flat, :hilly, :mountain, :itt]
        modifiers = zeros(n_riders)
        weights_for_type = STAGE_TYPE_MODIFIER_WEIGHTS[stage_type]

        for i in 1:n_riders
            !has_pcs[i] && continue
            cls = classes[i]
            rider_weights = get(weights_for_type, cls, weights_for_type["unclassed"])

            # Sprinter mountain penalty: fixed value, not PCS-derived
            if stage_type == :mountain && cls == "sprinter"
                modifiers[i] = SPRINTER_MOUNTAIN_PENALTY
                continue
            end

            isempty(rider_weights) && continue

            blend = 0.0
            for (col, w) in rider_weights
                blend += w * z_scores[col][i]
            end
            modifiers[i] = blend
        end

        result[stage_type] = base_strengths .+ modifier_scale .* modifiers
    end

    # TTT uses ITT modifiers (TT specialists are likely on strong TTT teams)
    result[:ttt] = copy(result[:itt])

    return result
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
    effective_vg_variance = vg_variance(bayesian_config) * season_scale
    @info "Season-adaptive VG variance: $(round(effective_vg_variance, digits=2)) " *
          "($(round(100 * frac_nonzero, digits=0))% with points, scale=$(round(season_scale, digits=2)))"

    # --- Current year (needed by race history and PCS season decay) ---
    current_year = if race_date !== nothing
        Dates.year(race_date)
    elseif race_year !== nothing
        race_year
    else
        Dates.year(Dates.today())
    end


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

    # --- Replace career-cumulative PCS specialty with decay-weighted season points ---
    # Career specialty scores never decay, so for riders with season-level data
    # we substitute a decay-weighted average of recent PCS season points. This
    # naturally captures current ability without career-cumulative bias. Riders
    # without season data keep their career specialty z-score as fallback.
    seasons_keys = Set{String}()
    if seasons_df !== nothing &&
       :riderkey in propertynames(seasons_df) &&
       :pcs_points in propertynames(seasons_df) &&
       :year in propertynames(seasons_df)
        for g in groupby(seasons_df, :riderkey)
            key = first(g.riderkey)
            push!(seasons_keys, key)

            weights = [exp(-bayesian_config.pcs_season_decay * (current_year - r.year)) for r in eachrow(g)]
            weighted_pts = sum(weights .* g.pcs_points) / sum(weights)

            idx = findfirst(==(key), df.riderkey)
            idx === nothing && continue
            pcs_z[idx] = weighted_pts
        end

        # Log-transform before z-scoring: season points are heavily right-skewed
        # (top riders 3000+, domestiques ~50), so raw z-scores produce extreme
        # outliers. log1p compresses the scale so relative differences matter
        # equally across the range.
        pcs_z = log1p.(max.(pcs_z, 0.0))

        # Re-z-score after substitution so the mixed signal is normalised
        pcs_mean = mean(pcs_z)
        pcs_std = std(pcs_z)
        pcs_z = pcs_std > 0 ? (pcs_z .- pcs_mean) ./ pcs_std : zeros(n_riders)
    end

    # --- Build odds lookup (with surname re-matching for unmatched riders) ---
    odds_lookup = Dict{String,Float64}()
    if odds_df !== nothing &&
       :riderkey in propertynames(odds_df) &&
       :odds in propertynames(odds_df)
        :rider in propertynames(odds_df) && rematch_riderkeys!(odds_df, df)
        raw_probs = 1.0 ./ Float64.(odds_df.odds)
        overround = sum(raw_probs)
        for (i, row) in enumerate(eachrow(odds_df))
            odds_lookup[row.riderkey] = raw_probs[i] / overround
        end
    end

    # --- Build Cycling Oracle lookup (with surname re-matching) ---
    oracle_lookup = Dict{String,Float64}()
    if oracle_df !== nothing &&
       :riderkey in propertynames(oracle_df) &&
       :win_prob in propertynames(oracle_df)
        :rider in propertynames(oracle_df) && rematch_riderkeys!(oracle_df, df)
        for row in eachrow(oracle_df)
            oracle_lookup[row.riderkey] = Float64(row.win_prob)
        end
    end

    # --- Compute market-based floor strengths (odds/oracle) ---
    # See BayesianConfig.floor_signals for the two floor mechanisms.
    # Odds/oracle: absent riders share the residual probability mass.
    rider_keys = Set(df.riderkey)
    odds_floor_strength_val = 0.0
    if :odds in bayesian_config.floor_signals && !isempty(odds_lookup)
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
            odds_floor_strength_val =
                log(floor_prob / baseline_prob) / bayesian_config.odds_normalisation
        end
        @info "Odds floor: $n_listed priced, $n_absent with floor (strength=$(round(odds_floor_strength_val, digits=2)))"
    end

    oracle_floor_strength_val = 0.0
    if :oracle in bayesian_config.floor_signals && !isempty(oracle_lookup)
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
            oracle_floor_strength_val =
                log(floor_prob / baseline_prob) / bayesian_config.odds_normalisation
        end
        @info "Oracle floor: $n_listed listed, $n_absent with floor (strength=$(round(oracle_floor_strength_val, digits=2)))"
    end

    # --- Qualitative and PCS form lookups (disabled April 2026) ---
    # These signals are no longer fed into the estimator (see comments in
    # estimate_rider_strength). The lookup-building code is retained here
    # commented out so backtesting can still re-enable them via signal flags
    # if form_df/qualitative_df are passed explicitly.
    qualitative_lookup = Dict{String,Vector{Tuple{Float64,Float64}}}()
    form_lookup = Dict{String,Float64}()
    form_floor_strength_val = 0.0
    qualitative_floor_strength_val = 0.0

    # --- Build race history lookup ---
    # Each entry is (strength, years_ago, variance_penalty)
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
        # position_to_strength already produces z-score-like values via logit
        # transform (~-2.5 to +2.5). No further z-scoring needed — re-normalising
        # across only the subset with history data would bias z=0 away from the
        # true field average.
    end

    # --- VG race history lookup (disabled April 2026) ---
    # Signal removed from estimation pipeline; see estimate_rider_strength.
    vg_history_lookup = Dict{String,Vector{Tuple{Float64,Int}}}()

    # Trajectory signal removed: 10-race 2026 review confirmed negligible
    # contribution (mean |shift| 0.2, precision share 4%).

    # --- PCS availability (needed for estimation) ---
    has_pcs = if :has_pcs_data in propertynames(df)
        Bool.(df.has_pcs_data)
    else
        specialty_cols =
            intersect(propertynames(df), [:oneday, :gc, :tt, :sprint, :climber])
        [any(df[i, col] != 0 for col in specialty_cols) for i = 1:n_riders]
    end

    # --- Race-level market flag ---
    # When odds exist for this race, discount non-market signals for ALL riders
    race_has_market = !isempty(odds_lookup)

    # --- Estimate strength for each rider ---
    strengths = Vector{Float64}(undef, n_riders)
    uncertainties = Vector{Float64}(undef, n_riders)
    shifts_pcs = Vector{Float64}(undef, n_riders)
    shifts_vg = Vector{Float64}(undef, n_riders)
    shifts_form = Vector{Float64}(undef, n_riders)
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
            RiderSignalData(
                pcs_score=pcs_z[i],
                has_pcs=has_pcs[i],
                race_history=hist_strengths,
                race_history_years_ago=hist_years,
                race_history_variance_penalties=hist_penalties,
                vg_points=vg_z[i],
                form_score=form_val,
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
            );
            n_starters=n_starters,
            config=bayesian_config,
            effective_vg_variance=effective_vg_variance,
            race_has_market=race_has_market,
        )

        strengths[i] = est.mean
        uncertainties[i] = sqrt(est.variance)
        shifts_pcs[i] = est.shift_pcs
        shifts_vg[i] = est.shift_vg
        shifts_form[i] = est.shift_form
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
    has_seasons = [in(df.riderkey[i], seasons_keys) for i = 1:n_riders]

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
    )
end


# Keyword convenience wrapper — forwards all RiderSignalData fields plus race-level context.
function estimate_rider_strength(;
    n_starters::Int=150,
    config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    effective_vg_variance::Float64=0.0,
    race_has_market::Bool=false,
    kwargs...
)
    estimate_rider_strength(
        RiderSignalData(; kwargs...);
        n_starters=n_starters,
        config=config,
        effective_vg_variance=effective_vg_variance,
        race_has_market=race_has_market,
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
        total_distance_km=total_distance_km,
    )
end
