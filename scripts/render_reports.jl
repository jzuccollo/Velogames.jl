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

using Velogames, DataFrames, Dates, Statistics, TOML, Base64, JSON3
using PlotlyBase

const commafmt = Velogames.commafmt

const FRESH = "--fresh" in ARGS

# Rider tables in race reports link each name to its dossier. Reports live in docs/reports/,
# so the lookup page is one level up. `df` must carry a `riderkey` column (html_table hides it).
const _RIDER_LINK = "../riders.html#"
rider_html_table(df; kwargs...) = html_table(df; rider_link_base=_RIDER_LINK, kwargs...)

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
            marker=attr(size=5, opacity=0.35, color="#cbd1d6", symbol="x"),
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
            marker=attr(size=is_opt ? 10 : 6, opacity=is_opt ? 0.9 : 0.5,
                color=is_opt ? COLOR_OPTIMAL : COLOR_OTHER),
            text=["$(r.rider) ($(r.team))<br>Cost: $(r.cost), Points: $(commafmt(r.score)), Value: $(round(Int, r.value))" for r in eachrow(sub)],
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
        line=attr(color="#7a828a", dash="dash", width=1.5), hoverinfo="skip"))

    write(io, plotly_html(traces, Layout(
            template="plotly_white", hovermode="closest",
            font=attr(family=REPORT_FONT, color="#2d3436"), hoverlabel=report_hoverlabel(),
            xaxis=report_xaxis("Cost (credits)"), yaxis=report_yaxis("Points scored")); id="plot-pts"))

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
            marker=attr(size=5, opacity=0.35, color="#cbd1d6", symbol="x"),
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
            marker=attr(size=is_opt ? 10 : 6, opacity=is_opt ? 0.9 : 0.5,
                color=is_opt ? COLOR_OPTIMAL : COLOR_OTHER),
            text=["$(r.rider) ($(r.team))<br>Cost: $(r.cost), Points: $(commafmt(r.score)), Value: $(round(Int, r.value))" for r in eachrow(sub)],
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
        line=attr(color="#7a828a", dash="dash", width=1.5), hoverinfo="skip"))

    write(io, plotly_html(traces2, Layout(
            template="plotly_white", hovermode="closest",
            font=attr(family=REPORT_FONT, color="#2d3436"), hoverlabel=report_hoverlabel(),
            xaxis=report_xaxis("Cost (credits)"), yaxis=report_yaxis("Value (points per credit)")); id="plot-val"))
end

"""Write top scorers table."""
function _write_top_scorers!(io::IOBuffer, scorers::DataFrame;
    has_class::Bool=false, heading::String="Top scorers")
    write(io, html_heading(heading, 3))
    top_n = min(15, nrow(scorers))
    top_cols = [:rider, :team, :cost, :score, :value, :riderkey]
    has_class && push!(top_cols, :class)
    top = scorers[1:top_n, top_cols]
    top[!, :value] = round.(Int, top.value)
    col_renames = [:rider => :Rider, :team => :Team, :cost => :Cost,
        :score => :Points, :value => :Value]
    has_class && push!(col_renames, :class => :Class)
    rename!(top, col_renames...)
    write(io, rider_html_table(top))
end

"""Set of riderkeys who finished the race (from archived PCS GC results), or `nothing`
if unavailable. Lets the report separate genuine underperformers from crashes/abandons."""
function load_finishers(pcs_slug, year)
    gc = load_race_snapshot("pcs_gc_results", pcs_slug, year)
    gc === nothing && return nothing
    fin = Set(gc.riderkey[gc.position.<Velogames.DNF_POSITION])
    return isempty(fin) ? nothing : fin
end

"""Map of riderkey => stage a rider abandoned on (from archived PCS per-stage results),
or `nothing` if unavailable."""
function load_abandons(pcs_slug, year)
    df = load_race_snapshot("pcs_abandons", pcs_slug, year)
    df === nothing && return nothing
    return Dict(df.riderkey .=> df.abandon_stage)
end

"""Write the biggest single-stage point hauls — standout individual stage performances."""
function _write_biggest_hauls!(io::IOBuffer, per_stage, stages)
    (per_stage === nothing || nrow(per_stage) == 0) && return
    write(io, html_heading("Biggest single-stage hauls", 2))
    write(io, "<p>The ten biggest one-day point hauls of the race &mdash; the standout individual stage performances.</p>\n")
    type_names = Dict(:flat => "Flat", :hilly => "Hilly", :mountain => "Mountain",
        :itt => "ITT", :ttt => "TTT")
    type_map = Dict(s.stage_number => get(type_names, s.stage_type, "—") for s in stages)
    top = first(sort(per_stage, :score, rev=true), min(10, nrow(per_stage)))
    df = DataFrame(
        Rider=top.rider,
        Stage=top.stage,
        Type=[get(type_map, s, "—") for s in top.stage],
        Points=top.score,
        riderkey=top.riderkey,
    )
    write(io, rider_html_table(df))
end

"""Write best value picks table."""
function _write_best_value!(io::IOBuffer, scorers::DataFrame; has_class::Bool=false)
    write(io, html_heading("Best value picks", 3))
    write(io, "<p>The ten riders who scored the most points per credit spent.</p>\n")
    best_value = sort(scorers, :value, rev=true)
    bv_cols = [:rider, :team, :cost, :score, :value, :riderkey]
    has_class && push!(bv_cols, :class)
    top_val = best_value[1:min(10, nrow(best_value)), bv_cols]
    top_val[!, :value] = round.(Int, top_val.value)
    col_renames = [:rider => :Rider, :team => :Team, :cost => :Cost,
        :score => :Points, :value => :Value]
    has_class && push!(col_renames, :class => :Class)
    rename!(top_val, col_renames...)
    write(io, rider_html_table(top_val))
end

"""Write "The ones to avoid" section: priciest blanks and premium disappointments.
When `finishers` is supplied, the blame tables are restricted to riders who finished
the race, and a separate table lists expensive riders who crashed out or withdrew."""
function _write_ones_to_avoid!(io::IOBuffer, allriders::DataFrame, finishers=nothing, abandons=nothing)
    write(io, html_heading("The ones to avoid", 2))

    # Only blame riders who actually finished; crashes/abandons are shown separately.
    blame = finishers === nothing ? allriders :
            filter(r -> r.riderkey in finishers, allriders)
    fin_clause = finishers === nothing ? "" : "finished the race but "

    write(io, html_heading("Priciest blanks", 3))
    pricey_zeroes = filter(row -> row.cost >= 8 && row.score == 0, blame)
    if nrow(pricey_zeroes) > 0
        write(io, "<p>The most expensive riders who $(fin_clause)failed to score a single point.</p>\n")
        sort!(pricey_zeroes, :cost, rev=true)
        display_df = pricey_zeroes[1:min(5, nrow(pricey_zeroes)), [:rider, :team, :cost, :score, :riderkey]]
        rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost, :score => :Points)
        write(io, rider_html_table(display_df))
    elseif finishers !== nothing
        write(io, "<p>Every rider priced at 8+ credits who finished the race scored at least once &mdash; the priciest blanks all abandoned (see below).</p>\n")
    else
        write(io, "<p>No expensive rider drew a complete blank.</p>\n")
    end

    write(io, html_heading("Biggest premium disappointments", 3))
    write(io, "<p>The five most expensive riders (8+ credits) who $(isempty(fin_clause) ? "" : "finished but ")scored the least for their price.</p>\n")
    premium = filter(row -> row.cost >= 8 && row.score > 0, blame)
    if nrow(premium) > 0
        sort!(premium, :value)
        display_df = premium[1:min(5, nrow(premium)), [:rider, :team, :cost, :score, :value, :riderkey]]
        display_df[!, :value] = round.(Int, display_df.value)
        rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost,
            :score => :Points, :value => :Value)
        write(io, rider_html_table(display_df))
    end

    # Expensive riders who abandoned — separated from genuine underperformance.
    if finishers !== nothing
        dnf = filter(row -> row.cost >= 8 && !(row.riderkey in finishers), allriders)
        if nrow(dnf) > 0
            write(io, html_heading("Expensive riders who abandoned", 3))
            write(io, "<p>Pricey picks who crashed out or withdrew before the finish. Points shown are what they managed beforehand &mdash; lost potential rather than necessarily a bad pick.</p>\n")
            sort!(dnf, :value)  # most credits wasted first; big-scoring late abandons last
            top = dnf[1:min(8, nrow(dnf)), :]
            display_df = DataFrame(Rider=top.rider, Team=top.team, Cost=top.cost,
                Points=top.score, riderkey=top.riderkey)
            if abandons !== nothing
                display_df[!, Symbol("Abandoned on")] =
                    [haskey(abandons, k) ? "Stage $(abandons[k])" : "—" for k in top.riderkey]
            end
            write(io, rider_html_table(display_df))
        end
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
    team_stats[!, :avg_value] = round.(Int, team_stats.total_points ./ max.(team_stats.total_cost, 1))
    sort!(team_stats, :total_points, rev=true)
    top_teams = team_stats[1:min(10, nrow(team_stats)), :]
    rename!(top_teams, :team => :Team, :total_points => :Points, :total_cost => :Cost,
        :scorers => :Scorers, :riders => :Starters, :avg_value => :Value)
    write(io, html_table(top_teams))
