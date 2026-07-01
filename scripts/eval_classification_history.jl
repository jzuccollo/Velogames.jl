#!/usr/bin/env julia
"""
TEMPORARY — see roadmap.md, residual issue "No stage-race backtesting path".
This is a standalone workaround: `backtest.jl` covers one-day classics only, so
GT signal validation has no home in the framework yet. To be folded into a
stage-race signal-isolation harness in `backtest.jl` + `render_backtesting.jl`,
after which this script collapses to a thin caller or is deleted.

Assessment harness for the Phase 2 points/KOM classification-history signal.

The Phase 2 analogue of `eval_gt_history.jl`. For each completed grand tour and
each secondary classification (points jersey, KOM), reconstruct the prior-edition
classification history two ways:

  WITHOUT  same-race standings only (e.g. prior Tours' green-jersey results)
  WITH     + grand-tour cross-history (Giro/Vuelta jersey results too)

and correlate each rider's resulting classification-strength estimate against
their actual finishing position in that classification. Reports whether prior
classification history predicts the jersey outcome at all (ρ), and the marginal
value of the cross-history (Δρ) — most relevant precisely because the points/KOM
betting markets are far thinner than the GC market.

Usage:  julia --project scripts/eval_classification_history.jl
"""

using Velogames, DataFrames, Dates, Statistics, Printf

const GTS = ["tour-de-france", "giro-d-italia", "vuelta-a-espana"]
const TARGET_YEARS = [2023, 2024, 2025]
const HISTORY_YEARS = 3
const CACHE = CacheConfig(joinpath(homedir(), ".velogames_cache"), 9999)

function history_strength(obs::Vector{Tuple{Float64,Int,Float64}})
    cfg = Velogames.BayesianConfig()
    prec = 1.0 / 100.0
    weighted = 0.0
    for (strength, years_ago, penalty) in obs
        v = Velogames.hist_base_variance(cfg) + cfg.hist_decay_rate * years_ago + penalty
        prec += 1.0 / v
        weighted += strength / v
    end
    return weighted / prec
end

# Classification standings for one edition (riderkey => position), cached.
function class_positions(slug, year, cls)
    df = try
        Velogames.getpcsraceresults(slug, year; classification = cls, cache_config = CACHE)
    catch
        return Dict{String,Int}()
    end
    d = Dict{String,Int}()
    for r in eachrow(df)
        (r.position > 0 && r.position < Velogames.DNF_POSITION) && (d[r.riderkey] = r.position)
    end
    return d
end

function gather_history(target_slug, target_year, cls)
    target_date = Velogames.resolve_race_date(target_slug, target_year)
    primary = Dict{String,Vector{Tuple{Float64,Int,Float64}}}()
    cross = Dict{String,Vector{Tuple{Float64,Int,Float64}}}()
    function add!(store, slug, year, penalty)
        pos = class_positions(slug, year, cls)
        n = max(length(pos), 1)
        for (key, p) in pos
            push!(get!(store, key, Tuple{Float64,Int,Float64}[]),
                (Velogames.position_to_strength(p, n), target_year - year, penalty))
        end
    end
    for y in (target_year-HISTORY_YEARS):(target_year-1)
        add!(primary, target_slug, y, 0.0)
    end
    for other in get(Velogames.GT_SIMILAR_RACES, target_slug, String[])
        for y in (target_year-HISTORY_YEARS):(target_year-1)
            add!(cross, other, y, Velogames.GT_SIMILAR_VARIANCE_PENALTY)
        end
        od = Velogames.resolve_race_date(other, target_year)
        if od !== nothing && target_date !== nothing && od < target_date
            add!(cross, other, target_year, Velogames.GT_SIMILAR_VARIANCE_PENALTY)
        end
    end
    return primary, cross
end

function eval_race(slug, year, cls)
    actual = class_positions(slug, year, cls)
    length(actual) < 8 && return nothing
    primary, cross = gather_history(slug, year, cls)
    riders = collect(keys(actual))
    pos = Float64[actual[k] for k in riders]
    s_wo = Float64[history_strength(get(primary, k, Tuple{Float64,Int,Float64}[])) for k in riders]
    s_w = Float64[history_strength(vcat(get(primary, k, Tuple{Float64,Int,Float64}[]),
                                        get(cross, k, Tuple{Float64,Int,Float64}[]))) for k in riders]
    gain = [i for (i, k) in enumerate(riders) if haskey(cross, k) && !haskey(primary, k)]
    keep = [i for (i, k) in enumerate(riders) if haskey(primary, k)]
    ρ(s) = Velogames.spearman_correlation(s, -pos)
    ρsub(s, idx) = length(idx) >= 4 ? Velogames.spearman_correlation(s[idx], -pos[idx]) : NaN
    return (slug=slug, year=year, n=length(riders),
        rho_wo=ρ(s_wo), rho_w=ρ(s_w), n_gain=length(gain),
        rho_gain=ρsub(s_w, gain), keep_delta=ρsub(s_w, keep) - ρsub(s_wo, keep))
end

for cls in (:points, :kom)
    results = filter(!isnothing, [eval_race(slug, year, cls) for slug in GTS, year in TARGET_YEARS])
    println("\n", "="^90)
    println("Phase 2 isolation backtest — does prior $(uppercase(string(cls))) history predict the $(cls) jersey?")
    println("="^90)
    @printf("%-18s %4s %4s | %7s %7s %7s | %5s %7s | %8s\n",
        "Race", "Yr", "N", "ρ_wo", "ρ_w", "Δρ", "nGain", "ρ_gain", "noharmΔ")
    println("-"^90)
    for r in results
        @printf("%-18s %4d %4d | %7.3f %7.3f %+7.3f | %5d %7s | %+8.3f\n",
            r.slug, r.year, r.n, r.rho_wo, r.rho_w, r.rho_w - r.rho_wo,
            r.n_gain, isnan(r.rho_gain) ? "  n/a" : @sprintf("%.3f", r.rho_gain), r.keep_delta)
    end
    println("-"^90)
    Δ = [r.rho_w - r.rho_wo for r in results]
    gains = filter(!isnan, [r.rho_gain for r in results])
    keeps = filter(!isnan, [r.keep_delta for r in results])
    @printf("POOLED  mean ρ_with (history predicts jersey) = %.3f  |  mean Δρ from GT cross = %+.3f (%d/%d improved)\n",
        mean([r.rho_w for r in results]), mean(Δ), count(>(0), Δ), length(Δ))
    @printf("        gain-subset mean ρ = %.3f  |  no-harm mean Δρ = %+.3f\n",
        isempty(gains) ? NaN : mean(gains), isempty(keeps) ? NaN : mean(keeps))
    println("="^90)
end
