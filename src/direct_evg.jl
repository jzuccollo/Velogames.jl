# ---------------------------------------------------------------------------
# Direct-EVG challenger (WP2.2, July 2026)
# ---------------------------------------------------------------------------

"""
Direct-EVG challenger — predicts each rider's expected VG total for a grand
tour directly, without the per-stage simulator. See docs/architecture-review.md
§5 and docs/remediation-plan.md WP2.2. Option B's learner
(`gt_propensity_factors`) promoted from correction layer to model, with the
market added as a first-class component.

## Model

Per rider, a log-space shrunken convex blend over the components the rider
actually has:

    log(EVG_i + c) = Σ_k w_ik·log(component_ik + c) / Σ_k w_ik
    EVG_i = max(exp(·) − c, 0)

- **Ability-implied points** (weight 1, always available): the production
  multidim `estimate_strengths` posterior — the estimation core is NOT on
  trial, only the strength→points transform — reduced to a scalar ability
  score, ranked across the field, and mapped through the fitted
  rank→expected-VG-total curve.
- **Market-implied points** (weight `market_weight` when priced): riders
  ranked by their best overround-normalised implied win probability across
  the GC / points jersey / KOM bookmaker markets, mapped through the SAME
  curve. Unpriced riders (and marketless editions — all pre-2026 archives)
  simply lack the component.
- **Own GT history** (weight `hist_weight`·s_i): recency-decayed weighted mean
  of the rider's prior grand-tour VG totals (`data.gt_vg_history`), cross-GT
  editions included with the same decay (no separate cross-GT knob). Partial
  pooling à la `gt_propensity_factors`: s_i = W_i/(W_i+κ),
  W_i = Σ_e decay^years_ago, so the history weight grows with edition count
  and debutants get s_i = 0 (ability-only, exactly).

## Binding decisions (per the WP2.2 orchestrator brief)

1. **One curve serves both orderings.** The rank→expected-VG-total curve is
   fitted ONCE, on realised VG totals versus field rank pooled over the FIT
   editions, and consumed by both the ability rank and the market rank. No
   pre-2026 GT odds exist, so the plan's "market-rank→VG-total pairs" cannot
   be fitted directly; the curve captures the shape of VG totals by rank and
   the components differ only in which ordering they consume. Form: shifted
   power law `log(V+c) = a − k·log(rank + s)` — monotone decreasing by
   construction (a plain log-log line overshoots rank 1 ~6×, and a quadratic
   in log-rank is non-monotone at the top, both rejected on the fit editions).
2. **`market_weight` is FIXED a priori at 2.0, never fitted.** No fit or
   validation edition has a market, so it cannot be estimated (and must not
   be tuned on 2026 data). The 2:1 market:ability weight ratio mirrors the
   one-day model's `market_precision_scale = 4.0` vs ability 1.0 evidence
   base — precision ratio 4 ⇒ weight ratio 2 as a stated prior choice.
3. **Free parameters: 7 total** (≤8 budget): `curve_a`, `curve_k`, `curve_s`
   (rank curve), `floor` (c), `hist_decay`, `hist_kappa` (κ), `hist_weight`.
   `market_weight` is a fixed prior, not fitted.
4. **Fitting protocol.** Fit on the 2023+2024 editions (6 GTs), validate on
   2025 (3 GTs); 2026 editions are evaluation-only and no 2026 outcome is
   read during fitting or model selection. Loss: log-space MSE against actual
   totals, evaluated at a FIXED reference floor of 30 VG points (the
   `gt_propensity_factors` value) — using the model floor in the loss would
   let a large `floor` compress log-space and shrink the MSE trivially.
   Optimiser: coarse grid then coordinate-descent refinement
   (`fit_direct_evg`). Model-selection decisions (curve form, ability
   composite, cross-GT rows) were made on the 2023–2024 fit and 2025
   validation only.

`DEFAULT_DIRECT_EVG_PARAMS` holds the fitted values.
"""
struct DirectEVGParams
    curve_a::Float64        # rank curve level, log(V+floor) space
    curve_k::Float64        # rank curve power-law exponent (positive)
    curve_s::Float64        # rank curve shift (flattens the top ranks)
    floor::Float64          # log-space floor c, in VG points
    hist_decay::Float64     # per-year recency decay on GT history weights
    hist_kappa::Float64     # partial-pooling shrinkage κ for history weight
    hist_weight::Float64    # max blend weight of history (ability = 1)
    market_weight::Float64  # blend weight when priced — FIXED at 2.0, not fitted
