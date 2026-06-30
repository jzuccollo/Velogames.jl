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
    # Precision contribution per signal (1/obs_variance summed across updates).
    # Used to compute order-invariant "information share" diagnostics that
    # complement the order-dependent mean-shift fields above.
    precisions::Dict{Symbol,Float64}
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

    # Market: oracle is less precise than odds. Raised 2.0 → 3.5 (April 2026) then
    # 3.5 → 5.0 (post 13-race review) as oracle's within-tier ρ stayed weakly anti-
    # informative in the middle tier (−0.128) despite having the largest mean |shift|.
    _odds_to_oracle_ratio::Float64 = 5.0

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
    #   :odds — market-based: bookmaker GC market prices the full field, so
    #       absence is informative (residual probability mass shared across
    #       absent riders).
    #   :form, :qualitative — fixed: absent riders get a per-signal floor
    #       strength as a z-score observation.
    #
    # `:oracle` is intentionally absent: Cycling Oracle publishes a top-15
    # with probabilities normalised to sum to 1.0, so applying the residual-
    # probability floor erroneously infers that absent riders have ~1% of
    # baseline (floor strength ≈ -4.7), which dominated the posterior of any
    # rider not in the published top-15. Treat oracle absence as
    # uninformative (consistent with Oracle Points / Oracle KOM handling).
    floor_signals::Set{Symbol} = Set([:odds, :qualitative])
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

# ---------------------------------------------------------------------------
# Multi-dimensional Bayesian model (stage races)
# ---------------------------------------------------------------------------

"""
The five rider-strength dimensions used for stage-race prediction. These are
attributes of *riders*, not of stages.

`:flat`, `:hilly`, `:mountain`, `:itt` are per-stage-type ability dimensions
(a rider's `:flat` is their bunch-finish ability). `:gc` is structurally
different — it tracks cumulative classification ability and is accumulated
per-stage rather than feeding the per-stage strength blend. See
`STAGE_TYPES` for the stage-side enumeration.
"""
const STRENGTH_DIMENSIONS = (:flat, :hilly, :mountain, :itt, :gc)

"""
The five stage-type values that a `StageProfile.stage_type` can take. `:ttt`
is treated as `:itt` for strength purposes (TT specialists are likely on
strong TTT teams). Stage types do *not* include `:gc` — `:gc` is a rider
strength dimension only.
"""
const STAGE_TYPES = (:flat, :hilly, :mountain, :itt, :ttt)

const _DIM_INDEX = Dict(d => i for (i, d) in enumerate(STRENGTH_DIMENSIONS))

"""
    MultiDimPosterior(mean::Vector{Float64}, variance::Vector{Float64})

Per-dimension Gaussian posterior over `STRENGTH_DIMENSIONS`. Dimensions are
treated as independent — cross-dimension coupling is captured *explicitly*
by `SIGNAL_DIMENSION_WEIGHTS` (each observation updates whichever dimensions
the routing table says it informs, with a per-target precision). An earlier
design used a full covariance matrix, but the implicit cov-driven leakage
overpowered the explicit routing for strong signals (e.g. a rider's huge
PCS GC score would leak into ITT, swamping a true TT specialist's PCS TT
direct evidence).
"""
struct MultiDimPosterior
    mean::Vector{Float64}
    variance::Vector{Float64}
end

"""Initial multidim prior: each dimension is N(0, prior_variance) independently."""
function multidim_prior(config::BayesianConfig)
    D = length(STRENGTH_DIMENSIONS)
    return MultiDimPosterior(zeros(D), fill(config.prior_variance, D))
end

"""
    bayesian_update_multidim_dim(post, observation, obs_variance, dim) -> MultiDimPosterior

Scalar Bayesian update on a single dimension's marginal posterior. Other
dimensions are unchanged. Conjugate normal-normal: posterior precision
adds to prior precision, posterior mean is the precision-weighted average.
"""
function bayesian_update_multidim_dim(
    post::MultiDimPosterior,
    observation::Float64,
    obs_variance::Float64,
    dim::Symbol,
)
    idx = _DIM_INDEX[dim]
    cur_var = post.variance[idx]
    cur_mean = post.mean[idx]
    prior_prec = 1.0 / cur_var
    obs_prec = 1.0 / obs_variance
    post_prec = prior_prec + obs_prec
    new_mean = (prior_prec * cur_mean + obs_prec * observation) / post_prec
    new_var = 1.0 / post_prec
    new_means = copy(post.mean)
    new_vars = copy(post.variance)
    new_means[idx] = new_mean
    new_vars[idx] = new_var
    return MultiDimPosterior(new_means, new_vars)
end

# --- Signal → dimension routing principle ---------------------------------
#
# The multidim model uses two complementary mechanisms to decide which
# strength dimensions a signal updates:
#
#   1. Direct (signal-specific) routing — `SIGNAL_DIMENSION_WEIGHTS` below.
#      Used when the signal source itself carries dimension information.
#      PCS sprint score, oracle GC, GC odds: a sprint specialty rating
#      means "flat ability" for every rider, regardless of class. Weights
#      apply uniformly across the field.
#
#   2. Per-rider class projection — `RACE_HISTORY_CLASS_PROJECTION` further
#      below. Used when the signal is dimension-agnostic (raw VG points,
#      generic PCS race finish positions). The rider's classification acts
#      as an attribution prior: a sprinter's VG points project mostly to
#      `:flat`/`:hilly`; a climber's project mostly to `:mountain`. The
#      class signal becomes a multiplier on an otherwise undifferentiated
#      total.
#
# Phase 6 will calibrate both tables empirically against per-stage VG
# history, and may revisit which mechanism each signal should use.
# --------------------------------------------------------------------------

"""
Signal → (dimension → weight) routing for the stage-race multidim model.

Each entry maps a signal source to a per-dimension weight vector. A non-zero
weight `w` means: this signal informs that dimension with effective variance
`base_variance / w`. Zero weights are skipped (no update).

PCS specialty signals route to the dimensions they're empirically informative
about (e.g. PCS sprint score → `:flat` strongly, `:hilly` weakly). Oracle
sources route to the jersey they predict (GC → `:gc`, points → `:flat`/`:hilly`,
KOM → `:mountain`).
"""
const SIGNAL_DIMENSION_WEIGHTS = (
    pcs_sprint   = (flat=1.0, hilly=0.1, mountain=0.0, itt=0.0, gc=0.0),
    # PCS oneday lumps together flat classics (sprinters score here too) and
    # hilly classics. Down-weighted so it doesn't dominate :hilly on its own;
    # the hilly dimension now needs both oneday AND climber to be strong.
    pcs_oneday   = (flat=0.2, hilly=0.5, mountain=0.0, itt=0.0, gc=0.0),
    pcs_climber  = (flat=0.0, hilly=0.5, mountain=1.0, itt=0.0, gc=0.0),
    pcs_tt       = (flat=0.0, hilly=0.0, mountain=0.0, itt=1.0, gc=0.0),
    # GC ability is the strongest single proxy for current climbing form,
    # since PCS climber is career-cumulative and stale. Heavier weight on
    # :mountain so current GC dominance translates into mountain favouritism.
    # `:hilly` cross-routing is small: punchy hilly finishes (cat-3 / cat-4
    # late climbs) reward puncheurs, not GC riders — Vingegaard contests
    # summit finishes, not 4 km kickers, so GC strength shouldn't dominate
    # `:hilly` posterior.
    pcs_gc       = (flat=0.0, hilly=0.1, mountain=0.7, itt=0.0, gc=1.0),
    # GC oracle and odds carry strong "this rider is contender for the overall"
    # information. Positive evidence cross-routes to mountain (Tour-winning
    # climbers typically win summit finishes), but minimally to :hilly — they
    # score daily-GC points there but rarely win punchy hilly stages.
    oracle_gc    = (flat=0.0, hilly=0.05, mountain=0.2, itt=0.0, gc=1.0),
    odds_gc      = (flat=0.0, hilly=0.05, mountain=0.2, itt=0.0, gc=1.0),
    # Jersey oracles predict season-long jersey winners. Points oracle
    # correlates with flat-stage finishing for listed sprinters (they
    # contest bunch finishes consistently), justifying a small :flat
    # weight. KOM oracle routes to :mountain only — those listed are
    # the riders most likely to chase summit-finish bonuses.
    oracle_points= (flat=0.4, hilly=0.1, mountain=0.0, itt=0.0, gc=0.0),
    oracle_kom   = (flat=0.0, hilly=0.0, mountain=1.0, itt=0.0, gc=0.0),
    # Bookmaker odds for jersey markets — same routing as the oracle
    # counterparts, but consumed with the sharper `odds_variance`.
    odds_points  = (flat=0.4, hilly=0.1, mountain=0.0, itt=0.0, gc=0.0),
    odds_kom     = (flat=0.0, hilly=0.0, mountain=1.0, itt=0.0, gc=0.0),
)

"""
Per-class default weighting used to project a past PCS race-history result onto
the multidim strength vector. Until we know the stage-type mix of each past race
(deferred to Phase 2), each result is attributed to dimensions according to the
rider's own class profile — a reasonable shortcut: a sprinter's past results
are mostly evidence about flat-stage ability, etc.
"""
const RACE_HISTORY_CLASS_PROJECTION = Dict{String,NamedTuple}(
    "sprinter"   => (flat=0.7, hilly=0.3, mountain=0.0, itt=0.0, gc=0.0),
    "climber"    => (flat=0.0, hilly=0.3, mountain=0.7, itt=0.0, gc=0.0),
    "allrounder" => (flat=0.0, hilly=0.0, mountain=0.3, itt=0.2, gc=0.5),
    "unclassed"  => (flat=0.2, hilly=0.5, mountain=0.0, itt=0.0, gc=0.3),
)

