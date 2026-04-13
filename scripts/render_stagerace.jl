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

using Velogames, DataFrames, Statistics, Dates, TOML

const FRESH = "--fresh" in ARGS
"--force" in ARGS && (ENV["VELOGAMES_FORCE_ARCHIVE"] = "1")

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

cross_stage_alpha = get(_cfg["optimisation"], "cross_stage_alpha", 0.7)
modifier_scale = get(_cfg["optimisation"], "modifier_scale", 0.5)
pcs_stage_scrape = get(_cfg["optimisation"], "pcs_stage_scrape", true)

race_cache = CacheConfig(joinpath(homedir(), ".velogames_cache"), FRESH ? 0 : 6)

# ---------------------------------------------------------------------------
# Stage profiles
# ---------------------------------------------------------------------------

config = setup_race(race_name, race_year; cache_config=race_cache)

stages = StageProfile[]
if pcs_stage_scrape && !isempty(config.pcs_slug)
    @info "Scraping stage profiles from PCS..."
    stages = getpcs_stage_profiles(config.pcs_slug, race_year;
        cache_config=race_cache, force_refresh=FRESH)
    if isempty(stages)
        @warn "PCS stage scraping returned no stages — falling back to aggregate approach"
    else
        @info "Got $(length(stages)) stage profiles from PCS"
    end
end

using_per_stage = !isempty(stages)

# Scrape race-specific scoring from VG
stage_scoring = try
    getvg_scoring(config.slug, config.year; pcs_slug=config.pcs_slug)
catch e
    @warn "Failed to scrape VG scoring, using grand tour defaults: $e"
    nothing
end

# ---------------------------------------------------------------------------
# Run prediction
# ---------------------------------------------------------------------------

predicted, chosenteam, top_teams, sim_vg_points = solve_stage(config;
    stages=stages,
    racehash=racehash,
    history_years=history_years,
    oracle_url=oracle_url,
    n_resamples=n_resamples,
    excluded_riders=excluded_riders,
    domestique_discount=domestique_discount,
    risk_aversion=risk_aversion,
    max_per_team=max_per_team,
    simulation_df=simulation_df,
    cross_stage_alpha=cross_stage_alpha,
    modifier_scale=modifier_scale,
    stage_scoring=stage_scoring)

if nrow(predicted) == 0
    error("No riders found — check race name, year, and startlist hash filter.")
end

# ---------------------------------------------------------------------------
# Build page content
# ---------------------------------------------------------------------------

io = IOBuffer()

n_total = nrow(predicted)
approach_str = using_per_stage ? "Per-stage simulation ($(length(stages)) stages)" : "Aggregate GC model"
write(io, "<p><strong>$(titlecase(config.name)) $(config.year)</strong> — $approach_str, $(n_total) riders, $(n_resamples) resamples</p>\n")

# --- Stage profile summary ---

if using_per_stage
    stage_types = [s.stage_type for s in stages]
    n_flat = count(==(:flat), stage_types)
    n_hilly = count(==(:hilly), stage_types)
    n_mountain = count(==(:mountain), stage_types)
    n_itt = count(==(:itt), stage_types)
    n_ttt = count(==(:ttt), stage_types)

    write(io, html_heading("Stage profile", 2))
    write(io, "<p><strong>$(length(stages)) stages:</strong> $n_flat flat, $n_hilly hilly, $n_mountain mountain, $n_itt ITT, $n_ttt TTT</p>\n")
    write(io, "<p>Cross-stage correlation α=$(cross_stage_alpha), modifier scale=$(modifier_scale)</p>\n")

    stage_df = DataFrame(
        Stage=[s.stage_number for s in stages],
        Type=[String(s.stage_type) for s in stages],
        Distance=["$(round(s.distance_km, digits=0)) km" for s in stages],
        ProfileScore=[s.profile_score for s in stages],
        Vert=["$(s.vertical_meters) m" for s in stages],
        Summit=[s.is_summit_finish ? "Yes" : "" for s in stages],
        HC=[s.n_hc_climbs > 0 ? string(s.n_hc_climbs) : "" for s in stages],
        Cat1=[s.n_cat1_climbs > 0 ? string(s.n_cat1_climbs) : "" for s in stages],
    )
    write(io, html_callout(html_table(stage_df); title="Stage details", collapsed=true))
