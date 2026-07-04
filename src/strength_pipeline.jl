# strength_pipeline.jl — per-rider signal assembly (RiderSignalData, AssembledSignals),
# Bayesian strength estimation (scalar + multidim), and the high-level
# estimate_strengths / predict_expected_points entry points.

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
    # Prior-edition classification history (multi-dim only).
    points_history::Vector{Float64} = Float64[]
    points_history_years_ago::Vector{Int} = Int[]
    points_history_penalties::Vector{Float64} = Float64[]
    kom_history::Vector{Float64} = Float64[]
    kom_history_years_ago::Vector{Int} = Int[]
    kom_history_penalties::Vector{Float64} = Float64[]
    # GT VG-history (Option A prototype, July 2026; multi-dim only). Each entry is
    # this rider's own log1p-z-scored VG total from one past edition of THIS grand
    # tour; `years_ago` drives recency decay. Multiple results ⇒ multiple conjugate
    # updates ⇒ a naturally tighter, sparsity-appropriate posterior for riders with
    # a longer GT record.
    gt_vg_history::Vector{Float64} = Float64[]
    gt_vg_history_years_ago::Vector{Int} = Int[]
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
    n_starters::Int = 150,
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    effective_vg_variance::Float64 = 0.0,  # 0 = use vg_variance(config)
    race_has_market::Bool = false,
    skip_block_correlation::Bool = false,
    force_enable::Set{Symbol} = Set{Symbol}(),
)
    (;
        pcs_score,
        has_pcs,
        race_history,
        race_history_years_ago,
        race_history_variance_penalties,
        vg_points,
        form_score,
        vg_race_history,
        vg_race_history_years_ago,
        odds_implied_prob,
        oracle_implied_prob,
        odds_floor_strength,
        oracle_floor_strength,
        form_floor_strength,
        qualitative_floor_strength,
        qualitative_adjustments,
        qualitative_confidences,
    ) = signals
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
    precisions = Dict{Symbol,Float64}(s => 0.0 for s in SIGNAL_KEYS)

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
        hist_var =
            (hist_base_variance(config) + config.hist_decay_rate * years_ago + penalty) * md
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
            vg_var =
                (vg_hist_base_variance(config) + config.vg_hist_decay_rate * years_ago) * md
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
            floor_var =
                qualitative_base_variance(config) *
                config.qualitative_floor_variance_multiplier
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
        for (n_k, obs_prec_k) in [
            (n_ability, ability_obs_prec),
            (n_history, history_obs_prec),
            (n_market, market_obs_prec),
        ]
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

# Cluster rows for the per-dimension block-correlation discount, matching the
# scalar path's grouping (ability / history / market).
const _CLUSTER_ABILITY = 1
const _CLUSTER_HISTORY = 2
const _CLUSTER_MARKET = 3

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
    _market_update_listed!(posterior, precisions, shifts, key, prob, base_var, weights,
                           n_starters, odds_normalisation) -> posterior

Apply one listed-only market signal (jersey / points / KOM / stage-win oracle or
odds) to the multidim posterior. These markets have list-cutoff selection bias,
so a below-baseline observation is a true no-op (clamp at 0) with no absence
floor. The log-odds observation is cross-routed to each dimension weighted by
`weights` (a fixed `SIGNAL_DIMENSION_WEIGHTS` field, or a class projection for
stage-win odds), accumulating precision under `key`. Returns the updated
posterior. Shared by five otherwise byte-identical blocks; the GC oracle/odds
markets keep their own code because they carry an absence floor.
"""
function _market_update_listed!(
    posterior,
    precisions::Dict{Symbol,Vector{Float64}},
    shifts::Dict{Symbol,Vector{Float64}},
    key::Symbol,
    prob::Float64,
    base_var::Float64,
    weights::NamedTuple,
    n_starters,
    odds_normalisation::Float64,
    cluster_prec::Matrix{Float64},
    cluster_n::Matrix{Int},
)
    mean_before = copy(posterior.mean)
    if prob > 0.0
        baseline = 1.0 / n_starters
        obs = log(prob / baseline) / odds_normalisation
        if obs > 0.0
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(weights, dsym)
                w == 0.0 && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[key][_DIM_INDEX[dsym]] += 1.0 / v
                cluster_prec[_CLUSTER_MARKET, _DIM_INDEX[dsym]] += 1.0 / v
                cluster_n[_CLUSTER_MARKET, _DIM_INDEX[dsym]] += 1
            end
        end
    end
    shifts[key] = posterior.mean .- mean_before
    return posterior
end

"""
    estimate_rider_strength_multidim(signals; n_starters, config, ...) -> MultiDimStrengthEstimate

Multi-dimensional Bayesian strength estimation for stage races. Mirrors the
signal sequence in `estimate_rider_strength` but routes each observation to
the dimensions in `STRENGTH_DIMENSIONS` according to `SIGNAL_DIMENSION_WEIGHTS`.
GC-flavoured floors (Cycling Oracle GC, GC odds) only touch the `:gc`
dimension; sprinters absent from the GC market are no longer penalised on
`:flat`/`:hilly`.

