#!/usr/bin/env julia
"""
Render the team assessor report as a standalone HTML page.

Usage:
    julia --project scripts/render_assessor.jl [--fresh]

Options:
    --fresh   Bypass cache, fetch all data fresh from the web
"""

using Velogames, DataFrames, Statistics, Dates, TOML

const FRESH = "--fresh" in ARGS

# ---------------------------------------------------------------------------
# Configuration (from race_config.toml)
# ---------------------------------------------------------------------------

const _cfg = TOML.parsefile(joinpath(@__DIR__, "..", "data", "race_config.toml"))

race_name = _cfg["race"]["name"]
race_year = _cfg["race"]["year"]
@info "Configuration" race = race_name year = race_year
racehash = _cfg["race"]["racehash"]
oracle_url = _cfg["data_sources"]["oracle_url"]
n_resamples = _cfg["optimisation"]["n_resamples"]
history_years = _cfg["optimisation"]["history_years"]
domestique_discount = _cfg["optimisation"]["domestique_discount"]
risk_aversion = _cfg["optimisation"]["risk_aversion"]
max_per_team = _cfg["optimisation"]["max_per_team"]
excluded_riders = String[x for x in _cfg["optimisation"]["excluded_riders"]]
simulation_df = let v = _cfg["optimisation"]["simulation_df"]
    v isa Integer ? v : nothing
end

vg_race_number = _cfg["team_assessor"]["vg_race_number"]
my_team = String.(_cfg["team_assessor"]["my_team"])
my_keys = createkey.(my_team)

breakaway_dir = joinpath(DEFAULT_ARCHIVE_DIR, "pcs_breakaways")
race_cache = CacheConfig(joinpath(homedir(), ".velogames_cache"), FRESH ? 0 : 6)

# ---------------------------------------------------------------------------
# Prediction
# ---------------------------------------------------------------------------

config = setup_race(race_name, race_year; cache_config=race_cache)
is_stage = config.type == :stage
scoring = get_scoring(is_stage ? :stage : (config.category > 0 ? config.category : 2))

# Try loading archived prediction
archived_prediction = !isempty(config.pcs_slug) ?
                      load_race_snapshot("predictions", config.pcs_slug, config.year) : nothing
used_archive = false

if archived_prediction !== nothing && nrow(archived_prediction) > 0
    predicted = archived_prediction
    used_archive = true

    if !hasproperty(predicted, :team)
        vg_riders = suppress_output() do
            getvgriders(config.current_url; cache_config=race_cache)
        end
        predicted = leftjoin(predicted, vg_riders[:, [:riderkey, :team]], on=:riderkey)
        predicted.team = coalesce.(predicted.team, "Unknown")
    end

    optimal_team = if :chosen in propertynames(predicted)
        filter(:chosen => ==(true), predicted)
    else
        nothing  # deferred until expected_vg_points is computed
    end
else
    println("No archive found — running fresh prediction...")
    if is_stage
        cross_stage_alpha = get(_cfg["optimisation"], "cross_stage_alpha", 0.7)
        modifier_scale = get(_cfg["optimisation"], "modifier_scale", 0.5)
        pcs_stage_scrape = get(_cfg["optimisation"], "pcs_stage_scrape", true)

        stages = StageProfile[]
        if pcs_stage_scrape && !isempty(config.pcs_slug)
            stages = getpcs_stage_profiles(config.pcs_slug, race_year;
                cache_config=race_cache, force_refresh=FRESH)
        end

        stage_scoring_fresh = try
            getvg_scoring(config.slug, config.year; pcs_slug=config.pcs_slug)
        catch; nothing; end

        predicted, optimal_team, _ = solve_stage(config;
            stages=stages, racehash=racehash, history_years=history_years,
            oracle_url=oracle_url,
            n_resamples=n_resamples, excluded_riders=excluded_riders,
            domestique_discount=domestique_discount,
            risk_aversion=risk_aversion, max_per_team=max_per_team,
            breakaway_dir=breakaway_dir, simulation_df=simulation_df,
            cross_stage_alpha=cross_stage_alpha, modifier_scale=modifier_scale,
            stage_scoring=stage_scoring_fresh)
    else
        predicted, optimal_team, _ = solve_oneday(config;
            racehash=racehash, history_years=history_years,
            oracle_url=oracle_url,
            n_resamples=n_resamples, excluded_riders=excluded_riders,
            domestique_discount=domestique_discount,
            risk_aversion=risk_aversion, max_per_team=max_per_team,
            breakaway_dir=breakaway_dir, simulation_df=simulation_df)
    end
