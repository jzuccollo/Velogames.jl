#!/usr/bin/env julia
"""
Render all race report pages for the Velogames retrospective site.

Usage:
    julia --project scripts/render_reports.jl [--years=2025,2026] [--force] [--fresh]

Options:
    --force   Regenerate all reports (default: skip existing HTML files)
    --fresh   Bypass cache, fetch all data fresh from the web

Generates standalone HTML pages directly (no Quarto dependency).
Auto-archives VG/PCS results if not already archived.
"""

using Velogames, DataFrames, Dates, Statistics, TOML
using PlotlyBase

const FRESH = "--fresh" in ARGS

function load_league_winners()
    toml_path = joinpath(@__DIR__, "..", "data", "league_winners.toml")
    data = TOML.parsefile(toml_path)
    winners = Dict{Tuple{String,Int},NamedTuple{(:name, :score),Tuple{String,Int}}}()
    for w in get(data, "winners", [])
        winners[(w["pcs_slug"], w["year"])] = (name=w["name"], score=w["score"])
    end
    return winners
end

const _report_cache = CacheConfig(joinpath(homedir(), ".velogames_cache"), FRESH ? 0 : 168)

# ---------------------------------------------------------------------------
# Shared report section helpers (used by both report_html and stage_race_report_html)
# ---------------------------------------------------------------------------

"""Write "Points scored by price" scatter plot with OLS trend line.
Returns (; jitter, costs_f, mean_c, x_min, x_max) for reuse by _write_points_per_credit!."""
function _write_points_by_price!(io::IOBuffer, allriders::DataFrame, optimal_keys::Set{String})
    write(io, html_heading("Was it worth paying more?", 2))
    write(io, html_heading("Points scored by price", 3))
    write(io, "<p>Each dot is a rider. The dashed line shows the general trend.</p>\n")

    nrow(allriders) == 0 && return (; jitter=Float64[], costs_f=Float64[], mean_c=0.0, x_min=0, x_max=1)

    jitter = (rand(nrow(allriders)) .- 0.5) .* 0.3
    traces = GenericTrace[]

    zeroes_mask = allriders.score .== 0
    zeroes = allriders[zeroes_mask, :]
    if nrow(zeroes) > 0
        push!(traces, PlotlyBase.scatter(
            x=zeroes.cost .+ jitter[zeroes_mask], y=zeroes.score,
            mode="markers", name="Did not score",
            marker=attr(size=5, opacity=0.35, color="#aaaaaa", symbol="x"),
            text=["$(r.rider) ($(r.team))<br>Cost: $(r.cost), Points: 0" for r in eachrow(zeroes)],
            hoverinfo="text"))
    end

    for (label, is_opt) in [("Other riders", false), ("Optimal team", true)]
        mask = (allriders.score .> 0) .& ([k in optimal_keys for k in allriders.riderkey] .== is_opt)
        sub = allriders[mask, :]
        nrow(sub) == 0 && continue
        push!(traces, PlotlyBase.scatter(
            x=sub.cost .+ jitter[mask], y=sub.score,
            mode="markers", name=label,
            marker=attr(size=is_opt ? 10 : 6, opacity=is_opt ? 0.9 : 0.5),
            text=["$(r.rider) ($(r.team))<br>Cost: $(r.cost), Points: $(r.score), Value: $(r.value)" for r in eachrow(sub)],
            hoverinfo="text"))
    end

    costs_f = Float64.(allriders.cost)
    scores_f = Float64.(allriders.score)
    mean_c, mean_s = mean(costs_f), mean(scores_f)
    β_pts = sum((costs_f .- mean_c) .* (scores_f .- mean_s)) / sum((costs_f .- mean_c) .^ 2)
    α_pts = mean_s - β_pts * mean_c
    x_min, x_max = minimum(allriders.cost), maximum(allriders.cost)
    trend_label = abs(β_pts) < 0.5 ? "Trend (no clear pattern)" : β_pts > 0 ? "Trend (pricier riders scored more)" : "Trend (cheaper riders were better value)"
    push!(traces, PlotlyBase.scatter(
        x=[x_min, x_max], y=[α_pts + β_pts * x_min, α_pts + β_pts * x_max],
        mode="lines", name=trend_label,
        line=attr(color="#666666", dash="dash", width=1.5), hoverinfo="skip"))

    write(io, plotly_html(traces, Layout(
            xaxis_title="Cost (credits)", yaxis_title="Points scored",
            hovermode="closest", template="plotly_white"); id="plot-pts"))

    return (; jitter, costs_f, mean_c, x_min, x_max)
end