end

_rank_curve_log(rank::Real, p::DirectEVGParams) =
    p.curve_a - p.curve_k * log(rank + p.curve_s)

"""
    _direct_evg_inputs(data::StageRaceBacktestData) -> NamedTuple

Precompute the parameter-independent per-rider inputs: ability rank (from the
production multidim strength estimate), market rank (0 = unpriced), and the
prior GT VG history list `(score, years_ago)`. Split from `_evg_from_inputs`
so `fit_direct_evg` runs `estimate_strengths` once per edition, not once per
grid point.
"""
function _direct_evg_inputs(data::StageRaceBacktestData)
    est = estimate_strengths(
        data.race_data;
        race_type = :stage,
        race_year = data.year,
    )
    riderkeys = String.(est.riderkey)
    n = length(riderkeys)

    # Ability score: mean of the six dimension posterior means. Chosen over
    # gc-only and max-of-dims on the 2025 validation: max wins the full-field
    # Spearman on the fit editions (0.466 vs 0.410 vs 0.304) but mean wins the
    # primary team-points-captured metric decisively (0.578 vs 0.385 mean
    # across the 2025 editions) and the fit-edition top-20 ordering (0.551 vs
    # 0.499), which is where the optimiser lives.
    dim_cols = [Symbol("strength_", d) for d in STRENGTH_DIMENSIONS]
    ability = vec(mean(Matrix{Float64}(est[:, dim_cols]); dims = 2))
    ability_rank = Vector{Int}(undef, n)
    ability_rank[sortperm(ability; rev = true)] = 1:n

    # Market rank: best overround-normalised implied probability across the
    # GC / points / KOM winner markets; rank among priced riders, 0 = unpriced.
    best_prob = Dict{String,Float64}()
    for odds_df in
        (data.race_data.odds_df, data.race_data.points_odds_df, data.race_data.kom_odds_df)
        odds_df === nothing && continue
        :odds in propertynames(odds_df) || continue
        probs = 1.0 ./ Float64.(odds_df.odds)
        probs ./= sum(probs)
        for (i, key) in enumerate(String.(odds_df.riderkey))
            probs[i] > get(best_prob, key, 0.0) && (best_prob[key] = probs[i])
        end
    end
    market_rank = zeros(Int, n)
    priced = [i for i = 1:n if haskey(best_prob, riderkeys[i])]
    order = sort(priced; by = i -> -best_prob[riderkeys[i]])
    for (r, i) in enumerate(order)
        market_rank[i] = r
    end

    # GT VG history: (score, years_ago) per rider, cross-GT rows included.
    hist = [Tuple{Float64,Int}[] for _ = 1:n]
    idx = Dict(k => i for (i, k) in enumerate(riderkeys))
    if data.gt_vg_history !== nothing
        for row in eachrow(data.gt_vg_history)
            i = get(idx, String(row.riderkey), 0)
            i == 0 && continue
            push!(hist[i], (max(0.0, Float64(row.score)), data.year - Int(row.year)))
        end
    end

    return (; riderkeys, ability_rank, market_rank, hist)
end