The scalar path's block-correlation discount is applied per dimension at the
end (gated by `config.multidim_block_correlation`), widening posteriors for
riders with multiple correlated observations on a dimension. Cluster
membership (ability/history/market) matches the scalar path;
`skip_block_correlation = true` isolates the raw conjugate updates for
per-signal SBC, mirroring the scalar escape hatch.
"""
function estimate_rider_strength_multidim(
    signals::RiderSignalData;
    n_starters::Int = 150,
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    effective_vg_variance::Float64 = 0.0,
    race_has_market::Bool = false,
    market_dims::Union{Nothing,Vector{Bool}} = nothing,
    skip_block_correlation::Bool = false,
)
    D = length(STRENGTH_DIMENSIONS)
    posterior = multidim_prior(config)
    # Dimension-aware market discount. The double-counting correction (inflate
    # non-market signal variance by `market_discount` when odds are present) must
    # only apply on dimensions a market actually informs. `market_dims[d]` says
    # whether any market signal routes to dimension d in this race; dimensions no
    # market touches (notably :itt, which has NO betting/oracle market) keep full
    # non-market weight — otherwise a GC market silently deletes the PCS-TT signal.
    md_vec = if market_dims !== nothing
        [market_dims[d] ? config.market_discount : 1.0 for d = 1:D]
    else
        fill(race_has_market ? config.market_discount : 1.0, D)
    end
    shifts = Dict{Symbol,Vector{Float64}}()
    # Per-(signal, dim) precision contributions for order-invariant info-share
    # diagnostics. Each `bayesian_update_multidim_dim(posterior, obs, var, dsym)`
    # call below accumulates `1/var` into the corresponding entry.
    precisions = Dict{Symbol,Vector{Float64}}(s => zeros(D) for s in SIGNAL_KEYS_MULTIDIM)
    # Per-(cluster, dim) observation precision and update counts, accumulated at
    # every update site for the end-of-function block-correlation discount.
    # Order-invariant by construction (unlike the scalar path's boundary
    # snapshots, which rely on cluster-contiguous update order).
    cluster_prec = zeros(Float64, 3, D)
    cluster_n = zeros(Int, 3, D)

    # --- PCS specialty (per-source, dim-specific) ---
    mean_before = copy(posterior.mean)
    if signals.has_pcs
        base_var = pcs_variance(config)
        for (sig_name, obs) in (
            (:pcs_sprint, signals.pcs_sprint_z),
            (:pcs_oneday, signals.pcs_oneday_z),
            (:pcs_climber, signals.pcs_climber_z),
            (:pcs_tt, signals.pcs_tt_z),
            (:pcs_gc, signals.pcs_gc_z),
        )
            weights_nt = getfield(SIGNAL_DIMENSION_WEIGHTS, sig_name)
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(weights_nt, dsym)
                w == 0.0 && continue
                v = base_var * md_vec[_DIM_INDEX[dsym]] / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[:pcs][_DIM_INDEX[dsym]] += 1.0 / v
                cluster_prec[_CLUSTER_ABILITY, _DIM_INDEX[dsym]] += 1.0 / v
                cluster_n[_CLUSTER_ABILITY, _DIM_INDEX[dsym]] += 1
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
        eff_var_base =
            effective_vg_variance > 0.0 ? effective_vg_variance : vg_variance(config)
        proj = get(
            RACE_HISTORY_CLASS_PROJECTION,
            lowercase(signals.rider_class),
            RACE_HISTORY_CLASS_PROJECTION["unclassed"],
        )
        for dsym in STRENGTH_DIMENSIONS
            w = getfield(proj, dsym)
            w == 0.0 && continue
            v = eff_var_base * md_vec[_DIM_INDEX[dsym]] / w
            posterior = bayesian_update_multidim_dim(posterior, signals.vg_points, v, dsym)
            precisions[:vg][_DIM_INDEX[dsym]] += 1.0 / v
            cluster_prec[_CLUSTER_ABILITY, _DIM_INDEX[dsym]] += 1.0 / v
            cluster_n[_CLUSTER_ABILITY, _DIM_INDEX[dsym]] += 1
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
            penalty =
                i <= length(signals.race_history_variance_penalties) ?
                signals.race_history_variance_penalties[i] : 0.0
            base_var =
                hist_base_variance(config) + config.hist_decay_rate * years_ago + penalty
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(proj, dsym)
                w == 0.0 && continue
                v = base_var * md_vec[_DIM_INDEX[dsym]] / w
                posterior = bayesian_update_multidim_dim(posterior, hist_strength, v, dsym)
                precisions[:history][_DIM_INDEX[dsym]] += 1.0 / v
                cluster_prec[_CLUSTER_HISTORY, _DIM_INDEX[dsym]] += 1.0 / v
                cluster_n[_CLUSTER_HISTORY, _DIM_INDEX[dsym]] += 1
            end
        end
    end
    shifts[:history] = posterior.mean .- mean_before

    # --- Points/KOM classification history (fixed dimension routing) ---
    # Prior-edition points-jersey and KOM standings, routed to the dimensions
    # they inform (points → flat/hilly, KOM → mountain) via SIGNAL_DIMENSION_WEIGHTS
    # rather than the rider's class — a past green-jersey finish is direct
    # evidence of flat/hilly ability regardless of how the rider is classed.
    for (sig_key, obs, yrs, pens) in (
        (
            :points_history,
            signals.points_history,
            signals.points_history_years_ago,
            signals.points_history_penalties,
        ),
        (
            :kom_history,
            signals.kom_history,
            signals.kom_history_years_ago,
            signals.kom_history_penalties,
        ),
    )
        mean_before = copy(posterior.mean)
        if !isempty(obs)
            w_nt = getfield(SIGNAL_DIMENSION_WEIGHTS, sig_key)
            for (i, (hist_strength, years_ago)) in enumerate(zip(obs, yrs))
                penalty = i <= length(pens) ? pens[i] : 0.0
                base_var =
                    hist_base_variance(config) +
                    config.hist_decay_rate * years_ago +
                    penalty
                for dsym in STRENGTH_DIMENSIONS
                    w = getfield(w_nt, dsym)
                    w == 0.0 && continue
                    v = base_var * md_vec[_DIM_INDEX[dsym]] / w
                    posterior =
                        bayesian_update_multidim_dim(posterior, hist_strength, v, dsym)
                    precisions[sig_key][_DIM_INDEX[dsym]] += 1.0 / v
                    cluster_prec[_CLUSTER_HISTORY, _DIM_INDEX[dsym]] += 1.0 / v
                    cluster_n[_CLUSTER_HISTORY, _DIM_INDEX[dsym]] += 1
                end
            end
        end
        shifts[sig_key] = posterior.mean .- mean_before
    end

    # --- VG race history (per-class projection, mirrors VG season points) ---
    mean_before = copy(posterior.mean)
    if !isempty(signals.vg_race_history)
        proj = get(
            RACE_HISTORY_CLASS_PROJECTION,
            lowercase(signals.rider_class),
            RACE_HISTORY_CLASS_PROJECTION["unclassed"],
        )
        for (vg_strength, years_ago) in
            zip(signals.vg_race_history, signals.vg_race_history_years_ago)
            eff_var = vg_hist_base_variance(config) + config.vg_hist_decay_rate * years_ago
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(proj, dsym)
                w == 0.0 && continue
                v = eff_var * md_vec[_DIM_INDEX[dsym]] / w
                posterior = bayesian_update_multidim_dim(posterior, vg_strength, v, dsym)
                precisions[:vg_history][_DIM_INDEX[dsym]] += 1.0 / v
                cluster_prec[_CLUSTER_HISTORY, _DIM_INDEX[dsym]] += 1.0 / v
                cluster_n[_CLUSTER_HISTORY, _DIM_INDEX[dsym]] += 1
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
                cluster_prec[_CLUSTER_MARKET, _DIM_INDEX[dsym]] += 1.0 / v
                cluster_n[_CLUSTER_MARKET, _DIM_INDEX[dsym]] += 1
            end
        end
    elseif signals.oracle_floor_strength != 0.0
        var_f = oracle_variance(config) * config.oracle_floor_variance_multiplier
        posterior = bayesian_update_multidim_dim(
            posterior,
            signals.oracle_floor_strength,
            var_f,
            :gc,
        )
        precisions[:oracle_gc][_DIM_INDEX[:gc]] += 1.0 / var_f
        cluster_prec[_CLUSTER_MARKET, _DIM_INDEX[:gc]] += 1.0 / var_f
        cluster_n[_CLUSTER_MARKET, _DIM_INDEX[:gc]] += 1
    end
    shifts[:oracle_gc] = posterior.mean .- mean_before

    # --- Cycling Oracle Points (→ :flat 0.4 + :hilly 0.1, listed only, clamp at 0) ---
    # Jersey-prediction oracles have selection bias: only riders chasing the
    # jersey are listed. A GC contender absent from points oracle is not
    # automatically weak on flat/hilly stages. Apply listed-rider boost only
    # (no absence floor); clamp at 0 so a low-probability listing never
    # reduces strength.
    posterior = _market_update_listed!(
        posterior,
        precisions,
        shifts,
        :oracle_points,
        signals.points_oracle_implied_prob,
        oracle_variance(config),
        SIGNAL_DIMENSION_WEIGHTS.oracle_points,
        n_starters,
        config.odds_normalisation,
        cluster_prec,
        cluster_n,
    )

    # --- Cycling Oracle KOM (→ :mountain, listed only, clamp at 0) ---
    posterior = _market_update_listed!(
        posterior,
        precisions,
        shifts,
        :oracle_kom,
        signals.kom_oracle_implied_prob,
        oracle_variance(config),
        SIGNAL_DIMENSION_WEIGHTS.oracle_kom,
        n_starters,
        config.odds_normalisation,
        cluster_prec,
        cluster_n,
    )

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
            posterior = bayesian_update_multidim_dim(
                posterior,
                signals.odds_floor_strength,
                var_f,
                :gc,
            )
            precisions[:odds][_DIM_INDEX[:gc]] += 1.0 / var_f
        end
    elseif signals.odds_floor_strength != 0.0
        var_f = odds_variance(config) * config.odds_floor_variance_multiplier
        posterior =
            bayesian_update_multidim_dim(posterior, signals.odds_floor_strength, var_f, :gc)
        precisions[:odds][_DIM_INDEX[:gc]] += 1.0 / var_f
    end
    shifts[:odds] = posterior.mean .- mean_before

    # --- Bookmaker Points-jersey market (→ :flat 0.4 + :hilly 0.1, listed only) ---
    # Same list-cutoff logic as Cycling Oracle: bookmakers only price plausible
    # jersey contenders. Inclusion is itself a positive endorsement; clamp at 0.
    posterior = _market_update_listed!(
        posterior,
        precisions,
        shifts,
        :odds_points,
        signals.points_odds_implied_prob,
        odds_variance(config),
        SIGNAL_DIMENSION_WEIGHTS.odds_points,
        n_starters,
        config.odds_normalisation,
        cluster_prec,
        cluster_n,
    )

    # --- Bookmaker KOM market (→ :mountain, listed only, clamp at 0) ---
    posterior = _market_update_listed!(
        posterior,
        precisions,
        shifts,
        :odds_kom,
        signals.kom_odds_implied_prob,
        odds_variance(config),
        SIGNAL_DIMENSION_WEIGHTS.odds_kom,
        n_starters,
        config.odds_normalisation,
        cluster_prec,
        cluster_n,
    )

    # --- Bookmaker "Rider To Win A Stage" market — class-aware routing ---
    # Stage-winning evidence informs the dimensions where the rider plausibly
    # wins (a sprinter scores stage-win points on flat/hilly, a climber on
    # hilly/mountain). Reuse RACE_HISTORY_CLASS_PROJECTION which already
    # encodes the per-class dimension mix.
    # List-cutoff market: skip update entirely when obs ≤ 0 (true no-op,
    # not posterior-shrinkage-toward-zero).
    stagewin_cls =
        haskey(RACE_HISTORY_CLASS_PROJECTION, signals.rider_class) ? signals.rider_class :
        "unclassed"
    posterior = _market_update_listed!(
        posterior,
        precisions,
        shifts,
        :odds_stagewin,
        signals.stagewin_odds_implied_prob,
        odds_variance(config),
        RACE_HISTORY_CLASS_PROJECTION[stagewin_cls],
        n_starters,
        config.odds_normalisation,
        cluster_prec,
        cluster_n,
    )

    # --- GT VG-history (Option A prototype, July 2026) ---
    # A rider's OWN prior grand-tour VG totals (log1p-z-scored per past edition).
    # Fixed routing via SIGNAL_DIMENSION_WEIGHTS.gt_vg_history — a role/propensity
    # factor, NOT the rider's class projection: the whole point is that it captures
    # scoring role the class/ability signals are blind to. Recency decay reuses
    # `vg_hist_decay_rate`. Sparsity is handled by the conjugate mechanism itself —
    # n editions give ~n× the precision of a single result, so a longer GT record
    # yields a tighter, more-informed posterior with no bolt-on multiplier.
    #
    # Two deliberate design choices make this do-no-harm on leaders:
    #   1. Runs LAST, AFTER the market updates. A leader's mountain/hilly posterior
    #      is already lifted (and tightened) by GC odds/oracle by this point, so the
    #      upward clamp below skips them entirely — no precision is added, so the
    #      market lift is not dampened. (Running BEFORE the market instead silently
    #      pulls leaders DOWN: the extra precision blunts the later market update.)
    #   2. UPWARD-ONLY: a dimension updates only when the observation would RAISE its
    #      mean. Prior GT VG success is evidence of *extra* scoring propensity on top
    #      of ability (a role bonus); it must never drag down a rider whose ability
    #      estimate already exceeds their historical-VG z. Same spirit as the
    #      "clamp at 0" list-cutoff market updates. Consequence: the inverse case (an
    #      elite classics rider on locked domestique duty whose LOW GT history should
    #      pull them down) is deliberately NOT handled — that two-sided correction
    #      would reintroduce the leader harm and belongs in an EVG-stage layer (B).
    #
    # NOT multiplied by `md_vec`: unlike PCS/history this is orthogonal to what the
    # GC/stage-win markets price for cheap domestiques, so the double-counting
    # `market_discount` must not suppress it (that would gut the signal on the very
    # dimensions the flagged break-hunters need lifting on).
    mean_before = copy(posterior.mean)
    if !isempty(signals.gt_vg_history)
        w_nt = SIGNAL_DIMENSION_WEIGHTS.gt_vg_history
        for (obs, years_ago) in
            zip(signals.gt_vg_history, signals.gt_vg_history_years_ago)
            base_var = config.gt_vg_hist_base_variance + config.vg_hist_decay_rate * years_ago
            for dsym in STRENGTH_DIMENSIONS
                w = getfield(w_nt, dsym)
                w == 0.0 && continue
                obs <= posterior.mean[_DIM_INDEX[dsym]] && continue
                v = base_var / w
                posterior = bayesian_update_multidim_dim(posterior, obs, v, dsym)
                precisions[:gt_vg_history][_DIM_INDEX[dsym]] += 1.0 / v
                cluster_prec[_CLUSTER_HISTORY, _DIM_INDEX[dsym]] += 1.0 / v
                cluster_n[_CLUSTER_HISTORY, _DIM_INDEX[dsym]] += 1
            end
        end
    end
    shifts[:gt_vg_history] = posterior.mean .- mean_before

    # --- Block-correlation precision discount (per dimension) ---
    # Same design-effect correction as the scalar path: within each cluster
    # (ability/history/market) observations share ρ_w, across clusters ρ_b.
    # Applied per dimension from the accumulated cluster precisions/counts.
    # Dimensions with ≤1 observation are left untouched.
    ρ_w = config.within_cluster_correlation
    ρ_b = config.between_cluster_correlation
    if config.multidim_block_correlation &&
       !skip_block_correlation &&
       (ρ_w > 0 || ρ_b > 0)
        prior_prec = 1.0 / config.prior_variance
        new_mean = copy(posterior.mean)
        new_var = copy(posterior.variance)
        for d = 1:D
            n_total_d = cluster_n[1, d] + cluster_n[2, d] + cluster_n[3, d]
            n_total_d > 1 || continue
            post_prec = 1.0 / posterior.variance[d]
            total_obs_prec = post_prec - prior_prec

            # Within-cluster discount, then collect active clusters
            cluster_precs = Float64[]
            for k = 1:3
                n_k = cluster_n[k, d]
                n_k == 0 && continue
                discount_k = n_k > 1 ? 1.0 + ρ_w * (n_k - 1) : 1.0
                push!(cluster_precs, cluster_prec[k, d] / discount_k)
            end

            # Between-cluster discount
            n_clusters = length(cluster_precs)
            eff_obs_prec = if n_clusters > 1
                sum(cluster_precs) / (1.0 + ρ_b * (n_clusters - 1))
            else
                cluster_precs[1]
            end

            # Reconstruct this dimension's posterior with discounted precision
            # (prior mean is 0, so obs_mean carries the whole posterior mean).
            obs_mean = posterior.mean[d] * post_prec / total_obs_prec
            eff_prec = prior_prec + eff_obs_prec
            new_mean[d] = eff_obs_prec * obs_mean / eff_prec
            new_var[d] = 1.0 / eff_prec
        end
        posterior = MultiDimPosterior(new_mean, new_var)
    end

    return MultiDimStrengthEstimate(
        copy(posterior.mean),
        copy(posterior.variance),
        shifts,
        precisions,
    )
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
    gt_vg_history_lookup::Dict{String,Vector{Tuple{Float64,Int}}}
    points_history_lookup::Dict{String,Vector{Tuple{Float64,Int,Float64}}}
    kom_history_lookup::Dict{String,Vector{Tuple{Float64,Int,Float64}}}
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
    race_history_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
    oracle_df::Union{DataFrame,Nothing} = nothing,
    points_oracle_df::Union{DataFrame,Nothing} = nothing,
    kom_oracle_df::Union{DataFrame,Nothing} = nothing,
    points_odds_df::Union{DataFrame,Nothing} = nothing,
    kom_odds_df::Union{DataFrame,Nothing} = nothing,
    stagewin_odds_df::Union{DataFrame,Nothing} = nothing,
    vg_history_df::Union{DataFrame,Nothing} = nothing,
    points_history_df::Union{DataFrame,Nothing} = nothing,
    kom_history_df::Union{DataFrame,Nothing} = nothing,
    gt_vg_history_df::Union{DataFrame,Nothing} = nothing,
    seasons_df::Union{DataFrame,Nothing} = nothing,
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing} = nothing,
    race_date::Union{Date,Nothing} = nothing,
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
    season_scale = 1.0 + config.vg_season_penalty * (1.0 - frac_nonzero)
    effective_vg_variance = vg_variance(config) * season_scale
    @info "Season-adaptive VG variance: $(round(effective_vg_variance, digits=2)) " *
          "($(round(100 * frac_nonzero, digits=0))% with points, scale=$(round(season_scale, digits=2)))"

    # --- has_pcs ---
    pcs_specialty_cols = (:sprint, :oneday, :climber, :tt, :gc)
    has_pcs = if :has_pcs_data in propertynames(df)
        Bool.(df.has_pcs_data)
    else
        avail = intersect(propertynames(df), collect(pcs_specialty_cols))
        [any(df[i, c] != 0 for c in avail) for i = 1:n_riders]
    end

    # --- Classifications (used by multidim only; harmless to always compute) ---
    class_col =
        :classraw in propertynames(df) ? :classraw :
        :class in propertynames(df) ? :class : nothing
    classes = if class_col !== nothing
        [lowercase(string(df[i, class_col])) for i = 1:n_riders]
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
            pts_all = Float64.(coalesce.(g.pcs_points, 0.0))
            yrs_all = Int.(coalesce.(g.year, current_year))
            # Drop post-race seasons: an archived per-season frame reconstructed
            # for a past race can carry later-year rows that would leak future
            # form (and, for year > current_year, flip the decay weight above 1).
            keep = yrs_all .<= current_year
            any(keep) || continue
            push!(seasons_keys, key)
            pts = pts_all[keep]
            yrs = yrs_all[keep]
            weights = exp.(-config.pcs_season_decay .* (current_year .- yrs))
            decay_avg = sum(weights .* pts) / sum(weights)
            career_avg = mean(pts)
            currency_factors[key] = career_avg > 0 ? decay_avg / career_avg : 1.0
        end
    end
    rider_currency = Float64[get(currency_factors, df.riderkey[i], 1.0) for i = 1:n_riders]

    # --- Market-source lookup helper (closure captures df, n_riders, etc.) ---
    function _market_lookup(
        src_df,
        prob_col::Symbol,
        label::String;
        apply_floor::Bool = true,
    )
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
                floor_strength = log(floor_prob / baseline_prob) / config.odds_normalisation
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
        if :odds in config.floor_signals && !isempty(odds_lookup)
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
                odds_floor = log(floor_prob / baseline_prob) / config.odds_normalisation
            end
            @info "Odds floor: $n_listed priced, $n_absent with floor (strength=$(round(odds_floor, digits=2)))"
        end
    end

    # --- Oracle GC: always build lookup; gate floor on `:oracle in floor_signals`.
    # The previous multidim path skipped building the lookup entirely when
    # `:oracle` was absent from `floor_signals`, dropping listed oracle riders
    # alongside the floor. Aligning with the scalar one-day behaviour.
    apply_oracle_floor = :oracle in config.floor_signals
    oracle_lookup, oracle_floor = _market_lookup(
        oracle_df,
        :win_prob,
        "Oracle GC floor";
        apply_floor = apply_oracle_floor,
    )

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

    # --- GT VG-history lookup (Option A prototype). log1p, then z-score WITHIN
    # each past edition's full field, so a rider's entry is "how their VG total
    # ranked among that Tour's starters". log1p first because GT totals are
    # heavily right-skewed (leaders 3000-4000, domestiques 50-300) — raw z-scoring
    # would let a single 4000 dominate σ and compress everyone else toward 0. A
    # cheap break-hunter who out-scores the median then lands materially above 0,
    # pulling their (currently far-below-average) strength estimate upward. ---
    gt_vg_history_lookup = Dict{String,Vector{Tuple{Float64,Int}}}()
    if gt_vg_history_df !== nothing &&
       :riderkey in propertynames(gt_vg_history_df) &&
       :score in propertynames(gt_vg_history_df) &&
       :year in propertynames(gt_vg_history_df)
        for g in groupby(gt_vg_history_df, :year)
            logged = log1p.(max.(Float64.(coalesce.(g.score, 0.0)), 0.0))
            μ = mean(logged)
            σ = std(logged)
            for (i, row) in enumerate(eachrow(g))
                ismissing(row.year) && continue
                z = σ > 0 ? (logged[i] - μ) / σ : 0.0
                years_ago = current_year - row.year
                push!(
                    get!(gt_vg_history_lookup, row.riderkey, Tuple{Float64,Int}[]),
                    (z, years_ago),
                )
            end
        end
    end

    # --- Classification history lookups (points jersey, KOM) — same shape as
    # race history: position → strength, recency, variance penalty. ---
    function _class_hist(cls_df)
        lookup = Dict{String,Vector{Tuple{Float64,Int,Float64}}}()
        cls_df === nothing && return lookup
        all(c -> c in propertynames(cls_df), (:riderkey, :position, :year)) || return lookup
        has_pen = :variance_penalty in propertynames(cls_df)
        for row in eachrow(cls_df)
            (ismissing(row.position) || ismissing(row.year)) && continue
            (row.position > 0 && row.position < 900) || continue
            push!(
                get!(lookup, row.riderkey, Tuple{Float64,Int,Float64}[]),
                (
                    position_to_strength(row.position, n_starters),
                    current_year - row.year,
                    has_pen ? Float64(coalesce(row.variance_penalty, 0.0)) : 0.0,
                ),
            )
        end
        return lookup
    end
    points_history_lookup = _class_hist(points_history_df)
    kom_history_lookup = _class_hist(kom_history_df)

    return AssembledSignals(
        n_riders,
        n_starters,
        current_year,
        vg_z,
        effective_vg_variance,
        has_pcs,
        classes,
        currency_factors,
        rider_currency,
        seasons_keys,
        history_lookup,
        vg_history_lookup,
        gt_vg_history_lookup,
        points_history_lookup,
        kom_history_lookup,
        odds_lookup,
        oracle_lookup,
        points_oracle_lookup,
        kom_oracle_lookup,
        points_odds_lookup,
        kom_odds_lookup,
        stagewin_odds_lookup,
        odds_floor,
        oracle_floor,
        points_oracle_floor,
        kom_oracle_floor,
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
    race_history_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
    oracle_df::Union{DataFrame,Nothing} = nothing,
    points_oracle_df::Union{DataFrame,Nothing} = nothing,
    kom_oracle_df::Union{DataFrame,Nothing} = nothing,
    points_odds_df::Union{DataFrame,Nothing} = nothing,
    kom_odds_df::Union{DataFrame,Nothing} = nothing,
    stagewin_odds_df::Union{DataFrame,Nothing} = nothing,
    vg_history_df::Union{DataFrame,Nothing} = nothing,
    points_history_df::Union{DataFrame,Nothing} = nothing,
    kom_history_df::Union{DataFrame,Nothing} = nothing,
    gt_vg_history_df::Union{DataFrame,Nothing} = nothing,
    seasons_df::Union{DataFrame,Nothing} = nothing,
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing} = nothing,
    race_date::Union{Date,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
)
    df = copy(rider_df)
    sig = _assemble_signals(
        df;
        race_history_df = race_history_df,
        odds_df = odds_df,
        oracle_df = oracle_df,
        points_oracle_df = points_oracle_df,
        kom_oracle_df = kom_oracle_df,
        points_odds_df = points_odds_df,
        kom_odds_df = kom_odds_df,
        stagewin_odds_df = stagewin_odds_df,
        vg_history_df = vg_history_df,
        points_history_df = points_history_df,
        kom_history_df = kom_history_df,
        gt_vg_history_df = gt_vg_history_df,
        seasons_df = seasons_df,
        config = config,
        race_year = race_year,
        race_date = race_date,
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
    # Preferred: a recency-weighted per-season specialty score in `<col>_r`
    # (decay-weighted sum of points earned per season — current form beats stale
    # palmarès). Fallback (backtest / failed scrape): career-cumulative specialty
    # × the currency ratio, so a rider in decline ranks lower than their lifetime
    # numbers alone would suggest.
    #
    # Standardise a raw specialty vector to a z-score using ONLY the riders who
    # actually have data (raw>0) to set μ/σ: the many domestiques with none would
    # otherwise drag the mean down and inflate the sd, compressing genuine
    # specialists toward the pack. Riders with no data still receive the resulting
    # (negative) z, which correctly ranks them below the field.
    function _specialty_z(raw)
        logged = log1p.(max.(raw, 0.0))
        has_data = raw .> 0.0
        ref = count(has_data) >= 2 ? logged[has_data] : logged
        μ = mean(ref)
        σ = std(ref)
        σ > 0 ? (logged .- μ) ./ σ : zeros(length(raw))
    end

    pcs_cols = (:sprint, :oneday, :climber, :tt, :gc)
    pcs_z = Dict{Symbol,Vector{Float64}}()
    for col in pcs_cols
        recency_col = Symbol(col, "_r")
        has_career = col in propertynames(df)
        career_z =
            has_career ?
            _specialty_z(Float64.(coalesce.(df[!, col], 0.0)) .* sig.rider_currency) :
            nothing

        if recency_col in propertynames(df)
            # Splice on the z-SCALE, not the raw scale: recency scores (decayed
            # per-season sums) and career scores (all-time totals) are different
            # magnitudes, so mixing raw values in one z-score would bias fallback
            # riders. Standardise each separately, then take the recency z where a
            # rider has one and the career z where the scrape failed (`missing`).
            rcol = df[!, recency_col]
            rec_z = _specialty_z([ismissing(v) ? 0.0 : Float64(v) for v in rcol])
            pcs_z[col] = [
                ismissing(rcol[i]) ? (career_z === nothing ? 0.0 : career_z[i]) : rec_z[i] for i = 1:n_riders
            ]
        elseif career_z !== nothing
            pcs_z[col] = career_z
        else
            pcs_z[col] = zeros(n_riders)
        end
    end

    D = length(STRENGTH_DIMENSIONS)

    # --- Dimension-aware market mask (Issue A) ---
    # A dimension is "market-informed" iff some market signal present in this race
    # routes to it *materially*. The double-counting discount (`market_discount`)
    # then applies per dimension: full weight kept on dimensions no market touches
    # (notably :itt, which has no market at all → PCS-TT stays sharp).
    #
    # The materiality threshold matters: markets cross-route weakly into adjacent
    # dimensions (odds_gc → kom 0.1, hilly 0.05) as a small correction, but that
    # trickle does NOT replace the primary PCS signal there, so discounting the
    # whole dimension 8× on the strength of it collapses (e.g.) KOM toward the
    # prior for the entire field whenever GC odds exist — defeating the point of
    # a separate KOM channel. Only mark a dimension when a market's routing weight
    # to it is ≥ MARKET_DIM_THRESHOLD (0.3): keeps odds_points→flat (0.4),
    # odds_gc→{mountain 0.5, gc 1.0} and odds_kom→kom (1.0), but not the 0.05/0.1
    # cross-routes.
    market_dims = fill(false, D)
    _mark_dims!(mask, wnt) =
        for (d, dsym) in enumerate(STRENGTH_DIMENSIONS)
            getfield(wnt, dsym) >= MARKET_DIM_THRESHOLD && (mask[d] = true)
        end
    if !isempty(sig.odds_lookup) || !isempty(sig.oracle_lookup)
        _mark_dims!(market_dims, SIGNAL_DIMENSION_WEIGHTS.odds_gc)
    end
    if !isempty(sig.points_odds_lookup) || !isempty(sig.points_oracle_lookup)
        _mark_dims!(market_dims, SIGNAL_DIMENSION_WEIGHTS.odds_points)
    end
    if !isempty(sig.kom_odds_lookup) || !isempty(sig.kom_oracle_lookup)
        _mark_dims!(market_dims, SIGNAL_DIMENSION_WEIGHTS.odds_kom)
    end
    if !isempty(sig.stagewin_odds_lookup)
        # Stage-win routing is per-rider class (RACE_HISTORY_CLASS_PROJECTION),
        # so the market-informed set is the union of dimensions any class routes
        # to materially — including :kom (climber 0.7) and :mountain (climber
        # 0.7), which the old hardcoded flat/hilly/mountain/gc list missed while
        # still applying the stage-win signal there.
        for proj in values(RACE_HISTORY_CLASS_PROJECTION)
            _mark_dims!(market_dims, proj)
        end
    end

    # --- Per-rider estimation ---
    means_per_dim = [Vector{Float64}(undef, n_riders) for _ = 1:D]
    vars_per_dim = [Vector{Float64}(undef, n_riders) for _ = 1:D]
    shifts_storage = Dict{Symbol,Vector{Vector{Float64}}}()
    precisions_storage = Dict{Symbol,Vector{Vector{Float64}}}()
    for sig_key in SIGNAL_KEYS_MULTIDIM
        shifts_storage[sig_key] = Vector{Vector{Float64}}(undef, n_riders)
        precisions_storage[sig_key] = Vector{Vector{Float64}}(undef, n_riders)
    end

    for i = 1:n_riders
        key = df.riderkey[i]

        hist = get(sig.history_lookup, key, Tuple{Float64,Int,Float64}[])
        hist_strengths = Float64[h[1] for h in hist]
        hist_years = Int[h[2] for h in hist]
        hist_penalties = Float64[h[3] for h in hist]

        vg_hist = get(sig.vg_history_lookup, key, Tuple{Float64,Int}[])
        vg_hist_strengths = Float64[h[1] for h in vg_hist]
        vg_hist_years = Int[h[2] for h in vg_hist]

        gt_vg_hist = get(sig.gt_vg_history_lookup, key, Tuple{Float64,Int}[])
        gt_vg_hist_z = Float64[h[1] for h in gt_vg_hist]
        gt_vg_hist_years = Int[h[2] for h in gt_vg_hist]

        pts_hist = get(sig.points_history_lookup, key, Tuple{Float64,Int,Float64}[])
        kom_hist = get(sig.kom_history_lookup, key, Tuple{Float64,Int,Float64}[])

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
            has_pcs = sig.has_pcs[i],
            pcs_sprint_z = pcs_z[:sprint][i],
            pcs_oneday_z = pcs_z[:oneday][i],
            pcs_climber_z = pcs_z[:climber][i],
            pcs_tt_z = pcs_z[:tt][i],
            pcs_gc_z = pcs_z[:gc][i],
            rider_class = sig.classes[i],
            race_history = hist_strengths,
            race_history_years_ago = hist_years,
            race_history_variance_penalties = hist_penalties,
            vg_points = sig.vg_z[i],
            vg_race_history = vg_hist_strengths,
            vg_race_history_years_ago = vg_hist_years,
            gt_vg_history = gt_vg_hist_z,
            gt_vg_history_years_ago = gt_vg_hist_years,
            points_history = Float64[h[1] for h in pts_hist],
            points_history_years_ago = Int[h[2] for h in pts_hist],
            points_history_penalties = Float64[h[3] for h in pts_hist],
            kom_history = Float64[h[1] for h in kom_hist],
            kom_history_years_ago = Int[h[2] for h in kom_hist],
            kom_history_penalties = Float64[h[3] for h in kom_hist],
            odds_implied_prob = odds_prob,
            oracle_implied_prob = oracle_prob,
            points_oracle_implied_prob = points_prob,
            kom_oracle_implied_prob = kom_prob,
            points_odds_implied_prob = points_odds_prob,
            kom_odds_implied_prob = kom_odds_prob,
            stagewin_odds_implied_prob = stagewin_odds_prob,
            odds_floor_strength = odds_floor,
            oracle_floor_strength = oracle_floor,
            points_oracle_floor_strength = points_floor,
            kom_oracle_floor_strength = kom_floor,
        )

        est = estimate_rider_strength_multidim(
            signals;
            n_starters = n_starters,
            config = config,
            effective_vg_variance = sig.effective_vg_variance,
            race_has_market = sig.race_has_market,
            market_dims = market_dims,
        )

        for d = 1:D
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
            for d = 1:D
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
        df[!, Symbol("strength_$dsym")] = round.(means_per_dim[d], digits = 3)
        df[!, Symbol("uncertainty_$dsym")] = round.(sqrt.(vars_per_dim[d]), digits = 3)
    end

    # --- Back-compat: scalar :strength and :uncertainty alias :gc dim ---
    gc_idx = _DIM_INDEX[:gc]
    df[!, :strength] = round.(means_per_dim[gc_idx], digits = 3)
    df[!, :uncertainty] = round.(sqrt.(vars_per_dim[gc_idx]), digits = 3)

    # --- Signal availability flags ---
    df[!, :has_pcs] = sig.has_pcs
    df[!, :has_race_history] =
        [haskey(sig.history_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_vg_history] =
        [haskey(sig.vg_history_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_odds] = [haskey(sig.odds_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_oracle] = [haskey(sig.oracle_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_points_oracle] =
        [haskey(sig.points_oracle_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_kom_oracle] =
        [haskey(sig.kom_oracle_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_points_odds] =
        [haskey(sig.points_odds_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_kom_odds] = [haskey(sig.kom_odds_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_stagewin_odds] =
        [haskey(sig.stagewin_odds_lookup, df.riderkey[i]) for i = 1:n_riders]
    df[!, :has_qualitative] = falses(n_riders)
    df[!, :has_form] = falses(n_riders)
    df[!, :has_seasons] = [haskey(sig.currency_factors, df.riderkey[i]) for i = 1:n_riders]

    # --- Per-signal shift columns (L2 norm across dims for each signal) ---
    _norm(v) = sqrt(sum(x^2 for x in v))
    df[!, :shift_pcs] =
        round.([_norm(shifts_storage[:pcs][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_vg] =
        round.([_norm(shifts_storage[:vg][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_form] =
        round.([_norm(shifts_storage[:form][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_history] =
        round.([_norm(shifts_storage[:history][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_vg_history] =
        round.([_norm(shifts_storage[:vg_history][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_oracle] =
        round.([_norm(shifts_storage[:oracle_gc][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_oracle_points] =
        round.([_norm(shifts_storage[:oracle_points][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_oracle_kom] =
        round.([_norm(shifts_storage[:oracle_kom][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_qualitative] =
        round.([_norm(shifts_storage[:qualitative][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_odds] =
        round.([_norm(shifts_storage[:odds][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_odds_points] =
        round.([_norm(shifts_storage[:odds_points][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_odds_kom] =
        round.([_norm(shifts_storage[:odds_kom][i]) for i = 1:n_riders], digits = 3)
    df[!, :shift_odds_stagewin] =
        round.([_norm(shifts_storage[:odds_stagewin][i]) for i = 1:n_riders], digits = 3)

    # --- Per-(signal, dim) shift columns: shift_<signal>_<dim> ---
    # Used by reports' per-dimension signal panel.
    for sig_key in keys(shifts_storage), (d, dsym) in enumerate(STRENGTH_DIMENSIONS)
        col = Symbol("shift_$(sig_key)_$(dsym)")
        df[!, col] = round.([shifts_storage[sig_key][i][d] for i = 1:n_riders], digits = 3)
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
        [sum(precisions_storage[s][i][d] for s in sig_keys) for d = 1:D] for i = 1:n_riders
    ]
    total_prec_overall = [sum(total_prec_by_dim[i]) for i = 1:n_riders]
    for sig_key in sig_keys
        sig_totals = [sum(precisions_storage[sig_key][i]) for i = 1:n_riders]
        df[!, Symbol("info_share_$(sig_key)")] = round.(
            [
                total_prec_overall[i] > 0 ? sig_totals[i] / total_prec_overall[i] : 0.0
                for i = 1:n_riders
            ],
            digits = 4,
        )
        for (d, dsym) in enumerate(STRENGTH_DIMENSIONS)
            df[!, Symbol("info_share_$(sig_key)_$(dsym)")] = round.(
                [
                    total_prec_by_dim[i][d] > 0 ?
                    precisions_storage[sig_key][i][d] / total_prec_by_dim[i][d] : 0.0
                    for i = 1:n_riders
                ],
                digits = 4,
            )
        end
    end
    # Alias: :info_share_oracle mirrors :info_share_oracle_gc (matches the
    # existing :shift_oracle alias). Lets the waterfall use a single oracle
    # column name across scalar and multidim pipelines.
    df[!, :info_share_oracle] = df[!, :info_share_oracle_gc]

    df[!, :domestique_penalty] = round.(domestique_penalties, digits = 3)

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
    race_history_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
    oracle_df::Union{DataFrame,Nothing} = nothing,
    points_oracle_df::Union{DataFrame,Nothing} = nothing,
    kom_oracle_df::Union{DataFrame,Nothing} = nothing,
    points_odds_df::Union{DataFrame,Nothing} = nothing,
    kom_odds_df::Union{DataFrame,Nothing} = nothing,
    stagewin_odds_df::Union{DataFrame,Nothing} = nothing,
    vg_history_df::Union{DataFrame,Nothing} = nothing,
    points_history_df::Union{DataFrame,Nothing} = nothing,
    kom_history_df::Union{DataFrame,Nothing} = nothing,
    gt_vg_history_df::Union{DataFrame,Nothing} = nothing,
    qualitative_df::Union{DataFrame,Nothing} = nothing,
    form_df::Union{DataFrame,Nothing} = nothing,
    seasons_df::Union{DataFrame,Nothing} = nothing,
    race_type::Symbol = :oneday,
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing} = nothing,
    race_date::Union{Date,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    force_enable::Set{Symbol} = Set{Symbol}(),
)
    # Stage races: route to multidim path
    if race_type == :stage
        return _estimate_strengths_multidim(
            rider_df;
            race_history_df = race_history_df,
            odds_df = odds_df,
            oracle_df = oracle_df,
            points_oracle_df = points_oracle_df,
            kom_oracle_df = kom_oracle_df,
            points_odds_df = points_odds_df,
            kom_odds_df = kom_odds_df,
            stagewin_odds_df = stagewin_odds_df,
            vg_history_df = vg_history_df,
            points_history_df = points_history_df,
            kom_history_df = kom_history_df,
            gt_vg_history_df = gt_vg_history_df,
            seasons_df = seasons_df,
            config = config,
            race_year = race_year,
            race_date = race_date,
            domestique_discount = domestique_discount,
        )
    end

    df = copy(rider_df)
    sig = _assemble_signals(
        df;
        race_history_df = race_history_df,
        odds_df = odds_df,
        oracle_df = oracle_df,
        # VG race history disabled in April 2026 ablation; ignore caller's vg_history_df
        vg_history_df = nothing,
        seasons_df = seasons_df,
        config = config,
        race_year = race_year,
        race_date = race_date,
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
            # Only seasons up to the race year (temporal integrity for backtests
            # / re-runs; see the currency-factor block above).
            rows = [r for r in eachrow(g) if r.year <= current_year]
            isempty(rows) && continue
            weights =
                [exp(-config.pcs_season_decay * (current_year - r.year)) for r in rows]
            weighted_pts =
                sum(w * r.pcs_points for (w, r) in zip(weights, rows)) / sum(weights)
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
        s => Vector{Float64}(undef, n_riders) for s in SIGNAL_KEYS
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
                pcs_score = pcs_z[i],
                has_pcs = sig.has_pcs[i],
                race_history = hist_strengths,
                race_history_years_ago = hist_years,
                race_history_variance_penalties = hist_penalties,
                vg_points = sig.vg_z[i],
                form_score = form_val,
                vg_race_history = vg_hist_strengths,
                vg_race_history_years_ago = vg_hist_years,
                odds_implied_prob = odds_prob,
                oracle_implied_prob = oracle_prob,
                odds_floor_strength = odds_floor,
                oracle_floor_strength = oracle_floor,
                form_floor_strength = form_floor,
                qualitative_floor_strength = qual_floor,
                qualitative_adjustments = qual_adjs,
                qualitative_confidences = qual_confs,
            );
            n_starters = n_starters,
            config = config,
            effective_vg_variance = sig.effective_vg_variance,
            race_has_market = sig.race_has_market,
            force_enable = force_enable,
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
    df[!, :strength] = round.(strengths, digits = 3)
    df[!, :uncertainty] = round.(uncertainties, digits = 3)

    df[!, :has_pcs] = sig.has_pcs
    df[!, :has_race_history] = has_race_history
    df[!, :has_vg_history] = falses(n_riders)
    df[!, :has_odds] = has_odds
    df[!, :has_oracle] = has_oracle
    df[!, :has_qualitative] = has_qualitative
    df[!, :has_form] = has_form
    df[!, :has_seasons] = has_seasons

    # --- Per-signal mean shifts (for diagnostics) ---
    df[!, :shift_pcs] = round.(shifts_pcs, digits = 3)
    df[!, :shift_vg] = round.(shifts_vg, digits = 3)
    df[!, :shift_form] = round.(shifts_form, digits = 3)
    df[!, :shift_history] = round.(shifts_history, digits = 3)
    df[!, :shift_vg_history] = round.(shifts_vg_history, digits = 3)
    df[!, :shift_oracle] = round.(shifts_oracle, digits = 3)
    df[!, :shift_qualitative] = round.(shifts_qualitative, digits = 3)
    df[!, :shift_odds] = round.(shifts_odds, digits = 3)

    # --- Order-invariant info-share columns (one-day scalar path) ---
    # info_share_<signal> = signal_precision / total_observed_precision per rider.
    sig_keys_scalar = collect(keys(precisions_storage))
    total_prec_per_rider =
        [sum(precisions_storage[s][i] for s in sig_keys_scalar) for i = 1:n_riders]
    for sig_key in sig_keys_scalar
        df[!, Symbol("info_share_$(sig_key)")] = round.(
            [
                total_prec_per_rider[i] > 0 ?
                precisions_storage[sig_key][i] / total_prec_per_rider[i] : 0.0 for
                i = 1:n_riders
            ],
            digits = 4,
        )
    end

    df[!, :domestique_penalty] = round.(domestique_penalties, digits = 3)

    return df
end


"""
    estimate_strengths(data::RaceData; kwargs...) -> DataFrame

