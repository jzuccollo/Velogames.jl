#!/usr/bin/env julia
"""
TEMPORARY — see roadmap.md, residual issue "No stage-race backtesting path".
This is a standalone workaround: `backtest.jl` covers one-day classics only, so
GT signal validation has no home in the framework yet. To be folded into a
stage-race signal-isolation harness in `backtest.jl` + `render_backtesting.jl`,
after which this script collapses to a thin caller or is deleted.

Assessment harness for the grand-tour cross-history signal (Phase 1).

History-isolation backtest. For each completed grand tour we reconstruct the
*only* temporally-clean signal available for a past GT — race history — two ways:

  WITHOUT  primary same-GT GC history only (the pre-existing behaviour)
  WITH     primary + other-GT cross-history (Giro/Vuelta → Tour, etc.)

and correlate each rider's resulting GC-strength estimate against their actual
GC finishing position. The delta (WITH − WITHOUT) is the marginal value of the
cross-history signal, isolated from market signals we cannot reconstruct
historically (odds/oracle/PCS-specialty snapshots don't exist for past GTs).

This answers: does other-GT GC history carry GC-rank-predictive information
beyond same-GT history? Its interaction with the full signal stack (odds, PCS
specialty) is assessed separately via the live 2026 ablation and prospective eval.

Reported per race and pooled:
  - rho_without / rho_with / Δrho  over the full finishing field
  - rho_with on the GAIN subset (riders with cross-history but NO same-GT
    history — where WITHOUT gives no signal at all; this is where the signal
    must prove itself)
  - top-10 overlap (predicted-strength top 10 vs actual GC top 10)

Usage:  julia --project scripts/eval_gt_history.jl
"""

using Velogames, DataFrames, Dates, Statistics, Printf

const GTS = ["tour-de-france", "giro-d-italia", "vuelta-a-espana"]
const TARGET_YEARS = [2023, 2024, 2025]
const HISTORY_YEARS = 3
const CACHE = CacheConfig(joinpath(homedir(), ".velogames_cache"), 9999)

# Conjugate normal update of a GC-strength from a set of history observations,
# mirroring the model's per-observation variance (base + decay·years_ago +
# penalty). Returns the posterior mean (prior is mean 0, variance 100).
function history_strength(obs::Vector{Tuple{Float64,Int,Float64}})
    cfg = Velogames.BayesianConfig()
    prec = 1.0 / 100.0          # uninformative prior precision
    weighted = 0.0
    for (strength, years_ago, penalty) in obs
        v = Velogames.hist_base_variance(cfg) + cfg.hist_decay_rate * years_ago + penalty
        prec += 1.0 / v
        weighted += strength / v
    end
    return weighted / prec
end

# GC result for one edition, cached. Returns riderkey => position (finishers only).
function gc_positions(slug, year)
    df = try
        Velogames.getpcsraceresults(slug, year; prefer_gc = true, cache_config = CACHE)
    catch
        return Dict{String,Int}()
    end
    d = Dict{String,Int}()
    for r in eachrow(df)
        (r.position > 0 && r.position < Velogames.DNF_POSITION) && (d[r.riderkey] = r.position)
    end
    return d
end

# Assemble each rider's prior history observations for a target race, split into
# primary (same GT, penalty 0) and cross (other GTs, penalty 3). Respects
# temporal integrity via resolve_race_date for within-year editions.
function gather_history(target_slug, target_year; penalty = Velogames.GT_SIMILAR_VARIANCE_PENALTY)
    target_date = Velogames.resolve_race_date(target_slug, target_year)
    primary = Dict{String,Vector{Tuple{Float64,Int,Float64}}}()
    cross = Dict{String,Vector{Tuple{Float64,Int,Float64}}}()

    function add!(store, slug, year, penalty)
        pos = gc_positions(slug, year)
        n = max(length(pos), 1)
        for (key, p) in pos
            obs = (Velogames.position_to_strength(p, n), target_year - year, penalty)
            push!(get!(store, key, Tuple{Float64,Int,Float64}[]), obs)
        end
    end

    # Primary: prior editions of the same GT.
    for y in (target_year-HISTORY_YEARS):(target_year-1)
        add!(primary, target_slug, y, 0.0)
    end
    # Cross: other GTs, prior editions + within-year editions strictly before the target.
    for other in get(Velogames.GT_SIMILAR_RACES, target_slug, String[])
        for y in (target_year-HISTORY_YEARS):(target_year-1)
            add!(cross, other, y, penalty)
        end
        other_date = Velogames.resolve_race_date(other, target_year)
        if other_date !== nothing && target_date !== nothing && other_date < target_date
            add!(cross, other, target_year, penalty)
        end
    end
    return primary, cross
