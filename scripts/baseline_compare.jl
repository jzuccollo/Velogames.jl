#!/usr/bin/env julia
# ---------------------------------------------------------------------------
# baseline_compare.jl — naive-persistence baseline vs the model's optimal team
#
# A deliberately trivial yardstick for grand-tour (Tour de France) team
# selection. Each rider's *baseline* expected points is simply the mean of
# their actual VG points across the two prior Tours. We then run the SAME
# constrained optimiser the production model uses (`build_model_stage`) on that
# baseline column to get a "naive optimal team", and set it beside the model's
# archived optimal team.
#
# Two deliverables:
#   1. `compare_year(year)` — model-optimal vs baseline-optimal side by side,
#      scored under BOTH metrics (model EVG and baseline points). Read-only.
#   2. `baseline_backtest(year)` — temporally clean scaffold: build the baseline
#      team from the two PRIOR Tours only, score it against `year`'s ACTUAL
#      results, and (where an archived model prediction exists) report the
#      model's realised-points edge.
#
# Everything is self-contained here so it can later be promoted into
# `src/baseline.jl` once the working tree is quiet. Package functions are
# reached fully-qualified via `Velogames.foo`.
#
# Run:  julia --project scripts/baseline_compare.jl
# ---------------------------------------------------------------------------

using Velogames
using DataFrames
using JuMP
using Statistics
using Printf

const TOUR_VG_SLUG = "velogame"
const TOUR_PCS_SLUG = "tour-de-france"

vg_riders_url(year::Int) = "https://www.velogames.com/$TOUR_VG_SLUG/$year/riders.php"
archived_predictions(year::Int) = load_race_snapshot("predictions", TOUR_PCS_SLUG, year)

# ---------------------------------------------------------------------------
# 1. Baseline expected points per rider
# ---------------------------------------------------------------------------

"""
    prior_edition_scores(year; n_prior=2) -> Dict{String,Vector{Float64}}

Collect each rider's actual VG total from the `n_prior` Tours immediately
before `year` (matched by `riderkey`). A rider present in two editions gets a
two-element vector, present in one gets a one-element vector.
"""
function prior_edition_scores(year::Int; n_prior::Int = 2)
    scores = Dict{String,Vector{Float64}}()
    for py in (year-1):-1:(year-n_prior)
        tot = Velogames.getvg_stage_race_totals(py, TOUR_VG_SLUG)
        nrow(tot) == 0 && continue  # edition not run yet / unavailable
        for r in eachrow(tot)
            push!(get!(scores, r.riderkey, Float64[]), Float64(r.score))
        end
    end
    return scores
end

"""
    compute_baseline_points(universe, year; n_prior=2) -> Vector{Float64}

Baseline expected points for every rider in `universe` (needs `:riderkey` and
integer `:cost`), aligned to its rows.

- **With history:** the mean of the rider's actual VG points across whichever of
  the `n_prior` prior Tours they appear in (both → mean; one → that value).
- **Without history** (debutants etc.): imputed as the mean baseline of the
  riders *with* history sharing the same integer cost (cost-cohort mean).
- **Edge case** — a cost cohort with no historical rider (common at the top
  end, where every rider at that price may be a debutant): fall back to the
  nearest populated cost cohort (smallest absolute cost gap; ties broken towards
  the *lower* cost, the more conservative choice, and deterministically so). If
  there are no populated cohorts at all, the global mean over historical riders.
"""
function compute_baseline_points(universe::DataFrame, year::Int; n_prior::Int = 2)
    scores = prior_edition_scores(year; n_prior = n_prior)
    raw = Dict(k => mean(v) for (k, v) in scores)  # per-rider baseline (history only)

    has_hist = [haskey(raw, k) for k in universe.riderkey]
    hist_df = universe[has_hist, :]

    # Cost-cohort means over universe riders that have history.
    cohort_mean = Dict{Int,Float64}()
    for gdf in groupby(hist_df, :cost)
        cohort_mean[gdf.cost[1]] = mean(raw[k] for k in gdf.riderkey)
    end
    global_mean = isempty(raw) ? 0.0 : mean(raw[k] for k in universe.riderkey if haskey(raw, k))

    function impute(cost::Integer)
        haskey(cohort_mean, cost) && return cohort_mean[cost]
        isempty(cohort_mean) && return global_mean
        # sort ascending so a distance tie resolves to the lower (cheaper) cohort
        # and the result is deterministic (Dict key order is not).
        nearest = argmin(c -> abs(c - cost), sort(collect(keys(cohort_mean))))
        return cohort_mean[nearest]
    end

    return [
        haskey(raw, k) ? raw[k] : impute(universe.cost[i]) for
        (i, k) in enumerate(universe.riderkey)
    ]
