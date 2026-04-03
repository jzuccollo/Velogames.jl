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
    allriders[!, :in_optimal] = [k in optimal_keys for k in allriders.riderkey]

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

    # Points by price
    write(io, html_heading("Was it worth paying more?", 2))
    write(io, html_heading("Points scored by price", 3))
    write(io, "<p>Each dot is a rider. The dashed line shows the general trend.</p>\n")

    if nrow(allriders) > 0
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
            mask = (allriders.score .> 0) .& (allriders.in_optimal .== is_opt)
            sub = allriders[mask, :]
            nrow(sub) == 0 && continue
            push!(traces, PlotlyBase.scatter(
                x=sub.cost .+ jitter[mask], y=sub.score,
                mode="markers", name=label,
                marker=attr(size=is_opt ? 10 : 6, opacity=is_opt ? 0.9 : 0.5),
                text=["$(r.rider) ($(r.team))<br>Cost: $(r.cost), Points: $(r.score), Value: $(r.value)" for r in eachrow(sub)],
                hoverinfo="text"))
        end

        # OLS trend line
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
    end

    # Top scorers
    write(io, html_heading("Top scorers this race", 3))
    top_n = min(15, nrow(scorers))
    top = scorers[1:top_n, [:rider, :team, :cost, :score, :value]]
    rename!(top, :rider => :Rider, :team => :Team, :cost => :Cost, :score => :Points, :value => :Value)
    write(io, html_table(top))

    # Points per credit
    write(io, html_heading("Points per credit by price", 3))
    write(io, "<p>How efficiently each rider converted their price tag into points.</p>\n")

    if nrow(allriders) > 0
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
            mask = (allriders.score .> 0) .& (allriders.in_optimal .== is_opt)
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

    # Best value picks
    write(io, html_heading("Best value picks", 3))
    write(io, "<p>The ten riders who scored the most points per credit spent.</p>\n")
    best_value = sort(scorers, :value, rev=true)
    top_val = best_value[1:min(10, nrow(best_value)), [:rider, :team, :cost, :score, :value]]
    rename!(top_val, :rider => :Rider, :team => :Team, :cost => :Cost, :score => :Points, :value => :Value)
    write(io, html_table(top_val))

    # The ones to avoid
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
        rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost, :score => :Points, :value => Symbol("Pts/credit"))
        write(io, html_table(display_df))
    end

    # Team performance
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

    body = String(take!(io))
    return html_page(;
        title="$race_name $year",
        subtitle="Fantasy retrospective — $race_date",
        body=body,
        include_plotly=true,
    )
end

function index_html(; reports_dir)
    report_files = isdir(reports_dir) ? filter(f -> endswith(f, ".html"), readdir(reports_dir)) : String[]

    io = IOBuffer()
    write(io, "<p>A look back at each race in the season: who delivered, who disappointed, and what the perfect team would have been.</p>\n")

    if isempty(report_files)
        write(io, "<p>No race reports generated yet.</p>\n")
    else
        races = []
        for f in report_files
            m = match(r"^(.+)-(\d{4})\.html$", f)
            m === nothing && continue
            pcs_slug = String(m[1])
            yr = parse(Int, m[2])
            ri = Velogames._find_race_by_slug(pcs_slug)
            name = ri !== nothing ? ri.name : replace(pcs_slug, "-" => " ") |> titlecase
            date_str = ri !== nothing ? replace(ri.date, r"^\d{4}" => string(yr)) : "$yr-01-01"
            push!(races, (name=name, date=date_str, year=yr, filename=f))
        end

        sort!(races, by=r -> r.date)
        year_list = sort(unique(r.year for r in races), rev=true)

        for yr in year_list
            year_races = filter(r -> r.year == yr, races)
            write(io, html_heading("$yr season", 2))
            rows = [(Race="<a href=\"reports/$(r.filename)\">$(r.name)</a>",
                      Date=Dates.format(Date(r.date), "d U")) for r in year_races]
            # Build a simple table
            write(io, "<table class=\"table table-sm\">\n<thead><tr><th>Race</th><th>Date</th></tr></thead>\n<tbody>\n")
            for r in rows
                write(io, "<tr><td>$(r.Race)</td><td>$(r.Date)</td></tr>\n")
            end
            write(io, "</tbody></table>\n")
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
    races = list_completed_races(years)
    println("Found $(nrow(races)) completed races")

    site_dir = joinpath(@__DIR__, "..", "site")
    docs_dir = joinpath(site_dir, "docs")
    reports_dir = joinpath(docs_dir, "reports")
    mkpath(reports_dir)

    generated = 0
    skipped = 0

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

    # Generate index page
    index = index_html(; reports_dir=reports_dir)
    write(joinpath(docs_dir, "index.html"), index)
    println("  Generated index.html")

    println("\nGenerated $generated reports ($skipped skipped, already exist)")
    if skipped > 0
        println("Pass --force to regenerate all reports")
    end
end

main()