end

"""Write classification (rider-type) performance table (grand tours only)."""
function _write_classification_performance!(io::IOBuffer, allriders::DataFrame, has_class::Bool)
    has_class || return
    write(io, html_heading("Classification performance", 2))
    write(io, "<p>How each rider classification fared in terms of points and value.</p>\n")
    class_stats = combine(
        groupby(allriders, :class),
        nrow => :riders,
        :score => mean => :avg_score,
        :cost => mean => :avg_cost,
        :value => mean => :avg_value,
    )
    class_stats[!, :avg_score] = round.(Int, class_stats.avg_score)
    class_stats[!, :avg_cost] = round.(Int, class_stats.avg_cost)
    class_stats[!, :avg_value] = round.(Int, class_stats.avg_value)
    sort!(class_stats, :avg_score, rev=true)
    rename!(class_stats,
        :class => :Class, :riders => :Riders, :avg_score => Symbol("Avg points"),
        :avg_cost => Symbol("Avg cost"), :avg_value => Symbol("Avg value"))
    write(io, html_table(class_stats))
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
        write(io, "<p><strong>$(winner_name)</strong> won our fantasy league with <strong>$(commafmt(winner_score))</strong> points. But could they have done better? Read on to find out.</p>\n")
    end

    # How the race played out
    write(io, html_heading("How the race played out", 2))
    write(io, "<ul>\n")
    write(io, "<li><strong>Riders who scored</strong>: $(nrow(scorers)) out of $(nrow(allriders)) starters</li>\n")
    if nrow(scorers) > 0
        write(io, "<li><strong>Top scorer</strong>: $(first(scorers).rider) with $(commafmt(first(scorers).score)) points</li>\n")
        best_val = first(sort(scorers, :value, rev=true))
        write(io, "<li><strong>Best value</strong>: $(best_val.rider) at $(round(Int, best_val.value)) pts/credit</li>\n")
        write(io, "<li><strong>Average value</strong> (all starters): $(round(Int, sum(allriders.score) / sum(allriders.cost))) points per credit</li>\n")
    end
    if optimal_team !== nothing
        write(io, "<li><strong>Perfect team score</strong>: $(commafmt(optimal_score)) points for $(optimal_cost) credits</li>\n")
    end
    if !isempty(winner_name) && winner_score > 0
        write(io, "<li><strong>League winner</strong>: $(winner_name) with $(commafmt(winner_score)) points</li>\n")
    end
    write(io, "</ul>\n")

    # The perfect team
    write(io, html_heading("The perfect team", 2))
    write(io, "<p>With the benefit of hindsight, this is the highest-scoring team that fits within the budget.</p>\n")

    if optimal_team !== nothing
        diff_str = winner_score > 0 ? " That's <strong>$(commafmt(optimal_score - winner_score))</strong> points more than our league winner." : ""
        write(io, "<p>The perfect team scores <strong>$(commafmt(optimal_score))</strong> points, costing <strong>$(optimal_cost)</strong> out of 100 credits.$diff_str</p>\n")

        display_df = sort(optimal_team[:, [:rider, :team, :cost, :score, :value, :riderkey]], :score, rev=true)
        display_df[!, :value] = round.(Int, display_df.value)
        rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost, :score => :Points, :value => :Value)
        write(io, rider_html_table(display_df))
    end

    # Cheapest winning team
    if cheapest_team !== nothing && winner_score > 0
        cheapest_score = sum(cheapest_team.score)
        cheapest_cost = sum(cheapest_team.cost)

        write(io, html_heading("The cheapest winning team", 2))
        write(io, "<p>What's the minimum investment that could have beaten <strong>$(winner_name)</strong>? This team scores <strong>$(commafmt(cheapest_score))</strong> points for just <strong>$(cheapest_cost)</strong> credits, leaving <strong>$(100 - cheapest_cost)</strong> credits on the table.</p>\n")

        display_df = sort(cheapest_team[:, [:rider, :team, :cost, :score, :value, :riderkey]], :score, rev=true)
        display_df[!, :value] = round.(Int, display_df.value)
        rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost, :score => :Points, :value => :Value)
        write(io, rider_html_table(display_df))
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
        accent=race_accent(pcs_slug),
    )
end

# Minimal monochrome line-art pictograms for stage terrain, drawn on a 0 0 24 24 grid.
# Shape carries the meaning, so a single neutral ink colour is used throughout.
const _STAGE_ICON_INK = "#54616b"
const _STAGE_ICON_BODIES = Dict(
    :flat => """<path d="M3 13 Q8 11 12 13 T21 13"/>""",
    :hilly => """<path d="M3 16 Q7 8 11 16 Q15 8 19 16 H21"/>""",
    :mountain => """<path d="M3 18 L10 6 L13 11 L17 6 L21 18"/>""",
    :itt => """<circle cx="12" cy="14" r="7"/><path d="M12 7 V4"/><path d="M10 4 H14"/><path d="M12 14 L15 11"/>""",
    :ttt => """<circle cx="10" cy="14" r="6"/><path d="M10 8 V5"/><path d="M8 5 H12"/><path d="M10 14 L13 11"/><path d="M19 11 H22"/><path d="M19 14 H22"/><path d="M19 17 H22"/>""",
)

"""Build a base64 data-URI SVG for a stage-type icon (base64 avoids `#`/`<` URI breakage)."""
function stage_icon_datauri(stage_type::Symbol)
    body = get(_STAGE_ICON_BODIES, stage_type, "")
    isempty(body) && return ""
    svg = """<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" """ *
          """fill="none" stroke="$_STAGE_ICON_INK" stroke-width="1.6" """ *
          """stroke-linecap="round" stroke-linejoin="round">$body</svg>"""
    return "data:image/svg+xml;base64," * base64encode(svg)
end

"""Convert a `#rrggbb` hex colour to an `rgba(...)` string at the given alpha."""
function hex_to_rgba(hex::AbstractString, alpha::Real)
    r = parse(Int, hex[2:3]; base=16)
    g = parse(Int, hex[4:5]; base=16)
    b = parse(Int, hex[6:7]; base=16)
    return "rgba($r,$g,$b,$alpha)"
end

# Muted terrain tints (used for the faint full-height shading and the ribbon cells
# behind each icon, so a stage's column is colour-tied to its terrain type).
# Muted, warm earth tones so the bands recede behind the lines.
const _TERRAIN_TINT = Dict(
    :flat => (151, 166, 122), :hilly => (201, 169, 110), :mountain => (190, 120, 96),
    :itt => (120, 146, 168), :ttt => (146, 120, 150),
)
function terrain_tint(stage_type::Symbol, alpha::Real)
    haskey(_TERRAIN_TINT, stage_type) || return "rgba(0,0,0,0)"
    r, g, b = _TERRAIN_TINT[stage_type]
    return "rgba($r,$g,$b,$alpha)"
end

"""Reclassify a stage's display type from its ProfileScore, matching the strength
model's dominant terrain dimension (`stage_dimension_weights`). Falls back to the
scraped type when ProfileScore is missing (≤0) or for time trials."""
function display_stage_type(s::Velogames.StageProfile)
    (s.stage_type == :itt || s.stage_type == :ttt || s.profile_score <= 0) && return s.stage_type
    w = Velogames.stage_dimension_weights(s)
    (:flat, :hilly, :mountain)[argmax((w.flat, w.hilly, w.mountain))]
end

function reclassify_stages(stages)
    map(stages) do s
        nt = display_stage_type(s)
        nt == s.stage_type ? s : Velogames.StageProfile(
            s.stage_number, nt, s.distance_km, s.profile_score, s.vertical_meters,
            s.gradient_final_km, s.n_hc_climbs, s.n_cat1_climbs,
            s.n_intermediate_sprints, s.is_summit_finish)
    end
end

# Shared chart styling for visual consistency across the report's charts.
const REPORT_FONT = "Public Sans, -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, \"Helvetica Neue\", Arial, sans-serif"
const COLOR_OPTIMAL = "#3d6b99"   # highlighted "optimal team" points
const COLOR_OTHER = "#9aa3ab"     # muted "other riders" points
report_xaxis(title) = attr(title=attr(text=title, font=attr(size=12, color="#54616b")),
    showgrid=false, zeroline=false, tickfont=attr(size=11, color="#54616b"))