"""Write "Points per credit by price" scatter plot with OLS trend line."""
function _write_points_per_credit!(io::IOBuffer, allriders::DataFrame, optimal_keys::Set{String},
    jitter, costs_f, mean_c, x_min, x_max)
    write(io, html_heading("Points per credit by price", 3))
    write(io, "<p>How efficiently each rider converted their price tag into points.</p>\n")

    nrow(allriders) == 0 && return

    traces2 = GenericTrace[]
    zeroes_mask2 = allriders.score .== 0
    zeroes2 = allriders[zeroes_mask2, :]
    if nrow(zeroes2) > 0
        push!(traces2, PlotlyBase.scatter(
            x=zeroes2.cost .+ jitter[zeroes_mask2], y=zeroes2.value,
            mode="markers", name="Did not score",
            marker=attr(size=5, opacity=0.35, color="#aaaaaa", symbol="x"),
            text=["$(r.rider) ($(r.team))<br>Cost: $(r.cost), Points: 0, Value: 0" for r in eachrow(zeroes2)],
            hoverinfo="text"))
    end

    for (label, is_opt) in [("Other riders", false), ("Optimal team", true)]
        mask = (allriders.score .> 0) .& ([k in optimal_keys for k in allriders.riderkey] .== is_opt)
        sub = allriders[mask, :]
        nrow(sub) == 0 && continue
        push!(traces2, PlotlyBase.scatter(
            x=sub.cost .+ jitter[mask], y=sub.value,
            mode="markers", name=label,
            marker=attr(size=is_opt ? 10 : 6, opacity=is_opt ? 0.9 : 0.5),
            text=["$(r.rider) ($(r.team))<br>Cost: $(r.cost), Points: $(r.score), Value: $(r.value)" for r in eachrow(sub)],
            hoverinfo="text"))
    end

    values_f = Float64.(allriders.value)
    mean_v = mean(values_f)
    β_val = sum((costs_f .- mean_c) .* (values_f .- mean_v)) / sum((costs_f .- mean_c) .^ 2)
    α_val = mean_v - β_val * mean_c
    trend_label2 = abs(β_val) < 0.05 ? "Trend (no clear pattern)" : β_val > 0 ? "Trend (pricier riders were more efficient)" : "Trend (cheaper riders were more efficient)"
    push!(traces2, PlotlyBase.scatter(
        x=[x_min, x_max], y=[α_val + β_val * x_min, α_val + β_val * x_max],
        mode="lines", name=trend_label2,
        line=attr(color="#666666", dash="dash", width=1.5), hoverinfo="skip"))

    write(io, plotly_html(traces2, Layout(
            xaxis_title="Cost (credits)", yaxis_title="Value (points per credit)",
            hovermode="closest", template="plotly_white"); id="plot-val"))
end

"""Write top scorers table."""
function _write_top_scorers!(io::IOBuffer, scorers::DataFrame;
    has_class::Bool=false, heading::String="Top scorers")
    write(io, html_heading(heading, 3))
    top_n = min(15, nrow(scorers))
    top_cols = [:rider, :team, :cost, :score, :value]
    has_class && push!(top_cols, :class)
    top = scorers[1:top_n, top_cols]
    col_renames = [:rider => :Rider, :team => :Team, :cost => :Cost,
        :score => :Points, :value => :Value]
    has_class && push!(col_renames, :class => :Class)
    rename!(top, col_renames...)
    write(io, html_table(top))
end

"""Write best value picks table."""
function _write_best_value!(io::IOBuffer, scorers::DataFrame; has_class::Bool=false)
    write(io, html_heading("Best value picks", 3))
    write(io, "<p>The ten riders who scored the most points per credit spent.</p>\n")
    best_value = sort(scorers, :value, rev=true)
    bv_cols = [:rider, :team, :cost, :score, :value]
    has_class && push!(bv_cols, :class)
    top_val = best_value[1:min(10, nrow(best_value)), bv_cols]
    col_renames = [:rider => :Rider, :team => :Team, :cost => :Cost,
        :score => :Points, :value => :Value]
    has_class && push!(col_renames, :class => :Class)
    rename!(top_val, col_renames...)
    write(io, html_table(top_val))
end

"""Write "The ones to avoid" section: priciest blanks and premium disappointments."""
function _write_ones_to_avoid!(io::IOBuffer, allriders::DataFrame)
    write(io, html_heading("The ones to avoid", 2))

    write(io, html_heading("Priciest blanks", 3))
    write(io, "<p>The most expensive riders who failed to score a single point.</p>\n")
    pricey_zeroes = filter(row -> row.cost >= 8 && row.score == 0, allriders)
    if nrow(pricey_zeroes) > 0
        sort!(pricey_zeroes, :cost, rev=true)
        display_df = pricey_zeroes[1:min(5, nrow(pricey_zeroes)), [:rider, :team, :cost, :score]]
        rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost, :score => :Points)
        write(io, html_table(display_df))
    end

    write(io, html_heading("Biggest premium disappointments", 3))
    write(io, "<p>The five most expensive riders (8+ credits) who scored the least for their price.</p>\n")
    premium = filter(row -> row.cost >= 8 && row.score > 0, allriders)
    if nrow(premium) > 0
        sort!(premium, :value)
        display_df = premium[1:min(5, nrow(premium)), [:rider, :team, :cost, :score, :value]]
        rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost,
            :score => :Points, :value => Symbol("Pts/credit"))
        write(io, html_table(display_df))
    end
end

