#!/usr/bin/env julia
"""
Render the stage race predictor report as a standalone HTML page.

Usage:
    julia --project scripts/render_stagerace.jl [--fresh] [--force]

Options:
    --fresh   Bypass cache, fetch all data fresh from the web
    --force   Overwrite existing prediction archive (default: skip if exists)
"""

using Velogames, DataFrames, Statistics, Dates, TOML

const FRESH = "--fresh" in ARGS
"--force" in ARGS && (ENV["VELOGAMES_FORCE_ARCHIVE"] = "1")

# ---------------------------------------------------------------------------
# Configuration (from race_config.toml)
# ---------------------------------------------------------------------------

const _cfg = TOML.parsefile(joinpath(@__DIR__, "..", "data", "race_config.toml"))

race_name = _cfg["race"]["name"]
race_year = _cfg["race"]["year"]
@info "Configuration" race=race_name year=race_year
racehash = _cfg["race"]["racehash"]

betfair_market_id = _cfg["data_sources"]["betfair_market_id"]
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

race_cache = CacheConfig(joinpath(homedir(), ".velogames_cache"), FRESH ? 0 : 6)

# ---------------------------------------------------------------------------
# Run prediction
# ---------------------------------------------------------------------------

config = setup_race(race_name, race_year; cache_config=race_cache)

predicted, chosenteam, top_teams, sim_vg_points = solve_stage(config;
    racehash=racehash,
    history_years=history_years,
    betfair_market_id=betfair_market_id,
    oracle_url=oracle_url,
    n_resamples=n_resamples,
    excluded_riders=excluded_riders,
    domestique_discount=domestique_discount,
    risk_aversion=risk_aversion,
    max_per_team=max_per_team,
    simulation_df=simulation_df)

if nrow(predicted) == 0
    error("No riders found — check race name, year, and startlist hash filter.")
end

# ---------------------------------------------------------------------------
# Build page content
# ---------------------------------------------------------------------------

io = IOBuffer()

n_total = nrow(predicted)
write(io, "<p><strong>$(titlecase(config.name)) $(config.year)</strong> — Stage race, $(n_total) riders, $(n_resamples) resamples</p>\n")

# --- Data sources ---

n_pcs = count(predicted.has_pcs)
n_history = count(predicted.has_race_history)
n_odds = count(predicted.has_odds)
n_oracle = count(predicted.has_oracle)
n_vg_hist = count(predicted.has_vg_history)
pct(n) = round(Int, 100 * n / n_total)

similar_races = get(SIMILAR_RACES, config.pcs_slug, String[])
similar_str = isempty(similar_races) ? "None configured" : join(similar_races, ", ")

sources_df = DataFrame(
    Source = [
        "PCS specialty ratings (class-blended)", "VG season points",
        "PCS race history ($(history_years) yrs)", "Similar races", "VG race history",
        "Cycling Oracle", "Betfair odds",
    ],
    Coverage = [
        "$(n_pcs)/$(n_total) ($(pct(n_pcs))%)", "$(n_total)/$(n_total) (100%)",
        "$(n_history)/$(n_total) ($(pct(n_history))%)", similar_str,
        "$(n_vg_hist)/$(n_total) ($(pct(n_vg_hist))%)",
        "$(n_oracle)/$(n_total) ($(pct(n_oracle))%)",
        "$(n_odds)/$(n_total) ($(pct(n_odds))%)",
    ],
)

sources_html = html_table(sources_df)
sources_html *= "<p>PCS specialty scores are blended by rider classification: all-rounders weight GC + TT + climbing, climbers weight climbing heavily, sprinters weight sprint + one-day.</p>\n"
write(io, html_callout(sources_html; title="Data sources", collapsed=false))

# --- Signal impact ---

rms(v) = sqrt(mean(v .^ 2))
signal_names = ["PCS specialty", "VG season points", "PCS form", "Trajectory", "PCS race history", "VG race history", "Cycling Oracle", "Betfair odds"]
shift_cols = [:shift_pcs, :shift_vg, :shift_form, :shift_trajectory, :shift_history, :shift_vg_history, :shift_oracle, :shift_odds]
affected_counts = [count(!=(0.0), predicted[!, c]) for c in shift_cols]
rms_shifts = [rms(predicted[!, c]) for c in shift_cols]

impact_df = DataFrame(
    Signal = signal_names,
    Riders_affected = affected_counts,
    RMS_shift = round.(rms_shifts, digits=3),
)
write(io, html_callout(
    "<p>How much each source shifted rider strength estimates from the uninformative prior.</p>\n" * html_table(impact_df);
    title="Signal impact", collapsed=true))

# --- Optimal team ---

