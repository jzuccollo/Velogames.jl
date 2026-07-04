#!/usr/bin/env julia
# ---------------------------------------------------------------------------
# league_eval.jl — score archived pre-race model teams against league winners
#
# For every race in data/league_winners.toml with an archived prediction and
# archived VG results, computes:
#   - the model's chosen team's realised VG points
#   - the hindsight-optimal team over the prediction universe
#   - two naive baselines: max-cost ("buy stars") and odds-implied (maximise
#     summed implied win probability), both under the same budget/size rules
#
# Fully offline: reads only the Dropbox archive and league_winners.toml.
# Evidence base for docs/architecture-review.md (July 2026).
#
# Run:  julia --project scripts/league_eval.jl
# ---------------------------------------------------------------------------
using DataFrames, Feather, JuMP, HiGHS, TOML, Statistics, Printf

const ARCH = joinpath(homedir(), "Dropbox", "code", "velogames", "archive")
const REPO = normpath(joinpath(@__DIR__, ".."))

fpath(dt, slug, yr) = joinpath(ARCH, dt, slug, "$yr.feather")
loadf(dt, slug, yr) = isfile(fpath(dt, slug, yr)) ? Feather.read(fpath(dt, slug, yr)) : nothing

function best_team(df, points_col; n = 6, budget = 100)
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    k = nrow(df)
    @variable(m, x[1:k], Bin)
    @constraint(m, sum(x) == n)
    @constraint(m, sum(x[i] * df.cost[i] for i in 1:k) <= budget)
    @objective(m, Max, sum(x[i] * df[i, points_col] for i in 1:k))
    optimize!(m)
    termination_status(m) == MOI.OPTIMAL || return nothing
    return df[[value(x[i]) > 0.5 for i in 1:k], :]
end

blank(slug, yr, wscore, status) = (; slug, yr, wscore, status,
    model_score = missing, model_cost = missing, opt_score = missing,
    mc_score = missing, odds_score = missing)

winners = TOML.parsefile(joinpath(REPO, "data", "league_winners.toml"))["winners"]

rows = NamedTuple[]
for w in winners
    slug, yr, wscore = w["pcs_slug"], w["year"], w["score"]
    is_gt = haskey(Dict("giro-d-italia" => 1, "tour-de-france" => 1, "vuelta-a-espana" => 1), slug)
    preds = loadf("predictions", slug, yr)
    res = is_gt ? loadf("vg_stage_totals", slug, yr) : loadf("vg_results", slug, yr)
    (preds === nothing || res === nothing) && (push!(rows, blank(slug, yr, wscore, preds === nothing ? "no preds" : "no results")); continue)

    if !(:cost in propertynames(preds))
        push!(rows, blank(slug, yr, wscore, "legacy preds (no cost)"))
        continue
    end

    score_of = Dict(String(r.riderkey) => Float64(r.score) for r in eachrow(res))

    n_riders = is_gt ? 9 : 6
    df = copy(preds)
    df.cost = Float64.(df.cost)
    df.actual = [get(score_of, String(k), 0.0) for k in df.riderkey]

    # model's archived chosen team
    model_score = missing
    model_cost = missing
    if :chosen in propertynames(df) && any(coalesce.(df.chosen, false))
        team = df[coalesce.(df.chosen, false), :]
        model_score = sum(team.actual)
        model_cost = sum(team.cost)
    end

    # hindsight optimum over the prediction universe (no class constraints for GTs — mildly optimistic)
    opt = best_team(df, :actual; n = n_riders)
    opt_score = opt === nothing ? missing : sum(opt.actual)

    # naive baseline 1: spend the budget on the most expensive riders
    mc = best_team(df, :cost; n = n_riders)
    mc_score = mc === nothing ? missing : sum(mc.actual)

    # naive baseline 2: odds-implied team (archived odds only)
    odds_score = missing
    odds = loadf("odds", slug, yr)
    if odds !== nothing && :odds in propertynames(odds)
        op = Dict(String(r.riderkey) => 1.0 / max(Float64(r.odds), 1.01) for r in eachrow(odds))
        df.oddsprob = [get(op, String(k), 0.0) for k in df.riderkey]
        ot = best_team(df, :oddsprob; n = n_riders)
        odds_score = ot === nothing ? missing : sum(ot.actual)
    end

    push!(rows, (; slug, yr, wscore, status = "ok", model_score, model_cost, opt_score, mc_score, odds_score))
end

out = DataFrame(rows)
println(out)

ok = filter(r -> r.status == "ok" && !ismissing(r.model_score), out)
if nrow(ok) > 0
    oneday = filter(r -> r.slug in ("giro-d-italia", "tour-de-france", "vuelta-a-espana") ? false : true, ok)
    println("\n=== One-day races (n=$(nrow(oneday))) ===")
    @printf("model total %.0f | winner total %.0f | optimal total %.0f | maxcost total %.0f\n",
        sum(oneday.model_score), sum(oneday.wscore), sum(skipmissing(oneday.opt_score)), sum(skipmissing(oneday.mc_score)))
    @printf("model beats league winner in %d/%d races\n", sum(oneday.model_score .> oneday.wscore), nrow(oneday))
    @printf("mean capture: model/opt %.2f | winner/opt %.2f | maxcost/opt %.2f\n",
        mean(oneday.model_score ./ oneday.opt_score), mean(oneday.wscore ./ oneday.opt_score), mean(skipmissing(oneday.mc_score ./ oneday.opt_score)))
    wo = filter(r -> !ismissing(r.odds_score), oneday)
    if nrow(wo) > 0
        @printf("odds-baseline races (n=%d): model %.0f | odds team %.0f | winner %.0f\n",
            nrow(wo), sum(wo.model_score), sum(wo.odds_score), sum(wo.wscore))
    end
end