"""Write team performance table."""
function _write_team_performance!(io::IOBuffer, allriders::DataFrame)
    write(io, html_heading("How did the teams fare?", 2))
    write(io, "<p>Which squads delivered the most points across all their riders?</p>\n")
    team_stats = combine(
        groupby(allriders, :team),
        :score => sum => :total_points,
        :cost => sum => :total_cost,
        :score => (s -> count(>(0), s)) => :scorers,
        nrow => :riders,
    )
    team_stats[!, :avg_value] = round.(team_stats.total_points ./ max.(team_stats.total_cost, 1), digits=1)
    sort!(team_stats, :total_points, rev=true)
    top_teams = team_stats[1:min(10, nrow(team_stats)), :]
    rename!(top_teams, :team => :Team, :total_points => :Points, :total_cost => :Cost,
        :scorers => :Scorers, :riders => :Starters, :avg_value => Symbol("Pts/credit"))
    write(io, html_table(top_teams))
end

"""Ensure VG and PCS results are archived for a race, fetching if needed."""
function _ensure_results_archived(pcs_slug::String, year::Int)
    # Already archived?
    load_race_snapshot("vg_results", pcs_slug, year) !== nothing && return

    # Auto-detect VG race number
    vg_race_number = 0
    try
        vg_racelist = suppress_output() do
            getvgracelist(year; cache_config=_report_cache)
        end
        race_info = find_race(pcs_slug)
        detected = match_vg_race_number(
            race_info !== nothing ? race_info.name : replace(pcs_slug, "-" => " "),
            vg_racelist)
        if detected !== nothing
            vg_race_number = detected
        end
    catch e
        @warn "Failed to auto-detect VG race number for $pcs_slug $year: $e"
    end

    if vg_race_number > 0
        try
            suppress_output() do
                archive_race_results(pcs_slug, year;
                    vg_race_number=vg_race_number, cache_config=_report_cache)
            end
            @info "Auto-archived results for $pcs_slug $year (VG race #$vg_race_number)"
        catch e
            @warn "Failed to auto-archive results for $pcs_slug $year: $e"
        end
    else
        @warn "Could not auto-detect VG race number for $pcs_slug $year — skipping archival"
    end
end

function report_html(;
    pcs_slug,
    year,
    race_name,
    race_date,
    winner_name="",
    winner_score=0,
)
    _ensure_results_archived(pcs_slug, year)

    allriders = load_report_data(pcs_slug, year; cache_config=_report_cache)
    if allriders === nothing
        @warn "No results available for $pcs_slug $year"
        return nothing
    end

    optimal_team = compute_optimal_team(allriders)
    optimal_score = optimal_team !== nothing ? sum(optimal_team.score) : 0
    optimal_cost = optimal_team !== nothing ? sum(optimal_team.cost) : 0

    cheapest_team = if winner_score > 0
        compute_cheapest_winning_team(allriders, winner_score)
    else
        nothing
    end

    scorers = filter(row -> row.score > 0, allriders)
    sort!(scorers, :score, rev=true)
    optimal_keys = optimal_team !== nothing ? Set(optimal_team.riderkey) : Set{String}()

    io = IOBuffer()

    # Intro
    if !isempty(winner_name) && winner_score > 0
        write(io, "<p><strong>$(winner_name)</strong> won our fantasy league with <strong>$(winner_score)</strong> points. But could they have done better? Read on to find out.</p>\n")
    end

    # How the race played out
    write(io, html_heading("How the race played out", 2))
    write(io, "<ul>\n")
    write(io, "<li><strong>Riders who scored</strong>: $(nrow(scorers)) out of $(nrow(allriders)) starters</li>\n")
    if nrow(scorers) > 0
        write(io, "<li><strong>Top scorer</strong>: $(first(scorers).rider) with $(first(scorers).score) points</li>\n")
        best_val = first(sort(scorers, :value, rev=true))
        write(io, "<li><strong>Best value</strong>: $(best_val.rider) at $(best_val.value) pts/credit</li>\n")
        write(io, "<li><strong>Average value</strong> (all starters): $(round(sum(allriders.score) / sum(allriders.cost), digits=1)) points per credit</li>\n")
    end
    if optimal_team !== nothing
        write(io, "<li><strong>Perfect team score</strong>: $(optimal_score) points for $(optimal_cost) credits</li>\n")
    end
    if !isempty(winner_name) && winner_score > 0
        write(io, "<li><strong>League winner</strong>: $(winner_name) with $(winner_score) points</li>\n")
    end
    write(io, "</ul>\n")

    # The perfect team
    write(io, html_heading("The perfect team", 2))
    write(io, "<p>With the benefit of hindsight, this is the highest-scoring team that fits within the budget.</p>\n")

    if optimal_team !== nothing
        diff_str = winner_score > 0 ? " That's <strong>$(optimal_score - winner_score)</strong> points more than our league winner." : ""
        write(io, "<p>The perfect team scores <strong>$(optimal_score)</strong> points, costing <strong>$(optimal_cost)</strong> out of 100 credits.$diff_str</p>\n")

        display_df = sort(optimal_team[:, [:rider, :team, :cost, :score, :value]], :score, rev=true)
        rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost, :score => :Points, :value => Symbol("Pts/credit"))
        write(io, html_table(display_df))
    end

    # Cheapest winning team
    if cheapest_team !== nothing && winner_score > 0
        cheapest_score = sum(cheapest_team.score)
        cheapest_cost = sum(cheapest_team.cost)

        write(io, html_heading("The cheapest winning team", 2))
        write(io, "<p>What's the minimum investment that could have beaten <strong>$(winner_name)</strong>? This team scores <strong>$(cheapest_score)</strong> points for just <strong>$(cheapest_cost)</strong> credits, leaving <strong>$(100 - cheapest_cost)</strong> credits on the table.</p>\n")

        display_df = sort(cheapest_team[:, [:rider, :team, :cost, :score, :value]], :score, rev=true)
        rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost, :score => :Points, :value => Symbol("Pts/credit"))
        write(io, html_table(display_df))
    end

    # Shared sections
    shared = _write_points_by_price!(io, allriders, optimal_keys)
    _write_top_scorers!(io, scorers; heading="Top scorers this race")
    _write_points_per_credit!(io, allriders, optimal_keys,
        shared.jitter, shared.costs_f, shared.mean_c, shared.x_min, shared.x_max)
    _write_best_value!(io, scorers)
    _write_ones_to_avoid!(io, allriders)
    _write_team_performance!(io, allriders)

    body = String(take!(io))
    return html_page(;
        title="$race_name $year",
        subtitle="Fantasy retrospective — $race_date",
        body=body,
        include_plotly=true,
        home_url="../index.html",
    )