Convenience method that unpacks `RaceData` fields.
"""
function estimate_strengths(
    data::RaceData;
    race_type::Symbol = :oneday,
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing} = nothing,
    race_date::Union{Date,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    force_enable::Set{Symbol} = Set{Symbol}(),
)
    estimate_strengths(
        data.rider_df;
        race_history_df = data.race_history_df,
        odds_df = data.odds_df,
        oracle_df = data.oracle_df,
        points_oracle_df = data.points_oracle_df,
        kom_oracle_df = data.kom_oracle_df,
        points_odds_df = data.points_odds_df,
        kom_odds_df = data.kom_odds_df,
        stagewin_odds_df = data.stagewin_odds_df,
        vg_history_df = data.vg_history_df,
        points_history_df = data.points_history_df,
        kom_history_df = data.kom_history_df,
        gt_vg_history_df = data.gt_vg_history_df,
        qualitative_df = data.qualitative_df,
        form_df = data.form_df,
        seasons_df = data.seasons_df,
        race_type = race_type,
        config = config,
        race_year = race_year,
        race_date = race_date,
        domestique_discount = domestique_discount,
        force_enable = force_enable,
    )
end


# Keyword convenience wrapper — forwards all RiderSignalData fields plus race-level context.
function estimate_rider_strength(;
    n_starters::Int = 150,
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    effective_vg_variance::Float64 = 0.0,
    race_has_market::Bool = false,
    skip_block_correlation::Bool = false,
    force_enable::Set{Symbol} = Set{Symbol}(),
    kwargs...,
)
    estimate_rider_strength(
        RiderSignalData(; kwargs...);
        n_starters = n_starters,
        config = config,
        effective_vg_variance = effective_vg_variance,
        race_has_market = race_has_market,
        skip_block_correlation = skip_block_correlation,
        force_enable = force_enable,
    )
end

"""
    predict_expected_points(rider_df, scoring; kwargs...) -> DataFrame