"""Blend the precomputed inputs into expected VG points under `params`."""
function _evg_from_inputs(inputs, p::DirectEVGParams)
    n = length(inputs.riderkeys)
    evg = Vector{Float64}(undef, n)
    for i = 1:n
        num = _rank_curve_log(inputs.ability_rank[i], p)
        den = 1.0
        if inputs.market_rank[i] > 0
            num += p.market_weight * _rank_curve_log(inputs.market_rank[i], p)
            den += p.market_weight
        end
        h = inputs.hist[i]
        if !isempty(h)
            W = 0.0
            hsum = 0.0
            for (score, years_ago) in h
                w = p.hist_decay^years_ago
                W += w
                hsum += w * score
            end
            wh = p.hist_weight * W / (W + p.hist_kappa)
            num += wh * log(hsum / W + p.floor)
            den += wh
        end
        evg[i] = max(exp(num / den) - p.floor, 0.0)
    end
    return evg
end

"""
    direct_evg(data::StageRaceBacktestData;
               params::DirectEVGParams = DEFAULT_DIRECT_EVG_PARAMS)
        -> DataFrame(riderkey, expected_vg_points)

The direct-EVG challenger predictor (plugs into the WP2.1 harness alongside
`champion_evg`). Reads only pre-race inputs from `data` — never
`riders.actual_total` or the classification results.
"""
function direct_evg(
    data::StageRaceBacktestData;
    params::DirectEVGParams = DEFAULT_DIRECT_EVG_PARAMS,
)
    inputs = _direct_evg_inputs(data)
    return DataFrame(
        riderkey = inputs.riderkeys,
        expected_vg_points = _evg_from_inputs(inputs, params),
    )
end

# Fixed reference floor for the fitting loss (see docstring decision 4).
const _EVG_LOSS_FLOOR = 30.0

function _evg_loss(inputs_actuals, p::DirectEVGParams)
    sse = 0.0
    n = 0
    for (inputs, actual) in inputs_actuals
        evg = _evg_from_inputs(inputs, p)
        for i in eachindex(actual)
            sse += (log(evg[i] + _EVG_LOSS_FLOOR) - log(actual[i] + _EVG_LOSS_FLOOR))^2
        end
        n += length(actual)
    end
    return sse / n
end

"""Fit the rank→expected-VG-total curve on pooled (field rank, actual total)
pairs from the fit editions: `log(V+floor) = a − k·log(rank + s)`, with `s` on
a grid and (a, k) by closed-form OLS given `s` (docstring decision 1)."""
function _fit_rank_curve(actuals::Vector{Vector{Float64}}, floor::Float64)
    ranks = Int[]
    ys = Float64[]
    for actual in actuals
        for (r, v) in enumerate(sort(actual; rev = true))
            push!(ranks, r)
            push!(ys, log(v + floor))
        end
    end
    best = (Inf, 0.0, 0.0, 0.0)
    for s in
        (0.0, 1.0, 2.0, 4.0, 8.0, 16.0, 24.0, 32.0, 48.0, 64.0, 96.0, 128.0, 192.0, 256.0)
        xs = log.(ranks .+ s)
        b = cov(xs, ys) / var(xs)
        a = mean(ys) - b * mean(xs)
        sse = sum(abs2, ys .- (a .+ b .* xs))
        sse < best[1] && (best = (sse, a, -b, s))
    end
    return best[2], best[3], best[4]   # a, k, s
end