end

const GRAND_TOUR_RACES = [
    (pcs_slug="giro-d-italia", name="Giro d'Italia", month=5, n_stages=21),
    (pcs_slug="tour-de-france", name="Tour de France", month=7, n_stages=21),
    (pcs_slug="vuelta-a-espana", name="Vuelta a España", month=9, n_stages=21),
]

function stage_race_report_html(;
    pcs_slug,
    year,
    race_name,
    race_date,
    n_stages,
    winner_name="",
    winner_score=0,
)
    archive_stage_race_results(pcs_slug, year;
        n_stages=n_stages, cache_config=_report_cache)

    allriders = load_stage_race_report_data(pcs_slug, year; cache_config=_report_cache)
    if allriders === nothing
        @warn "No results available for $pcs_slug $year"
        return nothing
    end

    per_stage = load_stage_race_per_stage_data(pcs_slug, year, n_stages;
        cache_config=_report_cache)
    stages = load_stage_profiles(pcs_slug, year)

    has_class = hasproperty(allriders, :class)

    optimal_team = compute_optimal_stage_team(allriders)
    optimal_score = optimal_team !== nothing ? sum(optimal_team.score) : 0
    optimal_cost = optimal_team !== nothing ? sum(optimal_team.cost) : 0

    cheapest_team = if winner_score > 0
        compute_cheapest_winning_stage_team(allriders, winner_score)
    else
        nothing
    end

    scorers = filter(row -> row.score > 0, allriders)
    sort!(scorers, :score, rev=true)
    optimal_keys = optimal_team !== nothing ? Set(optimal_team.riderkey) : Set{String}()

    io = IOBuffer()

    # --- Section 1: Intro + race summary ---
    if !isempty(winner_name) && winner_score > 0
        write(io, "<p><strong>$(winner_name)</strong> won our fantasy league with <strong>$(winner_score)</strong> points. But could they have done better? Read on to find out.</p>\n")
    end

    write(io, html_heading("How the race played out", 2))
    write(io, "<ul>\n")
    write(io, "<li><strong>Stages</strong>: $n_stages</li>\n")
    write(io, "<li><strong>Riders who scored</strong>: $(nrow(scorers)) out of $(nrow(allriders))</li>\n")
    if nrow(scorers) > 0
        write(io, "<li><strong>Top scorer</strong>: $(first(scorers).rider) with $(first(scorers).score) points</li>\n")
        best_val = first(sort(scorers, :value, rev=true))
        write(io, "<li><strong>Best value</strong>: $(best_val.rider) at $(best_val.value) pts/credit</li>\n")
    end
    if optimal_team !== nothing
        write(io, "<li><strong>Perfect team score</strong>: $(optimal_score) points for $(optimal_cost) credits</li>\n")
    end
    if !isempty(winner_name) && winner_score > 0
        write(io, "<li><strong>League winner</strong>: $(winner_name) with $(winner_score) points</li>\n")
    end

    # Stage profile summary
    if !isempty(stages)
        stage_types = [s.stage_type for s in stages]
        n_flat = count(==(:flat), stage_types)
        n_hilly = count(==(:hilly), stage_types)
        n_mountain = count(==(:mountain), stage_types)
        n_itt = count(==(:itt), stage_types)
        n_ttt = count(==(:ttt), stage_types)
        parts = String[]
        n_flat > 0 && push!(parts, "$n_flat flat")
        n_hilly > 0 && push!(parts, "$n_hilly hilly")
        n_mountain > 0 && push!(parts, "$n_mountain mountain")
        n_itt > 0 && push!(parts, "$n_itt ITT")
        n_ttt > 0 && push!(parts, "$n_ttt TTT")
        write(io, "<li><strong>Stage types</strong>: $(join(parts, ", "))</li>\n")
    end
    write(io, "</ul>\n")

    # --- Section 2: The perfect team ---
    write(io, html_heading("The perfect team", 2))
    write(io, "<p>With the benefit of hindsight, this is the highest-scoring team of 9 riders that fits within the budget and classification constraints.</p>\n")

    if optimal_team !== nothing
        diff_str = winner_score > 0 ? " That's <strong>$(optimal_score - winner_score)</strong> points more than our league winner." : ""
        write(io, "<p>The perfect team scores <strong>$(optimal_score)</strong> points, costing <strong>$(optimal_cost)</strong> out of 100 credits.$diff_str</p>\n")

        opt_cols = [:rider, :team, :cost, :score, :value]
        has_class && push!(opt_cols, :class)
        display_df = sort(optimal_team[:, opt_cols], :score, rev=true)
        col_renames = [:rider => :Rider, :team => :Team, :cost => :Cost,
            :score => :Points, :value => Symbol("Pts/credit")]
        has_class && push!(col_renames, :class => :Class)
        rename!(display_df, col_renames...)
        write(io, html_table(display_df))
    end

    # --- Section 3: Cheapest winning team ---
    if cheapest_team !== nothing && winner_score > 0
        cheapest_score = sum(cheapest_team.score)
        cheapest_cost = sum(cheapest_team.cost)

        write(io, html_heading("The cheapest winning team", 2))
        write(io, "<p>What's the minimum investment that could have beaten <strong>$(winner_name)</strong>? This team scores <strong>$(cheapest_score)</strong> points for just <strong>$(cheapest_cost)</strong> credits, leaving <strong>$(100 - cheapest_cost)</strong> credits on the table.</p>\n")

        ch_cols = [:rider, :team, :cost, :score, :value]
        has_class && push!(ch_cols, :class)
        display_df = sort(cheapest_team[:, ch_cols], :score, rev=true)
        col_renames = [:rider => :Rider, :team => :Team, :cost => :Cost,
            :score => :Points, :value => Symbol("Pts/credit")]
        has_class && push!(col_renames, :class => :Class)
        rename!(display_df, col_renames...)
        write(io, html_table(display_df))
    end

    # --- Section 4: Stage-by-stage progression ---
    if per_stage !== nothing && nrow(per_stage) > 0
        write(io, html_heading("Stage-by-stage progression", 2))
        write(io, "<p>How the top scorers accumulated their points across the race. The \"Final\" column shows end-of-race classification bonuses (GC, points, mountains, team). Background shading shows stage type: <span style=\"color:#4CAF50\">&#9632;</span> flat, <span style=\"color:#FF9800\">&#9632;</span> hilly, <span style=\"color:#F44336\">&#9632;</span> mountain, <span style=\"color:#2196F3\">&#9632;</span> ITT, <span style=\"color:#9C27B0\">&#9632;</span> TTT.</p>\n")

        # Top 8 by total score for the cumulative chart
        top_keys = first(scorers, min(8, nrow(scorers))).riderkey

        # Load totals for final classification bonuses
        totals_df = load_race_snapshot("vg_stage_totals", pcs_slug, year)
        cumulative = compute_cumulative_scores(per_stage, top_keys; totals=totals_df)
        final_stage = n_stages + 1

        if nrow(cumulative) > 0
            # Custom x-axis tick labels: 1..n_stages + "Final"
            tick_vals = collect(1:final_stage)
            tick_labels = [string(i) for i in 1:n_stages]
            push!(tick_labels, "Final")

            traces = GenericTrace[]
            for key in top_keys
                rider_cum = filter(row -> row.riderkey == key, cumulative)
                nrow(rider_cum) == 0 && continue
                rider_name = first(rider_cum).rider

                # Use dashed line for the final bonus segment
                main_mask = rider_cum.stage .<= n_stages
                main_data = rider_cum[main_mask, :]
                final_data = rider_cum[.!main_mask, :]

                push!(traces, PlotlyBase.scatter(
                    x=main_data.stage, y=main_data.cumulative_score,
                    mode="lines+markers", name=rider_name,
                    marker=attr(size=5),
                    line=attr(width=2.5),
                    legendgroup=rider_name, showlegend=true,
                    hovertemplate="%{meta}<br>Stage %{x}: +%{text} pts<br>Cumulative: %{y} pts<extra></extra>",
                    meta=fill(rider_name, nrow(main_data)),
                    text=string.(main_data.stage_score),
                ))

                if nrow(final_data) > 0 && nrow(main_data) > 0
                    # Connect last stage to final with a dashed line
                    last_main = last(main_data)
                    conn_x = [last_main.stage, first(final_data).stage]
                    conn_y = [last_main.cumulative_score, first(final_data).cumulative_score]
                    bonus_pts = first(final_data).stage_score
                    push!(traces, PlotlyBase.scatter(
                        x=conn_x, y=conn_y,
                        mode="lines+markers", name=rider_name,
                        marker=attr(size=7, symbol="diamond"),
                        line=attr(width=2, dash="dot"),
                        legendgroup=rider_name, showlegend=false,
                        hovertemplate="%{meta}<br>Final bonuses: +%{text} pts<br>Total: %{y} pts<extra></extra>",
                        meta=fill(rider_name, 2),
                        text=[string(0), string(bonus_pts)],
                    ))
                end
            end

            # Stage type background shading
            stage_type_colors = Dict(
                :flat => "rgba(76,175,80,0.08)", :hilly => "rgba(255,152,0,0.10)",
                :mountain => "rgba(244,67,54,0.08)", :itt => "rgba(33,150,243,0.10)",
                :ttt => "rgba(156,39,176,0.10)",
            )
            shapes = []
            if !isempty(stages)
                for s in stages
                    push!(shapes, attr(
                        type="rect", xref="x", yref="paper",
                        x0=s.stage_number - 0.5, x1=s.stage_number + 0.5,
                        y0=0, y1=1,
                        fillcolor=get(stage_type_colors, s.stage_type, "rgba(0,0,0,0)"),
                        line=attr(width=0), layer="below",
                    ))
                end
            end
            # "Final" column shading
            push!(shapes, attr(
                type="rect", xref="x", yref="paper",
                x0=final_stage - 0.5, x1=final_stage + 0.5,
                y0=0, y1=1,
                fillcolor="rgba(158,158,158,0.10)",
                line=attr(width=0), layer="below",
            ))

            layout = Layout(
                xaxis_title="Stage", yaxis_title="Cumulative VG points",
                hovermode="closest", template="plotly_white",
                xaxis=attr(tickvals=tick_vals, ticktext=tick_labels,
                    range=[0.5, final_stage + 0.5]),
                shapes=shapes,
                legend=attr(orientation="h", yanchor="bottom", y=1.02,
                    xanchor="left", x=0, font=attr(size=11)),
                margin=attr(t=80),
            )
            write(io, plotly_html(traces, layout; id="plot-progression", height="550px"))
        end
    end

    # --- Section 5: Points by stage type ---
    if per_stage !== nothing && !isempty(stages)
        write(io, html_heading("Points by stage type", 2))
        write(io, "<p>How points were distributed across different types of stages.</p>\n")

        type_map = Dict(s.stage_number => s.stage_type for s in stages)
        ps_typed = copy(per_stage)
        ps_typed[!, :stage_type] = [get(type_map, s, :unknown) for s in ps_typed.stage]

        type_summary = combine(
            groupby(ps_typed, :stage_type),
            :score => sum => :total_points,
            :score => mean => :avg_points_per_rider_stage,
            nrow => :rider_stages,
        )
        type_summary[!, :n_stages] = [
            count(s -> s.stage_type == Symbol(row.stage_type), stages)
            for row in eachrow(type_summary)]
        type_summary[!, :avg_per_stage] = round.(
            type_summary.total_points ./ max.(type_summary.n_stages, 1), digits=0)
        sort!(type_summary, :total_points, rev=true)

        rename!(type_summary,
            :stage_type => Symbol("Stage type"), :n_stages => :Stages,
            :total_points => Symbol("Total points"), :avg_per_stage => Symbol("Avg points/stage"))
        write(io, html_table(type_summary[:, [Symbol("Stage type"), :Stages,
            Symbol("Total points"), Symbol("Avg points/stage")]]))

        # Top scorer per stage type
        write(io, html_heading("Top scorer by stage type", 3))
        stage_type_scores = compute_stage_type_scores(per_stage, stages)
        type_cols = [:flat_score, :hilly_score, :mountain_score, :itt_score]
        type_labels = ["Flat", "Hilly", "Mountain", "ITT"]
        rows_html = String[]
        for (col, label) in zip(type_cols, type_labels)
            if hasproperty(stage_type_scores, col) && maximum(stage_type_scores[!, col]) > 0
                best_idx = argmax(stage_type_scores[!, col])
                best = stage_type_scores[best_idx, :]
                push!(rows_html, "<tr><td>$label</td><td>$(best.rider)</td><td>$(best[col])</td></tr>")
            end
        end
        if !isempty(rows_html)
            write(io, "<table class=\"table table-sm\">\n<thead><tr><th>Stage type</th><th>Top scorer</th><th>Points</th></tr></thead>\n<tbody>\n")
            for r in rows_html
                write(io, r * "\n")
            end
            write(io, "</tbody></table>\n")
        end
    end

    # --- Section 6: Consistency vs explosiveness ---
    if per_stage !== nothing && nrow(per_stage) > 0
        write(io, html_heading("Consistency vs explosiveness", 2))
        write(io, "<p>Riders who scored steadily across stages versus those who had a few big days. Each dot is a rider who scored at least once.</p>\n")

        rider_consistency = combine(
            groupby(per_stage, [:riderkey, :rider]),
            :score => (s -> count(>(0), s)) => :stages_scored,
            :score => maximum => :best_stage,
            :score => sum => :total,
        )
        filter!(row -> row.total > 0, rider_consistency)

        if nrow(rider_consistency) > 0
            traces_c = GenericTrace[]
            for is_opt in [false, true]
                mask = [k in optimal_keys for k in rider_consistency.riderkey] .== is_opt
                sub = rider_consistency[mask, :]
                nrow(sub) == 0 && continue
                push!(traces_c, PlotlyBase.scatter(
                    x=sub.stages_scored, y=sub.total,
                    mode="markers",
                    name=is_opt ? "Optimal team" : "Other riders",
                    marker=attr(
                        size=is_opt ? 12 : 7,
                        opacity=is_opt ? 0.9 : 0.5,
                    ),
                    text=["$(r.rider)<br>Stages scored: $(r.stages_scored)<br>Best stage: $(r.best_stage)<br>Total: $(r.total)" for r in eachrow(sub)],
                    hoverinfo="text",
                ))
            end
            write(io, plotly_html(traces_c, Layout(
                    xaxis_title="Stages scored on", yaxis_title="Total VG points",
                    hovermode="closest", template="plotly_white"); id="plot-consistency"))
        end
    end

    # --- Section 7: Classification performance ---
    if has_class
        write(io, html_heading("Classification performance", 2))
        write(io, "<p>How each rider classification fared in terms of points and value.</p>\n")

        class_stats = combine(
            groupby(allriders, :class),
            nrow => :riders,
            :score => mean => :avg_score,
            :cost => mean => :avg_cost,
            :value => mean => :avg_value,
        )
        class_stats[!, :avg_score] = round.(class_stats.avg_score, digits=0)
        class_stats[!, :avg_cost] = round.(class_stats.avg_cost, digits=1)
        class_stats[!, :avg_value] = round.(class_stats.avg_value, digits=1)
        sort!(class_stats, :avg_score, rev=true)
        rename!(class_stats,
            :class => :Class, :riders => :Riders, :avg_score => Symbol("Avg points"),
            :avg_cost => Symbol("Avg cost"), :avg_value => Symbol("Avg pts/credit"))
        write(io, html_table(class_stats))
    end

    # Shared sections
    shared = _write_points_by_price!(io, allriders, optimal_keys)
    _write_top_scorers!(io, scorers; has_class=has_class)
    _write_points_per_credit!(io, allriders, optimal_keys,
        shared.jitter, shared.costs_f, shared.mean_c, shared.x_min, shared.x_max)
    _write_best_value!(io, scorers; has_class=has_class)
    _write_ones_to_avoid!(io, allriders)
    _write_team_performance!(io, allriders)

    body = String(take!(io))
    return html_page(;
        title="$race_name $year",
        subtitle="Fantasy retrospective — $race_date",
        body=body,
        include_plotly=true,
        home_url="../index.html",
    )