Backtest entry point: estimates strengths then runs MC simulation to
compute expected VG points. Used by backtesting where we need expected points
without team optimisation.
"""
function predict_expected_points(
    rider_df::DataFrame,
    scoring::ScoringTable;
    race_history_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
    oracle_df::Union{DataFrame,Nothing} = nothing,
    vg_history_df::Union{DataFrame,Nothing} = nothing,
    qualitative_df::Union{DataFrame,Nothing} = nothing,
    form_df::Union{DataFrame,Nothing} = nothing,
    seasons_df::Union{DataFrame,Nothing} = nothing,
    n_sims::Int = 10000,
    race_type::Symbol = :oneday,
    rng::AbstractRNG = Random.default_rng(),
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing} = nothing,
    race_date::Union{Date,Nothing} = nothing,
    simulation_df::Union{Int,Nothing} = nothing,
    risk_aversion::Float64 = 0.0,
    domestique_discount::Float64 = 0.0,
    total_distance_km::Float64 = 0.0,
    force_enable::Set{Symbol} = Set{Symbol}(),
)
    df = estimate_strengths(
        rider_df;
        race_history_df = race_history_df,
        odds_df = odds_df,
        oracle_df = oracle_df,
        vg_history_df = vg_history_df,
        qualitative_df = qualitative_df,
        form_df = form_df,
        seasons_df = seasons_df,
        race_type = race_type,
        config = config,
        race_year = race_year,
        race_date = race_date,
        domestique_discount = domestique_discount,
        force_enable = force_enable,
    )

    # MC simulation for expected points (used by backtesting)
    n_riders = nrow(df)
    strengths = Float64.(df.strength)
    uncertainties = Float64.(df.uncertainty)

    sim_positions = simulate_race(
        strengths,
        uncertainties;
        n_sims = n_sims,
        rng = rng,
        simulation_df = simulation_df,
    )

    teams = String.(df.team)
    evg, dsd = expected_vg_points(sim_positions, teams, scoring)
    df[!, :expected_vg_points] = round.(evg, digits = 1)
    df[!, :downside_semi_dev] = round.(dsd, digits = 1)

    return df
end

function predict_expected_points(
    data::RaceData,
    scoring::ScoringTable;
    n_sims::Int = 10000,
    race_type::Symbol = :oneday,
    rng::AbstractRNG = Random.default_rng(),
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    race_year::Union{Int,Nothing} = nothing,
    race_date::Union{Date,Nothing} = nothing,
    simulation_df::Union{Int,Nothing} = nothing,
    risk_aversion::Float64 = 0.0,
    domestique_discount::Float64 = 0.0,
    total_distance_km::Float64 = 0.0,
    force_enable::Set{Symbol} = Set{Symbol}(),
)
    predict_expected_points(
        data.rider_df,
        scoring;
        race_history_df = data.race_history_df,
        odds_df = data.odds_df,
        oracle_df = data.oracle_df,
        vg_history_df = data.vg_history_df,
        qualitative_df = data.qualitative_df,
        form_df = data.form_df,
        seasons_df = data.seasons_df,
        n_sims = n_sims,
        race_type = race_type,
        rng = rng,
        config = config,
        race_year = race_year,
        race_date = race_date,
        simulation_df = simulation_df,
        risk_aversion = risk_aversion,
        domestique_discount = domestique_discount,
        total_distance_km = total_distance_km,
        force_enable = force_enable,
    )
end