function _weights_to_vec(nt::NamedTuple)
    [Float64(getfield(nt, d)) for d in STRENGTH_DIMENSIONS]
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
    # Multi-dim only fields (used by stage-race pipeline; ignored by scalar)
    pcs_sprint_z::Float64 = 0.0
    pcs_oneday_z::Float64 = 0.0
    pcs_climber_z::Float64 = 0.0
    pcs_tt_z::Float64 = 0.0
    pcs_gc_z::Float64 = 0.0
    rider_class::String = "unclassed"
    points_oracle_implied_prob::Float64 = 0.0
    points_oracle_floor_strength::Float64 = 0.0
    kom_oracle_implied_prob::Float64 = 0.0
    kom_oracle_floor_strength::Float64 = 0.0
    points_odds_implied_prob::Float64 = 0.0
    kom_odds_implied_prob::Float64 = 0.0
    stagewin_odds_implied_prob::Float64 = 0.0
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
    skip_block_correlation::Bool=false,
    force_enable::Set{Symbol}=Set{Symbol}(),
)
    (; pcs_score, has_pcs, race_history, race_history_years_ago,
        race_history_variance_penalties, vg_points, form_score,
        vg_race_history, vg_race_history_years_ago,
        odds_implied_prob, oracle_implied_prob,
        odds_floor_strength, oracle_floor_strength,
        form_floor_strength, qualitative_floor_strength,
        qualitative_adjustments, qualitative_confidences) = signals
    # --- Uninformative prior ---
    # Start from a diffuse prior (mean=0, large variance). All signals,
    # including PCS specialty, update this as observations.
    prior = BayesianPosterior(0.0, config.prior_variance)
    posterior = prior
    n_signals = 0
    n_ability = 0
    n_history = 0
    n_market = 0
    # Per-signal precision contributions (1/obs_variance summed per signal).
    # Used for order-invariant info-share diagnostics. Pre-discount: reflects
    # raw signal precision; the block-correlation discount is applied to the
    # posterior separately and does not retroactively rescale these.
    precisions = Dict{Symbol,Float64}(
        s => 0.0 for s in (:pcs, :vg, :form, :history, :vg_history, :oracle, :qualitative, :odds)
    )

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
        v = pcs_variance(config) * md
        posterior = bayesian_update(posterior, pcs_score, v)
        precisions[:pcs] += 1.0 / v
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
        v = eff_vg_var * md
        posterior = bayesian_update(posterior, vg_points, v)
        precisions[:vg] += 1.0 / v
        n_signals += 1
        n_ability += 1
    end
    shift_vg = posterior.mean - mean_before

    # --- Precision boundary: ability cluster complete ---
    prec_after_ability = 1.0 / posterior.variance

    # --- PCS form score (disabled April 2026; re-enable via force_enable=:form) ---
    # Ablation study across 11 prospective races showed near-zero within-tier
    # Spearman ρ (-0.014 bottom, 0.003 middle, 0.106 top). The signal shifts
    # the posterior without improving ordering, adding noise via the block-
    # correlation discount. Data collection and archival continue; the signal
    # can be re-enabled via backtesting's :form flag for future evaluation.
    if :form in force_enable
        mean_before = posterior.mean
        if form_score != 0.0
            v = form_variance(config) * md
            posterior = bayesian_update(posterior, form_score, v)
            precisions[:form] += 1.0 / v
            n_signals += 1
            n_history += 1
        elseif form_floor_strength != 0.0
            floor_var = form_variance(config) * config.form_floor_variance_multiplier * md
            posterior = bayesian_update(posterior, form_floor_strength, floor_var)
            precisions[:form] += 1.0 / floor_var
            n_signals += 1
            n_history += 1
        end
        shift_form = posterior.mean - mean_before
    else
        shift_form = 0.0
    end

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
        precisions[:history] += 1.0 / hist_var
        n_signals += 1
        n_history += 1
    end
    shift_history = posterior.mean - mean_before

    # --- VG race history (disabled April 2026; re-enable via force_enable=:vg_history) ---
    # Ablation study showed near-zero within-tier ρ (0.056 bottom, 0.048
    # middle, -0.071 top) — slightly anti-informative for top riders.
    # Dropping it alongside PCS form improves non-market ρ from 0.509 to
    # 0.528 with consistent direction across all tiers. Data collection
    # and archival continue; re-enable via backtesting's :vg_history flag.
    if :vg_history in force_enable
        mean_before = posterior.mean
        if length(vg_race_history) != length(vg_race_history_years_ago)
            @warn "vg_race_history ($(length(vg_race_history))) and vg_race_history_years_ago ($(length(vg_race_history_years_ago))) have different lengths"
        end
        for (vg_strength, years_ago) in zip(vg_race_history, vg_race_history_years_ago)
            vg_var = (vg_hist_base_variance(config) + config.vg_hist_decay_rate * years_ago) * md
            posterior = bayesian_update(posterior, vg_strength, vg_var)
            precisions[:vg_history] += 1.0 / vg_var
            n_signals += 1
            n_history += 1
        end
        shift_vg_history = posterior.mean - mean_before
    else
        shift_vg_history = 0.0
    end

    # --- Precision boundary: history cluster complete ---
    prec_after_history = 1.0 / posterior.variance

    # --- Update with Cycling Oracle predictions ---
    # Algorithmic win probabilities. Cycling Oracle publishes a normalised
    # top-15; inclusion is itself a positive endorsement, and the published
    # probability is intra-list ranking rather than a claim against the full
    # field. Clamp at 0 so a low-probability listing never reduces strength.
    mean_before = posterior.mean
    if oracle_implied_prob > 0.0
        baseline_prob = 1.0 / n_starters
        oracle_strength =
            log(oracle_implied_prob / baseline_prob) / config.odds_normalisation
        if oracle_strength > 0.0
            v = oracle_variance(config)
            posterior = bayesian_update(posterior, oracle_strength, v)
            precisions[:oracle] += 1.0 / v
            n_signals += 1
            n_market += 1
        end
    elseif oracle_floor_strength != 0.0
        floor_var = oracle_variance(config) * config.oracle_floor_variance_multiplier
        posterior = bayesian_update(posterior, oracle_floor_strength, floor_var)
        precisions[:oracle] += 1.0 / floor_var
        n_signals += 1
        n_market += 1
    end
    shift_oracle = posterior.mean - mean_before

    # --- Qualitative intelligence (disabled April 2026; re-enable via force_enable=:qualitative) ---
    # Ablation study showed negligible overall impact (ρ 0.505 vs 0.509)
    # and anti-informative direction for top-tier riders (ρ=-0.291, n=60).
    # Sample sizes were small, but the signal clearly contributes nothing
    # positive. Data collection and archival continue for manual analysis;
    # re-enable via backtesting's :qualitative flag.
    if :qualitative in force_enable
        mean_before = posterior.mean
        if !isempty(qualitative_adjustments)
            for (adj, conf) in zip(qualitative_adjustments, qualitative_confidences)
                if conf > 0.0
                    eff_var = qualitative_base_variance(config) / conf
                    posterior = bayesian_update(posterior, adj, eff_var)
                    precisions[:qualitative] += 1.0 / eff_var
                    n_signals += 1
                    n_market += 1
                end
            end
        elseif qualitative_floor_strength != 0.0
            floor_var = qualitative_base_variance(config) * config.qualitative_floor_variance_multiplier
            posterior = bayesian_update(posterior, qualitative_floor_strength, floor_var)
            precisions[:qualitative] += 1.0 / floor_var
            n_signals += 1
            n_market += 1
        end
        shift_qualitative = posterior.mean - mean_before
    else
        shift_qualitative = 0.0
    end

    # --- Update with betting odds ---
    # Odds-implied probability is the market's posterior. Very precise when available.
    # When listed below baseline (longshot tail), fall through to the bounded
    # absence floor instead of applying the negative obs — listings at long
    # odds are conservative tail-pricing, not strong negative endorsements.
    mean_before = posterior.mean
    if odds_implied_prob > 0.0
        baseline_prob = 1.0 / n_starters
        odds_strength = log(odds_implied_prob / baseline_prob) / config.odds_normalisation
        if odds_strength > 0.0
            v = odds_variance(config)
            posterior = bayesian_update(posterior, odds_strength, v)
            precisions[:odds] += 1.0 / v
            n_signals += 1
            n_market += 1
        elseif odds_floor_strength != 0.0
            floor_var = odds_variance(config) * config.odds_floor_variance_multiplier
            posterior = bayesian_update(posterior, odds_floor_strength, floor_var)
            precisions[:odds] += 1.0 / floor_var
            n_signals += 1
            n_market += 1
        end
    elseif odds_floor_strength != 0.0
        floor_var = odds_variance(config) * config.odds_floor_variance_multiplier
        posterior = bayesian_update(posterior, odds_floor_strength, floor_var)
        precisions[:odds] += 1.0 / floor_var
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

    if !skip_block_correlation && n_total > 1 && (ρ_w > 0 || ρ_b > 0)
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
        precisions,
    )
end

# ---------------------------------------------------------------------------
# Multi-dimensional strength estimation (stage races)
# ---------------------------------------------------------------------------

"""
    MultiDimStrengthEstimate

Result of `estimate_rider_strength_multidim`: per-dimension posterior mean and
variance plus per-signal per-dimension shift diagnostics.
"""
struct MultiDimStrengthEstimate
    mean::Vector{Float64}
    variance::Vector{Float64}
    shifts::Dict{Symbol,Vector{Float64}}
    # Precision contribution per (signal, dim): 1/obs_variance accumulated
    # across all bayesian_update_multidim_dim calls for that signal on that
    # dim. Used for order-invariant information-share diagnostics.
    precisions::Dict{Symbol,Vector{Float64}}
end