end

# ---------------------------------------------------------------------------
# 2. Baseline optimal team (reuse the production constrained optimiser)
# ---------------------------------------------------------------------------

"""
    baseline_team(universe) -> DataFrame

Run the production stage-race optimiser (`build_model_stage`: 9 riders,
cost <= 100, VG Sixes class minimums) maximising `:baseline_points`, and return
the selected rider rows. `universe` needs `:riderkey`, `:cost`, a class column
(`:class` or `:classraw`) and `:baseline_points`.
"""
function baseline_team(universe::DataFrame)
    # build_model_stage optimises internally and returns JuMP.value.(x), a
    # DenseAxisArray indexed by riderkey.
    sol = Velogames.build_model_stage(universe, 9, :baseline_points, :cost)
    sol === nothing && error("Baseline optimisation was infeasible.")
    chosen = Set(k for k in universe.riderkey if sol[k] > 0.5)
    return filter(r -> r.riderkey in chosen, universe)
end

# ---------------------------------------------------------------------------
# 3. Comparison vs the model's optimal team (read-only against the archive)
# ---------------------------------------------------------------------------

"""
    load_universe(year) -> DataFrame

The comparison universe is the archived model prediction pool for `year` (has
`:riderkey`, `:cost`, `:expected_vg_points`, `:chosen`), with the class column
joined on from the live VG rider pool (the archive lacks `:classraw`).
`:baseline_points` is added.
"""
function load_universe(year::Int)
    arch = archived_predictions(year)
    arch === nothing && error(
        "No archived prediction for $TOUR_PCS_SLUG $year at " *
        archive_path("predictions", TOUR_PCS_SLUG, year),
    )
    pool = Velogames.getvg_riders(vg_riders_url(year))
    classcols = select(pool, :riderkey, :classraw, :class)
    universe = leftjoin(arch, classcols, on = :riderkey)
    universe.class = String.(coalesce.(universe.class, "unclassed"))
    universe.chosen = coalesce.(universe.chosen, false)
    universe.baseline_points = compute_baseline_points(universe, year)
    return universe
end

# small helpers for tidy stdout
_rule(w = 78) = println(repeat("-", w))
_hdr(t) = (println(); println(t); _rule())

function _print_team(title, team; evg = :expected_vg_points, base = :baseline_points)
    _hdr(title)
    @printf("%-28s %6s %10s %10s\n", "rider", "cost", "model EVG", "baseline")
    _rule()
    for r in sort(team, base, rev = true) |> eachrow
        @printf("%-28s %6d %10.1f %10.1f\n", first(r.rider, 28), r.cost, r[evg], r[base])
    end
    _rule()
    @printf("%-28s %6d %10.1f %10.1f\n", "TOTAL", sum(team.cost), sum(team[!, evg]), sum(team[!, base]))
end

"""
    compare_year(year=2026)

Print the model-optimal and baseline-optimal Tour teams side by side, their
roster overlap and divergences, and both teams scored under both metrics.
"""
function compare_year(year::Int = 2026)
    universe = load_universe(year)
    model_team = filter(r -> r.chosen, universe)
    base_team = baseline_team(universe)

    n_hist = count(k -> k in keys(prior_edition_scores(year)), universe.riderkey)
    println("\n", repeat("=", 78))
    println("MODEL vs NAIVE-PERSISTENCE BASELINE — Tour de France $year")
    println(repeat("=", 78))
    @printf(
        "Universe: %d riders (archived model pool). With prior-Tour history: %d; imputed: %d.\n",
        nrow(universe),
        n_hist,
        nrow(universe) - n_hist,
    )

    _print_team("MODEL-OPTIMAL TEAM (maximises model EVG)", model_team)
    _print_team("BASELINE-OPTIMAL TEAM (maximises last-two-Tours mean points)", base_team)

    # Overlap / divergence
    mk, bk = Set(model_team.riderkey), Set(base_team.riderkey)
    shared = intersect(mk, bk)
    _hdr("ROSTER OVERLAP")
    @printf("Shared riders: %d of 9\n", length(shared))
    keyname(df, k) = first(df[findfirst(==(k), df.riderkey), :rider], 30)
    if !isempty(shared)
        println("  in both:      ", join(sort([keyname(model_team, k) for k in shared]), ", "))
    end
    only_model = setdiff(mk, bk)
    only_base = setdiff(bk, mk)
    !isempty(only_model) &&
        println("  model only:   ", join(sort([keyname(model_team, k) for k in only_model]), ", "))
    !isempty(only_base) &&
        println("  baseline only:", join(sort([keyname(base_team, k) for k in only_base]), ", "))

    # Cross-scoring: each team under both metrics
    _hdr("TEAMS SCORED UNDER BOTH METRICS")
    @printf("%-26s %14s %16s\n", "team", "total model EVG", "total baseline pts")
    _rule()
    @printf("%-26s %14.1f %16.1f\n", "model-optimal", sum(model_team.expected_vg_points), sum(model_team.baseline_points))
    @printf("%-26s %14.1f %16.1f\n", "baseline-optimal", sum(base_team.expected_vg_points), sum(base_team.baseline_points))
    _rule()
    println("Reading: each column is that metric's best-vs-actual. The model team's")
    println("baseline-points total vs the baseline team's shows how much cheaper")
    println("persistence 'thinks' the model squad is, and vice versa.")

    # Eyeball the baseline column
    _hdr("BASELINE POINTS — TOP 30 RIDERS")
    top = first(sort(universe, :baseline_points, rev = true), 30)
    @printf("%-30s %6s %10s %10s\n", "rider", "cost", "baseline", "model EVG")
    _rule()
    for r in eachrow(top)
        @printf("%-30s %6d %10.1f %10.1f\n", first(r.rider, 30), r.cost, r.baseline_points, r.expected_vg_points)
    end

    return (; universe, model_team, base_team)
