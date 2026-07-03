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
points_oracle_url = get(_cfg["data_sources"], "points_oracle_url", "")
kom_oracle_url = get(_cfg["data_sources"], "kom_oracle_url", "")

odds_df = if get(_cfg["data_sources"], "use_oddschecker", false)
    try
        parse_oddschecker_odds(read(joinpath(@__DIR__, "..", "oddschecker_paste.txt"), String))
    catch
        @warn "use_oddschecker=true but oddschecker_paste.txt not found or unparseable"
        nothing
    end
else
    nothing
end

# --- Secondary bookmaker markets (stage races): Points jersey, KOM, stage-win ---
function _try_parse_paste(filename)
    isempty(filename) && return nothing
    path = joinpath(@__DIR__, "..", filename)
    isfile(path) || return nothing
    try
        return parse_oddschecker_odds(read(path, String))
    catch e
        @warn "Failed to parse $filename: $e"
        return nothing
    end
end
points_odds_df = _try_parse_paste(get(_cfg["data_sources"], "points_odds_paste_file", ""))
kom_odds_df = _try_parse_paste(get(_cfg["data_sources"], "kom_odds_paste_file", ""))
stagewin_odds_df = _try_parse_paste(get(_cfg["data_sources"], "stagewin_odds_paste_file", ""))

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
        # Stage strength is now a continuous blend across (flat, hilly, mountain)
        # weighted by PCS ProfileScore + summit-finish flag (see
        # `stage_dimension_weights` in simulation.jl). Discrete reclassification
        # is no longer needed.
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

result = solve_stage(config;
    stages=stages,
    racehash=racehash,
    history_years=history_years,
    oracle_url=oracle_url,
    points_oracle_url=points_oracle_url,
    kom_oracle_url=kom_oracle_url,
    n_resamples=n_resamples,
    excluded_riders=excluded_riders,
    domestique_discount=domestique_discount,
    risk_aversion=risk_aversion,
    max_per_team=max_per_team,
    simulation_df=simulation_df,
    cross_stage_alpha=cross_stage_alpha,
    stage_scoring=stage_scoring,
    odds_df=odds_df,
    points_odds_df=points_odds_df,
    kom_odds_df=kom_odds_df,
    stagewin_odds_df=stagewin_odds_df)

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
    write(io, "<p>Cross-stage correlation α=$(cross_stage_alpha)</p>\n")

    if diagnostics !== nothing
        stage_df = format_stage_podium_picks(diagnostics, stages, predicted)
        stage_col_order = [
            "Stage", "Type", "Distance", "ProfileScore", "Vert", "Summit",
            "HC", "Cat1", "Likely 1st", "Likely 2nd", "Likely 3rd",
        ]
        write(io, html_callout(
            "<p>Most likely podium finishers per stage, alongside basic stage details. Probabilities in parentheses are the share of $(diagnostics.n_sims) simulations in which the named rider finished in that exact position. Each column names a distinct rider (the modal occupant of that position, excluding riders already shown to its left).</p>\n" *
            "<p><em>Caveat:</em> the simulation does not model breakaway wins, which take a large share of real hilly and mountain stages. Treat these as the favourites' odds <em>conditional on the stage being contested by the front group</em> — actual single-stage win rates are lower and more spread out.</p>\n" *
            html_table(stage_df[:, stage_col_order]);
            title="Stage details and podium picks", collapsed=false))
    end
end

# --- Data sources ---

n_pcs = count(predicted.has_pcs)
n_history = count(predicted.has_race_history)
n_odds = count(predicted.has_odds)
n_oracle = count(predicted.has_oracle)
n_points_oracle = :has_points_oracle in propertynames(predicted) ? count(predicted.has_points_oracle) : 0
n_kom_oracle = :has_kom_oracle in propertynames(predicted) ? count(predicted.has_kom_oracle) : 0
n_vg_hist = count(predicted.has_vg_history)
pct(n) = round(Int, 100 * n / n_total)

similar_races = get(SIMILAR_RACES, config.pcs_slug, String[])
similar_str = isempty(similar_races) ? "None configured" : join(similar_races, ", ")

sources_df = DataFrame(
    Source=[
        "PCS specialty (per-source)", "VG season points",
        "PCS race history ($(history_years) yrs)", "Similar races", "VG race history",
        "Oracle GC", "Oracle Points", "Oracle KOM", "Odds",
    ],
    Coverage=[
        "$(n_pcs)/$(n_total) ($(pct(n_pcs))%)", "$(n_total)/$(n_total) (100%)",
        "$(n_history)/$(n_total) ($(pct(n_history))%)", similar_str,
        "$(n_vg_hist)/$(n_total) ($(pct(n_vg_hist))%)",
        "$(n_oracle)/$(n_total) ($(pct(n_oracle))%)",
        "$(n_points_oracle)/$(n_total) ($(pct(n_points_oracle))%)",
        "$(n_kom_oracle)/$(n_total) ($(pct(n_kom_oracle))%)",
        "$(n_odds)/$(n_total) ($(pct(n_odds))%)",
    ],
)