end

prediction_ok = nrow(predicted) > 0

# Compute breakaway rates
b_rates, b_sectors = if isdir(breakaway_dir)
    try
        bdf = load_pcs_breakaway_stats(breakaway_dir)
        compute_breakaway_rates(bdf, String.(predicted.riderkey))
    catch
        Float64[], Float64[]
    end
else
    Float64[], Float64[]
end

# Simulation draws
sim_vg_points = if !prediction_ok || :strength ∉ propertynames(predicted) || :uncertainty ∉ propertynames(predicted)
    nothing
elseif is_stage && :stage_strength_flat in propertynames(predicted)
    # Per-stage simulation using archived stage strengths
    stage_profiles_df = load_race_snapshot("stage_profiles", config.pcs_slug, config.year)
    if stage_profiles_df !== nothing && nrow(stage_profiles_df) > 0
        stages_from_archive = [
            StageProfile(
                row.stage_number, Symbol(row.stage_type), row.distance_km,
                row.profile_score, row.vertical_meters, 0.0,
                row.n_hc_climbs, row.n_cat1_climbs, 0, row.is_summit_finish,
            ) for row in eachrow(stage_profiles_df)
        ]
        stage_strengths = Dict{Symbol,Vector{Float64}}(
            :flat => Float64.(predicted.stage_strength_flat),
            :hilly => Float64.(predicted.stage_strength_hilly),
            :mountain => Float64.(predicted.stage_strength_mountain),
            :itt => Float64.(predicted.stage_strength_itt),
        )
        cross_stage_alpha = get(_cfg["optimisation"], "cross_stage_alpha", 0.7)
        stage_scoring = try
            getvg_scoring(config.slug, config.year; pcs_slug=config.pcs_slug)
        catch
            SCORING_GRAND_TOUR
        end
        simulate_stage_race(
            stages_from_archive, stage_strengths,
            Float64.(predicted.uncertainty), String.(predicted.team),
            stage_scoring; n_sims=n_resamples, cross_stage_alpha=cross_stage_alpha,
        )
    else
        nothing
    end
else
    simulate_vg_draws(predicted, scoring; n_draws=n_resamples,
        breakaway_rates=b_rates, breakaway_mean_sectors=b_sectors,
        simulation_df=simulation_df)
end

if sim_vg_points !== nothing && !hasproperty(predicted, :expected_vg_points)
    predicted[!, :expected_vg_points] = [mean(@view sim_vg_points[i, :]) for i in 1:nrow(predicted)]
end

# Compute optimal team from simulation if archive lacked :chosen
if optimal_team === nothing && hasproperty(predicted, :expected_vg_points)
    build_fn = is_stage ? build_model_stage : build_model_oneday
    sol = build_fn(predicted, config.team_size, :expected_vg_points, :cost;
        totalcost=100, max_per_team=max_per_team)
    optimal_team = if sol !== nothing
        filter(row -> sol[row.riderkey] > 0.5, predicted)
    else
        DataFrame()
    end
elseif optimal_team === nothing
    optimal_team = DataFrame()
end

# ---------------------------------------------------------------------------
# Build page content
# ---------------------------------------------------------------------------

io = IOBuffer()

if prediction_ok
    source = used_archive ? "archived prediction (pre-race)" : "fresh prediction"
    write(io, "<p><strong>$(titlecase(config.name)) $(config.year)</strong> — $(nrow(predicted)) riders, $source</p>\n")
    if !used_archive
        write(io, html_callout("Using fresh prediction. If this race has already happened, VG season points may include results from this race. Run the predictor before the race to archive a clean prediction."))
    end
else
    write(io, html_callout("Prediction failed — no riders returned. Check race configuration."; type="warning"))
end

# --- Your team ---

write(io, html_heading("Your team", 2))

my_selection = prediction_ok ? filter(row -> row.riderkey in my_keys, predicted) : DataFrame()