report_yaxis(title) = attr(title=attr(text=title, font=attr(size=12, color="#54616b")),
    showgrid=true, gridcolor="#eef0f2", gridwidth=1, zeroline=false, tickformat=",",
    tickfont=attr(size=11, color="#54616b"))
report_hoverlabel() = attr(bgcolor="#ffffff", bordercolor="#e7e3da",
    font=attr(family=REPORT_FONT, size=12, color="#24303a"))
# Refined, muted editorial palette; deeper mustard/teal keep adjacent riders distinct.
const LINE_PALETTE = ["#3d6b99", "#c75b53", "#5c8a4a", "#d29a3c",
    "#3f938c", "#9b6a93", "#df8a3c", "#8c6f5e"]

const GRAND_TOUR_RACES = [
    (pcs_slug="giro-d-italia", name="Giro d'Italia", month=5, n_stages=21),
    (pcs_slug="tour-de-france", name="Tour de France", month=7, n_stages=21),
    (pcs_slug="vuelta-a-espana", name="Vuelta a España", month=9, n_stages=21),
]

# Per-race accent colour (leader's jersey); classics fall back to the default gold.
const _RACE_ACCENT = Dict(
    "giro-d-italia" => "#d6336c",   # maglia rosa
    "tour-de-france" => "#e0a500",  # maillot jaune
    "vuelta-a-espana" => "#d92c3a", # la roja
)
race_accent(pcs_slug) = get(_RACE_ACCENT, pcs_slug, "#d4a843")

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
    stages = reclassify_stages(load_stage_profiles(pcs_slug, year))
    finishers = load_finishers(pcs_slug, year)
    abandons = load_abandons(pcs_slug, year)

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
        write(io, "<p><strong>$(winner_name)</strong> won our fantasy league with <strong>$(commafmt(winner_score))</strong> points. But could they have done better? Read on to find out.</p>\n")
    end

    write(io, html_heading("The race in numbers", 2))
    write(io, "<ul>\n")
    write(io, "<li><strong>Stages</strong>: $n_stages</li>\n")
    write(io, "<li><strong>Riders who scored</strong>: $(nrow(scorers)) out of $(nrow(allriders))</li>\n")
    if nrow(scorers) > 0
        write(io, "<li><strong>Top scorer</strong>: $(first(scorers).rider) with $(commafmt(first(scorers).score)) points</li>\n")
        best_val = first(sort(scorers, :value, rev=true))
        write(io, "<li><strong>Best value</strong>: $(best_val.rider) at $(round(Int, best_val.value)) pts/credit</li>\n")
    end
    if optimal_team !== nothing
        write(io, "<li><strong>Perfect team score</strong>: $(commafmt(optimal_score)) points for $(optimal_cost) credits</li>\n")
    end
    if !isempty(winner_name) && winner_score > 0
        write(io, "<li><strong>League winner</strong>: $(winner_name) with $(commafmt(winner_score)) points</li>\n")
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
        diff_str = winner_score > 0 ? " That's <strong>$(commafmt(optimal_score - winner_score))</strong> points more than our league winner." : ""
        write(io, "<p>The perfect team scores <strong>$(commafmt(optimal_score))</strong> points, costing <strong>$(optimal_cost)</strong> out of 100 credits.$diff_str</p>\n")

        opt_cols = [:rider, :team, :cost, :score, :value, :riderkey]
        has_class && push!(opt_cols, :class)
        display_df = sort(optimal_team[:, opt_cols], :score, rev=true)
        display_df[!, :value] = round.(Int, display_df.value)
        col_renames = [:rider => :Rider, :team => :Team, :cost => :Cost,
            :score => :Points, :value => :Value]
        has_class && push!(col_renames, :class => :Class)
        rename!(display_df, col_renames...)
        write(io, rider_html_table(display_df))
    end

    # --- Section 3: Cheapest winning team ---
    if cheapest_team !== nothing && winner_score > 0
        cheapest_score = sum(cheapest_team.score)
        cheapest_cost = sum(cheapest_team.cost)

        write(io, html_heading("The cheapest winning team", 2))
        write(io, "<p>What's the minimum investment that could have beaten <strong>$(winner_name)</strong>? This team scores <strong>$(commafmt(cheapest_score))</strong> points for just <strong>$(cheapest_cost)</strong> credits, leaving <strong>$(100 - cheapest_cost)</strong> credits on the table.</p>\n")

        ch_cols = [:rider, :team, :cost, :score, :value, :riderkey]
        has_class && push!(ch_cols, :class)
        display_df = sort(cheapest_team[:, ch_cols], :score, rev=true)
        display_df[!, :value] = round.(Int, display_df.value)
        col_renames = [:rider => :Rider, :team => :Team, :cost => :Cost,
            :score => :Points, :value => :Value]
        has_class && push!(col_renames, :class => :Class)
        rename!(display_df, col_renames...)
        write(io, rider_html_table(display_df))
    end

    # --- Section 4: Stage-by-stage progression ---
    if per_stage !== nothing && nrow(per_stage) > 0
        write(io, html_heading("Stage-by-stage progression", 2))
        write(io, "<p>How the top scorers accumulated points across the race. Icons along the top mark each stage's terrain &mdash; flat, hilly, mountain, individual time trial (ITT) and team time trial (TTT). The dotted segment to <strong>Final</strong> shows end-of-race classification bonuses (GC, points, mountains, team).</p>\n")

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

            # On-brand, harmonious 8-colour palette (Tableau-10; first 5 match the site's
            # line_chart helper). Maximally distinguishable without neon clashes.
            line_palette = LINE_PALETTE
            # Stage-type label per stage number (for hover), from the reclassified stages.
            type_names = Dict(:flat => "flat", :hilly => "hilly", :mountain => "mountain",
                :itt => "ITT", :ttt => "TTT")
            stage_type_label = Dict(s.stage_number => get(type_names, s.stage_type, "stage")
                                    for s in stages)

            traces = GenericTrace[]
            # Collect (label_y, surname, colour) for direct end-of-line labels.
            end_labels = NamedTuple{(:y, :name, :color),Tuple{Float64,String,String}}[]
            for (ci, key) in enumerate(top_keys)
                rider_cum = filter(row -> row.riderkey == key, cumulative)
                nrow(rider_cum) == 0 && continue
                rider_name = first(rider_cum).rider
                line_color = line_palette[(ci - 1)%length(line_palette)+1]

                # Real stages form the solid line; the final-bonus pseudo-stage is drawn
                # separately as a dotted link to the "Final" column.
                main_mask = rider_cum.stage .<= n_stages
                main_data = rider_cum[main_mask, :]
                final_data = rider_cum[.!main_mask, :]

                # customdata per point: [stage_score, stage_type_label]
                cdata = [[sc, get(stage_type_label, st, "stage")]
                         for (st, sc) in zip(main_data.stage, main_data.stage_score)]
                push!(traces, PlotlyBase.scatter(
                    x=main_data.stage, y=main_data.cumulative_score,
                    mode="lines", name=rider_name,
                    line=attr(width=2.5, color=line_color),
                    showlegend=false,
                    hovertemplate="%{meta}<br>Stage %{x} (%{customdata[1]}): +%{customdata[0]} pts<br>Cumulative: %{y:,} pts<extra></extra>",
                    meta=fill(rider_name, nrow(main_data)),
                    customdata=cdata,
                ))

                if nrow(final_data) > 0 && nrow(main_data) > 0
                    last_main = last(main_data)
                    fin = first(final_data)
                    bonus_pts = fin.stage_score
                    # Dotted visual link from the last stage to the Final total (no hover,
                    # no marker — those belong only to the Final point below).
                    push!(traces, PlotlyBase.scatter(
                        x=[last_main.stage, fin.stage],
                        y=[last_main.cumulative_score, fin.cumulative_score],
                        mode="lines", name=rider_name,
                        line=attr(width=1.5, dash="dot", color=hex_to_rgba(line_color, 0.7)),
                        showlegend=false, hoverinfo="skip",
                    ))
                    # The Final total: the only diamond, with the correct bonus hover.
                    push!(traces, PlotlyBase.scatter(
                        x=[fin.stage], y=[fin.cumulative_score],
                        mode="markers", name=rider_name,
                        marker=attr(size=9, symbol="diamond", color=line_color,
                            line=attr(color="#ffffff", width=1.2)),
                        showlegend=false,
                        hovertemplate="$rider_name<br>Final bonuses: +$bonus_pts pts<br>Total: %{y:,} pts<extra></extra>",
                    ))
                end

                # Label position = the rider's right-most plotted point.
                label_y = Float64(last(rider_cum).cumulative_score)
                surname = String(last(split(rider_name)))
                push!(end_labels, (y=label_y, name=surname, color=line_color))
            end

            # De-overlap end labels: sort by y and push any that crowd the previous one.
            y_max = isempty(end_labels) ? 1.0 : maximum(e.y for e in end_labels)
            min_gap = 0.045 * y_max
            sort!(end_labels, by=e -> e.y)
            annotations = []
            last_y = -Inf
            for e in end_labels
                ly = max(e.y, last_y + min_gap)
                last_y = ly
                push!(annotations, attr(
                    x=final_stage, y=ly, xref="x", yref="y",
                    text=e.name, showarrow=false,
                    xanchor="left", xshift=6,
                    font=attr(size=11, color=e.color),
                ))
            end

            # Terrain: a faint full-height tint anchors each stage column to its type,
            # with monochrome icons in a thin ribbon strip above the plot (the ribbon
            # cell carries a slightly stronger tint so the icon ties to its column).
            shapes = []
            images = []
            push!(shapes, attr(
                type="line", xref="paper", yref="paper",
                x0=0, x1=1, y0=1.013, y1=1.013,
                line=attr(color="#e4e7ea", width=1),
            ))
            if !isempty(stages)
                for s in stages
                    push!(shapes, attr(
                        type="rect", xref="x", yref="paper",
                        x0=s.stage_number - 0.5, x1=s.stage_number + 0.5,
                        y0=0, y1=1,
                        fillcolor=terrain_tint(s.stage_type, 0.14),
                        line=attr(width=0), layer="below",
                    ))
                    push!(shapes, attr(
                        type="rect", xref="x", yref="paper",
                        x0=s.stage_number - 0.5, x1=s.stage_number + 0.5,
                        y0=1.015, y1=1.055,
                        fillcolor=terrain_tint(s.stage_type, 0.26),
                        line=attr(width=0),
                    ))
                    icon = stage_icon_datauri(s.stage_type)
                    isempty(icon) && continue
                    push!(images, attr(
                        source=icon, xref="x", yref="paper",
                        x=s.stage_number, y=1.035,
                        xanchor="center", yanchor="middle",
                        sizex=0.7, sizey=0.04, sizing="contain", layer="above",
                    ))
                end
            end
            # Thin dotted rule separating the "Final" column from the stages.
            push!(shapes, attr(
                type="line", xref="x", yref="paper",
                x0=final_stage - 0.5, x1=final_stage - 0.5,
                y0=0, y1=1,
                line=attr(color="#d9dde1", width=1, dash="dot"),
            ))

            layout = Layout(
                hovermode="closest", template="plotly_white",
                font=attr(family=REPORT_FONT, color="#2d3436"),
                hoverlabel=report_hoverlabel(),
                xaxis=attr(tickvals=tick_vals, ticktext=tick_labels,
                    range=[0.5, final_stage + 0.5], showgrid=false,
                    tickfont=attr(size=11, color="#54616b"),
                    title=attr(text="Stage", font=attr(size=12, color="#54616b"))),
                yaxis=attr(showgrid=true, gridcolor="#eef0f2", gridwidth=1, zeroline=false,
                    tickformat=",", tickfont=attr(size=11, color="#54616b"),
                    title=attr(text="Cumulative VG points", font=attr(size=12, color="#54616b"))),
                shapes=shapes,
                images=images,
                annotations=annotations,
                showlegend=false,
                margin=attr(t=64, r=96, b=56, l=64),
            )
            write(io, plotly_html(traces, layout; id="plot-progression", height="560px"))
        end
    end

    # --- Top scorers + biggest hauls: companions to the progression chart ---
    nrow(scorers) > 0 && _write_top_scorers!(io, scorers; has_class=has_class,
        heading="Top scorers this race")
    _write_biggest_hauls!(io, per_stage, stages)

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
            :total_points => Symbol("Total points"), :avg_per_stage => Symbol("Per stage"))
        write(io, html_table(type_summary[:, [Symbol("Stage type"), :Stages,
            Symbol("Total points"), Symbol("Per stage")]]))

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
                        color=is_opt ? COLOR_OPTIMAL : COLOR_OTHER,
                    ),
                    text=["$(r.rider)<br>Stages scored: $(r.stages_scored)<br>Best stage: $(commafmt(r.best_stage))<br>Total: $(commafmt(r.total))" for r in eachrow(sub)],
                    hoverinfo="text",
                ))
            end
            write(io, plotly_html(traces_c, Layout(
                    template="plotly_white", hovermode="closest",
                    font=attr(family=REPORT_FONT, color="#2d3436"), hoverlabel=report_hoverlabel(),
                    xaxis=report_xaxis("Stages scored on"), yaxis=report_yaxis("Total VG points")); id="plot-consistency"))
        end
    end

    # --- Value for money: who was worth their price, who wasn't ---
    shared = _write_points_by_price!(io, allriders, optimal_keys)
    _write_points_per_credit!(io, allriders, optimal_keys,
        shared.jitter, shared.costs_f, shared.mean_c, shared.x_min, shared.x_max)
    _write_best_value!(io, scorers; has_class=has_class)
    _write_ones_to_avoid!(io, allriders, finishers, abandons)
    _write_classification_performance!(io, allriders, has_class)
    _write_team_performance!(io, allriders)

    body = String(take!(io))
    return html_page(;
        title="$race_name $year",
        subtitle="Fantasy retrospective — $race_date",
        body=body,
        include_plotly=true,
        home_url="../index.html",
        accent=race_accent(pcs_slug),
    )