end

function eval_race(slug, year; penalty = Velogames.GT_SIMILAR_VARIANCE_PENALTY)
    actual = gc_positions(slug, year)
    isempty(actual) && return nothing
    primary, cross = gather_history(slug, year; penalty = penalty)

    riders = collect(keys(actual))
    pos = Float64[actual[k] for k in riders]
    s_without = Float64[history_strength(get(primary, k, Tuple{Float64,Int,Float64}[])) for k in riders]
    s_with = Float64[history_strength(vcat(get(primary, k, Tuple{Float64,Int,Float64}[]),
                                           get(cross, k, Tuple{Float64,Int,Float64}[]))) for k in riders]

    # Gain subset: cross history but no primary history (signal's design target).
    gain = [i for (i, k) in enumerate(riders) if haskey(cross, k) && !haskey(primary, k)]
    # No-harm subset: riders that DO have primary same-GT history — does adding
    # cross-history degrade riders the signal isn't meant to help?
    keep = [i for (i, k) in enumerate(riders) if haskey(primary, k)]

    ρ(s) = Velogames.spearman_correlation(s, -pos)
    ρsub(s, idx) = length(idx) >= 4 ? Velogames.spearman_correlation(s[idx], -pos[idx]) : NaN
    return (
        slug = slug, year = year, n = length(riders),
        rho_without = ρ(s_without), rho_with = ρ(s_with),
        n_gain = length(gain),
        rho_gain = ρsub(s_with, gain),
        keep_delta = ρsub(s_with, keep) - ρsub(s_without, keep),
        ovl_without = Velogames.top_n_overlap(s_without, Int.(pos), 10),
        ovl_with = Velogames.top_n_overlap(s_with, Int.(pos), 10),
    )
end

results = NamedTuple[]
for slug in GTS, year in TARGET_YEARS
    r = eval_race(slug, year)
    r !== nothing && push!(results, r)
end

println("\n", "="^96)
println("GT cross-history isolation backtest — does other-GT GC history improve GC-rank prediction?")
println("="^96)
@printf("%-18s %4s %4s | %7s %7s %7s | %5s %7s | %8s | %s\n",
    "Race", "Yr", "N", "ρ_woGT", "ρ_wGT", "Δρ", "nGain", "ρ_gain", "noharmΔ", "top10")
println("-"^96)
for r in results
    @printf("%-18s %4d %4d | %7.3f %7.3f %+7.3f | %5d %7s | %+8.3f | %d→%d\n",
        r.slug, r.year, r.n, r.rho_without, r.rho_with, r.rho_with - r.rho_without,
        r.n_gain, isnan(r.rho_gain) ? "  n/a" : @sprintf("%.3f", r.rho_gain),
        r.keep_delta, r.ovl_without, r.ovl_with)
end
println("-"^96)
Δ = [r.rho_with - r.rho_without for r in results]
gains = filter(!isnan, [r.rho_gain for r in results])
keepΔ = filter(!isnan, [r.keep_delta for r in results])
@printf("POOLED   mean Δρ (full field) = %+.3f   |   mean ρ_gain (gain subset) = %.3f over %d races\n",
    mean(Δ), isempty(gains) ? NaN : mean(gains), length(gains))
@printf("         no-harm subset mean Δρ = %+.3f (riders WITH same-GT history; ≥0 = no degradation)\n",
    isempty(keepΔ) ? NaN : mean(keepΔ))
@printf("         races improved: %d/%d   |   mean top-10 overlap %.1f → %.1f\n",
    count(>(0), Δ), length(Δ),
    mean([r.ovl_without for r in results]), mean([r.ovl_with for r in results]))
println("="^96)

# --- Penalty robustness sweep ---
println("\nPenalty robustness (mean Δρ full field / mean no-harm Δρ, across $(length(results)) races):")
for pen in [1.0, 3.0, 5.0, 8.0, 15.0]
    rs = filter(!isnothing, [eval_race(slug, year; penalty = pen) for slug in GTS, year in TARGET_YEARS])
    dfull = mean([r.rho_with - r.rho_without for r in rs])
    dkeep = mean(filter(!isnan, [r.keep_delta for r in rs]))
    @printf("  penalty=%5.1f →  Δρ_full = %+.3f   no-harm Δρ = %+.3f   (%d/%d races improved)\n",
        pen, dfull, dkeep, count(r -> r.rho_with > r.rho_without, rs), length(rs))
end
println("(higher penalty = less weight on cross-history; production default = $(Velogames.GT_SIMILAR_VARIANCE_PENALTY))")
