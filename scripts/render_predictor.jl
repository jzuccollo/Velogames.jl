#!/usr/bin/env julia
"""
Render the one-day predictor report as a standalone HTML page.

Usage:
    julia --project scripts/render_predictor.jl [--fresh] [--force]

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

betfair_market_id = _cfg["data_sources"]["betfair_market_id"]
oracle_url = _cfg["data_sources"]["oracle_url"]
qualitative_youtube_url = _cfg["data_sources"]["qualitative_youtube_url"]
qualitative_article_url = _cfg["data_sources"]["qualitative_article_url"]
qualitative_json_file = _cfg["data_sources"]["qualitative_json_file"]

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

n_resamples = _cfg["optimisation"]["n_resamples"]
history_years = _cfg["optimisation"]["history_years"]
domestique_discount = _cfg["optimisation"]["domestique_discount"]
risk_aversion = _cfg["optimisation"]["risk_aversion"]
max_per_team = _cfg["optimisation"]["max_per_team"]
excluded_riders = String[x for x in _cfg["optimisation"]["excluded_riders"]]
simulation_df = let v = _cfg["optimisation"]["simulation_df"]
    v isa Integer ? v : nothing
end

breakaway_dir = joinpath(DEFAULT_ARCHIVE_DIR, "pcs_breakaways")
race_cache = CacheConfig(joinpath(homedir(), ".velogames_cache"), FRESH ? 0 : 6)

# ---------------------------------------------------------------------------
# Run prediction
# ---------------------------------------------------------------------------

config = setup_race(race_name, race_year; cache_config=race_cache)
scoring = get_scoring(config.category > 0 ? config.category : 2)

# --- Qualitative intelligence ---
# Fetch from configured URLs if present; fall back to archive only when no sources are configured
has_qual_sources = !isempty(qualitative_youtube_url) || !isempty(qualitative_article_url) || !isempty(qualitative_json_file)
qual_sources = DataFrame[]

if has_qual_sources
    _qual_riders = Ref{Vector{String}}()
    function _get_qual_riders()
        if !isassigned(_qual_riders)
            _qual_riders[] = String.(suppress_output() do
                getvgriders(config.current_url; cache_config=race_cache)
            end.rider)
        end
        return _qual_riders[]
    end

    if !isempty(qualitative_youtube_url)
        try
            df = get_qualitative_auto(qualitative_youtube_url, _get_qual_riders(), race_name, string(Dates.today()))
            @info "YouTube qualitative: $(nrow(df)) rider assessments"
            push!(qual_sources, df)
        catch e
            @warn "Failed to extract qualitative intelligence from YouTube: $e"
        end
    end

    if !isempty(qualitative_article_url)
        try
            df = get_qualitative_article(qualitative_article_url, _get_qual_riders(), race_name, string(Dates.today()))
            @info "Article qualitative: $(nrow(df)) rider assessments"
            push!(qual_sources, df)
        catch e
            @warn "Failed to extract qualitative intelligence from article: $e"
        end
    end

    if isempty(qual_sources) && !isempty(qualitative_json_file)
        try
            push!(qual_sources, load_qualitative_file(qualitative_json_file))
            @info "Qualitative intelligence: $(nrow(last(qual_sources))) rider assessments loaded from file"
        catch e
            @warn "Failed to load qualitative file: $e"
        end
    end
end

qualitative_df = if !isempty(qual_sources)
    combined = reduce(vcat, qual_sources)
    combine(groupby(combined, :riderkey),
        :adjustment => mean => :adjustment,
        :confidence => mean => :confidence,
        :reasoning => first => :reasoning,
    )
elseif !has_qual_sources
    archived = load_race_snapshot("qualitative", config.pcs_slug, race_year)
    if archived !== nothing
        @info "Qualitative intelligence: loaded $(nrow(archived)) rider assessments from archive"
    end
    archived
else
    nothing
end

predicted, chosenteam, top_teams, sim_vg_points = solve_oneday(config;
    racehash=racehash,
    history_years=history_years,
    betfair_market_id=betfair_market_id,
    oracle_url=oracle_url,
    n_resamples=n_resamples,
    excluded_riders=excluded_riders,
    qualitative_df=qualitative_df,
    odds_df=odds_df,
    domestique_discount=domestique_discount,
    risk_aversion=risk_aversion,
    max_per_team=max_per_team,
    breakaway_dir=breakaway_dir,
    simulation_df=simulation_df,
    cache_config=race_cache,
)

# Note: predictions are archived by solve_oneday() via _archive_predictions().
# The archive is protected: existing archives are not overwritten unless
# the VELOGAMES_FORCE_ARCHIVE environment variable is set.

if nrow(predicted) == 0
    error("No riders found — check race name, year, and startlist hash filter.")
end

# ---------------------------------------------------------------------------
# Build page content
# ---------------------------------------------------------------------------

io = IOBuffer()

# --- Race summary ---

n_total = nrow(predicted)
write(io, "<p><strong>$(titlecase(config.name)) $(config.year)</strong> — Category $(config.category), $(n_total) riders, $(n_resamples) resamples</p>\n")

# --- Data sources ---

n_pcs = count(predicted.has_pcs)
n_history = count(predicted.has_race_history)
n_odds = count(predicted.has_odds)
n_oracle = count(predicted.has_oracle)
n_vg_hist = count(predicted.has_vg_history)
n_qualitative = count(predicted.has_qualitative)
n_form = count(predicted.has_form)
n_seasons = count(predicted.has_seasons)
pct(n) = round(Int, 100 * n / n_total)

similar_races = get(SIMILAR_RACES, config.pcs_slug, String[])
similar_str = isempty(similar_races) ? "None configured" : join(similar_races, ", ")

sources_df = DataFrame(
    Source=[
        "PCS season points", "VG season points", "PCS form (6 weeks)", "Career trajectory",
        "PCS race history ($(history_years) yrs)", "Similar races", "VG race history",
        "Cycling Oracle", "Qualitative intel", "Odds",
    ],
    Coverage=[
        "$(n_pcs)/$(n_total) ($(pct(n_pcs))%)", "$(n_total)/$(n_total) (100%)",
        "$(n_form)/$(n_total) ($(pct(n_form))%)", "$(n_seasons)/$(n_total) ($(pct(n_seasons))%)",
        "$(n_history)/$(n_total) ($(pct(n_history))%)", similar_str,
        "$(n_vg_hist)/$(n_total) ($(pct(n_vg_hist))%)",
        "$(n_oracle)/$(n_total) ($(pct(n_oracle))%)",
        "$(n_qualitative)/$(n_total) ($(pct(n_qualitative))%)",
        "$(n_odds)/$(n_total) ($(pct(n_odds))%)",
    ],
)

sources_html = html_table(sources_df)
budget = precision_budget(DEFAULT_BAYESIAN_CONFIG; n_history_years=history_years)
sources_html *= "<p>Precision budget:</p>\n" * html_table(budget)
write(io, html_callout(sources_html; title="Data sources", collapsed=false))

# --- Signal impact ---

rms(v) = sqrt(mean(v .^ 2))
signal_names = ["PCS seasons", "VG season points", "PCS form", "PCS race history", "VG race history", "Cycling Oracle", "Qualitative intel", "Betfair odds"]
shift_cols = [:shift_pcs, :shift_vg, :shift_form, :shift_history, :shift_vg_history, :shift_oracle, :shift_qualitative, :shift_odds]
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

# --- Optimal team ---

write(io, html_heading("Your optimal team", 2))

if nrow(chosenteam) > 0
    total_cost = sum(chosenteam.cost)
    total_evg = sum(chosenteam.expected_vg_points)

    write(io, "<p><strong>Total cost:</strong> $(total_cost) / 100 credits | <strong>Expected VG points:</strong> $(round(total_evg, digits=1)) | <strong>Budget remaining:</strong> $(100 - total_cost)</p>\n")

    display_cols = intersect([:rider, :team, :cost, :expected_vg_points, :selection_frequency, :strength, :uncertainty], propertynames(chosenteam))
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

ranking_cols = intersect([:rider, :team, :cost, :expected_vg_points, :selection_frequency, :strength, :uncertainty, :chosen], propertynames(predicted))
ranking = sort(predicted, :expected_vg_points, rev=true)
top_n = min(30, nrow(ranking))
write(io, html_table(ranking[1:top_n, ranking_cols]))

# Signal breakdown for top ranked
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

        # Value picks
        write(io, html_heading("Best value not selected", 3))
        write(io, "<p>Riders with the highest expected points per credit, not in the optimal team.</p>\n")
        top_value = sort(not_chosen, :value, rev=true)[1:min(10, nrow(not_chosen)), :]
        write(io, html_table(top_value[:, [:rider, :team, :cost, :expected_vg_points, :value]]))

        # High upside
        write(io, html_heading("High upside", 3))
        write(io, "<p>Strong riders with high uncertainty — potential outperformers if conditions suit them.</p>\n")
        not_chosen[!, :upside] = not_chosen.strength .+ not_chosen.uncertainty
        upside = sort(not_chosen, :upside, rev=true)[1:min(5, nrow(not_chosen)), :]
        write(io, html_table(upside[:, [:rider, :team, :cost, :expected_vg_points, :strength, :uncertainty]]))

        # Budget options
        write(io, html_heading("Budget options", 3))
        cheap_options = filter(row -> row.cost <= 6, not_chosen)
        if nrow(cheap_options) > 0
            write(io, "<p>Best riders costing 6 credits or less.</p>\n")
            cheap_sorted = sort(cheap_options, :expected_vg_points, rev=true)[1:min(5, nrow(cheap_options)), :]
            write(io, html_table(cheap_sorted[:, [:rider, :team, :cost, :expected_vg_points]]))
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
    title="Sixes Classics team builder",
    subtitle="$(titlecase(config.name)) $(config.year) — Monte Carlo simulation-based fantasy cycling team optimiser",
    body=body,
)

output_dir = joinpath(@__DIR__, "..", get(get(_cfg, "output", Dict()), "dir", "prediction_docs"))
mkpath(output_dir)
output_path = joinpath(output_dir, "predictor.html")
write(output_path, page)
@info "Written to $output_path"
