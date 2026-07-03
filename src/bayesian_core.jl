"""
Bayesian strength estimation and Monte Carlo race simulation.

Converts rider data from multiple sources into strength estimates and expected
Velogames points. The pipeline has two stages:

1. **Bayesian strength estimation** — an uninformative prior (mean=0, SD=10) is
   updated sequentially with observations from multiple signal sources (PCS
   specialty, VG season points, form, race history, VG race history,
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
- `history_precision_scale` — form, race history, VG history
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
- `history_precision_scale` — form + race history + VG history
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

    # Historical signals: form, race history, VG history
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
# `:kom` is a scoring-only dimension: it drives the daily mountains-classification
# competition (`_score_daily_mountains!`) but is NOT part of the finish-position
# blend (`stage_dimension_weights` returns no kom weight). This decouples KOM /
# breakaway propensity from summit-finish placing so a polka-dot specialist no
# longer inflates his predicted stage-finish position (see mountain-dimension fix).
const STRENGTH_DIMENSIONS = (:flat, :hilly, :mountain, :itt, :gc, :kom)

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
    pcs_sprint = (flat = 1.0, hilly = 0.1, mountain = 0.0, itt = 0.0, gc = 0.0, kom = 0.0),
    # PCS oneday lumps together flat classics (sprinters score here too) and
    # hilly classics. Routed to :hilly at 0.5 (needs oneday AND climber to make
    # :hilly strong). NO :flat weight (B1, July 2026): all-rounders with huge
    # one-day scores that are really *hilly/GC* ability (Pogačar, oneday≈9983)
    # leaked onto :flat and inflated their flat-sprint top-10 rate. Pure flat
    # sprint ability is already captured by pcs_sprint (weight 1.0), so the
    # oneday→flat route was almost all leak. Trimming it drops Pogačar's
    # backtest flat strength (1.02→0.75) with elite sprinters unchanged; inert
    # in production (market_discount suppresses PCS for priced riders).
    pcs_oneday = (flat = 0.0, hilly = 0.5, mountain = 0.0, itt = 0.0, gc = 0.0, kom = 0.0),
    # Climbing ability is the base for BOTH summit-finish placing (:mountain) and
    # the daily KOM competition (:kom) — a strong climber leads climbs whether or
    # not he chases the jersey. KOM-market signals add breakaway/jersey propensity
    # on top of this base (see odds_kom / oracle_kom / kom_history below).
    pcs_climber = (flat = 0.0, hilly = 0.5, mountain = 1.0, itt = 0.0, gc = 0.0, kom = 1.0),
    pcs_tt = (flat = 0.0, hilly = 0.0, mountain = 0.0, itt = 1.0, gc = 0.0, kom = 0.0),
    # GC ability is the strongest single proxy for current climbing form,
    # since PCS climber is career-cumulative and stale. Heavier weight on
    # :mountain so current GC dominance translates into mountain favouritism.
    # `:hilly` cross-routing is small: punchy hilly finishes (cat-3 / cat-4
    # late climbs) reward puncheurs, not GC riders — Vingegaard contests
    # summit finishes, not 4 km kickers, so GC strength shouldn't dominate
    # `:hilly` posterior.
    pcs_gc = (flat = 0.0, hilly = 0.1, mountain = 0.7, itt = 0.0, gc = 1.0, kom = 0.5),
    # GC oracle and odds carry strong "this rider is contender for the overall"
    # information. Positive evidence cross-routes to mountain (Tour-winning
    # climbers typically win summit finishes), but minimally to :hilly — they
    # score daily-GC points there but rarely win punchy hilly stages.
    # mountain raised 0.2→0.5 (toward pcs_gc's 0.7): the *market's* GC signal is
    # sharper than career PCS and should inform summit-finish placing at least as
    # strongly. Previously KOM-market riders out-punched real GC climbers on
    # :mountain because odds_gc reached it at only 0.2 while odds_kom hit 1.0.
    oracle_gc = (flat = 0.0, hilly = 0.05, mountain = 0.5, itt = 0.0, gc = 1.0, kom = 0.1),
    odds_gc = (flat = 0.0, hilly = 0.05, mountain = 0.5, itt = 0.0, gc = 1.0, kom = 0.1),
    # Jersey oracles predict season-long jersey winners. Points oracle
    # correlates with flat-stage finishing for listed sprinters (they
    # contest bunch finishes consistently), justifying a small :flat
    # weight. KOM oracle routes to :mountain only — those listed are
    # the riders most likely to chase summit-finish bonuses.
    oracle_points = (
        flat = 0.4,
        hilly = 0.1,
        mountain = 0.0,
        itt = 0.0,
        gc = 0.0,
        kom = 0.0,
    ),
    # KOM jersey signals now route to :kom ONLY (was :mountain 1.0). :kom drives
    # the daily mountains-classification scoring, not finish position — so a
    # breakaway/jersey hunter earns KOM points without being predicted to place
    # on summit finishes he doesn't contest.
    oracle_kom = (flat = 0.0, hilly = 0.0, mountain = 0.0, itt = 0.0, gc = 0.0, kom = 1.0),
    # Bookmaker odds for jersey markets — same routing as the oracle
    # counterparts, but consumed with the sharper `odds_variance`.
    odds_points = (flat = 0.4, hilly = 0.1, mountain = 0.0, itt = 0.0, gc = 0.0, kom = 0.0),
    odds_kom = (flat = 0.0, hilly = 0.0, mountain = 0.0, itt = 0.0, gc = 0.0, kom = 1.0),
    # Prior-edition classification standings (history, not market). A strong
    # past points-jersey finish is evidence of flat/hilly stage ability; a strong
    # past KOM finish is evidence of mountain ability. Same dimension routing as
    # the jersey oracles.
    points_history = (
        flat = 0.4,
        hilly = 0.1,
        mountain = 0.0,
        itt = 0.0,
        gc = 0.0,
        kom = 0.0,
    ),
    kom_history = (flat = 0.0, hilly = 0.0, mountain = 0.0, itt = 0.0, gc = 0.0, kom = 1.0),
)

"""
Per-class default weighting used to project a past PCS race-history result onto
the multidim strength vector. Until we know the stage-type mix of each past race
(deferred to Phase 2), each result is attributed to dimensions according to the
rider's own class profile — a reasonable shortcut: a sprinter's past results
are mostly evidence about flat-stage ability, etc.
"""
# `kom` mirrors `mountain`: generic (dimension-agnostic) history / VG evidence
# for a climber is as much evidence about KOM-competition ability as about
# summit-finish placing. KOM-specific market signals add propensity on top.
const RACE_HISTORY_CLASS_PROJECTION = Dict{String,NamedTuple}(
    "sprinter" =>
        (flat = 0.7, hilly = 0.3, mountain = 0.0, itt = 0.0, gc = 0.0, kom = 0.0),
    "climber" =>
        (flat = 0.0, hilly = 0.3, mountain = 0.7, itt = 0.0, gc = 0.0, kom = 0.7),
    "allrounder" =>
        (flat = 0.0, hilly = 0.0, mountain = 0.3, itt = 0.2, gc = 0.5, kom = 0.3),
    "unclassed" =>
        (flat = 0.2, hilly = 0.5, mountain = 0.0, itt = 0.0, gc = 0.3, kom = 0.0),
)

# Minimum routing weight for a market signal to count as "informing" a dimension
# for the double-counting discount. Above this, the market materially replaces
# the PCS signal there (odds_points→flat 0.4, odds_gc→mountain 0.5/gc 1.0,
# odds_kom→kom 1.0); below it, the market only trickles in as a small correction
# (odds_gc→kom 0.1, hilly 0.05) and must not trigger the full discount.
const MARKET_DIM_THRESHOLD = 0.3

# Canonical signal keys for the estimators' precision/shift bookkeeping. Defined
# once so a newly added signal can't be silently dropped from one dict while
# present in another. `SIGNAL_KEYS` is the scalar (one-day) estimator's set;
# `SIGNAL_KEYS_MULTIDIM` adds the per-market sub-channels (GC / points / KOM /
# stage-win) and classification history used by the stage-race estimator. Both
# are used only for order-independent Dict initialisation, so the order here is
# for readability. (The prediction-archive allow-list in `race_solver.jl` and the
# report display columns are deliberately kept explicit — they carry `shift_`/
# `info_share_` prefixes and per-dimension strength columns, not bare keys.)
const SIGNAL_KEYS = (:pcs, :vg, :form, :history, :vg_history, :oracle, :qualitative, :odds)
const SIGNAL_KEYS_MULTIDIM = (
    :pcs,
    :vg,
    :form,
    :history,
    :vg_history,
    :points_history,
    :kom_history,
    :oracle_gc,
    :oracle_points,
    :oracle_kom,
    :qualitative,
    :odds,
    :odds_points,
    :odds_kom,
    :odds_stagewin,
)

function _weights_to_vec(nt::NamedTuple)
    [Float64(getfield(nt, d)) for d in STRENGTH_DIMENSIONS]
end