end

"""Look up a grand tour by PCS slug, returning (name, month) or nothing."""
function _find_grand_tour(pcs_slug::String)
    for gt in GRAND_TOUR_RACES
        gt.pcs_slug == pcs_slug && return gt
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Rider lookup: cross-event "how did rider X do?" data + search page
# ---------------------------------------------------------------------------

function _ordinal(n::Integer)
    n <= 0 && return "—"
    suffix = (n % 100 in 11:13) ? "th" : get(Dict(1 => "st", 2 => "nd", 3 => "rd"), n % 10, "th")
    return "$n$suffix"
end

"""riderkey => (rank, label) for a one-day race, from archived PCS finishing positions."""
function _oneday_finish_lookup(pcs_slug, year)
    d = Dict{String,Tuple{Int,String}}()
    pcs = load_race_snapshot("pcs_results", pcs_slug, year)
    pcs === nothing && return d
    for r in eachrow(pcs)
        pos = r.position
        d[r.riderkey] = pos >= Velogames.DNF_POSITION ? (Velogames.DNF_POSITION, "DNF") : (pos, _ordinal(pos))
    end
    return d
end

"""riderkey => (rank, label) for a stage race, from archived GC results and abandons.
Abandons take precedence over a GC placing (a rider who abandoned has no GC time)."""
function _stage_finish_lookup(pcs_slug, year)
    d = Dict{String,Tuple{Int,String}}()
    gc = load_race_snapshot("pcs_gc_results", pcs_slug, year)
    if gc !== nothing
        for r in eachrow(gc)
            r.position < Velogames.DNF_POSITION || continue
            d[r.riderkey] = (r.position, "GC " * _ordinal(r.position))
        end
    end
    abandons = load_race_snapshot("pcs_abandons", pcs_slug, year)
    if abandons !== nothing
        for r in eachrow(abandons)
            d[r.riderkey] = (Velogames.DNF_POSITION, "DNF · st $(r.abandon_stage)")
        end
    end
    return d
end

"""Collect one normalised row per (rider, race) across one-day classics and grand tours,
reconciling the two result schemas into a single shape the lookup page can search."""
function collect_rider_rows(years)
    rows = Any[]

    # One-day classics
    for r in eachrow(list_completed_races(years))
        df = try
            load_report_data(r.pcs_slug, r.year; cache_config=_report_cache)
        catch e
            @warn "lookup: skipped one-day $(r.pcs_slug) $(r.year): $e"
            nothing
        end
        df === nothing && continue
        finish = _oneday_finish_lookup(r.pcs_slug, r.year)
        for rr in eachrow(df)
            rank, label = get(finish, rr.riderkey, (0, ""))
            (rank == 0 && rr.score == 0) && continue  # neither a recorded finish nor any points
            push!(rows, (
                rider=rr.rider, key=rr.riderkey, team=rr.team,
                event=r.name, year=r.year, type="oneday", date=r.date,
                cost=rr.cost, points=rr.score, finish=label, rank=rank,
                report="reports/$(r.pcs_slug)-$(r.year).html",
            ))
        end
    end

    # Grand tours
    for gt in GRAND_TOUR_RACES, year in years
        load_race_snapshot("vg_stage_totals", gt.pcs_slug, year) === nothing && continue
        df = try
            load_stage_race_report_data(gt.pcs_slug, year; cache_config=_report_cache)
        catch e
            @warn "lookup: skipped stage $(gt.pcs_slug) $year: $e"
            nothing
        end
        df === nothing && continue
        finish = _stage_finish_lookup(gt.pcs_slug, year)
        date = "$year-$(lpad(gt.month, 2, '0'))-15"
        for rr in eachrow(df)
            rank, label = get(finish, rr.riderkey, (0, "Finished"))
            (rank == 0 && rr.score == 0) && continue
            push!(rows, (
                rider=rr.rider, key=rr.riderkey, team=rr.team,
                event=gt.name, year=year, type="tour", date=date, slug=gt.pcs_slug,
                cost=rr.cost, points=rr.score, finish=label, rank=rank,
                report="reports/$(gt.pcs_slug)-$year.html",
            ))
        end
    end

    return rows