"""
    estimate_rider_strength_multidim(signals; n_starters, config, ...) -> MultiDimStrengthEstimate

Multi-dimensional Bayesian strength estimation for stage races. Mirrors the
signal sequence in `estimate_rider_strength` but routes each observation to
the dimensions in `STRENGTH_DIMENSIONS` according to `SIGNAL_DIMENSION_WEIGHTS`.
GC-flavoured floors (Cycling Oracle GC, GC odds) only touch the `:gc`
dimension; sprinters absent from the GC market are no longer penalised on
`:flat`/`:hilly`.
"""
function estimate_rider_strength_multidim(
    signals::RiderSignalData;
    n_starters::Int=150,
    config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    effective_vg_variance::Float64=0.0,
    race_has_market::Bool=false,
)
    D = length(STRENGTH_DIMENSIONS)
    posterior = multidim_prior(config)
    md = race_has_market ? config.market_discount : 1.0
    shifts = Dict{Symbol,Vector{Float64}}()
    # Per-(signal, dim) precision contributions for order-invariant info-share
    # diagnostics. Each `bayesian_update_multidim_dim(posterior, obs, var, dsym)`
    # call below accumulates `1/var` into the corresponding entry.
    precisions = Dict{Symbol,Vector{Float64}}(
        s => zeros(D) for s in (
            :pcs, :vg, :form, :history, :vg_history,
            :oracle_gc, :oracle_points, :oracle_kom, :qualitative,
            :odds, :odds_points, :odds_kom, :odds_stagewin,
        )
    )

    # --- PCS specialty (per-source, dim-specific) ---
    mean_before = copy(posterior.mean)
    if signals.has_pcs
        base_var = pcs_variance(config) * md
        for (sig_name, obs) in (
            (:pcs_sprint,  signals.pcs_sprint_z),
            (:pcs_oneday,  signals.pcs_oneday_z),
            (:pcs_climber, signals.pcs_climber_z),
            (:pcs_tt,      signals.pcs_tt_z),
            (:pcs_gc,      signals.pcs_gc_z),
        )
            weights_nt = getfield(SIGNAL_DIMENSION_WEIGHTS, sig_name)
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(weights_nt, dsym)
                w == 0.0 && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[:pcs][_DIM_INDEX[dsym]] += 1.0 / v
            end
        end
    end
    shifts[:pcs] = posterior.mean .- mean_before

    # --- VG season points (per-class projection rather than uniform ability) ---
    # Routing VG points uniformly across all dimensions caused strong cross-dim
    # leakage: a rider with high VG points (e.g. Vingegaard from GC scoring)
    # would inflate every dimension, including ones where they are not strong
    # (e.g. ITT, where Ganna with low VG but huge PCS tt should dominate).
    # Project VG via the rider's class profile instead — same mechanism as
    # PCS race history.
    mean_before = copy(posterior.mean)
    if signals.vg_points != 0.0
        eff_var_base = effective_vg_variance > 0.0 ? effective_vg_variance : vg_variance(config)
        eff_var_base *= md
        proj = get(
            RACE_HISTORY_CLASS_PROJECTION,
            lowercase(signals.rider_class),
            RACE_HISTORY_CLASS_PROJECTION["unclassed"],
        )
        for dsym in STRENGTH_DIMENSIONS
            w = getfield(proj, dsym)
            w == 0.0 && continue
            v = eff_var_base / w
            posterior = bayesian_update_multidim_dim(posterior, signals.vg_points, v, dsym)
            precisions[:vg][_DIM_INDEX[dsym]] += 1.0 / v
        end
    end
    shifts[:vg] = posterior.mean .- mean_before

    # PCS form: disabled (mirrors scalar default; not propagated through multidim path in Phase 1)
    shifts[:form] = zeros(D)

    # --- PCS race history (projected onto dims by rider class) ---
    mean_before = copy(posterior.mean)
    if !isempty(signals.race_history)
        proj = get(
            RACE_HISTORY_CLASS_PROJECTION,
            lowercase(signals.rider_class),
            RACE_HISTORY_CLASS_PROJECTION["unclassed"],
        )
        for (i, (hist_strength, years_ago)) in
            enumerate(zip(signals.race_history, signals.race_history_years_ago))
            penalty = i <= length(signals.race_history_variance_penalties) ?
                      signals.race_history_variance_penalties[i] : 0.0
            base_var = (hist_base_variance(config) + config.hist_decay_rate * years_ago + penalty) * md
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(proj, dsym)
                w == 0.0 && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, hist_strength, v, dsym)
                precisions[:history][_DIM_INDEX[dsym]] += 1.0 / v
            end
        end
    end
    shifts[:history] = posterior.mean .- mean_before

    # --- VG race history (per-class projection, mirrors VG season points) ---
    mean_before = copy(posterior.mean)
    if !isempty(signals.vg_race_history)
        proj = get(
            RACE_HISTORY_CLASS_PROJECTION,
            lowercase(signals.rider_class),
            RACE_HISTORY_CLASS_PROJECTION["unclassed"],
        )
        for (vg_strength, years_ago) in zip(signals.vg_race_history, signals.vg_race_history_years_ago)
            eff_var = (vg_hist_base_variance(config) + config.vg_hist_decay_rate * years_ago) * md
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(proj, dsym)
                w == 0.0 && continue
                v = eff_var / w
                posterior = bayesian_update_multidim_dim(posterior, vg_strength, v, dsym)
                precisions[:vg_history][_DIM_INDEX[dsym]] += 1.0 / v
            end
        end
    end
    shifts[:vg_history] = posterior.mean .- mean_before

    # --- Cycling Oracle GC ---
    # Cycling Oracle publishes a normalised top-15. Inclusion is itself a
    # positive endorsement; the published probability ranks within the listed
    # set, not against the full field. A bottom-of-list 0.01% prob would
    # otherwise compute a strongly negative observation (worse than absence),
    # which is wrong — clamp at 0 so listing never reduces strength.
    # Routes to gc + a secondary boost on mountain/hilly (GC contenders
    # are elite climbers).
    mean_before = copy(posterior.mean)
    if signals.oracle_implied_prob > 0.0
        baseline = 1.0 / n_starters
        obs = log(signals.oracle_implied_prob / baseline) / config.odds_normalisation
        # Skip entirely if obs is negative — list-cutoff publication means a
        # below-baseline listing is intra-list ranking, not negative evidence.
        # Observing 0 with finite variance would still shrink the posterior;
        # we want a true no-op for low-prob listings.
        if obs > 0.0
            base_var = oracle_variance(config)
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(SIGNAL_DIMENSION_WEIGHTS.oracle_gc, dsym)
                w == 0.0 && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[:oracle_gc][_DIM_INDEX[dsym]] += 1.0 / v
            end
        end
    elseif signals.oracle_floor_strength != 0.0
        var_f = oracle_variance(config) * config.oracle_floor_variance_multiplier
        posterior = bayesian_update_multidim_dim(posterior, signals.oracle_floor_strength, var_f, :gc)
        precisions[:oracle_gc][_DIM_INDEX[:gc]] += 1.0 / var_f
    end
    shifts[:oracle_gc] = posterior.mean .- mean_before

    # --- Cycling Oracle Points (→ :flat 0.4 + :hilly 0.1, listed only, clamp at 0) ---
    # Jersey-prediction oracles have selection bias: only riders chasing the
    # jersey are listed. A GC contender absent from points oracle is not
    # automatically weak on flat/hilly stages. Apply listed-rider boost only
    # (no absence floor); clamp at 0 so a low-probability listing never
    # reduces strength.
    mean_before = copy(posterior.mean)
    if signals.points_oracle_implied_prob > 0.0
        baseline = 1.0 / n_starters
        obs = log(signals.points_oracle_implied_prob / baseline) / config.odds_normalisation
        if obs > 0.0
            base_var = oracle_variance(config)
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(SIGNAL_DIMENSION_WEIGHTS.oracle_points, dsym)
                w == 0.0 && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[:oracle_points][_DIM_INDEX[dsym]] += 1.0 / v
            end
        end
    end
    shifts[:oracle_points] = posterior.mean .- mean_before

    # --- Cycling Oracle KOM (→ :mountain, listed only, clamp at 0) ---
    mean_before = copy(posterior.mean)
    if signals.kom_oracle_implied_prob > 0.0
        baseline = 1.0 / n_starters
        obs = log(signals.kom_oracle_implied_prob / baseline) / config.odds_normalisation
        if obs > 0.0
            base_var = oracle_variance(config)
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(SIGNAL_DIMENSION_WEIGHTS.oracle_kom, dsym)
                w == 0.0 && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[:oracle_kom][_DIM_INDEX[dsym]] += 1.0 / v
            end
        end
    end
    shifts[:oracle_kom] = posterior.mean .- mean_before

    # Qualitative: still disabled
    shifts[:qualitative] = zeros(D)

    # --- Betting odds (GC outright market) ---
    # Positive evidence (listed at or above baseline): cross-route to gc +
    # secondary mountain/hilly. Listed below baseline (e.g. 1001/1 longshot)
    # falls through to the bounded gc-only floor — avoids the cross-route
    # crushing the rider's actual strong dimensions just because bookmakers
    # tail-priced them. Absent rider: same floor.
    mean_before = copy(posterior.mean)
    if signals.odds_implied_prob > 0.0
        baseline = 1.0 / n_starters
        obs = log(signals.odds_implied_prob / baseline) / config.odds_normalisation
        if obs > 0.0
            base_var = odds_variance(config)
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(SIGNAL_DIMENSION_WEIGHTS.odds_gc, dsym)
                w == 0.0 && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[:odds][_DIM_INDEX[dsym]] += 1.0 / v
            end
        elseif signals.odds_floor_strength != 0.0
            var_f = odds_variance(config) * config.odds_floor_variance_multiplier
            posterior = bayesian_update_multidim_dim(posterior, signals.odds_floor_strength, var_f, :gc)
            precisions[:odds][_DIM_INDEX[:gc]] += 1.0 / var_f
        end
    elseif signals.odds_floor_strength != 0.0
        var_f = odds_variance(config) * config.odds_floor_variance_multiplier
        posterior = bayesian_update_multidim_dim(posterior, signals.odds_floor_strength, var_f, :gc)
        precisions[:odds][_DIM_INDEX[:gc]] += 1.0 / var_f
    end
    shifts[:odds] = posterior.mean .- mean_before

    # --- Bookmaker Points-jersey market (→ :flat 0.4 + :hilly 0.1, listed only) ---
    # Same list-cutoff logic as Cycling Oracle: bookmakers only price plausible
    # jersey contenders. Inclusion is itself a positive endorsement; clamp at 0.
    mean_before = copy(posterior.mean)
    if signals.points_odds_implied_prob > 0.0
        baseline = 1.0 / n_starters
        obs = log(signals.points_odds_implied_prob / baseline) / config.odds_normalisation
        if obs > 0.0
            base_var = odds_variance(config)
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(SIGNAL_DIMENSION_WEIGHTS.odds_points, dsym)
                w == 0.0 && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[:odds_points][_DIM_INDEX[dsym]] += 1.0 / v
            end
        end
    end
    shifts[:odds_points] = posterior.mean .- mean_before

    # --- Bookmaker KOM market (→ :mountain, listed only, clamp at 0) ---
    mean_before = copy(posterior.mean)
    if signals.kom_odds_implied_prob > 0.0
        baseline = 1.0 / n_starters
        obs = log(signals.kom_odds_implied_prob / baseline) / config.odds_normalisation
        if obs > 0.0
            base_var = odds_variance(config)
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(SIGNAL_DIMENSION_WEIGHTS.odds_kom, dsym)
                w == 0.0 && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[:odds_kom][_DIM_INDEX[dsym]] += 1.0 / v
            end
        end
    end
    shifts[:odds_kom] = posterior.mean .- mean_before

    # --- Bookmaker "Rider To Win A Stage" market — class-aware routing ---
    # Stage-winning evidence informs the dimensions where the rider plausibly
    # wins (a sprinter scores stage-win points on flat/hilly, a climber on
    # hilly/mountain). Reuse RACE_HISTORY_CLASS_PROJECTION which already
    # encodes the per-class dimension mix.
    # List-cutoff market: skip update entirely when obs ≤ 0 (true no-op,
    # not posterior-shrinkage-toward-zero).
    mean_before = copy(posterior.mean)
    if signals.stagewin_odds_implied_prob > 0.0
        baseline = 1.0 / n_starters
        obs = log(signals.stagewin_odds_implied_prob / baseline) / config.odds_normalisation
        if obs > 0.0
            base_var = odds_variance(config)
            cls = haskey(RACE_HISTORY_CLASS_PROJECTION, signals.rider_class) ?
                  signals.rider_class : "unclassed"
            weights = RACE_HISTORY_CLASS_PROJECTION[cls]
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(weights, dsym)
                w == 0.0 && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[:odds_stagewin][_DIM_INDEX[dsym]] += 1.0 / v
            end
        end
    end
    shifts[:odds_stagewin] = posterior.mean .- mean_before

    return MultiDimStrengthEstimate(
        copy(posterior.mean),
        copy(posterior.variance),
        shifts,
        precisions,
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
Per-stage and per-classification diagnostic counters from `simulate_stage_race`.

Counts are aggregated across simulations. To convert to probabilities, divide
by `n_sims`. Used by reporting scripts to surface "rider X has a 23% chance of
finishing on the podium of stage 5" or "rider Y has a 67% chance of being in
the GC top 10".

- `stage_finish_counts[stage_idx, rider, k]` for k ∈ 1:3 — per-stage podium counts
- `stage_top10_counts[stage_idx, rider]` — per-stage top-10 finishes
- `final_gc_position_counts[rider, k]` for k ∈ 1:final_gc_top — final GC at position k
- `final_points_position_counts[rider, k]` for k ∈ 1:final_points_top — same, points jersey
- `final_mountains_position_counts[rider, k]` — same, mountains/KOM jersey
- `final_team_position_counts[team_name][k]` — final team classification at position k
"""
struct StageRaceDiagnostics
    n_sims::Int
    stage_finish_counts::Array{Int,3}      # n_stages × n_riders × 3
    stage_top10_counts::Matrix{Int}        # n_stages × n_riders
    final_gc_position_counts::Matrix{Int}  # n_riders × top_k
    final_points_position_counts::Matrix{Int}
    final_mountains_position_counts::Matrix{Int}
    final_team_position_counts::Dict{String,Vector{Int}}  # team_name → positions
end

# Per-stage points-jersey allocation by stage type, calibrated to recent Giro
# regulations: Tipo A (flat) ≫ Tipo B (hilly/medium) > Tipo C (high mountain).
# Flat-stage winners earn ~3× a mountain-stage winner — this is what makes
# versatile sprinters (Pedersen, Milan, Kooij) dominate the points jersey
# rather than GC contenders. Without per-type weighting the simulator awarded
# the jersey by raw count of top-5 finishes, which favoured GC riders who
# place top-5 on hilly/mountain stages.
const STAGE_POINTS_JERSEY_ALLOCATION = (
    flat     = [50.0, 35.0, 25.0, 18.0, 14.0, 12.0, 10.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0],
    hilly    = [25.0, 18.0, 12.0, 8.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0],
    mountain = [15.0, 12.0, 9.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0],
    itt      = [15.0, 10.0, 6.0, 3.0, 2.0, 1.0],
    ttt      = [15.0, 10.0, 6.0, 3.0, 2.0, 1.0],
)

# Approximate intermediate sprint points contributed to the points jersey on
# flat/hilly stages. Real Giro awards 20/12/8/... at each banner, ~2 banners
# per stage. We model a single combined banner discounted to ~50% to allow
# for breakaway riders absorbing some of the points. Crucially, ordering is
# done on `:flat` strength (not stage strength) so a sprinter who skips the
# climb still banks intermediate-sprint points — which is how versatile
# sprinters (Pedersen, Milan, Kooij) build winning points-jersey margins
# over GC riders who don't contest them.
const INTERMEDIATE_SPRINT_POINTS = [20.0, 12.0, 8.0, 6.0, 4.0, 2.0, 1.0]

# Per-event breakaway-noise scales. Each row gives a per-dimension σ that gets
# blended against `stage_dimension_weights` to produce a per-stage scalar
# breakaway-noise standard deviation. The breakaway noise is added to a single
# ranking event and is decoupled from cumulative GC accumulation — captures
# the unmodelled breakaway dynamic where a non-GC rider wins the relevant
# event but doesn't gain GC time.
#
# Without these, dominant climbers win ~96% of mountain stages and sweep the
# points jersey in simulation, versus ~30-50% mountain-stage win rate and
# zero points-jersey wins for GC contenders in reality.
#
# Intermediate sprint banners are not noise-augmented (sprinters reliably
# contest banners; ranked by `:flat` strength + the main stage noise term).
const BREAKAWAY_NOISE_BY_EVENT = (
    stage_finish  = (flat=0.0, hilly=1.0, mountain=1.5, itt=0.0),
    points_jersey = (flat=0.0, hilly=1.5, mountain=2.5, itt=0.0),
)

@inline function _breakaway_sd(event::Symbol, w::NamedTuple)
    scale = getproperty(BREAKAWAY_NOISE_BY_EVENT, event)
    return w.flat * scale.flat + w.hilly * scale.hilly + w.mountain * scale.mountain + w.itt * scale.itt
end

@inline function _score_stage_finish_and_assists!(
    stage_pts::Vector{Float64},
    positions::Vector{Int},
    teams::Vector{String},
    scoring::StageRaceScoringTable,
    stype::Symbol,
    n_riders::Int,
)
    fill!(stage_pts, 0.0)
    for i in 1:n_riders
        stage_pts[i] = Float64(stage_finish_points_for_position(positions[i], scoring))
    end
    assist_depth = length(scoring.stage_assist_points)
    if stype != :itt && stype != :ttt && assist_depth > 0
        for i in 1:n_riders
            if positions[i] <= assist_depth
                for j in 1:n_riders
                    if j != i && teams[j] == teams[i]
                        stage_pts[j] += scoring.stage_assist_points[positions[i]]
                    end
                end
            end
        end
    end
    return nothing
end

@inline function _score_daily_gc_and_assists!(
    stage_pts::Vector{Float64},
    gc_positions::Vector{Int},
    teams::Vector{String},
    scoring::StageRaceScoringTable,
    stype::Symbol,
    n_riders::Int,
)
    for i in 1:n_riders
        stage_pts[i] += daily_gc_points_for_position(gc_positions[i], scoring)
    end
    assist_depth = length(scoring.gc_assist_points)
    if stype != :itt && stype != :ttt && assist_depth > 0
        for i in 1:n_riders
            if gc_positions[i] <= assist_depth
                for j in 1:n_riders
                    if j != i && teams[j] == teams[i]
                        stage_pts[j] += scoring.gc_assist_points[gc_positions[i]]
                    end
                end
            end
        end
    end
    return nothing
end

# Team time trial: the whole squad rides together and shares one result, so the
# outcome is a ranking of TEAMS (by mean TT strength), not individuals. Every
# rider takes their team's placing as their finishing position.
function _assign_team_positions!(
    positions::Vector{Int},
    noisy::Vector{Float64},
    teams::Vector{String},
    n_riders::Int,
)
    team_sum = Dict{String,Float64}()
    team_n = Dict{String,Int}()
    for i in 1:n_riders
        team_sum[teams[i]] = get(team_sum, teams[i], 0.0) + noisy[i]
        team_n[teams[i]] = get(team_n, teams[i], 0) + 1
    end
    ranked = sort(collect(keys(team_sum)), by=t -> team_sum[t] / team_n[t], rev=true)
    team_rank = Dict(t => r for (r, t) in enumerate(ranked))
    for i in 1:n_riders
        positions[i] = team_rank[teams[i]]
    end
    return nothing
end

# Score a team time trial: every rider earns the points for their team's
# placing. Uses the dedicated `ttt_team_points` table, falling back to the
# normal stage-finish table if VG published no TTT-specific scoring.
@inline function _score_ttt_team!(
    stage_pts::Vector{Float64},
    positions::Vector{Int},
    scoring::StageRaceScoringTable,
    n_riders::Int,
)
    fill!(stage_pts, 0.0)
    pts_table = isempty(scoring.ttt_team_points) ? scoring.stage_finish_points :
                scoring.ttt_team_points
    depth = length(pts_table)
    for i in 1:n_riders
        positions[i] <= depth && (stage_pts[i] += pts_table[positions[i]])
    end
    return nothing
end

@inline function _score_points_jersey_stage!(
    points_jersey_total::Vector{Float64},
    noisy::Vector{Float64},
    order::Vector{Int},
    w::NamedTuple,
    stype::Symbol,
    n_riders::Int,
    rng::AbstractRNG,
)
    pts_alloc = get(STAGE_POINTS_JERSEY_ALLOCATION, stype, STAGE_POINTS_JERSEY_ALLOCATION.hilly)
    alloc_depth = length(pts_alloc)
    br_sd = _breakaway_sd(:points_jersey, w)
    if br_sd > 0.0
        pts_noisy = similar(noisy)
        for i in 1:n_riders
            pts_noisy[i] = noisy[i] + br_sd * randn(rng)
        end
        pts_order = sortperm(pts_noisy, rev=true)
    else
        pts_order = order
    end
    for rank in 1:min(alloc_depth, n_riders)
        points_jersey_total[pts_order[rank]] += pts_alloc[rank]
    end
    return nothing
end

@inline function _score_intermediate_sprint!(
    points_jersey_total::Vector{Float64},
    stage_strengths::Dict{Symbol,Vector{Float64}},
    fallback_strengths::Vector{Float64},
    uncertainties::Vector{Float64},
    alpha::Float64,
    beta::Float64,
    rider_noise::Vector{Float64},
    stage_noise::Vector{Float64},
    stype::Symbol,
    n_riders::Int,
)
    if stype != :flat && stype != :hilly
        return nothing
    end
    flat_str = get(stage_strengths, :flat, fallback_strengths)
    int_noisy = Vector{Float64}(undef, n_riders)
    for i in 1:n_riders
        int_noisy[i] = flat_str[i] +
            uncertainties[i] * (alpha * rider_noise[i] + beta * stage_noise[i])
    end
    int_order = sortperm(int_noisy, rev=true)
    for rank in 1:min(length(INTERMEDIATE_SPRINT_POINTS), n_riders)
        points_jersey_total[int_order[rank]] += 0.5 * INTERMEDIATE_SPRINT_POINTS[rank]
    end
    return nothing
end

"""
    stage_dimension_weights(stage::StageProfile) -> NamedTuple

Continuous weighting across `(flat, hilly, mountain, itt)` for a single stage,
derived primarily from PCS ProfileScore + summit-finish flag. Used by
`simulate_stage_race` to blend per-dimension rider strengths.

Replaces a discrete `stage_type` lookup that incorrectly treated all "hilly"
stages identically — a Giro Tipo B with 680m vert and PS=14 (essentially a
sprint stage) drew the same per-dimension projection as a hard summit-finish
hilly with PS=152.

Anchor points (linear interpolation between), tuned against the empirical PS
distribution seen on a real grand tour where PCS-flat stages score PS≈7-28,
hilly score PS≈14-152, and mountain score PS≈89-396:
- PS ≤ 20:   `flat = 1.0`
- PS = 90:   `hilly = 1.0`
- PS ≥ 250:  `mountain = 1.0`

Summit finish reallocates 30% of `hilly` weight to `mountain` (a hilly stage
ending uphill rewards climbers more than a hilly stage ending in a town
sprint). ITT and TTT remain pure (TTT is treated as ITT for strength).

Falls back to discrete `stage_type` when `profile_score ≤ 0` (synthetic test
stages or unparsed PCS pages).
"""
function stage_dimension_weights(stage::StageProfile)
    if stage.stage_type == :itt || stage.stage_type == :ttt
        return (flat=0.0, hilly=0.0, mountain=0.0, itt=1.0)
    end
    if stage.profile_score <= 0
        return stage.stage_type == :flat     ? (flat=1.0, hilly=0.0, mountain=0.0, itt=0.0) :
               stage.stage_type == :mountain ? (flat=0.0, hilly=0.0, mountain=1.0, itt=0.0) :
                                               (flat=0.0, hilly=1.0, mountain=0.0, itt=0.0)
    end
    ps = Float64(stage.profile_score)
    # Flat-to-hilly ramp starts at PS 40 (not 20): a rolling sprint stage with a
    # modest ProfileScore (~50-60) is still won by sprinters in a bunch finish,
    # so it should stay majority-flat rather than tipping puncheurs/GC riders
    # onto the podium. PS 58 → ~64% flat / 36% hilly.
    if ps <= 40.0
        f, h, m = 1.0, 0.0, 0.0
    elseif ps <= 90.0
        h = (ps - 40.0) / 50.0
        f = 1.0 - h
        m = 0.0
    elseif ps <= 250.0
        m = (ps - 90.0) / 160.0
        h = 1.0 - m
        f = 0.0
    else
        f, h, m = 0.0, 0.0, 1.0
    end
    if stage.is_summit_finish && h > 0.0
        shift = 0.3 * h
        h -= shift
        m += shift
    end
    return (flat=f, hilly=h, mountain=m, itt=0.0)
end

"""
    simulate_stage_race(stages, stage_strengths, uncertainties, teams, scoring;
                        n_sims=500, cross_stage_alpha=0.7, gc_strengths=Float64[],
                        rng) -> (Matrix{Float64}, StageRaceDiagnostics)

Simulate a full grand tour stage by stage. Always returns a tuple of
`(vg_points, diagnostics)`:
- `vg_points` — total VG points per rider per simulation draw (`n_riders × n_sims`)
- `diagnostics` — per-stage podium/top-10 counts and final-classification position counts

Each draw has persistent rider noise (correlated across stages via
`cross_stage_alpha`) and independent per-stage noise. For each stage, riders
are ranked by noisy strength, scored for stage finish, assists, and daily GC
classification. After all stages, final classification bonuses are awarded.

Per-event scoring (stage finish + assists, daily GC + assists, points jersey,
intermediate sprint, KOM) is delegated to `_score_*` helpers above. Breakaway
noise scales live in `BREAKAWAY_NOISE_BY_EVENT`.
"""
function simulate_stage_race(
    stages::Vector{StageProfile},
    stage_strengths::Dict{Symbol,Vector{Float64}},
    uncertainties::Vector{Float64},
    teams::Vector{String},
    scoring::StageRaceScoringTable;
    n_sims::Int=500,
    cross_stage_alpha::Float64=0.7,
    gc_strengths::Vector{Float64}=Float64[],
    rng::AbstractRNG=Random.default_rng(),
)
    n_riders = length(uncertainties)
    n_stages = length(stages)
    alpha = cross_stage_alpha
    beta = sqrt(1.0 - alpha^2)  # ensures total noise variance = uncertainty²

    # If gc_strengths not supplied, fall back to per-rider mean across stage types.
    # Production callers always supply gc_strengths via `compute_stage_strengths`;
    # this fallback keeps synthetic test inputs working.
    if isempty(gc_strengths)
        keys_present = collect(keys(stage_strengths))
        gc_strengths = [
            mean(stage_strengths[k][i] for k in keys_present) for i in 1:n_riders
        ]
    end

    sim_vg_points = zeros(Float64, n_riders, n_sims)

    # Diagnostic accumulators (always populated)
    diag_stage_finish = zeros(Int, n_stages, n_riders, 3)
    diag_stage_top10 = zeros(Int, n_stages, n_riders)
    diag_gc_top = length(scoring.final_gc_points)
    diag_points_top = length(scoring.final_points_class)
    diag_mountains_top = length(scoring.final_mountains_class)
    diag_team_top = length(scoring.final_team_class)
    diag_gc_pos = zeros(Int, n_riders, diag_gc_top)
    diag_points_pos = zeros(Int, n_riders, diag_points_top)
    diag_mountains_pos = zeros(Int, n_riders, diag_mountains_top)
    diag_team_pos = Dict{String,Vector{Int}}()
    for t in unique(teams)
        diag_team_pos[t] = zeros(Int, diag_team_top)
    end

    # Pre-allocate working arrays
    noisy = Vector{Float64}(undef, n_riders)
    strengths_blend = Vector{Float64}(undef, n_riders)
    positions = Vector{Int}(undef, n_riders)
    rider_noise = Vector{Float64}(undef, n_riders)
    stage_noise = Vector{Float64}(undef, n_riders)
    cumulative_gc_score = Vector{Float64}(undef, n_riders)
    gc_positions = Vector{Int}(undef, n_riders)
    stage_pts = Vector{Float64}(undef, n_riders)
    points_jersey_total = Vector{Float64}(undef, n_riders)
    mountain_top5_counts = Vector{Int}(undef, n_riders)

    for sim in 1:n_sims
        for i in 1:n_riders
            rider_noise[i] = randn(rng)
        end

        fill!(cumulative_gc_score, 0.0)
        fill!(points_jersey_total, 0.0)
        fill!(mountain_top5_counts, 0)
        rider_total_pts = zeros(Float64, n_riders)

        for (stage_idx, stage) in enumerate(stages)
            stype = stage.stage_type
            # Blend per-dim strengths into a per-stage strength vector using
            # PCS ProfileScore-derived weights.
            w = stage_dimension_weights(stage)
            flat_s     = get(stage_strengths, :flat, gc_strengths)
            hilly_s    = get(stage_strengths, :hilly, gc_strengths)
            mountain_s = get(stage_strengths, :mountain, gc_strengths)
            itt_s      = get(stage_strengths, :itt, gc_strengths)
            for i in 1:n_riders
                strengths_blend[i] = w.flat * flat_s[i] + w.hilly * hilly_s[i] +
                    w.mountain * mountain_s[i] + w.itt * itt_s[i]
            end

            # Stage-finish noisy strengths + GC accumulation. The same noise
            # term scales both stage finish and cumulative GC, so a rider who
            # has a "good day" finishes higher and gains GC time.
            for i in 1:n_riders
                stage_noise[i] = randn(rng)
                noise_term = uncertainties[i] * (alpha * rider_noise[i] + beta * stage_noise[i])
                noisy[i] = strengths_blend[i] + noise_term
                cumulative_gc_score[i] += gc_strengths[i] + noise_term
            end

            # Stage-finish breakaway noise (decoupled from GC).
            br_finish_sd = _breakaway_sd(:stage_finish, w)
            if br_finish_sd > 0.0
                for i in 1:n_riders
                    noisy[i] += br_finish_sd * randn(rng)
                end
            end

            # Rank by noisy stage strength → positions, record podium/top-10.
            # A team time trial is scored as a ranking of teams: every rider
            # shares their squad's placing.
            order = sortperm(noisy, rev=true)
            if stype == :ttt
                _assign_team_positions!(positions, noisy, teams, n_riders)
            else
                for (pos, rider_idx) in enumerate(order)
                    positions[rider_idx] = pos
                end
            end
            for i in 1:n_riders
                p = positions[i]
                if p <= 3
                    diag_stage_finish[stage_idx, i, p] += 1
                end
                if p <= 10
                    diag_stage_top10[stage_idx, i] += 1
                end
            end

            if stype == :ttt
                _score_ttt_team!(stage_pts, positions, scoring, n_riders)
            else
                _score_stage_finish_and_assists!(stage_pts, positions, teams, scoring, stype, n_riders)
            end

            # Cumulative GC ranking after this stage.
            gc_order = sortperm(cumulative_gc_score, rev=true)
            for (gc_pos, rider_idx) in enumerate(gc_order)
                gc_positions[rider_idx] = gc_pos
            end

            _score_daily_gc_and_assists!(stage_pts, gc_positions, teams, scoring, stype, n_riders)
            _score_points_jersey_stage!(points_jersey_total, noisy, order, w, stype, n_riders, rng)

            # KOM proxy: count mountain top-5 finishes per rider.
            for i in 1:n_riders
                if positions[i] <= 5 && stype == :mountain
                    mountain_top5_counts[i] += 1
                end
            end

            _score_intermediate_sprint!(points_jersey_total, stage_strengths, strengths_blend,
                uncertainties, alpha, beta, rider_noise, stage_noise, stype, n_riders)

            for i in 1:n_riders
                rider_total_pts[i] += stage_pts[i]
            end
        end

        # --- Final classification bonuses ---

        # Final GC
        for i in 1:n_riders
            rider_total_pts[i] += final_gc_points_for_position(gc_positions[i], scoring)
            if gc_positions[i] <= diag_gc_top
                diag_gc_pos[i, gc_positions[i]] += 1
            end
        end

        # Final points classification (Tipo A/B/C-weighted points-jersey total)
        sprint_order = sortperm(points_jersey_total, rev=true)
        for rank in 1:min(length(scoring.final_points_class), n_riders)
            rider_idx = sprint_order[rank]
            if points_jersey_total[rider_idx] > 0
                rider_total_pts[rider_idx] += scoring.final_points_class[rank]
                if rank <= diag_points_top
                    diag_points_pos[rider_idx, rank] += 1
                end
            end
        end

        # Final mountains classification (mountain top-5 count proxy)
        kom_order = sortperm(mountain_top5_counts, rev=true)
        for rank in 1:min(length(scoring.final_mountains_class), n_riders)
            rider_idx = kom_order[rank]
            if mountain_top5_counts[rider_idx] > 0
                rider_total_pts[rider_idx] += scoring.final_mountains_class[rank]
                if rank <= diag_mountains_top
                    diag_mountains_pos[rider_idx, rank] += 1
                end
            end
        end

        # Final team classification (sum of top-3 cumulative GC scores per team)
        team_set = unique(teams)
        team_cum_scores = Dict{String,Float64}()
        for t in team_set
            team_idx = findall(==(t), teams)
            sorted_cum = sort(cumulative_gc_score[team_idx], rev=true)
            team_cum_scores[t] = sum(sorted_cum[1:min(3, length(sorted_cum))])
        end
        team_ranking = sort(collect(team_cum_scores), by=x -> x.second, rev=true)
        for rank in 1:min(length(scoring.final_team_class), length(team_ranking))
            t = team_ranking[rank].first
            for i in 1:n_riders
                if teams[i] == t
                    rider_total_pts[i] += scoring.final_team_class[rank]
                end
            end
            if rank <= diag_team_top
                diag_team_pos[t][rank] += 1
            end
        end

        for i in 1:n_riders
            sim_vg_points[i, sim] = rider_total_pts[i]
        end
    end

    diagnostics = StageRaceDiagnostics(
        n_sims,
        diag_stage_finish,
        diag_stage_top10,
        diag_gc_pos,
        diag_points_pos,
        diag_mountains_pos,
        diag_team_pos,
    )
    return sim_vg_points, diagnostics
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
# Stage-race per-stage strength projection
# ---------------------------------------------------------------------------

"""
    compute_stage_strengths(rider_df) -> Dict{Symbol, Vector{Float64}}

Project the multi-dimensional strength posterior onto per-stage-type strength
vectors used by `simulate_stage_race`. Each stage type maps directly to its
dimension column (`:flat → strength_flat`, etc.); `:ttt` reuses `:itt`.

`rider_df` must already carry `strength_flat`, `strength_hilly`,
`strength_mountain`, `strength_itt` columns produced by the multidim path of
`estimate_strengths(... ; race_type=:stage)`.
"""
function compute_stage_strengths(rider_df::DataFrame)
    result = Dict{Symbol,Vector{Float64}}()
    for dsym in (:flat, :hilly, :mountain, :itt)
        result[dsym] = Float64.(rider_df[!, Symbol("strength_$dsym")])
    end
    result[:ttt] = copy(result[:itt])
    return result
end


# ---------------------------------------------------------------------------
# High-level prediction pipeline
# ---------------------------------------------------------------------------

"""
    AssembledSignals

All per-rider signal data prepared from raw input DataFrames, ready for
either the scalar (`:oneday`) or multi-dimensional (`:stage`) per-rider
update loop. Built once by `_assemble_signals` so the two pipelines don't
duplicate ~250 lines of identical assembly.

Fields that are pipeline-specific (e.g. `classes` for stage; `seasons_keys`
for one-day reporting) are computed unconditionally — the cost is trivial
and avoids tangled kwargs.
"""
struct AssembledSignals
    n_riders::Int
    n_starters::Int
    current_year::Int

    vg_z::Vector{Float64}
    effective_vg_variance::Float64

    has_pcs::Vector{Bool}
    classes::Vector{String}

    currency_factors::Dict{String,Float64}
    rider_currency::Vector{Float64}
    seasons_keys::Set{String}

    history_lookup::Dict{String,Vector{Tuple{Float64,Int,Float64}}}
    vg_history_lookup::Dict{String,Vector{Tuple{Float64,Int}}}
    odds_lookup::Dict{String,Float64}
    oracle_lookup::Dict{String,Float64}
    points_oracle_lookup::Dict{String,Float64}
    kom_oracle_lookup::Dict{String,Float64}
    points_odds_lookup::Dict{String,Float64}
    kom_odds_lookup::Dict{String,Float64}
    stagewin_odds_lookup::Dict{String,Float64}

    odds_floor::Float64
    oracle_floor::Float64
    points_oracle_floor::Float64
    kom_oracle_floor::Float64

    race_has_market::Bool
end

"""
    _assemble_signals(rider_df; ...) -> AssembledSignals

Build all per-rider signal data shared by the scalar and multidim
estimators: VG z-score with season-adaptive variance, current year,
classifications, PCS currency factors, market lookups (odds, oracle GC,
points oracle, KOM oracle) with absence floors, and history lookups.

`rider_df` must carry `:riderkey` and `:points` columns (the latter is
read unconditionally for the VG z-score). PCS specialty columns
(`:sprint, :oneday, :climber, :tt, :gc`) and `:classraw`/`:class` are
read when present.

Mutates `rider_df` only via `rematch_riderkeys!` on the market-source
DataFrames (preserved from the original behaviour). Per-source PCS
specialty z-scoring is left to each pipeline because the scalar one-day
path uses a different mechanism (raw decay-weighted points substitution)
than the multidim path (currency-factor multiplier on career specialty).
"""
function _assemble_signals(
    rider_df::DataFrame;
    race_history_df::Union{DataFrame,Nothing}=nothing,
    odds_df::Union{DataFrame,Nothing}=nothing,
    oracle_df::Union{DataFrame,Nothing}=nothing,
    points_oracle_df::Union{DataFrame,Nothing}=nothing,
    kom_oracle_df::Union{DataFrame,Nothing}=nothing,
    points_odds_df::Union{DataFrame,Nothing}=nothing,
    kom_odds_df::Union{DataFrame,Nothing}=nothing,
    stagewin_odds_df::Union{DataFrame,Nothing}=nothing,
    vg_history_df::Union{DataFrame,Nothing}=nothing,
    seasons_df::Union{DataFrame,Nothing}=nothing,
    bayesian_config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing}=nothing,
    race_date::Union{Date,Nothing}=nothing,
)
    df = rider_df
    n_riders = nrow(df)
    n_starters = n_riders

    current_year = if race_date !== nothing
        Dates.year(race_date)
    elseif race_year !== nothing
        race_year
    else
        Dates.year(Dates.today())
    end

    # --- VG z-score + season-adaptive variance ---
    vg_pts = Float64.(coalesce.(df[!, :points], 0.0))
    vg_mean = mean(vg_pts)
    vg_std = std(vg_pts)
    vg_z = vg_std > 0 ? (vg_pts .- vg_mean) ./ vg_std : zeros(n_riders)
    frac_nonzero = count(vg_pts .> 0) / max(length(vg_pts), 1)
    season_scale = 1.0 + bayesian_config.vg_season_penalty * (1.0 - frac_nonzero)
    effective_vg_variance = vg_variance(bayesian_config) * season_scale
    @info "Season-adaptive VG variance: $(round(effective_vg_variance, digits=2)) " *
          "($(round(100 * frac_nonzero, digits=0))% with points, scale=$(round(season_scale, digits=2)))"

    # --- has_pcs ---
    pcs_specialty_cols = (:sprint, :oneday, :climber, :tt, :gc)
    has_pcs = if :has_pcs_data in propertynames(df)
        Bool.(df.has_pcs_data)
    else
        avail = intersect(propertynames(df), collect(pcs_specialty_cols))
        [any(df[i, c] != 0 for c in avail) for i in 1:n_riders]
    end

    # --- Classifications (used by multidim only; harmless to always compute) ---
    class_col = :classraw in propertynames(df) ? :classraw :
                :class in propertynames(df) ? :class : nothing
    classes = if class_col !== nothing
        [lowercase(string(df[i, class_col])) for i in 1:n_riders]
    else
        fill("unclassed", n_riders)
    end

    # --- Currency factors: decay-weighted recent / career-average PCS points ---
    currency_factors = Dict{String,Float64}()
    seasons_keys = Set{String}()
    if seasons_df !== nothing &&
       :riderkey in propertynames(seasons_df) &&
       :pcs_points in propertynames(seasons_df) &&
       :year in propertynames(seasons_df)
        for g in groupby(seasons_df, :riderkey)
            key = first(g.riderkey)
            push!(seasons_keys, key)
            pts = Float64.(coalesce.(g.pcs_points, 0.0))
            yrs = Int.(coalesce.(g.year, current_year))
            length(pts) == 0 && continue
            weights = exp.(-bayesian_config.pcs_season_decay .* (current_year .- yrs))
            decay_avg = sum(weights .* pts) / sum(weights)
            career_avg = mean(pts)
            currency_factors[key] = career_avg > 0 ? decay_avg / career_avg : 1.0
        end
    end
    rider_currency = Float64[get(currency_factors, df.riderkey[i], 1.0) for i in 1:n_riders]

    # --- Market-source lookup helper (closure captures df, n_riders, etc.) ---
    function _market_lookup(src_df, prob_col::Symbol, label::String; apply_floor::Bool=true)
        lookup = Dict{String,Float64}()
        floor_strength = 0.0
        if src_df === nothing ||
           !(:riderkey in propertynames(src_df)) ||
           !(prob_col in propertynames(src_df))
            return lookup, floor_strength
        end
        :rider in propertynames(src_df) && rematch_riderkeys!(src_df, df)
        for row in eachrow(src_df)
            lookup[row.riderkey] = Float64(row[prob_col])
        end
        if apply_floor && !isempty(lookup)
            listed_prob = sum(values(lookup))
            n_listed = length(intersect(keys(lookup), Set(df.riderkey)))
            n_absent = n_riders - n_listed
            if n_absent > 0
                residual_prob = 1.0 - listed_prob
                floor_prob = if residual_prob > 0.001
                    residual_prob / n_absent
                else
                    minimum(values(lookup)) * 0.5
                end
                baseline_prob = 1.0 / n_starters
                floor_strength =
                    log(floor_prob / baseline_prob) / bayesian_config.odds_normalisation
            end
            @info "$label: $n_listed listed, $n_absent with floor (strength=$(round(floor_strength, digits=2)))"
        end
        return lookup, floor_strength
    end

    # --- Odds (overround-corrected; floor gated by floor_signals) ---
    odds_lookup = Dict{String,Float64}()
    odds_floor = 0.0
    if odds_df !== nothing &&
       :riderkey in propertynames(odds_df) &&
       :odds in propertynames(odds_df)
        :rider in propertynames(odds_df) && rematch_riderkeys!(odds_df, df)
        raw_probs = 1.0 ./ Float64.(odds_df.odds)
        overround = sum(raw_probs)
        for (i, row) in enumerate(eachrow(odds_df))
            odds_lookup[row.riderkey] = raw_probs[i] / overround
        end
        if :odds in bayesian_config.floor_signals && !isempty(odds_lookup)
            listed_prob = sum(values(odds_lookup))
            n_listed = length(intersect(keys(odds_lookup), Set(df.riderkey)))
            n_absent = n_riders - n_listed
            if n_absent > 0
                residual_prob = 1.0 - listed_prob
                floor_prob = if residual_prob > 0.001
                    residual_prob / n_absent
                else
                    minimum(values(odds_lookup)) * 0.5
                end
                baseline_prob = 1.0 / n_starters
                odds_floor =
                    log(floor_prob / baseline_prob) / bayesian_config.odds_normalisation
            end
            @info "Odds floor: $n_listed priced, $n_absent with floor (strength=$(round(odds_floor, digits=2)))"
        end
    end

    # --- Oracle GC: always build lookup; gate floor on `:oracle in floor_signals`.
    # The previous multidim path skipped building the lookup entirely when
    # `:oracle` was absent from `floor_signals`, dropping listed oracle riders
    # alongside the floor. Aligning with the scalar one-day behaviour.
    apply_oracle_floor = :oracle in bayesian_config.floor_signals
    oracle_lookup, oracle_floor =
        _market_lookup(oracle_df, :win_prob, "Oracle GC floor"; apply_floor=apply_oracle_floor)

    # --- Points / KOM oracles: always build lookup, always apply floor.
    # Listed-rider absence is itself informative for jersey predictions.
    points_oracle_lookup, points_oracle_floor =
        _market_lookup(points_oracle_df, :win_prob, "Oracle points floor")
    kom_oracle_lookup, kom_oracle_floor =
        _market_lookup(kom_oracle_df, :win_prob, "Oracle KOM floor")

    # --- Bookmaker secondary markets (Points / KOM / stage-win).
    # Overround-corrected probabilities; no floor for absent riders (jersey
    # absence is uninformative — see oracle Points / KOM blocks).
    function _bookmaker_lookup(odds_input_df, label)
        lookup = Dict{String,Float64}()
        odds_input_df === nothing && return lookup
        :riderkey in propertynames(odds_input_df) || return lookup
        :odds in propertynames(odds_input_df) || return lookup
        :rider in propertynames(odds_input_df) && rematch_riderkeys!(odds_input_df, df)
        raw_probs = 1.0 ./ Float64.(odds_input_df.odds)
        overround = sum(raw_probs)
        for (i, row) in enumerate(eachrow(odds_input_df))
            lookup[row.riderkey] = raw_probs[i] / overround
        end
        n_listed = length(intersect(keys(lookup), Set(df.riderkey)))
        @info "$label: $n_listed listed (no floor for absent riders)"
        return lookup
    end
    points_odds_lookup = _bookmaker_lookup(points_odds_df, "Odds points")
    kom_odds_lookup = _bookmaker_lookup(kom_odds_df, "Odds KOM")
    stagewin_odds_lookup = _bookmaker_lookup(stagewin_odds_df, "Odds stage-win")

    # --- Race history lookup ---
    history_lookup = Dict{String,Vector{Tuple{Float64,Int,Float64}}}()
    if race_history_df !== nothing &&
       :riderkey in propertynames(race_history_df) &&
       :position in propertynames(race_history_df) &&
       :year in propertynames(race_history_df)
        has_penalty = :variance_penalty in propertynames(race_history_df)
        for row in eachrow(race_history_df)
            key = row.riderkey
            pos = row.position
            yr = row.year
            if !ismissing(pos) && !ismissing(yr) && pos > 0 && pos < 900
                years_ago = current_year - yr
                strength = position_to_strength(pos, n_starters)
                penalty = has_penalty ? Float64(coalesce(row.variance_penalty, 0.0)) : 0.0
                if !haskey(history_lookup, key)
                    history_lookup[key] = Tuple{Float64,Int,Float64}[]
                end
                push!(history_lookup[key], (strength, years_ago, penalty))
            end
        end
    end

    # --- VG race history lookup (z-scored within year) ---
    vg_history_lookup = Dict{String,Vector{Tuple{Float64,Int}}}()
    if vg_history_df !== nothing &&
       :riderkey in propertynames(vg_history_df) &&
       :score in propertynames(vg_history_df) &&
       :year in propertynames(vg_history_df)
        for g in groupby(vg_history_df, :year)
            scores = Float64.(coalesce.(g.score, 0.0))
            μ = mean(scores)
            σ = std(scores)
            for (i, row) in enumerate(eachrow(g))
                z = σ > 0 ? (scores[i] - μ) / σ : 0.0
                key = row.riderkey
                yr = row.year
                if !ismissing(yr)
                    years_ago = current_year - yr
                    if !haskey(vg_history_lookup, key)
                        vg_history_lookup[key] = Tuple{Float64,Int}[]
                    end
                    push!(vg_history_lookup[key], (z, years_ago))
                end
            end
        end
    end

    return AssembledSignals(
        n_riders, n_starters, current_year,
        vg_z, effective_vg_variance,
        has_pcs, classes,
        currency_factors, rider_currency, seasons_keys,
        history_lookup, vg_history_lookup,
        odds_lookup, oracle_lookup, points_oracle_lookup, kom_oracle_lookup,
        points_odds_lookup, kom_odds_lookup, stagewin_odds_lookup,
        odds_floor, oracle_floor, points_oracle_floor, kom_oracle_floor,
        !isempty(odds_lookup),
    )
end

"""
    _estimate_strengths_multidim(rider_df; ...) -> DataFrame

Multi-dimensional strength estimation for stage races. Routes each signal
to the dimensions in `STRENGTH_DIMENSIONS` according to `SIGNAL_DIMENSION_WEIGHTS`,
producing per-dimension strength and uncertainty columns.

`strength` and `uncertainty` are aliased to the `:gc` dimension for back-compat
with downstream display code that expects scalar columns.
"""
function _estimate_strengths_multidim(
    rider_df::DataFrame;
    race_history_df::Union{DataFrame,Nothing}=nothing,
    odds_df::Union{DataFrame,Nothing}=nothing,
    oracle_df::Union{DataFrame,Nothing}=nothing,
    points_oracle_df::Union{DataFrame,Nothing}=nothing,
    kom_oracle_df::Union{DataFrame,Nothing}=nothing,
    points_odds_df::Union{DataFrame,Nothing}=nothing,
    kom_odds_df::Union{DataFrame,Nothing}=nothing,
    stagewin_odds_df::Union{DataFrame,Nothing}=nothing,
    vg_history_df::Union{DataFrame,Nothing}=nothing,
    seasons_df::Union{DataFrame,Nothing}=nothing,
    bayesian_config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing}=nothing,
    race_date::Union{Date,Nothing}=nothing,
    domestique_discount::Float64=0.0,
)
    df = copy(rider_df)
    sig = _assemble_signals(
        df;
        race_history_df=race_history_df,
        odds_df=odds_df,
        oracle_df=oracle_df,
        points_oracle_df=points_oracle_df,
        kom_oracle_df=kom_oracle_df,
        points_odds_df=points_odds_df,
        kom_odds_df=kom_odds_df,
        stagewin_odds_df=stagewin_odds_df,
        vg_history_df=vg_history_df,
        seasons_df=seasons_df,
        bayesian_config=bayesian_config,
        race_year=race_year,
        race_date=race_date,
    )
    n_riders = sig.n_riders
    n_starters = sig.n_starters

    n_currency = count(!=(1.0), sig.rider_currency)
    if n_currency > 0
        @info "Applied PCS currency factor to $n_currency riders " *
              "(median=$(round(median(sig.rider_currency); digits=2)), " *
              "min=$(round(minimum(sig.rider_currency); digits=2)))"
    end

    # --- Per-source PCS specialty z-scores (log1p, then z-score across field) ---
    # Each rider's career specialty is scaled by their currency factor before
    # log1p+z-scoring, so a rider in decline ranks lower than their career
    # numbers alone would suggest.
    pcs_cols = (:sprint, :oneday, :climber, :tt, :gc)
    pcs_z = Dict{Symbol,Vector{Float64}}()
    for col in pcs_cols
        if col in propertynames(df)
            raw = Float64.(coalesce.(df[!, col], 0.0)) .* sig.rider_currency
            logged = log1p.(max.(raw, 0.0))
            μ = mean(logged)
            σ = std(logged)
            pcs_z[col] = σ > 0 ? (logged .- μ) ./ σ : zeros(n_riders)
        else
            pcs_z[col] = zeros(n_riders)
        end
    end

    D = length(STRENGTH_DIMENSIONS)

    # --- Per-rider estimation ---
    means_per_dim = [Vector{Float64}(undef, n_riders) for _ in 1:D]
    vars_per_dim = [Vector{Float64}(undef, n_riders) for _ in 1:D]
    shifts_storage = Dict{Symbol,Vector{Vector{Float64}}}()
    precisions_storage = Dict{Symbol,Vector{Vector{Float64}}}()
    for sig_key in (:pcs, :vg, :form, :history, :vg_history, :oracle_gc, :oracle_points, :oracle_kom, :qualitative, :odds, :odds_points, :odds_kom, :odds_stagewin)
        shifts_storage[sig_key] = Vector{Vector{Float64}}(undef, n_riders)
        precisions_storage[sig_key] = Vector{Vector{Float64}}(undef, n_riders)
    end

    for i in 1:n_riders
        key = df.riderkey[i]

        hist = get(sig.history_lookup, key, Tuple{Float64,Int,Float64}[])
        hist_strengths = Float64[h[1] for h in hist]
        hist_years = Int[h[2] for h in hist]
        hist_penalties = Float64[h[3] for h in hist]

        vg_hist = get(sig.vg_history_lookup, key, Tuple{Float64,Int}[])
        vg_hist_strengths = Float64[h[1] for h in vg_hist]
        vg_hist_years = Int[h[2] for h in vg_hist]

        odds_prob = get(sig.odds_lookup, key, 0.0)
        oracle_prob = get(sig.oracle_lookup, key, 0.0)
        points_prob = get(sig.points_oracle_lookup, key, 0.0)
        kom_prob = get(sig.kom_oracle_lookup, key, 0.0)
        points_odds_prob = get(sig.points_odds_lookup, key, 0.0)
        kom_odds_prob = get(sig.kom_odds_lookup, key, 0.0)
        stagewin_odds_prob = get(sig.stagewin_odds_lookup, key, 0.0)

        # Always pass the race-level odds floor strength: the estimator's
        # listed-below-baseline branch falls through to the floor, which needs
        # access regardless of whether the rider is listed (a longshot listing
        # at 1001/1 should fall to the floor, not produce a sharp negative obs).
        # For listed-above-baseline riders, the positive-evidence branch fires
        # first and the floor is unused.
        odds_floor = sig.odds_floor
        oracle_floor = haskey(sig.oracle_lookup, key) ? 0.0 : sig.oracle_floor
        points_floor = haskey(sig.points_oracle_lookup, key) ? 0.0 : sig.points_oracle_floor
        kom_floor = haskey(sig.kom_oracle_lookup, key) ? 0.0 : sig.kom_oracle_floor

        signals = RiderSignalData(
            has_pcs=sig.has_pcs[i],
            pcs_sprint_z=pcs_z[:sprint][i],
            pcs_oneday_z=pcs_z[:oneday][i],
            pcs_climber_z=pcs_z[:climber][i],
            pcs_tt_z=pcs_z[:tt][i],
            pcs_gc_z=pcs_z[:gc][i],
            rider_class=sig.classes[i],
            race_history=hist_strengths,
            race_history_years_ago=hist_years,
            race_history_variance_penalties=hist_penalties,
            vg_points=sig.vg_z[i],
            vg_race_history=vg_hist_strengths,
            vg_race_history_years_ago=vg_hist_years,
            odds_implied_prob=odds_prob,
            oracle_implied_prob=oracle_prob,
            points_oracle_implied_prob=points_prob,
            kom_oracle_implied_prob=kom_prob,
            points_odds_implied_prob=points_odds_prob,
            kom_odds_implied_prob=kom_odds_prob,
            stagewin_odds_implied_prob=stagewin_odds_prob,
            odds_floor_strength=odds_floor,
            oracle_floor_strength=oracle_floor,
            points_oracle_floor_strength=points_floor,
            kom_oracle_floor_strength=kom_floor,
        )

        est = estimate_rider_strength_multidim(
            signals;
            n_starters=n_starters,
            config=bayesian_config,
            effective_vg_variance=sig.effective_vg_variance,
            race_has_market=sig.race_has_market,
        )

        for d in 1:D
            means_per_dim[d][i] = est.mean[d]
            vars_per_dim[d][i] = est.variance[d]
        end
        for sig_key in keys(shifts_storage)
            shifts_storage[sig_key][i] = get(est.shifts, sig_key, zeros(D))
            precisions_storage[sig_key][i] = get(est.precisions, sig_key, zeros(D))
        end
    end

    # --- Domestique discount: per-dimension based on per-dimension gap ---
    # A rider's domestique role differs by stage type. Ganna is INEOS's TT leader
    # but a GC domestique. The penalty should reflect "are you the team's pick
    # for this dimension or supporting someone stronger here", computed dim-wise.
    domestique_penalties = zeros(n_riders)
    if domestique_discount > 0
        teams_vec = String.(df.team)
        for team in unique(teams_vec)
            team_idx = findall(teams_vec .== team)
            length(team_idx) <= 1 && continue
            for d in 1:D
                leader_d = maximum(means_per_dim[d][team_idx])
                for i in team_idx
                    gap_d = leader_d - means_per_dim[d][i]
                    penalty_d = domestique_discount * max(gap_d, 0.0)
                    means_per_dim[d][i] -= penalty_d
                    if d == _DIM_INDEX[:gc]
                        domestique_penalties[i] = penalty_d
                    end
                end
            end
        end
        n_penalised = count(domestique_penalties .> 0)
        @info "Applied domestique discount ($domestique_discount) to $n_penalised riders (per-dim gaps)"
    end

    # --- Add per-dim columns ---
    for (d, dsym) in enumerate(STRENGTH_DIMENSIONS)
        df[!, Symbol("strength_$dsym")] = round.(means_per_dim[d], digits=3)
        df[!, Symbol("uncertainty_$dsym")] = round.(sqrt.(vars_per_dim[d]), digits=3)
    end

    # --- Back-compat: scalar :strength and :uncertainty alias :gc dim ---
    gc_idx = _DIM_INDEX[:gc]
    df[!, :strength] = round.(means_per_dim[gc_idx], digits=3)
    df[!, :uncertainty] = round.(sqrt.(vars_per_dim[gc_idx]), digits=3)

    # --- Signal availability flags ---
    df[!, :has_pcs] = sig.has_pcs
    df[!, :has_race_history] = [haskey(sig.history_lookup, df.riderkey[i]) for i in 1:n_riders]
    df[!, :has_vg_history] = [haskey(sig.vg_history_lookup, df.riderkey[i]) for i in 1:n_riders]
    df[!, :has_odds] = [haskey(sig.odds_lookup, df.riderkey[i]) for i in 1:n_riders]
    df[!, :has_oracle] = [haskey(sig.oracle_lookup, df.riderkey[i]) for i in 1:n_riders]
    df[!, :has_points_oracle] = [haskey(sig.points_oracle_lookup, df.riderkey[i]) for i in 1:n_riders]
    df[!, :has_kom_oracle] = [haskey(sig.kom_oracle_lookup, df.riderkey[i]) for i in 1:n_riders]
    df[!, :has_points_odds] = [haskey(sig.points_odds_lookup, df.riderkey[i]) for i in 1:n_riders]
    df[!, :has_kom_odds] = [haskey(sig.kom_odds_lookup, df.riderkey[i]) for i in 1:n_riders]
    df[!, :has_stagewin_odds] = [haskey(sig.stagewin_odds_lookup, df.riderkey[i]) for i in 1:n_riders]
    df[!, :has_qualitative] = falses(n_riders)
    df[!, :has_form] = falses(n_riders)
    df[!, :has_seasons] = [haskey(sig.currency_factors, df.riderkey[i]) for i in 1:n_riders]

    # --- Per-signal shift columns (L2 norm across dims for each signal) ---
    _norm(v) = sqrt(sum(x^2 for x in v))
    df[!, :shift_pcs] = round.([_norm(shifts_storage[:pcs][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_vg] = round.([_norm(shifts_storage[:vg][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_form] = round.([_norm(shifts_storage[:form][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_history] = round.([_norm(shifts_storage[:history][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_vg_history] = round.([_norm(shifts_storage[:vg_history][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_oracle] = round.([_norm(shifts_storage[:oracle_gc][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_oracle_points] = round.([_norm(shifts_storage[:oracle_points][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_oracle_kom] = round.([_norm(shifts_storage[:oracle_kom][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_qualitative] = round.([_norm(shifts_storage[:qualitative][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_odds] = round.([_norm(shifts_storage[:odds][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_odds_points] = round.([_norm(shifts_storage[:odds_points][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_odds_kom] = round.([_norm(shifts_storage[:odds_kom][i]) for i in 1:n_riders], digits=3)
    df[!, :shift_odds_stagewin] = round.([_norm(shifts_storage[:odds_stagewin][i]) for i in 1:n_riders], digits=3)

    # --- Per-(signal, dim) shift columns: shift_<signal>_<dim> ---
    # Used by reports' per-dimension signal panel.
    for sig_key in keys(shifts_storage), (d, dsym) in enumerate(STRENGTH_DIMENSIONS)
        col = Symbol("shift_$(sig_key)_$(dsym)")
        df[!, col] = round.([shifts_storage[sig_key][i][d] for i in 1:n_riders], digits=3)
    end

    # --- Order-invariant info-share columns ---
    # info_share_<signal>: signal's share of the rider's total observed
    # precision summed across dims. Used by the per-rider waterfall as a
    # single-number summary that doesn't suffer the L2-norm cross-dim
    # aggregation bias or the marginal-shift order-dependence.
    # info_share_<signal>_<dim>: per-dim share — signal's precision contribution
    # to that dim divided by total observed precision on that dim. Used by
    # the chosen-team per-dim panel.
    sig_keys = collect(keys(precisions_storage))
    total_prec_by_dim = [
        [sum(precisions_storage[s][i][d] for s in sig_keys) for d in 1:D]
        for i in 1:n_riders
    ]
    total_prec_overall = [sum(total_prec_by_dim[i]) for i in 1:n_riders]
    for sig_key in sig_keys
        sig_totals = [sum(precisions_storage[sig_key][i]) for i in 1:n_riders]
        df[!, Symbol("info_share_$(sig_key)")] = round.(
            [total_prec_overall[i] > 0 ? sig_totals[i] / total_prec_overall[i] : 0.0
             for i in 1:n_riders],
            digits=4,
        )
        for (d, dsym) in enumerate(STRENGTH_DIMENSIONS)
            df[!, Symbol("info_share_$(sig_key)_$(dsym)")] = round.(
                [total_prec_by_dim[i][d] > 0 ?
                    precisions_storage[sig_key][i][d] / total_prec_by_dim[i][d] : 0.0
                 for i in 1:n_riders],
                digits=4,
            )
        end
    end
    # Alias: :info_share_oracle mirrors :info_share_oracle_gc (matches the
    # existing :shift_oracle alias). Lets the waterfall use a single oracle
    # column name across scalar and multidim pipelines.
    df[!, :info_share_oracle] = df[!, :info_share_oracle_gc]

    df[!, :domestique_penalty] = round.(domestique_penalties, digits=3)

    return df
end


"""
    estimate_strengths(rider_df, race_type; kwargs...) -> DataFrame

Bayesian strength estimation pipeline: takes rider data from multiple sources
and computes posterior strength and uncertainty for each rider.

## Race types
- `:oneday` — uses PCS one-day specialty as the prior; scalar posterior.
- `:stage` — multi-dimensional posterior over `STRENGTH_DIMENSIONS`. Output
  DataFrame gains `strength_<dim>` and `uncertainty_<dim>` columns; scalar
  `strength`/`uncertainty` aliases the `:gc` dimension for back-compat.

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
    points_oracle_df::Union{DataFrame,Nothing}=nothing,
    kom_oracle_df::Union{DataFrame,Nothing}=nothing,
    points_odds_df::Union{DataFrame,Nothing}=nothing,
    kom_odds_df::Union{DataFrame,Nothing}=nothing,
    stagewin_odds_df::Union{DataFrame,Nothing}=nothing,
    vg_history_df::Union{DataFrame,Nothing}=nothing,
    qualitative_df::Union{DataFrame,Nothing}=nothing,
    form_df::Union{DataFrame,Nothing}=nothing,
    seasons_df::Union{DataFrame,Nothing}=nothing,
    race_type::Symbol=:oneday,
    bayesian_config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing}=nothing,
    race_date::Union{Date,Nothing}=nothing,
    domestique_discount::Float64=0.0,
    force_enable::Set{Symbol}=Set{Symbol}(),
)
    # Stage races: route to multidim path
    if race_type == :stage
        return _estimate_strengths_multidim(
            rider_df;
            race_history_df=race_history_df,
            odds_df=odds_df,
            oracle_df=oracle_df,
            points_oracle_df=points_oracle_df,
            kom_oracle_df=kom_oracle_df,
            points_odds_df=points_odds_df,
            kom_odds_df=kom_odds_df,
            stagewin_odds_df=stagewin_odds_df,
            vg_history_df=vg_history_df,
            seasons_df=seasons_df,
            bayesian_config=bayesian_config,
            race_year=race_year,
            race_date=race_date,
            domestique_discount=domestique_discount,
        )
    end

    df = copy(rider_df)
    sig = _assemble_signals(
        df;
        race_history_df=race_history_df,
        odds_df=odds_df,
        oracle_df=oracle_df,
        # VG race history disabled in April 2026 ablation; ignore caller's vg_history_df
        vg_history_df=nothing,
        seasons_df=seasons_df,
        bayesian_config=bayesian_config,
        race_year=race_year,
        race_date=race_date,
    )
    n_riders = sig.n_riders
    n_starters = sig.n_starters
    current_year = sig.current_year

    # --- PCS z-scores: one-day specialty + decay-weighted seasons substitution ---
    # Step 1: z-score raw oneday specialty.
    pcs_z = zeros(n_riders)
    if :oneday in propertynames(df)
        pcs_raw = Float64.(coalesce.(df.oneday, 0.0))
        pcs_mean = mean(pcs_raw)
        pcs_std = std(pcs_raw)
        pcs_z = pcs_std > 0 ? (pcs_raw .- pcs_mean) ./ pcs_std : zeros(n_riders)
    end

    # Step 2: for riders with seasons data, replace the z-score with the raw
    # decay-weighted PCS points (absolute value, not currency ratio). Differs
    # from the multidim path which uses currency_factors as a multiplier on
    # career specialty rather than an absolute substitute.
    if seasons_df !== nothing &&
       :riderkey in propertynames(seasons_df) &&
       :pcs_points in propertynames(seasons_df) &&
       :year in propertynames(seasons_df)
        for g in groupby(seasons_df, :riderkey)
            key = first(g.riderkey)
            weights = [exp(-bayesian_config.pcs_season_decay * (current_year - r.year)) for r in eachrow(g)]
            weighted_pts = sum(weights .* g.pcs_points) / sum(weights)
            idx = findfirst(==(key), df.riderkey)
            idx === nothing && continue
            pcs_z[idx] = weighted_pts
        end
        # Log-transform before re-z-scoring: season points are heavily
        # right-skewed (top riders 3000+, domestiques ~50).
        pcs_z = log1p.(max.(pcs_z, 0.0))
        pcs_mean = mean(pcs_z)
        pcs_std = std(pcs_z)
        pcs_z = pcs_std > 0 ? (pcs_z .- pcs_mean) ./ pcs_std : zeros(n_riders)
    end

    # --- Qualitative and PCS form: disabled in April 2026 ablation. Retained
    # as empty lookups so the per-rider loop continues to populate the
    # corresponding `RiderSignalData` fields (the estimator ignores them).
    qualitative_lookup = Dict{String,Vector{Tuple{Float64,Float64}}}()
    form_lookup = Dict{String,Float64}()
    form_floor_strength_val = 0.0
    qualitative_floor_strength_val = 0.0

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
    precisions_storage = Dict{Symbol,Vector{Float64}}(
        s => Vector{Float64}(undef, n_riders)
        for s in (:pcs, :vg, :form, :history, :vg_history, :oracle, :qualitative, :odds)
    )

    for i = 1:n_riders
        key = df.riderkey[i]

        hist = get(sig.history_lookup, key, Tuple{Float64,Int,Float64}[])
        hist_strengths = Float64[h[1] for h in hist]
        hist_years = Int[h[2] for h in hist]
        hist_penalties = Float64[h[3] for h in hist]

        # VG race history disabled (April 2026); pass empty.
        vg_hist_strengths = Float64[]
        vg_hist_years = Int[]

        odds_prob = get(sig.odds_lookup, key, 0.0)
        oracle_prob = get(sig.oracle_lookup, key, 0.0)
        form_val = get(form_lookup, key, 0.0)

        # Floor strengths: applied to absent riders, AND used as fall-through
        # for listed-below-baseline riders (longshots) in the odds branch.
        # Other floors stay gated on absence.
        odds_floor = sig.odds_floor
        oracle_floor = haskey(sig.oracle_lookup, key) ? 0.0 : sig.oracle_floor
        form_floor = haskey(form_lookup, key) ? 0.0 : form_floor_strength_val
        qual_floor = haskey(qualitative_lookup, key) ? 0.0 : qualitative_floor_strength_val

        qual_entries = get(qualitative_lookup, key, Tuple{Float64,Float64}[])
        qual_adjs = Float64[q[1] for q in qual_entries]
        qual_confs = Float64[q[2] for q in qual_entries]

        est = estimate_rider_strength(
            RiderSignalData(
                pcs_score=pcs_z[i],
                has_pcs=sig.has_pcs[i],
                race_history=hist_strengths,
                race_history_years_ago=hist_years,
                race_history_variance_penalties=hist_penalties,
                vg_points=sig.vg_z[i],
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
            effective_vg_variance=sig.effective_vg_variance,
            race_has_market=sig.race_has_market,
            force_enable=force_enable,
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
        for sig_key in keys(precisions_storage)
            precisions_storage[sig_key][i] = get(est.precisions, sig_key, 0.0)
        end
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
    has_race_history = [haskey(sig.history_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_odds = [haskey(sig.odds_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_oracle = [haskey(sig.oracle_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_qualitative = [haskey(qualitative_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_form = [haskey(form_lookup, df.riderkey[i]) for i = 1:n_riders]
    has_seasons = [in(df.riderkey[i], sig.seasons_keys) for i = 1:n_riders]

    # --- Add results to DataFrame ---
    df[!, :strength] = round.(strengths, digits=3)
    df[!, :uncertainty] = round.(uncertainties, digits=3)

    df[!, :has_pcs] = sig.has_pcs
    df[!, :has_race_history] = has_race_history
    df[!, :has_vg_history] = falses(n_riders)
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

    # --- Order-invariant info-share columns (one-day scalar path) ---
    # info_share_<signal> = signal_precision / total_observed_precision per rider.
    sig_keys_scalar = collect(keys(precisions_storage))
    total_prec_per_rider = [
        sum(precisions_storage[s][i] for s in sig_keys_scalar)
        for i in 1:n_riders
    ]
    for sig_key in sig_keys_scalar
        df[!, Symbol("info_share_$(sig_key)")] = round.(
            [total_prec_per_rider[i] > 0 ?
                precisions_storage[sig_key][i] / total_prec_per_rider[i] : 0.0
             for i in 1:n_riders],
            digits=4,
        )
    end

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
    force_enable::Set{Symbol}=Set{Symbol}(),
)
    estimate_strengths(
        data.rider_df;
        race_history_df=data.race_history_df,
        odds_df=data.odds_df,
        oracle_df=data.oracle_df,
        points_oracle_df=data.points_oracle_df,
        kom_oracle_df=data.kom_oracle_df,
        points_odds_df=data.points_odds_df,
        kom_odds_df=data.kom_odds_df,
        stagewin_odds_df=data.stagewin_odds_df,
        vg_history_df=data.vg_history_df,
        qualitative_df=data.qualitative_df,
        form_df=data.form_df,
        seasons_df=data.seasons_df,
        race_type=race_type,
        bayesian_config=bayesian_config,
        race_year=race_year,
        race_date=race_date,
        domestique_discount=domestique_discount,
        force_enable=force_enable,
    )
end


# Keyword convenience wrapper — forwards all RiderSignalData fields plus race-level context.
function estimate_rider_strength(;
    n_starters::Int=150,
    config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    effective_vg_variance::Float64=0.0,
    race_has_market::Bool=false,
    skip_block_correlation::Bool=false,
    force_enable::Set{Symbol}=Set{Symbol}(),
    kwargs...
)
    estimate_rider_strength(
        RiderSignalData(; kwargs...);
        n_starters=n_starters,
        config=config,
        effective_vg_variance=effective_vg_variance,
        race_has_market=race_has_market,
        skip_block_correlation=skip_block_correlation,
        force_enable=force_enable,
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
    force_enable::Set{Symbol}=Set{Symbol}(),
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
        force_enable=force_enable,
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
    force_enable::Set{Symbol}=Set{Symbol}(),
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
        force_enable=force_enable,
    )
end
