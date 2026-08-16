#!/usr/bin/env julia
"""
Render the one-day predictor report as a standalone HTML page.

Usage:
    julia --project scripts/render_predictor.jl [--fresh] [--force]

Options:
    --fresh   Bypass cache, fetch all data fresh from the web
    --force   Overwrite existing prediction archive (default: skip if exists)
"""

using Velogames, DataFrames, Statistics, Dates

function render_predictor(rc::RenderConfig)
    rc.race.type == :oneday || error(
        "render_predictor is for one-day races; $(rc.race.name) is a stage race — use render_stagerace.jl",
    )

    config = rc.race
    history_years = rc.history_years
    n_resamples = rc.n_resamples
    market_blend_weight = rc.market_blend_weight

    @info "Configuration" race = config.name year = config.year
    scoring = get_scoring(config.category > 0 ? config.category : 2)

    # Note: predictions are archived by solve_oneday() via _archive_predictions().
    # The archive is protected: existing archives are not overwritten unless
    # the VELOGAMES_FORCE_ARCHIVE environment variable is set.
    predicted, chosenteam, top_teams, sim_vg_points = solve_oneday(rc)

    if nrow(predicted) == 0
        error("No riders found — check race name, year, and startlist hash filter.")
    end

    # ---------------------------------------------------------------------------
    # Build page content
    # ---------------------------------------------------------------------------

    io = IOBuffer()

    # --- Race summary ---

    n_total = nrow(predicted)
    write(
        io,
        "<p><strong>$(titlecase(config.name)) $(config.year)</strong> — Category $(config.category), $(n_total) riders, $(n_resamples) resamples</p>\n",
    )

    # --- Data sources ---

    n_pcs = count(predicted.has_pcs)
    n_history = count(predicted.has_race_history)
    n_odds = count(predicted.has_odds)
    n_oracle = count(predicted.has_oracle)
    pct(n) = round(Int, 100 * n / n_total)

    similar_races = get(SIMILAR_RACES, config.pcs_slug, String[])
    similar_str = isempty(similar_races) ? "None configured" : join(similar_races, ", ")

    sources_df = DataFrame(
        Source = [
            "PCS season points",
            "VG season points",
            "PCS race history ($(history_years) yrs)",
            "Similar races",
            "Cycling Oracle",
            "Odds",
        ],
        Coverage = [
            "$(n_pcs)/$(n_total) ($(pct(n_pcs))%)",
            "$(n_total)/$(n_total) (100%)",
            "$(n_history)/$(n_total) ($(pct(n_history))%)",
            similar_str,
            "$(n_oracle)/$(n_total) ($(pct(n_oracle))%)",
            "$(n_odds)/$(n_total) ($(pct(n_odds))%)",
        ],
    )

    sources_html = html_table(sources_df)
    budget = precision_budget(DEFAULT_BAYESIAN_CONFIG; n_history_years = history_years)
    sources_html *= "<p>Precision budget:</p>\n" * html_table(budget)
    write(io, html_callout(sources_html; title = "Data sources", collapsed = false))

    # --- Signal impact ---

    rms(v) = sqrt(mean(v .^ 2))
    signal_names =
        ["PCS seasons", "VG season points", "PCS race history", "Cycling Oracle", "Odds"]
    shift_cols = [:shift_pcs, :shift_vg, :shift_history, :shift_oracle, :shift_odds]
    affected_counts = [count(!=(0.0), predicted[!, c]) for c in shift_cols]
    rms_shifts = [rms(predicted[!, c]) for c in shift_cols]

    impact_df = DataFrame(
        Signal = signal_names,
        Riders_affected = affected_counts,
        RMS_shift = round.(rms_shifts, digits = 3),
    )
    write(
        io,
        html_callout(
            "<p>How much each source shifted rider strength estimates from the uninformative prior.</p>\n" *
            html_table(impact_df);
            title = "Signal impact",
            collapsed = true,
        ),
    )

    # --- Optimal team ---

    write(io, html_heading("Your optimal team", 2))

    if nrow(chosenteam) > 0
        total_cost = sum(chosenteam.cost)
        total_evg = sum(chosenteam.expected_vg_points)

        write(
            io,
            "<p><strong>Total cost:</strong> $(total_cost) / 100 credits | <strong>Expected VG points:</strong> $(round(total_evg, digits=1)) | <strong>Budget remaining:</strong> $(100 - total_cost)</p>\n",
        )

        if :market_blend_points in propertynames(predicted)
            write(
                io,
                html_callout(
                    "The team was picked on a blend of the simulator and the bookmaker market " *
                    "(<code>market_blend_weight = $(market_blend_weight)</code>), so it need not be the " *
                    "top-6 by expected VG points alone. <code>market_blend_points</code> is the " *
                    "blended score actually optimised.";
                    title = "Market blend active",
                ),
            )
        end

        display_cols = intersect(
            [
                :rider,
                :team,
                :cost,
                :expected_vg_points,
                :market_blend_points,
                :selection_frequency,
                :strength,
                :uncertainty,
            ],
            propertynames(chosenteam),
        )
        write(
            io,
            html_table(sort(chosenteam[:, display_cols], :expected_vg_points, rev = true)),
        )

        # Signal breakdown
        waterfall =
            format_signal_waterfall(sort(chosenteam, :expected_vg_points, rev = true))
        write(
            io,
            html_callout(
                "<p>How each signal shifted the strength estimate for riders in your team.</p>\n" *
                waterfall;
                title = "Signal breakdown",
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
    # The forks must re-solve on whatever column the team was actually picked on,
    # or they would describe a different roster from the one shown above.
    if length(top_teams) > 0
        write(
            io,
            format_near_optimal_section(
                top_teams,
                predicted,
                build_model_oneday;
                team_size = config.team_size,
                max_per_team = rc.max_per_team,
                points_col = :market_blend_points in propertynames(predicted) ?
                             :market_blend_points : :expected_vg_points,
            ),
        )
    end

    # --- Full rankings + alternative picks (shared with the stage-race report) ---

    write(
        io,
        format_rankings_and_alternatives(
            predicted,
            chosenteam;
            ranking_cols = [
                :rider,
                :team,
                :cost,
                :expected_vg_points,
                :market_blend_points,
                :selection_frequency,
                :strength,
                :uncertainty,
                :chosen,
            ],
        ),
    )

    page = html_page(;
        title = "Sixes Classics team builder",
        subtitle = "$(titlecase(config.name)) $(config.year) — Monte Carlo simulation-based fantasy cycling team optimiser",
        body = String(take!(io)),
    )
    return write_report(page, rc.output_dir, "predictor.html")
end

if abspath(PROGRAM_FILE) == @__FILE__
    "--force" in ARGS && (ENV["VELOGAMES_FORCE_ARCHIVE"] = "1")
    render_predictor(load_render_config(; fresh = "--fresh" in ARGS))
end
