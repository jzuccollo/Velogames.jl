#!/usr/bin/env julia
"""
Render the stage race predictor report as a standalone HTML page.

Uses per-stage simulation with stage-type strength modifiers when stage profiles
are available (via PCS scraping or manual definition). Falls back to the aggregate
approach when no stage profiles are provided.

Usage:
    julia --project scripts/render_stagerace.jl [--fresh] [--force]

Options:
    --fresh   Bypass cache, fetch all data fresh from the web
    --force   Overwrite existing prediction archive (default: skip if exists)
"""

using Velogames, DataFrames, Statistics, Dates

function render_stagerace(rc::RenderConfig)
    rc.race.type == :stage || error(
        "render_stagerace is for stage races; $(rc.race.name) is a one-day race — use render_predictor.jl",
    )

    config = rc.race
    history_years = rc.history_years
    n_resamples = rc.n_resamples
    max_per_team = rc.max_per_team
    cross_stage_alpha = rc.cross_stage_alpha

    @info "Configuration" race = config.name year = config.year

    # Single assignment: `stages` is captured by a comprehension further down, and
    # a reassigned captured variable would be boxed.
    stages = if rc.pcs_stage_scrape && !isempty(config.pcs_slug)
        @info "Scraping stage profiles from PCS..."
        scraped = getpcs_stage_profiles(
            config.pcs_slug,
            config.year;
            cache_config = config.cache,
            force_refresh = rc.fresh,
        )
        if isempty(scraped)
            @warn "PCS stage scraping returned no stages — falling back to aggregate approach"
        else
            @info "Got $(length(scraped)) stage profiles from PCS"
        end
        scraped
    else
        StageProfile[]
    end

    using_per_stage = !isempty(stages)

    # Scrape race-specific scoring from VG
    stage_scoring = try
        getvg_scoring(config.slug, config.year; pcs_slug = config.pcs_slug)
    catch e
        @warn "Failed to scrape VG scoring, using grand tour defaults: $e"
        nothing
    end

    result = solve_stage(rc, stages, stage_scoring)

    predicted = result.predicted
    chosenteam = result.chosenteam
    top_teams = result.top_teams
    sim_vg_points = result.sim_vg_points
    diagnostics = result.diagnostics

    if nrow(predicted) == 0
        error("No riders found — check race name, year, and startlist hash filter.")
    end

    # ---------------------------------------------------------------------------
    # Build page content
    # ---------------------------------------------------------------------------

    io = IOBuffer()

    n_total = nrow(predicted)
    approach_str =
        using_per_stage ? "Per-stage simulation ($(length(stages)) stages)" :
        "Aggregate GC model"
    write(
        io,
        "<p><strong>$(titlecase(config.name)) $(config.year)</strong> — $approach_str, $(n_total) riders, $(n_resamples) resamples</p>\n",
    )

    # --- Stage profile summary ---

    if using_per_stage
        stage_types = [s.stage_type for s in stages]
        n_flat = count(==(:flat), stage_types)
        n_hilly = count(==(:hilly), stage_types)
        n_mountain = count(==(:mountain), stage_types)
        n_itt = count(==(:itt), stage_types)
        n_ttt = count(==(:ttt), stage_types)

        write(io, html_heading("Stage profile", 2))
        write(
            io,
            "<p><strong>$(length(stages)) stages:</strong> $n_flat flat, $n_hilly hilly, $n_mountain mountain, $n_itt ITT, $n_ttt TTT</p>\n",
        )
        write(io, "<p>Cross-stage correlation α=$(cross_stage_alpha)</p>\n")

        if diagnostics !== nothing
            stage_df = format_stage_podium_picks(diagnostics, stages, predicted)
            stage_col_order = [
                "Stage",
                "Type",
                "Distance",
                "ProfileScore",
                "Vert",
                "Summit",
                "HC",
                "Cat1",
                "Likely 1st",
                "Likely 2nd",
                "Likely 3rd",
            ]
            write(
                io,
                html_callout(
                    "<p>Most likely podium finishers per stage, alongside basic stage details. Probabilities in parentheses are the share of $(diagnostics.n_sims) simulations in which the named rider finished in that exact position. Each column names a distinct rider (the modal occupant of that position, excluding riders already shown to its left).</p>\n" *
                    "<p><em>Caveat:</em> the simulation does not model breakaway participation, so treat these picks as the favourites' odds <em>conditional on the stage being contested by the front group</em> — actual single-stage win rates are lower and more spread out.</p>\n" *
                    html_table(stage_df[:, stage_col_order]);
                    title = "Stage details and podium picks",
                    collapsed = false,
                ),
            )
        end
    end

    # --- Data sources ---

    n_pcs = count(predicted.has_pcs)
    n_history = count(predicted.has_race_history)
    n_odds = count(predicted.has_odds)
    n_oracle = count(predicted.has_oracle)
    n_points_oracle =
        :has_points_oracle in propertynames(predicted) ?
        count(predicted.has_points_oracle) : 0
    n_kom_oracle =
        :has_kom_oracle in propertynames(predicted) ? count(predicted.has_kom_oracle) : 0
    n_vg_hist = count(predicted.has_vg_history)
    pct(n) = round(Int, 100 * n / n_total)

    similar_races = get(SIMILAR_RACES, config.pcs_slug, String[])
    similar_str = isempty(similar_races) ? "None configured" : join(similar_races, ", ")

    sources_df = DataFrame(
        Source = [
            "PCS specialty (per-source)",
            "VG season points",
            "PCS race history ($(history_years) yrs)",
            "Similar races",
            "VG race history",
            "Oracle GC",
            "Oracle Points",
            "Oracle KOM",
            "Odds",
        ],
        Coverage = [
            "$(n_pcs)/$(n_total) ($(pct(n_pcs))%)",
            "$(n_total)/$(n_total) (100%)",
            "$(n_history)/$(n_total) ($(pct(n_history))%)",
            similar_str,
            "$(n_vg_hist)/$(n_total) ($(pct(n_vg_hist))%)",
            "$(n_oracle)/$(n_total) ($(pct(n_oracle))%)",
            "$(n_points_oracle)/$(n_total) ($(pct(n_points_oracle))%)",
            "$(n_kom_oracle)/$(n_total) ($(pct(n_kom_oracle))%)",
            "$(n_odds)/$(n_total) ($(pct(n_odds))%)",
        ],
    )

    sources_html = html_table(sources_df)
    sources_html *= "<p>PCS specialty (sprint, oneday, climber, tt, gc) is routed per-source to the strength dimensions it informs. GC-flavoured market signals (Oracle GC + odds) only update the <code>:gc</code> dimension; points-jersey oracle updates <code>:flat</code>/<code>:hilly</code>; KOM oracle updates <code>:mountain</code>.</p>\n"
    write(io, html_callout(sources_html; title = "Data sources", collapsed = false))

    # --- Signal impact (per-dimension) ---

    write(
        io,
        html_callout(
            "<p>Per-dimension RMS shift in posterior mean from each signal. Note GC-flavoured floors (Oracle GC, Odds) only touch the GC column — sprinters absent from those markets are no longer penalised on their flat/hilly dimensions.</p>\n" *
            format_signal_impact_per_dim(predicted);
            title = "Signal impact (per dimension)",
            collapsed = true,
        ),
    )

    # --- Classification predictions (GC, Points, KOM, Team) ---

    if diagnostics !== nothing
        write(io, html_heading("Final classification predictions", 2))
        write(
            io,
            "<p>Top riders by probability of finishing in each classification's prize positions, summarised across $(diagnostics.n_sims) simulated grand tours. The win column shows the share of simulations in which they finished 1st; the top-N column shows the share they finished anywhere in the prize positions.</p>\n",
        )

        write(io, html_heading("General classification (GC)", 3))
        write(io, format_classification_table(diagnostics, :gc, predicted))

        write(io, html_heading("Points classification", 3))
        write(io, format_classification_table(diagnostics, :points, predicted))

        write(io, html_heading("Mountains classification (KOM)", 3))
        write(io, format_classification_table(diagnostics, :mountains, predicted))

        write(io, html_heading("Team classification", 3))
        write(io, format_team_classification(diagnostics))
    end

    # --- Per-dimension strength distributions by class ---

    if :strength_flat in propertynames(predicted)
        write(io, html_heading("Per-dimension strength profile", 2))
        write(
            io,
            "<p>Mean rider strength on each dimension, broken down by classification. Higher = predicted to finish better on that stage type.</p>\n",
        )

        class_col =
            :classraw in propertynames(predicted) ? :classraw :
            :class in propertynames(predicted) ? :class : nothing

        if class_col !== nothing
            classes = sort(unique(lowercase.(string.(predicted[!, class_col]))))
            type_cols = [
                :strength_flat,
                :strength_hilly,
                :strength_mountain,
                :strength_itt,
                :strength_gc,
                :strength_kom,
            ]
            type_labels = ["Flat", "Hilly", "Mountain", "ITT", "GC", "KOM"]

            summary_rows = []
            for cls in classes
                mask = lowercase.(string.(predicted[!, class_col])) .== cls
                row = Dict("Class" => titlecase(cls), "N" => count(mask))
                for (col, label) in zip(type_cols, type_labels)
                    row[label] = round(mean(predicted[mask, col]), digits = 2)
                end
                push!(summary_rows, row)
            end
            summary_df = DataFrame(summary_rows)
            col_order = intersect(
                ["Class", "N", "Flat", "Hilly", "Mountain", "ITT", "GC", "KOM"],
                names(summary_df),
            )
            write(io, html_table(summary_df[:, col_order]))
        end
    end

    # --- Optimal team ---

    write(io, html_heading("Your optimal team", 2))

    if nrow(chosenteam) > 0
        total_cost = sum(chosenteam.cost)
        total_evg = sum(chosenteam.expected_vg_points)

        write(
            io,
            "<p><strong>Total cost:</strong> $(total_cost) / 100 credits | <strong>Expected VG points:</strong> $(round(total_evg, digits=1)) | <strong>Budget remaining:</strong> $(100 - total_cost)</p>\n",
        )

        # Classification breakdown
        if hasproperty(chosenteam, :classraw)
            classes = sort(unique(chosenteam.classraw))
            class_str =
                join(["$(c): $(count(chosenteam.classraw .== c))" for c in classes], " | ")
            write(io, "<p><strong>Classes:</strong> $(class_str)</p>\n")
        end

        # Include per-dimension strengths in team table
        base_cols = [
            :rider,
            :team,
            :classraw,
            :cost,
            :expected_vg_points,
            :selection_frequency,
            :strength_gc,
            :uncertainty_gc,
        ]
        dim_cols = [
            :strength_flat,
            :strength_hilly,
            :strength_mountain,
            :strength_itt,
            :strength_kom,
        ]
        all_display_cols = vcat(base_cols, dim_cols)
        display_cols = intersect(all_display_cols, propertynames(chosenteam))
        write(
            io,
            html_table(sort(chosenteam[:, display_cols], :expected_vg_points, rev = true)),
        )

        # Signal breakdown — order-invariant info-share percentages (signal precision /
        # total observed precision per rider). Sums to 100% across signals per rider.
        waterfall =
            format_signal_waterfall(sort(chosenteam, :expected_vg_points, rev = true))
        write(
            io,
            html_callout(
                "<p>Each cell shows the share of total observed precision contributed by that signal — order-invariant, summing to 100% across signals per rider. Market signals are split by jersey (GC / points / KOM / stage-win), so a rider whose <em>Odds KOM</em> cell shows 70% is favoured mainly for the mountains classification, not the overall.</p>\n" *
                waterfall;
                title = "Signal breakdown (info share)",
                collapsed = true,
            ),
        )

        # Per-dimension info-share heatmap — diagnoses which signals drove which
        # dimension for each chosen rider (useful when ranking depends on multi-
        # dim simulation, not just the scalar :gc strength).
        info_share_dim =
            format_info_share_per_dim(sort(chosenteam, :expected_vg_points, rev = true))
        write(
            io,
            html_callout(
                "<p>Per-dimension info share for your team. Each signal block has 6 columns (F=flat, H=hilly, M=mountain, I=ITT, G=gc, K=kom); cells show the percent of total observed precision on that dimension contributed by that signal. Order-invariant.</p>\n" *
                info_share_dim;
                title = "Per-dimension info share (chosen team)",
                collapsed = true,
            ),
        )
    else
        write(
            io,
            html_callout(
                "No optimal team generated — check configuration and try again.";
                type = "warning",
            ),
        )
    end

    # --- Near-optimal team set: switcher + filler pool + structural forks ---
    # Uses the live `predicted` frame (which carries the class columns the archive
    # lacks) and the k-best `top_teams` returned by the solver.
    if length(top_teams) > 0
        write(
            io,
            format_near_optimal_section(
                top_teams,
                predicted,
                build_model_stage;
                team_size = config.team_size,
                max_per_team = max_per_team,
            ),
        )
    end

    # --- Full rankings + alternative picks (shared with the one-day report) ---

    write(
        io,
        format_rankings_and_alternatives(
            predicted,
            chosenteam;
            ranking_cols = [
                :rider,
                :team,
                :classraw,
                :cost,
                :expected_vg_points,
                :selection_frequency,
                :strength_gc,
                :uncertainty_gc,
                :chosen,
                :strength_flat,
                :strength_hilly,
                :strength_mountain,
                :strength_itt,
                :strength_kom,
            ],
        ),
    )

    page = html_page(;
        title = "Stage race team builder",
        subtitle = "$(titlecase(config.name)) $(config.year) — $approach_str",
        body = String(take!(io)),
    )
    return write_report(page, rc.output_dir, "stagerace.html")
end

if abspath(PROGRAM_FILE) == @__FILE__
    "--force" in ARGS && (ENV["VELOGAMES_FORCE_ARCHIVE"] = "1")
    render_stagerace(load_render_config(; fresh = "--fresh" in ARGS))
end