sources_html = html_table(sources_df)
sources_html *= "<p>PCS specialty (sprint, oneday, climber, tt, gc) is routed per-source to the strength dimensions it informs. GC-flavoured market signals (Oracle GC + odds) only update the <code>:gc</code> dimension; points-jersey oracle updates <code>:flat</code>/<code>:hilly</code>; KOM oracle updates <code>:mountain</code>.</p>\n"
write(io, html_callout(sources_html; title="Data sources", collapsed=false))

# --- Signal impact (per-dimension) ---

write(io, html_callout(
    "<p>Per-dimension RMS shift in posterior mean from each signal. Note GC-flavoured floors (Oracle GC, Odds) only touch the GC column — sprinters absent from those markets are no longer penalised on their flat/hilly dimensions.</p>\n" *
    format_signal_impact_per_dim(predicted);
    title="Signal impact (per dimension)", collapsed=true))

# --- Classification predictions (GC, Points, KOM, Team) ---

if diagnostics !== nothing
    write(io, html_heading("Final classification predictions", 2))
    write(io, "<p>Top riders by probability of finishing in each classification's prize positions, summarised across $(diagnostics.n_sims) simulated grand tours. The win column shows the share of simulations in which they finished 1st; the top-N column shows the share they finished anywhere in the prize positions.</p>\n")

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
    write(io, "<p>Mean rider strength on each dimension, broken down by classification. Higher = predicted to finish better on that stage type.</p>\n")

    class_col = :classraw in propertynames(predicted) ? :classraw :
                :class in propertynames(predicted) ? :class : nothing

    if class_col !== nothing
        classes = sort(unique(lowercase.(string.(predicted[!, class_col]))))
        type_cols = [:strength_flat, :strength_hilly, :strength_mountain, :strength_itt, :strength_gc, :strength_kom]
        type_labels = ["Flat", "Hilly", "Mountain", "ITT", "GC", "KOM"]

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
        col_order = intersect(["Class", "N", "Flat", "Hilly", "Mountain", "ITT", "GC", "KOM"], names(summary_df))
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

    # Include per-dimension strengths in team table
    base_cols = [:rider, :team, :classraw, :cost, :expected_vg_points, :selection_frequency, :strength_gc, :uncertainty_gc]
    dim_cols = [:strength_flat, :strength_hilly, :strength_mountain, :strength_itt, :strength_kom]
    all_display_cols = vcat(base_cols, dim_cols)
    display_cols = intersect(all_display_cols, propertynames(chosenteam))
    write(io, html_table(sort(chosenteam[:, display_cols], :expected_vg_points, rev=true)))

    # Signal breakdown — order-invariant info-share percentages (signal precision /
    # total observed precision per rider). Sums to 100% across signals per rider.
    waterfall = format_signal_waterfall(sort(chosenteam, :expected_vg_points, rev=true))
    write(io, html_callout(
        "<p>Each cell shows the share of total observed precision contributed by that signal — order-invariant, summing to 100% across signals per rider. Market signals are split by jersey (GC / points / KOM / stage-win), so a rider whose <em>Odds KOM</em> cell shows 70% is favoured mainly for the mountains classification, not the overall.</p>\n" * waterfall;
        title="Signal breakdown (info share)", collapsed=true))

    # Per-dimension info-share heatmap — diagnoses which signals drove which
    # dimension for each chosen rider (useful when ranking depends on multi-
    # dim simulation, not just the scalar :gc strength).
    info_share_dim = format_info_share_per_dim(sort(chosenteam, :expected_vg_points, rev=true))
    write(io, html_callout(
        "<p>Per-dimension info share for your team. Each signal block has 6 columns (F=flat, H=hilly, M=mountain, I=ITT, G=gc, K=kom); cells show the percent of total observed precision on that dimension contributed by that signal. Order-invariant.</p>\n" * info_share_dim;
        title="Per-dimension info share (chosen team)", collapsed=true))
else
    write(io, html_callout("No optimal team generated — check configuration and try again."; type="warning"))
end

# --- Full rankings ---

write(io, html_heading("Full prediction rankings", 2))
write(io, "<p>Top 30 riders by expected VG points:</p>\n")

base_ranking_cols = [:rider, :team, :classraw, :cost, :expected_vg_points, :selection_frequency, :strength_gc, :uncertainty_gc, :chosen]
dim_ranking_cols = [:strength_flat, :strength_hilly, :strength_mountain, :strength_itt, :strength_kom]
all_ranking_cols = vcat(base_ranking_cols, dim_ranking_cols)
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
