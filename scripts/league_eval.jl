#!/usr/bin/env julia
# ---------------------------------------------------------------------------
# league_eval.jl — score archived pre-race model teams against league winners
#
# For every race in the archive's league_winners.toml with an archived prediction and
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
using DataFrames, JuMP, HiGHS, TOML, Statistics, Printf, Velogames

const REPO = normpath(joinpath(@__DIR__, ".."))

# Stage races archive their VG results under vg_stage_totals (their own VG
# competition); one-day classics under vg_results.
is_stage_race(slug) = haskey(Velogames._STAGE_RACE_VG_SLUGS, slug)
results_for(slug, yr) = load_race_snapshot(
    is_stage_race(slug) ? "vg_stage_totals" : "vg_results", slug, yr)

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

winners = load_league_winners()

rows = NamedTuple[]
for w in winners
    slug, yr, wscore = w.pcs_slug, w.year, w.score
    is_gt = is_stage_race(slug)
    preds = load_race_snapshot("predictions", slug, yr)
    res = results_for(slug, yr)
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
    probs = market_win_probs(load_race_snapshot("odds", slug, yr), df.riderkey)
    if !isempty(probs)
        df.oddsprob = probs
        ot = best_team(df, :oddsprob; n = n_riders)
        odds_score = ot === nothing ? missing : sum(ot.actual)
    end

    push!(rows, (; slug, yr, wscore, status = "ok", model_score, model_cost, opt_score, mc_score, odds_score))
end

out = DataFrame(rows)
println(out)

ok = filter(r -> r.status == "ok" && !ismissing(r.model_score), out)
if nrow(ok) > 0
    oneday = filter(r -> !is_stage_race(r.slug), ok)
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

# ---------------------------------------------------------------------------
# League standings — cumulative placement (WP0.1) + entered-vs-advised (WP0.2)
#
# Reads the vgleague package's scraped standings (../vgleague/data/...; see
# the July 2026 remediation plan, decision D1 — no scraper duplicated here) via
# `load_league_standings`, plus the optional manual data/league_standings.toml
# fallback. Requires data/race_config.toml's [league] section (see
# race_config.toml.example); skips gracefully if either is absent.
# ---------------------------------------------------------------------------

const MODEL_LABEL = "Model (this repo)"

function report_league_placement(out::DataFrame)
race_config_path = joinpath(REPO, "data", "race_config.toml")
if !isfile(race_config_path)
    println(
        "\nNo data/race_config.toml found — skipping league placement section (see race_config.toml.example [league]).",
    )