end

# ---------------------------------------------------------------------------
# 4. Backtest scaffolding — quantify the model's edge over time
# ---------------------------------------------------------------------------

"""
    baseline_backtest(year; n_prior=2)

Temporally clean backtest of the naive baseline (it only ever uses editions
before `year`):

  1. Build the baseline team for `year` from the `n_prior` prior Tours, over
     that year's VG rider pool.
  2. Score it against `year`'s ACTUAL VG totals.
  3. If an archived MODEL prediction exists for `year`, score the model team's
     realised points too and report `model_realised - baseline_realised`.
     Otherwise report the baseline only and note the model side becomes
     computable once predictions are archived.
"""
function baseline_backtest(year::Int; n_prior::Int = 2)
    println("\n", repeat("=", 78))
    println("BASELINE BACKTEST — Tour de France $year (baseline from prior $n_prior editions)")
    println(repeat("=", 78))

    pool = Velogames.getvg_riders(vg_riders_url(year))
    universe = select(pool, :rider, :riderkey, :team, :cost, :classraw, :class)
    universe.baseline_points = compute_baseline_points(universe, year; n_prior = n_prior)
    base_team = baseline_team(universe)

    actual = Velogames.getvg_stage_race_totals(year, TOUR_VG_SLUG)
    if nrow(actual) == 0
        println("No actual VG results for $year yet — cannot score. (Tour not run / not archived.)")
        return nothing
    end
    actual_pts = Dict(r.riderkey => Float64(r.score) for r in eachrow(actual))
    realised(keys) = sum(get(actual_pts, k, 0.0) for k in keys)

    base_realised = realised(base_team.riderkey)

    _hdr("BASELINE-OPTIMAL TEAM (built from prior editions only)")
    @printf("%-30s %6s %10s %12s\n", "rider", "cost", "baseline", "realised $year")
    _rule()
    for r in sort(base_team, :baseline_points, rev = true) |> eachrow
        @printf(
            "%-30s %6d %10.1f %12.1f\n",
            first(r.rider, 30),
            r.cost,
            r.baseline_points,
            get(actual_pts, r.riderkey, 0.0),
        )
    end
    _rule()
    @printf("%-30s %6d %10s %12.1f\n", "TOTAL", sum(base_team.cost), "", base_realised)

    arch = archived_predictions(year)
    if arch !== nothing
        model_team = filter(r -> coalesce(r.chosen, false), arch)
        model_realised = realised(model_team.riderkey)
        _hdr("RESULT")
        @printf("Baseline realised points : %.1f\n", base_realised)
        @printf("Model realised points    : %.1f\n", model_realised)
        @printf("Model edge (model - base): %+.1f\n", model_realised - base_realised)
    else
        _hdr("RESULT")
        @printf("Baseline realised points : %.1f\n", base_realised)
        println("No archived model prediction for $year — the model side becomes")
        println(
            "computable once a prediction is archived at " *
            "$(archive_path("predictions", TOUR_PCS_SLUG, year)).",
        )
    end
    return base_realised
end

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

function main()
    # (3) 2026: model-optimal vs baseline-optimal, now.
    compare_year(2026)

    # (4) Demo backtest on a completed year: 2025 baseline built from 2023+2024,
    #     scored against real 2025 results. No 2025 model archive → baseline only.
    baseline_backtest(2025)
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