end

"""Per-stage grand-tour detail for the dossier, keyed "<riderkey>|<slug>|<year>" => array of
(s, pos, pts, win): per-stage VG points joined to the rider's PCS stage finish. Built only for
riders who scored VG points in that grand tour (the relevant set); lazy-loaded by the page."""
function collect_stage_rows(years)
    out = Dict{String,Vector{Any}}()
    for gt in GRAND_TOUR_RACES, year in years
        vg = load_race_snapshot("vg_stage_results", gt.pcs_slug, year)
        vg === nothing && continue
        pcs = load_race_snapshot("pcs_stage_results", gt.pcs_slug, year)

        posmap = Dict{Tuple{String,Int},Int}()
        if pcs !== nothing
            for r in eachrow(pcs)
                posmap[(r.riderkey, r.stage)] = r.position
            end
        end
        vgmap = Dict{Tuple{String,Int},Int}()
        riders = String[]
        for r in eachrow(vg)
            vgmap[(r.riderkey, r.stage)] = r.score
            push!(riders, r.riderkey)
        end

        for key in unique(riders)
            entries = Any[]
            for s in 1:gt.n_stages
                pts = get(vgmap, (key, s), 0)
                p = get(posmap, (key, s), Velogames.DNF_POSITION)
                has_pos = p < Velogames.DNF_POSITION
                (pts == 0 && !has_pos) && continue
                push!(entries, (s=s, pos=has_pos ? _ordinal(p) : "", pts=pts, win=has_pos && p == 1))
            end
            isempty(entries) || (out["$key|$(gt.pcs_slug)|$year"] = entries)
        end
    end
    return out
end