end

"""Look up a grand tour by PCS slug, returning (name, month) or nothing."""
function _find_grand_tour(pcs_slug::String)
    for gt in GRAND_TOUR_RACES
        gt.pcs_slug == pcs_slug && return gt
    end
    return nothing
end

function index_html(; reports_dir)
    report_files = isdir(reports_dir) ? filter(f -> endswith(f, ".html"), readdir(reports_dir)) : String[]

    io = IOBuffer()
    write(io, "<p>A look back at each race in the season: who delivered, who disappointed, and what the perfect team would have been.</p>\n")

    if isempty(report_files)
        write(io, "<p>No race reports generated yet.</p>\n")
    else
        grand_tours = []
        classics = []
        for f in report_files
            m = match(r"^(.+)-(\d{4})\.html$", f)
            m === nothing && continue
            pcs_slug = String(m[1])
            yr = parse(Int, m[2])

            gt = _find_grand_tour(pcs_slug)
            if gt !== nothing
                # Grand tour — use month for ordering
                date_str = "$yr-$(lpad(gt.month, 2, '0'))-01"
                push!(grand_tours, (name=gt.name, date=date_str, year=yr,
                    filename=f, is_grand_tour=true))
            else
                ri = Velogames._find_race_by_slug(pcs_slug)
                name = ri !== nothing ? ri.name : replace(pcs_slug, "-" => " ") |> titlecase
                date_str = ri !== nothing ? replace(ri.date, r"^\d{4}" => string(yr)) : "$yr-01-01"
                push!(classics, (name=name, date=date_str, year=yr,
                    filename=f, is_grand_tour=false))
            end
        end

        all_races = vcat(grand_tours, classics)
        sort!(all_races, by=r -> r.date)
        year_list = sort(unique(r.year for r in all_races), rev=true)

        for yr in year_list
            write(io, html_heading("$yr season", 2))

            yr_gts = sort(filter(r -> r.year == yr && r.is_grand_tour, all_races), by=r -> r.date)
            yr_classics = sort(filter(r -> r.year == yr && !r.is_grand_tour, all_races), by=r -> r.date)

            if !isempty(yr_gts)
                write(io, html_heading("Grand tours", 3))
                write(io, "<table class=\"table table-sm\">\n<thead><tr><th>Race</th><th>Date</th></tr></thead>\n<tbody>\n")
                for r in yr_gts
                    write(io, "<tr><td><a href=\"reports/$(r.filename)\">$(r.name)</a></td><td>$(Dates.format(Date(r.date), "U"))</td></tr>\n")
                end
                write(io, "</tbody></table>\n")
            end

            if !isempty(yr_classics)
                if !isempty(yr_gts)
                    write(io, html_heading("Classics", 3))
                end
                write(io, "<table class=\"table table-sm\">\n<thead><tr><th>Race</th><th>Date</th></tr></thead>\n<tbody>\n")
                for r in yr_classics
                    write(io, "<tr><td><a href=\"reports/$(r.filename)\">$(r.name)</a></td><td>$(Dates.format(Date(r.date), "d U"))</td></tr>\n")
                end
                write(io, "</tbody></table>\n")
            end
        end
    end

    body = String(take!(io))
    return html_page(;
        title="Velogames: race reports",
        subtitle="Fantasy cycling retrospectives for the Dulwich league",
        body=body,
    )