end

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
    Source=[
        "PCS season points (class-blended)", "VG season points",
        "PCS race history ($(history_years) yrs)", "Similar races", "VG race history",
        "Cycling Oracle", "Odds",
    ],
    Coverage=[
        "$(n_pcs)/$(n_total) ($(pct(n_pcs))%)", "$(n_total)/$(n_total) (100%)",
        "$(n_history)/$(n_total) ($(pct(n_history))%)", similar_str,
        "$(n_vg_hist)/$(n_total) ($(pct(n_vg_hist))%)",
        "$(n_oracle)/$(n_total) ($(pct(n_oracle))%)",
        "$(n_odds)/$(n_total) ($(pct(n_odds))%)",
    ],
)

sources_html = html_table(sources_df)
sources_html *= "<p>PCS season scores are blended by rider classification: all-rounders weight GC + TT + climbing, climbers weight climbing heavily, sprinters weight sprint + one-day.</p>\n"
write(io, html_callout(sources_html; title="Data sources", collapsed=false))

# --- Signal impact ---

rms(v) = sqrt(mean(v .^ 2))
signal_names = ["PCS seasons", "VG season points", "PCS form", "PCS race history", "VG race history", "Cycling Oracle", "Odds"]
shift_cols = [:shift_pcs, :shift_vg, :shift_form, :shift_history, :shift_vg_history, :shift_oracle, :shift_odds]
affected_counts = [count(!=(0.0), predicted[!, c]) for c in shift_cols]
rms_shifts = [rms(predicted[!, c]) for c in shift_cols]

impact_df = DataFrame(
    Signal=signal_names,
    Riders_affected=affected_counts,
    RMS_shift=round.(rms_shifts, digits=3),
)
write(io, html_callout(
    "<p>How much each source shifted rider strength estimates from the uninformative prior.</p>\n" * html_table(impact_df);
    title="Signal impact", collapsed=true))

# --- Stage-type strength distributions ---

if using_per_stage && :stage_strength_flat in propertynames(predicted)
    write(io, html_heading("Stage-type strength profile", 2))
    write(io, "<p>How rider strengths vary by stage type. Higher = predicted to finish better on that stage type.</p>\n")

    has_class = :classraw in propertynames(predicted)
    if has_class
        class_col = :classraw
    elseif :class in propertynames(predicted)
        class_col = :class
    else
        class_col = nothing
    end

    # Build a summary table: mean strength per class per stage type
    if class_col !== nothing
        classes = sort(unique(lowercase.(string.(predicted[!, class_col]))))
        type_cols = [:stage_strength_flat, :stage_strength_hilly, :stage_strength_mountain, :stage_strength_itt]
        type_labels = ["Flat", "Hilly", "Mountain", "ITT"]

        summary_rows = []
        for cls in classes
            mask = lowercase.(string.(predicted[!, class_col])) .== cls
            row = Dict("Class" => titlecase(cls), "N" => count(mask))
            for (col, label) in zip(type_cols, type_labels)
                row[label] = round(mean(predicted[mask, col]), digits=2)
            end
            push!(summary_rows, row)
        end
        summary_df = DataFrame(summary_rows)
        # Reorder columns
        col_order = intersect(["Class", "N", "Flat", "Hilly", "Mountain", "ITT"], names(summary_df))
        write(io, html_table(summary_df[:, col_order]))
    end
end

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

    # Include stage-type strengths in team table if available
    base_cols = [:rider, :team, :classraw, :cost, :expected_vg_points, :selection_frequency, :strength, :uncertainty]
    stage_cols = [:stage_strength_flat, :stage_strength_hilly, :stage_strength_mountain, :stage_strength_itt]
    all_display_cols = using_per_stage ? vcat(base_cols, stage_cols) : base_cols
    display_cols = intersect(all_display_cols, propertynames(chosenteam))
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

base_ranking_cols = [:rider, :team, :classraw, :cost, :expected_vg_points, :selection_frequency, :strength, :uncertainty, :chosen]
stage_ranking_cols = [:stage_strength_flat, :stage_strength_mountain, :stage_strength_itt]
all_ranking_cols = using_per_stage ? vcat(base_ranking_cols, stage_ranking_cols) : base_ranking_cols
ranking_cols = intersect(all_ranking_cols, propertynames(predicted))
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
    subtitle="$(titlecase(config.name)) $(config.year) — $approach_str",
    body=body,
)

output_dir = joinpath(@__DIR__, "..", get(get(_cfg, "output", Dict()), "dir", "prediction_docs"))
mkpath(output_dir)
output_path = joinpath(output_dir, "stagerace.html")
write(output_path, page)
@info "Written to $output_path"