if prediction_ok
    matched_keys = Set(my_selection.riderkey)
    for (name, key) in zip(my_team, my_keys)
        if key ∉ matched_keys
            write(io, html_callout("<strong>$name</strong> not found in the rider list. Check the spelling matches VG exactly."; type="warning"))
        end
    end

    if nrow(my_selection) > 0
        my_cost = sum(my_selection.cost)
        my_evg = sum(my_selection.expected_vg_points)
        write(io, "<p><strong>Total cost:</strong> $my_cost / 100 credits | <strong>Expected VG points:</strong> $(round(my_evg, digits=1)) | <strong>Budget remaining:</strong> $(100 - my_cost)</p>\n")

        display_cols = intersect([:rider, :team, :cost, :expected_vg_points, :selection_frequency, :strength, :uncertainty], propertynames(my_selection))
        write(io, html_table(sort(my_selection[:, display_cols], :expected_vg_points, rev=true)))
    end
end

# --- Optimal team ---

write(io, html_heading("Optimal team", 2))

if prediction_ok && nrow(optimal_team) > 0
    opt_cost = sum(optimal_team.cost)
    opt_evg = sum(optimal_team.expected_vg_points)
    write(io, "<p><strong>Total cost:</strong> $opt_cost / 100 credits | <strong>Expected VG points:</strong> $(round(opt_evg, digits=1)) | <strong>Budget remaining:</strong> $(100 - opt_cost)</p>\n")

    display_cols = intersect([:rider, :team, :cost, :expected_vg_points, :selection_frequency, :strength, :uncertainty], propertynames(optimal_team))
    write(io, html_table(sort(optimal_team[:, display_cols], :expected_vg_points, rev=true)))
end

# --- Comparison ---

write(io, html_heading("Comparison", 2))

if prediction_ok && nrow(my_selection) > 0 && nrow(optimal_team) > 0
    my_evg = sum(my_selection.expected_vg_points)
    opt_evg = sum(optimal_team.expected_vg_points)
    diff = my_evg - opt_evg
    pct_diff = round(100 * diff / opt_evg, digits=1)
    my_cost = sum(my_selection.cost)
    opt_cost = sum(optimal_team.cost)

    comp_df = DataFrame(
        Metric=["Expected VG points", "Total cost", "Budget remaining", "Riders"],
        Your_team=["$(round(my_evg, digits=1))", "$my_cost", "$(100 - my_cost)", "$(nrow(my_selection))"],
        Optimal_team=["$(round(opt_evg, digits=1))", "$opt_cost", "$(100 - opt_cost)", "$(nrow(optimal_team))"],
        Difference=["$(round(diff, digits=1)) ($(pct_diff)%)", "$(my_cost - opt_cost)", "$(opt_cost - my_cost)", ""],
    )
    write(io, html_table(comp_df))

    my_riders = Set(my_selection.riderkey)
    opt_riders = Set(optimal_team.riderkey)
    shared = intersect(my_riders, opt_riders)
    only_mine = setdiff(my_riders, opt_riders)
    only_optimal = setdiff(opt_riders, my_riders)

    shared_names = sort(String.(filter(row -> row.riderkey in shared, predicted).rider))
    write(io, "<p><strong>Shared riders ($(length(shared))):</strong> $(join(shared_names, ", "))</p>\n")

    if !isempty(only_mine)
        mine_names = sort(String.(filter(row -> row.riderkey in only_mine, predicted).rider))
        write(io, "<p><strong>Only in your team ($(length(only_mine))):</strong> $(join(mine_names, ", "))</p>\n")
    end
    if !isempty(only_optimal)
        opt_names = sort(String.(filter(row -> row.riderkey in only_optimal, predicted).rider))
        write(io, "<p><strong>Only in optimal team ($(length(only_optimal))):</strong> $(join(opt_names, ", "))</p>\n")
    end

    # Swap analysis
    if !isempty(only_mine) && !isempty(only_optimal)
        write(io, html_heading("Swap analysis", 3))
        write(io, "<p>What you'd gain or lose by swapping each of your unique riders for their optimal counterpart.</p>\n")

        my_unique = sort(filter(row -> row.riderkey in only_mine, predicted), :expected_vg_points, rev=true)
        opt_unique = sort(filter(row -> row.riderkey in only_optimal, predicted), :expected_vg_points, rev=true)

        swap_rows = NamedTuple{(:Your_rider, :Exp_pts, :Cost, :Optimal_rider, :Opt_pts, :Opt_cost),Tuple{String,Any,Any,String,Any,Any}}[]
        for i in 1:max(nrow(my_unique), nrow(opt_unique))
            push!(swap_rows, (
                Your_rider=i <= nrow(my_unique) ? String(my_unique[i, :rider]) : "",
                Exp_pts=i <= nrow(my_unique) ? round(my_unique[i, :expected_vg_points], digits=1) : "",
                Cost=i <= nrow(my_unique) ? my_unique[i, :cost] : "",
                Optimal_rider=i <= nrow(opt_unique) ? String(opt_unique[i, :rider]) : "",
                Opt_pts=i <= nrow(opt_unique) ? round(opt_unique[i, :expected_vg_points], digits=1) : "",
                Opt_cost=i <= nrow(opt_unique) ? opt_unique[i, :cost] : "",
            ))
        end
        write(io, html_table(DataFrame(swap_rows)))
    end