write(io, html_heading("Your optimal team", 2))

if nrow(chosenteam) > 0
    total_cost = sum(chosenteam.cost)
    total_evg = sum(chosenteam.expected_vg_points)

    write(io, "<p><strong>Total cost:</strong> $(total_cost) / 100 credits | <strong>Expected VG points:</strong> $(round(total_evg, digits=1)) | <strong>Budget remaining:</strong> $(100 - total_cost)</p>\n")

    # Classification breakdown
    if hasproperty(chosenteam, :classraw)
        classes = sort(unique(chosenteam.classraw))
        class_str = join(["$(c): $(count(chosenteam.classraw .== c))" for c in classes], " | ")
        write(io, "<p><strong>Classes:</strong> $(class_str)</p>\n")
    end

    display_cols = intersect([:rider, :team, :classraw, :cost, :expected_vg_points, :selection_frequency, :strength, :uncertainty], propertynames(chosenteam))
    write(io, html_table(sort(chosenteam[:, display_cols], :expected_vg_points, rev=true)))

    # Signal breakdown
    waterfall = format_signal_waterfall(sort(chosenteam, :expected_vg_points, rev=true))
    write(io, html_callout(
        "<p>How each signal shifted the strength estimate for riders in your team.</p>\n" * waterfall;
        title="Signal breakdown", collapsed=true))
else
    write(io, html_callout("No optimal team generated — check configuration and try again."; type="warning"))
end

# --- Full rankings ---

write(io, html_heading("Full prediction rankings", 2))
write(io, "<p>Top 30 riders by expected VG points:</p>\n")

ranking_cols = intersect([:rider, :team, :classraw, :cost, :expected_vg_points, :selection_frequency, :strength, :uncertainty, :chosen], propertynames(predicted))
ranking = sort(predicted, :expected_vg_points, rev=true)
top_n = min(30, nrow(ranking))
write(io, html_table(ranking[1:top_n, ranking_cols]))

waterfall_full = format_signal_waterfall(ranking[1:top_n, :]; max_riders=top_n)
write(io, html_callout(
    "<p>Signal shifts for top-ranked riders.</p>\n" * waterfall_full;
    title="Signal breakdown", collapsed=true))

# --- Alternative picks ---

write(io, html_heading("Alternative picks", 2))

if nrow(chosenteam) > 0
    not_chosen = filter(:chosen => ==(false), predicted)

    if nrow(not_chosen) > 0
        not_chosen[!, :value] = not_chosen.expected_vg_points ./ not_chosen.cost
        has_class = :classraw in propertynames(not_chosen)
        base_cols = has_class ? [:rider, :team, :classraw] : [:rider, :team]

        # Value picks
        write(io, html_heading("Best value not selected", 3))
        write(io, "<p>Riders with the highest expected points per credit, not in the optimal team.</p>\n")
        top_value = sort(not_chosen, :value, rev=true)[1:min(10, nrow(not_chosen)), :]
        write(io, html_table(top_value[:, vcat(base_cols, [:cost, :expected_vg_points, :value])]))

        # High upside
        write(io, html_heading("High upside", 3))
        write(io, "<p>Strong riders with high uncertainty — potential outperformers if conditions suit them.</p>\n")
        not_chosen[!, :upside] = not_chosen.strength .+ not_chosen.uncertainty
        upside = sort(not_chosen, :upside, rev=true)[1:min(5, nrow(not_chosen)), :]
        write(io, html_table(upside[:, vcat(base_cols, [:cost, :expected_vg_points, :strength, :uncertainty])]))

        # Budget options
        write(io, html_heading("Budget options", 3))
        cheap_options = filter(row -> row.cost <= 6, not_chosen)
        if nrow(cheap_options) > 0
            write(io, "<p>Best riders costing 6 credits or less.</p>\n")
            cheap_sorted = sort(cheap_options, :expected_vg_points, rev=true)[1:min(5, nrow(cheap_options)), :]
            write(io, html_table(cheap_sorted[:, vcat(base_cols, [:cost, :expected_vg_points])]))
        else
            write(io, "<p>No riders at cost 6 or below available.</p>\n")
        end
    end
end

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------

body = String(take!(io))
page = html_page(;
    title="Stage race team builder",
    subtitle="$(titlecase(config.name)) $(config.year) — Monte Carlo simulation-based fantasy cycling team optimiser",
    body=body,
)

output_dir = joinpath(@__DIR__, "..", get(get(_cfg, "output", Dict()), "dir", "prediction_docs"))
mkpath(output_dir)
output_path = joinpath(output_dir, "stagerace.html")
write(output_path, page)
@info "Written to $output_path"