else
    cfg = TOML.parsefile(race_config_path)
    league_cfg = get(cfg, "league", Dict())
    if isempty(league_cfg)
        println(
            "\nNo [league] section in data/race_config.toml — skipping league placement section.",
        )
    else
        standings = load_league_standings(;
            data_dir = league_cfg["vgleague_data_dir"],
            game_slug = league_cfg["game_slug"],
            year = league_cfg["year"],
            league_id = string(league_cfg["league_id"]),
            toml_path = joinpath(REPO, "data", "league_standings.toml"),
        )

        if nrow(standings) == 0
            println(
                "\nNo league standings found for $(league_cfg["game_slug"]) $(league_cfg["year"]) $(league_cfg["league_id"]) at $(league_cfg["vgleague_data_dir"]) — skipping.",
            )
        else
            user_name = get(league_cfg, "user_name", "")

            # Match every standings race_name to a pcs_slug via the classics schedule
            slug_of_racename = Dict{String,String}()
            for rn in unique(standings.race_name)
                key = Velogames.normalise_race_name(rn)
                for ri in CLASSICS_RACES_2026
                    if Velogames.normalise_race_name(ri.name) == key
                        slug_of_racename[rn] = ri.pcs_slug
                        break
                    end
                end
            end
            racename_of_slug = Dict(v => k for (k, v) in slug_of_racename)

            # Resolve the "current race" pcs_slug for the manual entered_team override.
            # Deliberately avoids `find_race`'s fuzzy fallback (its substring match
            # mis-resolves short GT aliases like "Tour" against "Paris-Tours Elite") —
            # exact pcs_slug matches, the explicit stage-race alias table, and
            # normalised classics display names are used, in that order.
            current_slug = ""
            if haskey(cfg, "race")
                rn = cfg["race"]["name"]
                key = replace(lowercase(rn), " " => "", "-" => "")
                nk = Velogames.normalise_race_name(rn)
                ci = findfirst(
                    ri -> Velogames.normalise_race_name(ri.name) == nk,
                    CLASSICS_RACES_2026,
                )
                current_slug =
                    if Velogames._find_race_by_slug(rn) !== nothing
                        rn
                    elseif haskey(Velogames._STAGE_RACE_PCS_SLUGS, key)
                        Velogames._STAGE_RACE_PCS_SLUGS[key]
                    elseif ci !== nothing
                        CLASSICS_RACES_2026[ci].pcs_slug
                    else
                        ""
                    end
            end
            entered_cfg = get(cfg, "entered_team", Dict())
            entered_riders = get(entered_cfg, "riders", String[])
            entered_score_override = Float64(get(entered_cfg, "score", 0))

            common = NamedTuple[]
            skipped = String[]
            for r in eachrow(out)
                if r.status != "ok" || ismissing(r.model_score)
                    push!(skipped, "$(r.slug) $(r.yr): $(r.status)")
                    continue
                end
                race_name = get(racename_of_slug, r.slug, nothing)
                if race_name === nothing
                    push!(skipped, "$(r.slug) $(r.yr): no matching league standings")
                    continue
                end
                push!(
                    common,
                    (; slug = r.slug, yr = r.yr, race_name = race_name, model_score = r.model_score),
                )
            end

            if isempty(common)
                println(
                    "\nNo races with both an archived model score and league standings — skipping cumulative-placement section.",
                )
            else
                println(
                    "\n=== Cumulative league placement (model as phantom entrant, n=$(length(common)) common races) ===",
                )

                scored_by_race = Dict(
                    c.race_name => Dict(
                        String(row.username) => Float64(row.score) for
                        row in eachrow(filter(:race_name => ==(c.race_name), standings))
                    ) for c in common
                )
                entrants = Set{String}()
                for scored in values(scored_by_race)
                    union!(entrants, keys(scored))
                end

                cumulative = Dict{String,Float64}(u => 0.0 for u in entrants)
                cumulative[MODEL_LABEL] = 0.0
                entered_cumulative = 0.0
                model_cumulative_for_entered = 0.0

                for c in common
                    scored = scored_by_race[c.race_name]
                    for u in entrants
                        cumulative[u] += get(scored, u, 0.0)
                    end
                    cumulative[MODEL_LABEL] += c.model_score

                    ranked = [(u, s) for (u, s) in scored]
                    push!(ranked, (MODEL_LABEL, c.model_score))
                    sort!(ranked, by = x -> -x[2])
                    place = findfirst(x -> x[1] == MODEL_LABEL, ranked)
                    @printf(
                        "%-26s model %5.0f | placed %2d/%2d | leader %-22s %5.0f\n",
                        c.race_name,
                        c.model_score,
                        place,
                        length(ranked),
                        ranked[1][1],
                        ranked[1][2]
                    )

                    # Entered-vs-advised (WP0.2): the user's own entered team for
                    # this race, from the league standings. The manual
                    # [entered_team] override is handled in its own block below —
                    # it must not be gated on the race appearing in the classics
                    # standings (grand tours and un-scraped races never do).
                    if !isempty(user_name)
                        entered_score = get(scored, user_name, missing)
                        if !ismissing(entered_score)
                            entered_cumulative += entered_score
                            model_cumulative_for_entered += c.model_score
                            delta = entered_score - c.model_score
                            @printf(
                                "  entered (%s): %5.0f | model: %5.0f | delta (entered - model): %+.0f\n",
                                user_name,
                                entered_score,
                                c.model_score,
                                delta
                            )
                        end
                    end
                end

                cum_ranked = sort(collect(cumulative), by = x -> -x[2])
                cum_place = findfirst(x -> x[1] == MODEL_LABEL, cum_ranked)
                println("\n--- Cumulative totals over the $(length(common)) common races ---")
                for (rank, (name, score)) in enumerate(cum_ranked)
                    marker = name == MODEL_LABEL ? "  <== model" : ""
                    @printf("%2d. %-26s %6.0f%s\n", rank, name, score, marker)
                end
                println(
                    "Model would place $cum_place/$(length(cum_ranked)) cumulatively over these $(length(common)) races.",
                )

                if !isempty(user_name) && entered_cumulative > 0
                    @printf(
                        "\nEntered team (%s) cumulative: %.0f | Model cumulative (same subset): %.0f | delta: %+.0f\n",
                        user_name,
                        entered_cumulative,
                        model_cumulative_for_entered,
                        entered_cumulative - model_cumulative_for_entered
                    )
                end
            end

            if !isempty(skipped)
                println("\nRaces skipped (no archived model score or no matching league standings):")
                for s in skipped
                    println("  - $s")
                end
            end

            # Manual [entered_team] override (WP0.2): scored directly against
            # archived results, independent of the league standings — reachable
            # for grand tours and races the vgleague cache hasn't scraped yet.
            if !isempty(current_slug) &&
               (entered_score_override > 0 || !isempty(entered_riders))
                race_yr = cfg["race"]["year"]
                entered_score = if entered_score_override > 0
                    entered_score_override
                else
                    res = results_for(current_slug, race_yr)
                    if res === nothing
                        missing
                    else
                        actual_of = Dict(
                            String(rr.riderkey) => Float64(rr.score) for
                            rr in eachrow(res)
                        )
                        sum(get(actual_of, createkey(name), 0.0) for name in entered_riders)
                    end
                end
                if ismissing(entered_score)
                    println(
                        "\n[entered_team] set for $current_slug $race_yr but no archived results yet — cannot score the entered team.",
                    )
                else
                    @printf(
                        "\nEntered team for %s %d (manual [entered_team]): %.0f\n",
                        current_slug,
                        race_yr,
                        entered_score
                    )
                end
            end
        end
    end
end
end

report_league_placement(out)