function _fit_direct_evg_core(inputs_actuals)
    actuals = [ia[2] for ia in inputs_actuals]

    make(floor, decay, kappa, weight) = begin
        a, k, s = _fit_rank_curve(actuals, floor)
        DirectEVGParams(a, k, s, floor, decay, kappa, weight, 2.0)
    end

    # The (hist_kappa, hist_weight) grids deliberately reach into the large-κ
    # regime: for W ≪ κ the history weight is ≈ (weight/κ)·W — proportional to
    # edition count with no saturation — and both the fit and the 2025
    # validation prefer that end of the ridge. Bounds are documented here and
    # enforced in refinement rather than left to open-ended drift.
    best = nothing
    best_loss = Inf
    for floor in (10.0, 20.0, 30.0, 50.0, 75.0, 100.0),
        decay in (0.5, 0.6, 0.7, 0.8, 0.9, 1.0),
        kappa in (0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 8.0, 12.0),
        weight in (0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 9.0, 14.0)

        p = make(floor, decay, kappa, weight)
        loss = _evg_loss(inputs_actuals, p)
        if loss < best_loss
            best_loss = loss
            best = p
        end
    end

    # Coordinate-descent refinement around the coarse optimum (±10/20%),
    # clamped to the coarse-grid bounds.
    refine(v, lo, hi) = unique(clamp.(v .* (0.8, 0.9, 1.0, 1.1, 1.2), lo, hi))
    for _ = 1:4
        improved = false
        for floor in refine(best.floor, 10.0, 100.0),
            decay in refine(best.hist_decay, 0.5, 1.0),
            kappa in refine(best.hist_kappa, 0.25, 12.0),
            weight in refine(best.hist_weight, 0.5, 14.0)

            p = make(floor, decay, kappa, weight)
            loss = _evg_loss(inputs_actuals, p)
            if loss < best_loss - 1e-9
                best_loss = loss
                best = p
                improved = true
            end
        end
        improved || break
    end

    @info "fit_direct_evg: loss=$(round(best_loss; digits=4)) on " *
          "$(sum(length.(actuals))) rider-editions; curve=(a=$(round(best.curve_a; digits=3)), " *
          "k=$(round(best.curve_k; digits=3)), s=$(round(best.curve_s; digits=2))), " *
          "floor=$(round(best.floor; digits=1)), decay=$(round(best.hist_decay; digits=3)), " *
          "kappa=$(round(best.hist_kappa; digits=3)), hist_weight=$(round(best.hist_weight; digits=3))"
    return best
end

"""
    fit_direct_evg(datas::Vector{StageRaceBacktestData}) -> DirectEVGParams

Reproducible fitting entry point. `datas` must be the FIT editions only
(2023+2024 per the WP2.2 protocol) — this function reads `actual_total`.
For each candidate floor the rank curve is refitted in closed form, then
(floor, hist_decay, hist_kappa, hist_weight) are grid-searched coarse-to-fine
on the log-space MSE at the fixed reference floor. `market_weight` stays at
its a-priori 2.0 throughout (decision 2; the fit editions are marketless, so
the loss is flat in it by construction).
"""
function fit_direct_evg(datas::Vector{StageRaceBacktestData})
    inputs_actuals =
        [(_direct_evg_inputs(d), Float64.(d.riders.actual_total)) for d in datas]
    return _fit_direct_evg_core(inputs_actuals)
end

# Fitted by `fit_direct_evg` on Giro/Tour/Vuelta 2023+2024 (six editions,
# 1,043 rider-editions; log-space MSE 1.2289 at the reference floor), validated
# on the 2025 editions — see the WP2.2 commit message for the validation table.
# Full-precision values so the constant is exactly the fit output. Note the
# fitted (hist_kappa, hist_weight) sit at the large-κ end of the ridge: with
# W ≤ ~4 the effective history weight is ≈ 1.55·W, i.e. near-proportional to
# (decayed) edition count, which both the fit and the 2025 validation prefer
# to a strongly saturating weight.
const DEFAULT_DIRECT_EVG_PARAMS = DirectEVGParams(
    14.000775474814532,   # curve_a
    1.8275218106520676,   # curve_k
    32.0,                 # curve_s
    69.11999999999999,    # floor
    0.66,                 # hist_decay
    8.743558348800004,    # hist_kappa
    13.552000000000003,   # hist_weight
    2.0,                  # market_weight (fixed prior)
)

# Register the challenger as a standing harness predictor (WP2.3 memo: retained
# as the standing comparator). Runs after backtest.jl's registry exists because
# Velogames.jl includes this file later.
_STAGE_PREDICTORS[:direct] = direct_evg