end

# ---------------------------------------------------------------------------
# Retrospective (after the race)
# ---------------------------------------------------------------------------

write(io, html_heading("Retrospective", 2))

if !prediction_ok
    write(io, html_callout("Retrospective analysis unavailable — prediction failed."; type="warning"))
elseif vg_race_number == -1
    write(io, html_callout("Retrospective analysis skipped. Set <code>vg_race_number</code> to enable after the race."))
else
    # Fetch actual VG results
    local actual_results = nothing
    if is_stage
        actual_results = try
            suppress_output() do
                getvg_stage_race_totals(race_year, config.slug; cache_config=race_cache)
            end
        catch e
            @warn "Failed to fetch VG stage race totals: $e"
            nothing
        end
    else
        # Auto-detect race number for one-day races
        local actual_race_number = vg_race_number
        if actual_race_number == 0
            try
                vg_racelist = suppress_output() do
                    getvgracelist(race_year; cache_config=race_cache)
                end
                race_info = find_race(race_name)
                detected = match_vg_race_number(
                    race_info !== nothing ? race_info.name : race_name, vg_racelist)
                if detected !== nothing
                    actual_race_number = detected
                end
            catch e
                @warn "Auto-detection failed: $e"
            end
        end

        if actual_race_number > 0
            actual_results = try
                suppress_output() do
                    getvgraceresults(race_year, actual_race_number; cache_config=race_cache)
                end
            catch e
                @warn "Failed to fetch VG race results: $e"
                nothing
            end

            # Archive one-day results
            if !isempty(config.pcs_slug)
                try
                    suppress_output() do
                        archive_race_results(config.pcs_slug, config.year;
                            vg_race_number=actual_race_number, cache_config=race_cache)
                    end
                catch e
                    @warn "Failed to archive race results: $e"
                end
            end
        end
    end

    if actual_results === nothing || nrow(actual_results) == 0
        write(io, html_callout("No VG results available yet. Re-render after the race finishes."))
        else
            # Build full retrospective pool
            all_vg_riders = suppress_output() do
                getvgriders(config.current_url; cache_config=race_cache)
            end

            retro = leftjoin(
                all_vg_riders[:, [:rider, :team, :cost, :riderkey]],
                actual_results[:, [:riderkey, :score]], on=:riderkey)
            retro[!, :actual_vg_points] = coalesce.(retro.score, 0)
            select!(retro, Not(:score))

            if prediction_ok
                pred_cols = intersect([:riderkey, :expected_vg_points, :strength], propertynames(predicted))
                retro = leftjoin(retro, predicted[:, pred_cols], on=:riderkey, makeunique=true)
            else
                retro[!, :expected_vg_points] .= missing
                retro[!, :strength] .= missing
            end

            # PIT values
            pit_values = if sim_vg_points !== nothing && size(sim_vg_points, 1) > 0
                compute_pit_values(predicted, sim_vg_points, retro)
            else
                DataFrame()
            end

            my_retro = filter(row -> row.riderkey in my_keys, retro)
            model_retro = if prediction_ok && nrow(optimal_team) > 0
                filter(row -> row.riderkey in Set(optimal_team.riderkey), retro)
            else
                DataFrame()
            end

            # Hindsight-optimal team
            build_fn = is_stage ? build_model_stage : build_model_oneday
            hindsight_sol = build_fn(retro, config.team_size, :actual_vg_points, :cost; totalcost=100)
            hindsight_team = if hindsight_sol !== nothing
                filter(row -> hindsight_sol[row.riderkey] > 0.5, retro)
            else
                DataFrame()
            end

            # Summary
            my_actual = nrow(my_retro) > 0 ? sum(my_retro.actual_vg_points) : 0
            model_actual = nrow(model_retro) > 0 ? sum(model_retro.actual_vg_points) : 0
            hindsight_actual = nrow(hindsight_team) > 0 ? sum(hindsight_team.actual_vg_points) : 0

            sum_or_na(df, col) = nrow(df) > 0 && col in propertynames(df) && any(!ismissing, df[!, col]) ?
                                 string(round(sum(skipmissing(df[!, col])), digits=1)) : "—"

            my_pcr = hindsight_actual > 0 ? round(100 * my_actual / hindsight_actual, digits=1) : 0.0
            model_pcr = hindsight_actual > 0 && model_actual > 0 ?
                        round(100 * model_actual / hindsight_actual, digits=1) : "—"

            write(io, html_heading("Summary", 3))

            summary_comp = DataFrame(
                Metric=["Actual VG points", "Expected VG points", "Points captured", "Total cost"],
                Your_team=["$my_actual", sum_or_na(my_retro, :expected_vg_points), "$(my_pcr)%",
                    nrow(my_retro) > 0 ? string(sum(my_retro.cost)) : "—"],
                Models_team=[model_actual > 0 ? "$model_actual" : "—", sum_or_na(model_retro, :expected_vg_points),
                    model_pcr isa Number ? "$(model_pcr)%" : string(model_pcr),
                    nrow(model_retro) > 0 ? string(sum(model_retro.cost)) : "—"],
                Hindsight_optimal=["$hindsight_actual", "—", "100%",
                    nrow(hindsight_team) > 0 ? string(sum(hindsight_team.cost)) : "—"],
            )
            write(io, html_table(summary_comp))

            # Model calibration summary
            if nrow(pit_values) > 0
                scored_pv = filter(:scored => identity, pit_values)
                if nrow(scored_pv) > 0
                    mean_pit = round(mean(scored_pv.pit_value), digits=2)
                    unc_lo, unc_hi = round.(extrema(predicted.uncertainty), digits=2)
                    label = mean_pit > 0.6 ? "underestimates scoring riders" : mean_pit < 0.4 ? "overestimates scoring riders" : "well-calibrated"
                    write(io, "<p><strong>Model calibration:</strong> uncertainty range $(unc_lo)–$(unc_hi) | mean PIT (scoring riders) = $mean_pit | $label</p>\n")
                end
            end

            # Per-rider detail
            retro_cols = [:rider, :team, :cost, :actual_vg_points]
            :expected_vg_points in propertynames(retro) && push!(retro_cols, :expected_vg_points)
            :strength in propertynames(retro) && push!(retro_cols, :strength)

            write(io, html_heading("Your team", 3))
            if nrow(my_retro) > 0
                write(io, html_table(sort(my_retro[:, retro_cols], :actual_vg_points, rev=true)))
            else
                write(io, "<p>No riders matched to results.</p>\n")
            end

            write(io, html_heading("Model's team", 3))
            if nrow(model_retro) > 0
                write(io, html_table(sort(model_retro[:, retro_cols], :actual_vg_points, rev=true)))
            else
                write(io, "<p>No model team available.</p>\n")
            end

            write(io, html_heading("Hindsight-optimal team", 3))
            if nrow(hindsight_team) > 0
                write(io, html_table(sort(hindsight_team[:, retro_cols], :actual_vg_points, rev=true)))
            end

            # Distribution charts
            if sim_vg_points !== nothing && size(sim_vg_points, 1) > 0
                write(io, html_heading("Simulated points distributions", 3))
                write(io, "<p>Box plots show VG points across $(size(sim_vg_points, 2)) simulations. Red diamonds mark actual results.</p>\n")

                for (team_label, team_retro) in [
                    ("Your team", my_retro),
                    ("Model's team", model_retro),
                    ("Hindsight-optimal team", hindsight_team),
                ]
                    nrow(team_retro) == 0 && continue
                    plot_df = copy(team_retro)
                    if :expected_vg_points ∉ propertynames(plot_df)
                        plot_df[!, :expected_vg_points] .= 0.0
                    else
                        plot_df[!, :expected_vg_points] = coalesce.(plot_df.expected_vg_points, 0.0)
                    end
                    write(io, sim_distribution_chart(
                        plot_df, predicted, sim_vg_points;
                        actual_results=team_retro, title=team_label))
                end
            end

            # PIT calibration
            if nrow(pit_values) > 0
                scored_pit = filter(:scored => identity, pit_values)
                n_scored = nrow(scored_pit)

                n_total_pit = nrow(pit_values)
                n_zero = nrow(filter(:scored => !, pit_values))
                actual_zero_pct = round(100 * n_zero / n_total_pit, digits=1)

                write(io, html_heading("VG points calibration", 3))
                write(io, "<p><strong>Zero-score calibration:</strong> $(actual_zero_pct)% of riders scored zero vs predicted.</p>\n")

                if n_scored > 0
                    write(io, pit_histogram_chart(pit_values;
                        title="PIT calibration — $(config.name) $(config.year)"))
                end

                # Team total distributions
                write(io, html_heading("Team total distributions", 3))
                for (team_label, team_retro) in [
                    ("Your team", my_retro),
                    ("Model's team", model_retro),
                    ("Hindsight-optimal team", hindsight_team),
                ]
                    nrow(team_retro) == 0 && continue
                    team_keys = String.(team_retro.riderkey)
                    actual_total = Float64(sum(team_retro.actual_vg_points))
                    write(io, team_total_distribution_chart(
                        team_keys, predicted, sim_vg_points;
                        actual_total=actual_total, title=team_label))
                end
            end

            # Prediction misses
            retro_with_preds = filter(row -> !ismissing(row.expected_vg_points), retro)
            if nrow(retro_with_preds) > 0
                retro_with_preds[!, :prediction_error] = retro_with_preds.actual_vg_points .- retro_with_preds.expected_vg_points
                retro_sorted = sort(retro_with_preds, :prediction_error, rev=true)

                write(io, html_heading("Prediction misses", 3))

                write(io, html_heading("Underestimated (actual > expected)", 4))
                top_under = filter(row -> row.prediction_error > 0, first(retro_sorted, min(10, nrow(retro_sorted))))
                if nrow(top_under) > 0
                    write(io, html_table(top_under[:, [:rider, :team, :cost, :expected_vg_points, :actual_vg_points, :prediction_error]]))
                else
                    write(io, "<p>No significant underestimates.</p>\n")
                end

                write(io, html_heading("Overestimated (expected > actual)", 4))
                top_over = filter(row -> row.prediction_error < 0, sort(last(retro_sorted, min(10, nrow(retro_sorted))), :prediction_error))
                if nrow(top_over) > 0
                    write(io, html_table(top_over[:, [:rider, :team, :cost, :expected_vg_points, :actual_vg_points, :prediction_error]]))
                else
                    write(io, "<p>No significant overestimates.</p>\n")
                end
            end

            # Prospective model evaluation
            if !isempty(config.pcs_slug)
                prosp = evaluate_prospective(config.pcs_slug, config.year)
                if prosp !== nothing
                    write(io, html_heading("Model evaluation", 3))
                    write(io, "<p>Comparing archived pre-race predictions against actual PCS results.</p>\n")
                    eval_df = DataFrame(
                        Metric=["Matched riders", "Spearman rho", "Top-5 overlap", "Top-10 overlap", "Mean abs rank error"],
                        Value=[prosp.n_matched, round(prosp.spearman_rho, digits=3),
                            "$(prosp.top5_overlap) / 5", "$(prosp.top10_overlap) / 10",
                            round(prosp.mean_abs_rank_error, digits=1)],
                    )
                    write(io, html_table(eval_df))
                end
            end
        end
    end

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------

body = String(take!(io))
page = html_page(;
    title="Team assessor",
    subtitle="$(titlecase(config.name)) $(config.year) — compare a custom team against the optimal selection",
    body=body,
)

output_dir = joinpath(@__DIR__, "..", get(get(_cfg, "output", Dict()), "dir", "prediction_docs"))
mkpath(output_dir)
output_path = joinpath(output_dir, "assessor.html")
write(output_path, page)
@info "Written to $output_path"