end

function main()
    years = [2025, 2026]
    force = false
    for arg in ARGS
        if startswith(arg, "--years=")
            years_str = replace(arg, "--years=" => "")
            years = parse.(Int, split(years_str, ","))
        elseif arg == "--force"
            force = true
        end
    end

    league_winners = load_league_winners()

    # Archive results for any league winners not yet in the archive
    for ((pcs_slug, year), _) in league_winners
        year in years || continue
        if load_race_snapshot("vg_results", pcs_slug, year) === nothing
            println("  Archiving results for $pcs_slug $year...")
            _ensure_results_archived(pcs_slug, year)
        end
    end

    races = list_completed_races(years)
    println("Found $(nrow(races)) completed one-day races")

    site_dir = joinpath(@__DIR__, "..", "site")
    docs_dir = joinpath(site_dir, "docs")
    reports_dir = joinpath(docs_dir, "reports")
    mkpath(reports_dir)

    generated = 0
    skipped = 0

    # One-day classics reports
    for row in eachrow(races)
        filename = "$(row.pcs_slug)-$(row.year).html"
        filepath = joinpath(reports_dir, filename)

        if !force && isfile(filepath)
            skipped += 1
            continue
        end

        d = Date(row.date)
        race_date = Dates.format(d, "d U yyyy")

        winner = get(league_winners, (row.pcs_slug, row.year), nothing)
        page = report_html(;
            pcs_slug=row.pcs_slug,
            year=row.year,
            race_name=row.name,
            race_date=race_date,
            winner_name=winner !== nothing ? winner.name : "",
            winner_score=winner !== nothing ? winner.score : 0,
        )

        if page !== nothing
            write(filepath, page)
            println("  Generated reports/$filename")
            generated += 1
        end
    end

    # Grand tour reports
    gt_generated = 0
    gt_skipped = 0
    for gt in GRAND_TOUR_RACES
        for year in years
            filename = "$(gt.pcs_slug)-$(year).html"
            filepath = joinpath(reports_dir, filename)

            if !force && isfile(filepath)
                gt_skipped += 1
                continue
            end

            # Check if data is available (archived or live)
            has_data = load_race_snapshot("vg_stage_totals", gt.pcs_slug, year) !== nothing
            if !has_data
                # Try fetching live to see if the race has finished
                vg_slug = get(Velogames._STAGE_RACE_VG_SLUGS, gt.pcs_slug, "")
                if !isempty(vg_slug)
                    try
                        totals = suppress_output() do
                            getvg_stage_race_totals(year, vg_slug; cache_config=_report_cache)
                        end
                        if totals !== nothing && nrow(totals) > 0 && maximum(totals.score) > 0
                            # Verify the race is complete by checking the last stage has data
                            last_stage = suppress_output() do
                                getvg_stage_results(year, vg_slug, gt.n_stages;
                                    cache_config=_report_cache)
                            end
                            has_data = last_stage !== nothing && nrow(last_stage) > 0 &&
                                       maximum(last_stage.score) > 0
                        end
                    catch
                    end
                end
            end

            has_data || continue

            race_date = Dates.format(Date(year, gt.month, 1), "U yyyy")
            winner = get(league_winners, (gt.pcs_slug, year), nothing)
            page = stage_race_report_html(;
                pcs_slug=gt.pcs_slug,
                year=year,
                race_name=gt.name,
                race_date=race_date,
                n_stages=gt.n_stages,
                winner_name=winner !== nothing ? winner.name : "",
                winner_score=winner !== nothing ? winner.score : 0,
            )

            if page !== nothing
                write(filepath, page)
                println("  Generated reports/$filename")
                gt_generated += 1
            end
        end
    end

    # Generate index page
    index = index_html(; reports_dir=reports_dir)
    write(joinpath(docs_dir, "index.html"), index)
    println("  Generated index.html")

    total_generated = generated + gt_generated
    total_skipped = skipped + gt_skipped
    println("\nGenerated $total_generated reports ($total_skipped skipped, already exist)")
    if generated > 0 || skipped > 0
        println("  Classics: $generated new, $skipped skipped")
    end
    if gt_generated > 0 || gt_skipped > 0
        println("  Grand tours: $gt_generated new, $gt_skipped skipped")
    end
    if total_skipped > 0
        println("Pass --force to regenerate all reports")
    end
end

main()