const _LOOKUP_BODY = raw"""
<style>
  /* Lookup page sits on the shared masthead/paper card; widen it and drop the empty TOC. */
  nav#toc { display: none; }
  .page-body { max-width: 1060px; }
  main.content { max-width: none; }

  .lookup-intro { color: var(--ink-soft); margin: 0 0 1.6em; max-width: 46em; }

  /* ---- Search field ---- */
  .search-wrap { position: relative; max-width: 30em; margin: 0 0 1.1em; }
  .search-wrap .ico {
    position: absolute; left: 1em; top: 50%; transform: translateY(-50%);
    width: 18px; height: 18px; color: var(--ink-soft); pointer-events: none;
  }
  #q {
    width: 100%; font-family: var(--font-body); font-size: 1.08em; color: var(--ink);
    padding: 0.85em 1em 0.85em 2.9em; background: var(--paper);
    border: 1px solid var(--rule); border-radius: 10px; outline: none;
    box-shadow: 0 1px 2px rgba(15, 35, 55, 0.05); transition: border-color 0.15s, box-shadow 0.15s;
  }
  #q::placeholder { color: #aab1b8; }
  #q:focus { border-color: var(--accent); box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 28%, transparent); }

  .suggest {
    list-style: none; margin: 0.4em 0 0; padding: 0.3em; position: absolute; z-index: 20;
    left: 0; right: 0; background: var(--paper); border: 1px solid var(--rule);
    border-radius: 10px; box-shadow: 0 10px 30px rgba(15, 35, 55, 0.12); display: none;
  }
  .suggest.open { display: block; }
  .suggest li {
    display: flex; align-items: baseline; justify-content: space-between; gap: 1em;
    padding: 0.55em 0.8em; border-radius: 7px; cursor: pointer; margin: 0;
  }
  .suggest li.on, .suggest li:hover { background: #f3efe6; box-shadow: inset 2px 0 0 var(--accent); }
  .suggest .s-name { font-weight: 600; color: var(--ink); }
  .suggest .s-team { font-size: 0.82em; color: var(--ink-soft); text-align: right; }

  /* ---- Example chips ---- */
  .examples { display: flex; flex-wrap: wrap; gap: 0.5em; align-items: center; margin: 0 0 0.5em; }
  .examples .ex-label {
    font-size: 0.72em; text-transform: uppercase; letter-spacing: 0.09em;
    font-weight: 700; color: var(--ink-soft); margin-right: 0.2em;
  }
  .chip {
    font-family: var(--font-body); font-size: 0.86em; color: var(--navy); cursor: pointer;
    background: #faf8f3; border: 1px solid var(--rule); border-radius: 999px;
    padding: 0.34em 0.95em; transition: background 0.15s, border-color 0.15s, color 0.15s;
  }
  .chip:hover { background: var(--navy); border-color: var(--navy); color: #fff; }

  /* ---- Empty state ---- */
  .empty-state {
    margin-top: 2.4em; padding: 2.2em 0 1em; border-top: 1px solid var(--rule-soft);
    color: var(--ink-soft);
  }
  .empty-state .big {
    font-family: var(--font-display); font-size: 1.5em; color: var(--navy);
    margin: 0 0 0.3em; font-weight: 600;
  }

  /* ---- Dossier ---- */
  .dossier { margin-top: 1.8em; opacity: 0; }
  .dossier.show { animation: rise 0.45s cubic-bezier(0.2, 0.7, 0.3, 1) both; }

  .dossier-head { border-bottom: 2px solid var(--accent); padding-bottom: 0.7em; margin-bottom: 1.4em; }
  .dossier-head .eyebrow {
    font-size: 0.76em; text-transform: uppercase; letter-spacing: 0.1em;
    font-weight: 700; color: var(--ink-soft); margin: 0 0 0.25em;
  }
  .dossier-head h2 {
    font-family: var(--font-display); font-size: clamp(2em, 5vw, 2.9em); line-height: 1.04;
    letter-spacing: -0.015em; color: var(--navy); margin: 0; border: none; padding: 0;
  }

  .strip-filter { display: flex; align-items: baseline; gap: 0.5em; margin: 0 0 1.3em;
    font-size: 0.72em; text-transform: uppercase; letter-spacing: 0.09em; font-weight: 700; color: var(--ink-soft); }
  .strip-filter select {
    font-family: var(--font-body); font-size: 1.1em; font-weight: 600; letter-spacing: 0;
    text-transform: none; color: var(--navy); background-color: var(--paper);
    border: 1px solid var(--rule); border-radius: 8px; padding: 0.3em 2em 0.3em 0.7em; cursor: pointer;
    appearance: none; -webkit-appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 8'%3E%3Cpath fill='none' stroke='%23043b5c' stroke-width='1.6' d='M1 1.5 6 6.5 11 1.5'/%3E%3C/svg%3E");
    background-repeat: no-repeat; background-position: right 0.7em center; background-size: 0.72em;
    transition: border-color 0.15s, box-shadow 0.15s;
  }
  .strip-filter select:hover { border-color: var(--navy); }
  .strip-filter select:focus-visible {
    outline: none; border-color: var(--accent);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 28%, transparent);
  }

  /* Lift the headline strips (and the tooltips that drop out of them) above the season blocks
     below: those animate in with a transform, forming stacking contexts that would otherwise
     paint over a tooltip extending down into the ledger. */
  #strips { position: relative; z-index: 10; }

  .disc { margin: 0 0 1.6em; }
  .disc-label {
    position: relative;
    font-size: 0.72em; text-transform: uppercase; letter-spacing: 0.1em; font-weight: 700;
    color: var(--ink-soft); margin: 0 0 0.7em; padding-bottom: 0.5em; border-bottom: 1px solid var(--rule);
  }
  /* Short gold tab under each discipline heading — an editorial section marker echoing the
     masthead rule and the spark/podium golds. */
  .disc-label::after {
    content: ""; position: absolute; left: 0; bottom: -1px; width: 2.2em; height: 2px;
    background: var(--accent); border-radius: 1px;
  }
  .statstrip { display: flex; flex-wrap: wrap; gap: 0.5em 0; margin: 0; }
  .disc:last-of-type { margin-bottom: 1.9em; }
  /* Even gutters: every stat carries equal left/right padding with the divider on its left edge,
     so the hairlines sit centred between figures rather than hugging one side. */
  .stat { flex: 1 1 0; min-width: 8em; padding: 0.1em 1.4em; border-left: 1px solid var(--rule-soft); }
  .stat:first-child { padding-left: 0; border-left: none; }
  .stat .v {
    font-family: var(--font-display); font-size: 2em; font-weight: 600; color: var(--navy);
    line-height: 1.05; letter-spacing: -0.01em; font-variant-numeric: tabular-nums lining-nums;
  }
  .stat .v.dnf { color: #a23b34; }
  .stat .l {
    font-size: 0.7em; text-transform: uppercase; letter-spacing: 0.08em; font-weight: 700;
    color: var(--ink-soft); margin-top: 0.4em; line-height: 1.3;
  }

  /* Info badge + tooltip explaining each stat's calculation */
  .info {
    position: relative; display: inline-flex; align-items: center; justify-content: center;
    width: 1.2em; height: 1.2em; margin-left: 0.4em; vertical-align: -0.18em;
    border: 1px solid currentColor; border-radius: 50%;
    font-family: var(--font-display); font-style: italic; font-weight: 700;
    font-size: 0.92em; line-height: 1; text-transform: none; letter-spacing: 0;
    color: var(--ink-soft); opacity: 0.5; cursor: help; user-select: none;
    transition: opacity 0.12s;
  }
  .info:hover, .info:focus { opacity: 0.95; outline: none; }
  .info .tip {
    position: absolute; top: 168%; left: 50%;
    transform: translateX(-50%) translateY(-3px);
    width: max-content; max-width: 16em;
    background: var(--navy); color: #fff; padding: 0.65em 0.85em; border-radius: 8px;
    font: 400 0.8rem/1.5 var(--font-body); text-transform: none; letter-spacing: 0;
    text-align: left; white-space: normal; text-shadow: none;
    opacity: 0; visibility: hidden; pointer-events: none; z-index: 40;
    box-shadow: 0 6px 22px rgba(15, 35, 55, 0.22);
    transition: opacity 0.14s, transform 0.14s;
  }
  .info .tip::after {
    content: ""; position: absolute; bottom: 100%; left: 50%; transform: translateX(-50%);
    border: 5px solid transparent; border-bottom-color: var(--navy);
  }
  .info:hover .tip, .info:focus .tip {
    opacity: 1; visibility: visible; transform: translateX(-50%) translateY(0);
  }
  @media (max-width: 560px) {
    .info .tip { max-width: 13em; }
  }

  .season-label {
    font-family: var(--font-display); font-size: 1.25em; font-weight: 600; color: var(--ink);
    margin: 1.7em 0 0.2em; display: flex; align-items: center; gap: 0.8em;
  }
  .season-label .season-cost {
    font-family: var(--font-body); font-size: 0.56em; font-weight: 700; text-transform: uppercase;
    letter-spacing: 0.06em; color: #8a6400; white-space: nowrap;
    background: color-mix(in srgb, var(--accent) 18%, transparent);
    padding: 0.4em 0.75em; border-radius: 999px; line-height: 1;
  }
  .season-label::after { content: ""; flex: 1; height: 1px; background: var(--rule); }

  table.ledger { table-layout: fixed; }
  table.ledger th.c-pts, table.ledger td.c-pts { text-align: right; }
  table.ledger td.c-event { font-weight: 600; }
  table.ledger td.c-event .ev-tour { font-weight: 400; font-size: 0.8em; color: var(--ink-soft); margin-left: 0.5em; letter-spacing: 0.02em; }
  table.ledger td.c-date { color: var(--ink-soft); white-space: nowrap; }

  .res { display: inline-block; padding: 0.12em 0.7em; border-radius: 999px; font-size: 0.82em; font-weight: 700; white-space: nowrap; }
  .res-podium { background: color-mix(in srgb, var(--accent) 26%, transparent); color: #8a6400; }
  .res-top { background: rgba(10, 106, 168, 0.12); color: #0a5a8f; }
  .res-pack { color: var(--ink-soft); font-weight: 600; }
  .res-dnf { background: rgba(162, 59, 52, 0.12); color: #a23b34; }

  .ptscell { display: flex; align-items: center; justify-content: flex-end; gap: 0.7em; }
  .ptscell .pv { font-variant-numeric: tabular-nums; min-width: 2.6em; text-align: right; font-weight: 600; }
  .ptscell .pv.zero { color: #aab1b8; font-weight: 400; }
  .spark { width: 4.5em; height: 7px; border-radius: 4px; background: var(--rule-soft); overflow: hidden; }
  .spark > span { display: block; height: 100%; background: linear-gradient(90deg, var(--accent), color-mix(in srgb, var(--accent) 60%, #c0712a)); border-radius: 4px; }

  .footnote { font-size: 0.78em; color: var(--ink-soft); margin-top: 1.6em; padding-top: 0.9em; border-top: 1px solid var(--rule-soft); }

  /* Expandable grand-tour rows */
  table.ledger tr.tour-row { cursor: pointer; }
  table.ledger tr.tour-row:hover { background: #f3efe6; }
  table.ledger tr.tour-row .caret {
    display: inline-flex; align-items: center; justify-content: center;
    width: 1.6em; height: 1.6em; margin-right: 0.55em; vertical-align: middle;
    border-radius: 6px; background: color-mix(in srgb, var(--accent) 22%, transparent);
    color: #8a6400; font-size: 0.78em; font-weight: 700;
    transition: background 0.12s;
  }
  table.ledger tr.tour-row:hover .caret { background: color-mix(in srgb, var(--accent) 40%, transparent); }
  table.ledger tr.tour-row.open .caret { background: var(--accent); color: #fff; }
  tr.stage-detail > td { background: #faf8f3; padding: 0.5em 1.1em 0.9em; }
  .stage-wrap { max-width: 34em; }
  table.stage-table { width: 100%; border-collapse: collapse; margin: 0; font-size: 0.86em; box-shadow: none; border-radius: 0; }
  table.stage-table th { background: transparent; color: var(--ink-soft); text-transform: uppercase; letter-spacing: 0.06em; font-size: 0.86em; border-bottom: 1px solid var(--rule); padding: 0.3em 0.7em; }
  table.stage-table td { padding: 0.32em 0.7em; border-bottom: 1px solid var(--rule-soft); }
  table.stage-table tbody tr:last-child td { border-bottom: none; }
  table.stage-table td.st-n { color: var(--ink-soft); white-space: nowrap; font-weight: 600; }
  .st-pos { color: var(--ink-soft); }
  .st-none { color: var(--ink-soft); font-size: 0.9em; margin: 0.2em 0; }

  .dossier.show .season-block { animation: rise 0.4s cubic-bezier(0.2, 0.7, 0.3, 1) both; }

  @media (max-width: 560px) {
    .statstrip { gap: 0.9em 1.4em; }
    .stat { flex: 0 1 calc(50% - 0.7em); min-width: 0; border-left: none; padding: 0.1em 0; }
    .spark { display: none; }
  }
</style>

<p class="lookup-intro">Type a rider&rsquo;s name to see every race they rode this season &mdash; where they finished, and how many Velogames points they scored. Share a dossier by copying its link.</p>

<div class="search-wrap">
  <svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"></circle><path d="M21 21l-4.3-4.3"></path></svg>
  <input id="q" type="text" autocomplete="off" spellcheck="false" placeholder="Search a rider — e.g. Pogačar, Ballerini" aria-label="Search for a rider" />
  <ul id="sugg" class="suggest" role="listbox"></ul>
</div>
<div id="examples" class="examples"></div>

<div id="dossier" class="dossier"></div>
<div id="empty" class="empty-state">
  <p class="big">Who are you looking for?</p>
  <p>Search by surname or full name. Results cover every classic and grand tour we have data for.</p>
</div>

<script>
(function () {
  var norm = function (s) { return s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase(); };
  var esc = function (s) { return String(s).replace(/[&<>"]/g, function (c) { return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]; }); };
  var ord = function (n) { var s = ["th", "st", "nd", "rd"], v = n % 100; return n + (s[(v - 20) % 10] || s[v] || s[0]); };
  var fmt = function (n) { return n.toLocaleString("en-GB"); };
  var fmtDate = function (iso) { var d = new Date(iso); return isNaN(d) ? "" : d.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" }); };

  var RIDERS = new Map();
  var LIST = [];
  var CURRENT = null;  // {oneday, tours} for the dossier on screen, so the year filter can recompute
  var q = document.getElementById("q");
  var sugg = document.getElementById("sugg");
  var matches = [], active = -1;

  fetch("riders.json").then(function (r) { return r.json(); }).then(function (rows) {
    rows.forEach(function (r) {
      if (!RIDERS.has(r.key)) RIDERS.set(r.key, { name: r.rider, key: r.key, team: r.team, races: [], _y: -1 });
      var e = RIDERS.get(r.key);
      e.races.push(r);
      if (r.year > e._y) { e._y = r.year; e.team = r.team; }  // display the most recent team
    });
    LIST = Array.from(RIDERS.values()).map(function (e) {
      return { name: e.name, key: e.key, team: e.team, n: norm(e.name) };
    }).sort(function (a, b) { return a.name.localeCompare(b.name); });
    buildExamples();
    if (location.hash.length > 1) {
      var k = decodeURIComponent(location.hash.slice(1));
      if (RIDERS.has(k)) { q.value = RIDERS.get(k).name; render(k); }
    }
  });

  function buildExamples() {
    var tops = Array.from(RIDERS.values()).map(function (e) {
      return { key: e.key, name: e.name, pts: e.races.reduce(function (s, r) { return s + r.points; }, 0) };
    }).sort(function (a, b) { return b.pts - a.pts; }).slice(0, 5);
    var box = document.getElementById("examples");
    box.innerHTML = '<span class="ex-label">Try</span>' + tops.map(function (t) {
      return '<button class="chip" data-key="' + esc(t.key) + '">' + esc(t.name) + "</button>";
    }).join("");
    Array.prototype.forEach.call(box.querySelectorAll(".chip"), function (b) {
      b.onclick = function () { select(b.getAttribute("data-key")); };
    });
  }

  function renderSugg() {
    if (!matches.length) { closeSugg(); return; }
    sugg.innerHTML = matches.map(function (m, i) {
      return '<li role="option" data-key="' + esc(m.key) + '" class="' + (i === active ? "on" : "") + '">' +
        '<span class="s-name">' + esc(m.name) + '</span><span class="s-team">' + esc(m.team) + "</span></li>";
    }).join("");
    sugg.classList.add("open");
    Array.prototype.forEach.call(sugg.querySelectorAll("li"), function (li) {
      li.onmousedown = function (e) { e.preventDefault(); select(li.getAttribute("data-key")); };
    });
  }
  function closeSugg() { sugg.classList.remove("open"); sugg.innerHTML = ""; matches = []; active = -1; }

  q.addEventListener("input", function () {
    var v = norm(q.value.trim());
    if (!v) { closeSugg(); return; }
    matches = LIST.filter(function (e) { return e.n.indexOf(v) !== -1; }).slice(0, 8);
    active = -1; renderSugg();
  });
  q.addEventListener("keydown", function (e) {
    if (!matches.length) return;
    if (e.key === "ArrowDown") { e.preventDefault(); active = (active + 1) % matches.length; renderSugg(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); active = (active - 1 + matches.length) % matches.length; renderSugg(); }
    else if (e.key === "Enter") { e.preventDefault(); select(matches[active >= 0 ? active : 0].key); }
    else if (e.key === "Escape") { closeSugg(); }
  });
  document.addEventListener("click", function (e) { if (!e.target.closest(".search-wrap")) closeSugg(); });

  function select(key) {
    var e = RIDERS.get(key);
    if (!e) return;
    q.value = e.name; closeSugg();
    history.replaceState(null, "", "#" + encodeURIComponent(key));
    render(key);
  }

  function resClass(r) {
    if (r.rank >= 1 && r.rank <= 3) return "res res-podium";
    if (/^DNF/.test(r.finish)) return "res res-dnf";
    if (r.rank >= 1 && r.rank <= 10) return "res res-top";
    return "res-pack";
  }

  // Per-stage grand-tour detail (lazy-loaded once, on first expand).
  var STAGES = null, stagesP = null;
  function loadStages() {
    if (STAGES) return Promise.resolve(STAGES);
    if (!stagesP) stagesP = fetch("stages.json").then(function (r) { return r.json(); }).then(function (m) { STAGES = m; return m; });
    return stagesP;
  }

  function reportHref(r, e) {
    return r.report + "?rider=" + encodeURIComponent(e.key) + "&name=" + encodeURIComponent(e.name);
  }

  function stageDetailHtml(entries) {
    var maxP = entries.reduce(function (m, x) { return Math.max(m, x.pts); }, 1);
    var body = entries.map(function (x) {
      var w = Math.round((x.pts / maxP) * 100);
      var bar = x.pts > 0 ? '<span class="spark"><span style="width:' + w + '%"></span></span>' : "";
      var pv = '<span class="pv' + (x.pts > 0 ? "" : " zero") + '">' + fmt(x.pts) + "</span>";
      var pos = x.pos
        ? '<span class="' + (x.win ? "res res-podium" : "st-pos") + '">' + esc(x.pos) + (x.win ? " · win" : "") + "</span>"
        : '<span class="st-pos">—</span>';
      return '<tr><td class="st-n">Stage ' + x.s + "</td><td>" + pos +
        '</td><td class="c-pts"><span class="ptscell">' + bar + pv + "</span></td></tr>";
    }).join("");
    return '<table class="stage-table"><thead><tr><th>Stage</th><th>Finish</th>' +
      '<th class="c-pts">VG pts</th></tr></thead><tbody>' + body + "</tbody></table>";
  }

  function toggleStage(row) {
    var open = row.classList.toggle("open");
    var caret = row.querySelector(".caret");
    if (caret) caret.textContent = open ? "▾" : "▸";
    var next = row.nextElementSibling;
    if (!open) { if (next && next.className === "stage-detail") next.remove(); return; }
    var dr = document.createElement("tr");
    dr.className = "stage-detail";
    dr.innerHTML = '<td colspan="4"><div class="stage-wrap">Loading…</div></td>';
    row.parentNode.insertBefore(dr, row.nextSibling);
    loadStages().then(function (map) {
      var entries = map[row.getAttribute("data-stagekey")];
      dr.querySelector(".stage-wrap").innerHTML =
        entries && entries.length ? stageDetailHtml(entries) : '<p class="st-none">No per-stage VG points recorded.</p>';
    });
  }

  // One delegated handler survives dossier re-renders (#dossier itself is never replaced).
  document.getElementById("dossier").addEventListener("click", function (ev) {
    var row = ev.target.closest(".tour-row");
    if (!row || ev.target.closest("a")) return;  // let the race-name link navigate
    toggleStage(row);
  });

  // The year filter recomputes only the headline strips; the season ledger below stays put.
  document.getElementById("dossier").addEventListener("change", function (ev) {
    if (!ev.target.classList.contains("year-filter") || !CURRENT) return;
    var strips = document.getElementById("strips");
    if (strips) strips.innerHTML = stripsHtml(CURRENT.oneday, CURRENT.tours, ev.target.value);
  });

  // The two headline discipline strips, optionally narrowed to a single season ("all" = every year).
  function stripsHtml(oneday, tours, year) {
    var od = year === "all" ? oneday : oneday.filter(function (r) { return String(r.year) === year; });
    var tr = year === "all" ? tours : tours.filter(function (r) { return String(r.year) === year; });
    return discStrip("Classics", od, "Avg pts / race") + discStrip("Grand tours", tr, "Avg pts / tour");
  }

  function render(key) {
    var e = RIDERS.get(key);
    if (!e) return;
    document.getElementById("empty").style.display = "none";

    var races = e.races.slice().sort(function (a, b) { return b.date.localeCompare(a.date); });
    var oneday = races.filter(function (r) { return r.type === "oneday"; });
    var tours = races.filter(function (r) { return r.type === "tour"; });
    var maxPts = Math.max(1, Math.max.apply(null, races.map(function (r) { return r.points; })));
    var hasTour = tours.length > 0;

    var years = Array.from(new Set(races.map(function (r) { return r.year; }))).sort(function (a, b) { return b - a; });

    var html = "";
    html += '<div class="dossier-head"><p class="eyebrow">' + esc(e.team) + '</p><h2>' + esc(e.name) + "</h2></div>";

    // Separate VG-performance rows per discipline — classics and grand tours are on different
    // points scales, so blending them into one average is misleading. A row is shown only when
    // the rider has races of that type. The optional year filter recomputes them in place.
    CURRENT = { oneday: oneday, tours: tours };
    if (years.length > 1) {
      var opts = '<option value="all">All seasons</option>' +
        years.map(function (y) { return '<option value="' + y + '">' + y + " season</option>"; }).join("");
      html += '<div class="strip-filter"><span>Show</span><select class="year-filter" aria-label="Filter headline results by season">' + opts + "</select></div>";
    }
    html += '<div id="strips">' + stripsHtml(oneday, tours, "all") + "</div>";

    years.forEach(function (yr, yi) {
      var yrRaces = races.filter(function (r) { return r.year === yr; });
      html += '<div class="season-block" style="animation-delay:' + (yi * 0.06) + 's">';
      // The classics price is one season-long charge, so it belongs on the season header rather
      // than repeated on every race row; grand-tour prices are shown per tour on their own rows.
      var odYr = yrRaces.filter(function (r) { return r.type === "oneday"; });
      var costTag = odYr.length ? ' <span class="season-cost">Classics ' + fmt(odYr[0].cost || 0) + " cr</span>" : "";
      html += '<div class="season-label">' + yr + " season" + costTag + "</div>";
      html += '<table class="table ledger"><thead><tr>' +
        '<th>Race</th><th>Date</th><th>Result</th><th class="c-pts">Velogames pts</th>' +
        "</tr></thead><tbody>";
      yrRaces.forEach(function (r) {
        var w = Math.round((r.points / maxPts) * 100);
        var isTour = r.type === "tour";
        var caret = isTour ? '<span class="caret">▸</span>' : "";
        var tourTag = isTour ? '<span class="ev-tour">Grand Tour · ' + fmt(r.cost || 0) + " cr</span>" : "";
        var spark = r.points > 0 ? '<span class="spark"><span style="width:' + w + '%"></span></span>' : "";
        var pv = '<span class="pv' + (r.points > 0 ? "" : " zero") + '">' + fmt(r.points) + "</span>";
        var stagekey = isTour ? (key + "|" + r.slug + "|" + r.year) : "";
        html += "<tr" + (isTour ? ' class="tour-row" data-stagekey="' + esc(stagekey) + '"' : "") + ">" +
          '<td class="c-event">' + caret + '<a href="' + esc(reportHref(r, e)) + '">' + esc(r.event) + "</a>" + tourTag + "</td>" +
          '<td class="c-date">' + fmtDate(r.date) + "</td>" +
          '<td><span class="' + resClass(r) + '">' + esc(r.finish || "—") + "</span></td>" +
          '<td class="c-pts"><span class="ptscell">' + spark + pv + "</span></td>" +
          "</tr>";
      });
      html += "</tbody></table></div>";
    });

    var notes = [];
    if (races.some(function (r) { return !r.finish; })) {
      notes.push("A dash (—) means the finishing position for that race hasn’t been recorded — PCS placings were archived from 2026, so earlier one-day races show Velogames points only.");
    }
    if (hasTour) {
      notes.push("Grand-tour points are full-race totals; click a grand tour to break it down by stage.");
    }
    if (notes.length) html += '<p class="footnote">' + notes.join(" ") + "</p>";

    var d = document.getElementById("dossier");
    d.innerHTML = html;
    d.classList.remove("show"); void d.offsetWidth; d.classList.add("show");
  }

  function stat(value, label, info) {
    var badge = info
      ? ' <span class="info" tabindex="0" role="note" aria-label="' + esc(info) + '">i<span class="tip">' + esc(info) + "</span></span>"
      : "";
    return '<div class="stat"><div class="v">' + esc(value) + '</div><div class="l">' + esc(label) + badge + "</div></div>";
  }

  // A labelled VG-performance row for one discipline (avg points, credits, value, races started),
  // all computed within that discipline. Returns "" when the rider has no races of the type.
  //
  // The two formats commit credits differently, so the value metric is computed differently:
  //  - Grand tours lock a fixed 9-rider lineup for all 21 stages, so a DNF forfeits the rest
  //    of the race. Raw points relative to budget exposure is the right measure: total points
  //    across every grand tour ÷ summed credits (each grand tour is its own game, counted once).
  //  - Classics charge one season-long price but let managers swap riders freely before each
  //    race, so low attendance shouldn't tank a rider's value. Each season is scored by average
  //    points per race started, normalised by that season's price; we then average the seasons.
  function discStrip(label, arr, avgLabel) {
    if (!arr.length) return "";
    var tot = arr.reduce(function (s, r) { return s + r.points; }, 0);
    var isTour = arr[0].type === "tour";

    var ppc;
    if (isTour) {
      var seen = {}, credits = 0;
      arr.forEach(function (r) {
        var gk = r.year + "|" + r.event;
        if (!seen[gk]) { seen[gk] = true; credits += (r.cost || 0); }
      });
      ppc = credits ? (tot / credits) : 0;
    } else {
      // Per-season efficiency: points ÷ (races started × that season's credit price), averaged
      // across seasons. Each season's price is paid once, so all its races share one cost.
      var byYear = {};
      arr.forEach(function (r) {
        var g = byYear[r.year] || (byYear[r.year] = { pts: 0, started: 0, cost: r.cost || 0 });
        g.pts += r.points;
        g.started += 1;
      });
      var vsum = 0, vn = 0;
      for (var y in byYear) {
        var g = byYear[y];
        if (g.started > 0 && g.cost > 0) { vsum += g.pts / (g.started * g.cost); vn += 1; }
      }
      ppc = vn ? (vsum / vn) : 0;
    }

    // Credits committed, by season. Classics charge one season-long price (shared across that
    // year's races); each grand tour charges its own. We surface the most recent season's price —
    // the actionable "what they'd cost now" — and label the year when the strip spans seasons.
    var costByYear = {}, seenGame = {};
    arr.forEach(function (r) {
      if (isTour) {
        var gk = r.year + "|" + r.event;
        if (seenGame[gk]) return;
        seenGame[gk] = true;
        costByYear[r.year] = (costByYear[r.year] || 0) + (r.cost || 0);
      } else {
        costByYear[r.year] = r.cost || 0;  // shared season price
      }
    });
    var costYears = Object.keys(costByYear).sort();
    var latestYear = costYears[costYears.length - 1];
    var multiYear = costYears.length > 1;

    var infoAvg = "Total points ÷ the number of " + (isTour ? "grand tours" : "classics") + " ridden (across all archived seasons).";
    var infoPpc = isTour
      ? "Total points ÷ credits, counting each grand tour’s price once (a grand tour is one game). A DNF forfeits the locked lineup's remaining stages, so it rightly drags this down."
      : "Average points per race started ÷ the season's credit price, averaged across seasons. The classics price buys the rider for the whole spring while managers swap freely before each race, so skipped races don't penalise value — but watch the races-started count for small samples.";
    var infoCost = isTour
      ? "Credits paid for this rider's grand tour" + (multiYear ? "s in " + latestYear + " (a season's cost sums its tours). Filter to a year for that season's price." : ". Each grand tour is its own game with its own price.")
      : "The classics season price — paid once for the whole spring, not per race." + (multiYear ? " Shown for " + latestYear + "; filter to a year for that season's price." : "");
    var startedStat = isTour ? "" :
      stat(fmt(arr.length), "Races started", "Number of classics this rider actually started (across all archived seasons). A high points-per-credit off one or two races is a small sample, not a sure thing.");
    return '<div class="disc"><div class="disc-label">' + esc(label) + " &middot; " + arr.length +
      (arr.length === 1 ? " race" : " races") + "</div>" +
      '<div class="statstrip">' +
        stat(fmt(Math.round(tot / arr.length)), avgLabel, infoAvg) +
        stat(fmt(costByYear[latestYear]), multiYear ? "Credits · " + latestYear : "Credits", infoCost) +
        stat(fmt(Math.round(ppc)), "Points / credit", infoPpc) +
        startedStat +
      "</div></div>";
  }
})();
</script>
"""

