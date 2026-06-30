#!/usr/bin/env julia
"""
Live ablation of the grand-tour cross-history signal on the configured race.

Unlike the history-isolation backtest (`eval_gt_history.jl`), this runs the FULL
production pipeline — odds, oracle, PCS specialty, the lot — with GT cross-history
toggled on vs off, and reports how the GC strengths, rankings, and optimal team
move. This is the marginal-value test: does the signal still matter once it has to
compete with the market and PCS specialty ratings that already encode GT form?

No ground truth (the race hasn't run), so this is descriptive: we check the
signal moves the right riders (those with GT history but sparse same-race history)
in the right direction, and leaves rich-history riders essentially unchanged.

Usage:  julia --project scripts/ablation_gt_history.jl
"""

using Velogames, DataFrames, Statistics, TOML, Printf

const FRESH = false
cfg = TOML.parsefile(joinpath(@__DIR__, "..", "data", "race_config.toml"))
race_cache = CacheConfig(joinpath(homedir(), ".velogames_cache"), 9999)

race_name = cfg["race"]["name"]
race_year = cfg["race"]["year"]
racehash = cfg["race"]["racehash"]
config = setup_race(race_name, race_year; cache_config=race_cache)

_paste(f) = (p = joinpath(@__DIR__, "..", f); isfile(p) ? parse_oddschecker_odds(read(p, String)) : nothing)
odds_df = get(cfg["data_sources"], "use_oddschecker", false) ? _paste("oddschecker_paste.txt") : nothing
points_odds_df = _paste(get(cfg["data_sources"], "points_odds_paste_file", ""))
kom_odds_df = _paste(get(cfg["data_sources"], "kom_odds_paste_file", ""))

stages = Velogames.getpcs_stage_profiles(config.pcs_slug, race_year; cache_config=race_cache)
stage_scoring = try
    getvg_scoring(config.slug, config.year; pcs_slug=config.pcs_slug)
catch
    nothing
end

opt = cfg["optimisation"]
function run_pipeline(include_gt::Bool)
    result = solve_stage(config;
        stages=stages, racehash=racehash,
        history_years=opt["history_years"],
        oracle_url=get(cfg["data_sources"], "oracle_url", ""),
        points_oracle_url=get(cfg["data_sources"], "points_oracle_url", ""),
        kom_oracle_url=get(cfg["data_sources"], "kom_oracle_url", ""),
        n_resamples=200,
        excluded_riders=String[x for x in opt["excluded_riders"]],
        domestique_discount=opt["domestique_discount"],
        risk_aversion=opt["risk_aversion"],
        max_per_team=opt["max_per_team"],
        simulation_df=(opt["simulation_df"] isa Integer ? opt["simulation_df"] : nothing),
        cross_stage_alpha=get(opt, "cross_stage_alpha", 0.7),
        stage_scoring=stage_scoring,
        odds_df=odds_df, points_odds_df=points_odds_df, kom_odds_df=kom_odds_df,
        include_gt_history=include_gt)
    return result.predicted
end

@info "Running WITHOUT GT cross-history..."
without = run_pipeline(false)
@info "Running WITH GT cross-history..."
with = run_pipeline(true)

# Join on rider, compare GC strength + GC rank + expected points.
w = select(with, :rider, :strength_gc => :sg_with, :expected_vg_points => :ev_with)
wo = select(without, :rider, :strength_gc => :sg_wo, :expected_vg_points => :ev_wo)
cmp = innerjoin(w, wo, on=:rider)
function rankvec(v)  # rank 1 = highest value
    p = sortperm(v, rev=true)
    r = Vector{Int}(undef, length(v))
    for (i, idx) in enumerate(p); r[idx] = i; end
    return r
end
cmp.rank_with = rankvec(cmp.sg_with)
cmp.rank_wo = rankvec(cmp.sg_wo)
cmp.dsg = cmp.sg_with .- cmp.sg_wo
cmp.drank = cmp.rank_wo .- cmp.rank_with        # positive = moved UP the GC order
cmp.dev = cmp.ev_with .- cmp.ev_wo

println("\n", "="^88)
println("Live GT cross-history ablation — $(titlecase(config.name)) $(config.year)  (full pipeline, GT on vs off)")
println("="^88)

println("\nBiggest GC-strength MOVERS (|Δstrength_gc|), with GC-rank shift:")
@printf("%-24s %8s %8s %7s | %5s→%-5s (%+d)\n", "Rider", "sg_wo", "sg_with", "Δsg", "rank", "", 0)
for r in first(sort(cmp, :dsg, by=abs, rev=true), 12) |> eachrow
    @printf("%-24s %8.2f %8.2f %+7.2f | %5d→%-5d (%+d)\n",
        r.rider, r.sg_wo, r.sg_with, r.dsg, r.rank_wo, r.rank_with, r.drank)
end

println("\nNo-harm check — top GC favourites (rich same-race history, should barely move):")
for nm in ("Pogačar", "Vingegaard", "Evenepoel", "Lipowitz")
    idx = findfirst(x -> occursin(lowercase(nm), lowercase(x)), cmp.rider)
    idx === nothing && continue
    r = cmp[idx, :]
    @printf("  %-22s Δstrength_gc=%+.3f  rank %d→%d  Δexp_pts=%+.0f\n",
        r.rider, r.dsg, r.rank_wo, r.rank_with, r.dev)
end

println("\nOptimal team change:")
team_wo = Set(without[without.chosen .== true, :rider]); team_w = Set(with[with.chosen .== true, :rider])
added = setdiff(team_w, team_wo); dropped = setdiff(team_wo, team_w)
println("  WITH-only (added):   ", isempty(added) ? "(none)" : join(added, ", "))
println("  WITHOUT-only (dropped): ", isempty(dropped) ? "(none)" : join(dropped, ", "))
@printf("  GC top-10 membership changed for %d riders\n",
    count(r -> (r.rank_with <= 10) != (r.rank_wo <= 10), eachrow(cmp)))
println("="^88)