lookup_page_html() = html_page(;
    title="Rider lookup",
    subtitle="How did any rider do? Search every race of the season",
    body=_LOOKUP_BODY,
    home_url="index.html",
)

function index_html(; reports_dir)
    report_files = isdir(reports_dir) ? filter(f -> endswith(f, ".html"), readdir(reports_dir)) : String[]

    io = IOBuffer()
    write(io, "<p>A look back at each race in the season: who delivered, who disappointed, and what the perfect team would have been.</p>\n")
    write(io, "<p style=\"margin:1.2em 0 0.4em\"><a href=\"riders.html\" style=\"display:inline-block;background:var(--navy);color:#fff;font-weight:600;padding:0.6em 1.2em;border-radius:8px;text-decoration:none\">Look up any rider&rsquo;s season &rarr;</a></p>\n")

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

    # Rider lookup data + page (always rebuilt — the JSON must cover every race)
    rider_rows = collect_rider_rows(years)
    open(joinpath(docs_dir, "riders.json"), "w") do io
        JSON3.write(io, rider_rows)
    end
    stage_detail = collect_stage_rows(years)
    open(joinpath(docs_dir, "stages.json"), "w") do io
        JSON3.write(io, stage_detail)
    end
    write(joinpath(docs_dir, "riders.html"), lookup_page_html())
    println("  Generated riders.json ($(length(rider_rows)) rows), stages.json ($(length(stage_detail)) rider-tours) and riders.html")

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
