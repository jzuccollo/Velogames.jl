#!/usr/bin/env julia
"""
Render the backtesting and calibration report as a standalone HTML page.

Usage:
    julia --project scripts/render_backtesting.jl [--fresh]

Options:
    --fresh   Bypass cache, fetch all data fresh from the web
"""

using Velogames, DataFrames, Statistics, Dates, Random

const FRESH = "--fresh" in ARGS

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

backtest_years = [2023, 2024, 2025]
n_sims = 1000
history_years = 5
bt_cache = CacheConfig(joinpath(homedir(), ".velogames_cache"), FRESH ? 0 : 168)

# ---------------------------------------------------------------------------
# Build page content
# ---------------------------------------------------------------------------

io = IOBuffer()

# --- Overview ---

write(io, html_heading("Overview", 2))
write(io, """<p>This report validates the Bayesian strength estimation model at three levels:</p>
<ol>
<li><strong>Prior predictive checks</strong> (no data needed) — simulate from the model's generative process and check whether implied outcomes match domain knowledge.</li>
<li><strong>Historical backtest</strong> (PCS results 2023–2025) — a sanity check that predictions beat random and that rank correlations look reasonable.</li>
<li><strong>Prospective evaluation</strong> (archived predictions vs results) — the most trustworthy evaluation, comparing pre-race predictions against actual outcomes.</li>
</ol>
<p>The model has three tuneable precision scale factors (<code>market_precision_scale</code>, <code>history_precision_scale</code>, <code>ability_precision_scale</code>) plus two decay rates.</p>
""")

# --- Precision budget ---

write(io, html_heading("Precision budget", 2))
write(io, "<p>How much weight does each signal carry in the posterior?</p>\n")
budget = precision_budget(DEFAULT_BAYESIAN_CONFIG; n_history_years=history_years)
write(io, html_table(budget))

# --- Prior predictive checks ---

write(io, html_heading("Prior predictive checks", 2))
write(io, "<p>Simulating from the generative process and checking whether implied outcomes match cycling domain knowledge.</p>\n")

facts_df = suppress_output() do
    check_stylised_facts(DEFAULT_BAYESIAN_CONFIG;
        n_races=200, n_riders=150, rng=MersenneTwister(42))
end

all_pass = all(facts_df.pass)
status = all_pass ? "All checks pass." : "Some checks <strong>failed</strong> — review the scale factors."

write(io, html_heading("Stylised facts check", 3))
write(io, "<p>$status</p>\n")
write(io, html_table(facts_df))

# --- Sensitivity sweeps ---

write(io, html_heading("Sensitivity sweeps", 3))
write(io, "<p>How sensitive are the model's predictions to each scale factor?</p>\n")

for param in [:market_precision_scale, :history_precision_scale, :ability_precision_scale]
    sweep_df = suppress_output() do
        sensitivity_sweep(param, [0.01, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 15.0, 25.0];
            rng=MersenneTwister(42))
    end
    write(io, html_heading("<code>$param</code>", 4; id=replace(string(param), "_" => "-")))
    write(io, html_table(sweep_df))
end

# --- SBC ---

write(io, html_heading("Simulation-based calibration", 3))
write(io, "<p>SBC checks whether the Bayesian inference pipeline correctly recovers true parameters from synthetic data.</p>\n")

sbc = suppress_output() do
    simulation_based_calibration(DEFAULT_BAYESIAN_CONFIG;
        n_sims=500, rng=MersenneTwister(42))
end

sbc_df = DataFrame(
    Diagnostic = ["Mean CDF rank", "Chi-squared p-value", "Uniform?"],
    Value = [round(sbc.mean_rank, digits=3), round(sbc.chi_squared_p, digits=3),
             sbc.chi_squared_p > 0.05 ? "Yes" : "No"],
    Expected = ["0.5", "> 0.05", "Yes"],
)
write(io, html_table(sbc_df))

# --- Historical backtest ---

write(io, html_heading("Historical backtest", 2))

races = build_race_catalogue(backtest_years; history_years=history_years)

cat_counts = combine(
    groupby(
        DataFrame(year=[r.year for r in races], category=[r.category for r in races]),
        :year
    ),
    nrow => :n_races
)

write(io, "<p>Backtesting across <strong>$(length(races)) races</strong> from $(join(string.(backtest_years), ", ")).</p>\n")
write(io, html_table(cat_counts))

@info "Prefetching race data..."
race_data = prefetch_all_races(races; cache_config=bt_cache)

# --- Data availability ---

write(io, html_heading("Data availability", 3))

n_total = length(races)
n_fetched = length(race_data)
n_with_odds = count(d -> d.odds_df !== nothing, values(race_data))
n_with_oracle = count(d -> d.oracle_df !== nothing, values(race_data))
n_with_history = count(d -> d.race_history_df !== nothing, values(race_data))
n_with_vg_history = count(d -> d.vg_history_df !== nothing, values(race_data))
n_with_form = count(d -> d.form_df !== nothing, values(race_data))
n_with_seasons = count(d -> d.seasons_df !== nothing, values(race_data))

avail_df = DataFrame(
    Signal = [
        "PCS results (ground truth)", "PCS specialty ratings", "VG season points (cumulative)",
        "PCS race history", "VG race history", "Archived PCS form",
        "Archived PCS seasons (trajectory)", "Archived Betfair odds", "Archived Cycling Oracle",
    ],
    Races = [
        "$n_fetched / $n_total", "$n_fetched / $n_fetched", "$n_fetched / $n_fetched",
        "$n_with_history / $n_fetched", "$n_with_vg_history / $n_fetched", "$n_with_form / $n_fetched",
        "$n_with_seasons / $n_fetched", "$n_with_odds / $n_fetched", "$n_with_oracle / $n_fetched",
    ],
    Coverage = [
        "$(round(100 * n_fetched / n_total, digits=0))%", "100%", "100%",
        "$(round(100 * n_with_history / max(n_fetched, 1), digits=0))%",
        "$(round(100 * n_with_vg_history / max(n_fetched, 1), digits=0))%",
        "$(round(100 * n_with_form / max(n_fetched, 1), digits=0))%",
        "$(round(100 * n_with_seasons / max(n_fetched, 1), digits=0))%",
        "$(round(100 * n_with_odds / max(n_fetched, 1), digits=0))%",
        "$(round(100 * n_with_oracle / max(n_fetched, 1), digits=0))%",
    ],
)
write(io, html_table(avail_df))

if n_with_odds > 0 || n_with_oracle > 0
    write(io, "<p>Races with archived odds/oracle data:</p>\n")
    archive_rows = NamedTuple{(:race, :year, :odds, :oracle), Tuple{String,Int,String,String}}[]
    for (race, data) in sort(collect(race_data), by=p -> (p.first.year, p.first.name))
        has_odds = data.odds_df !== nothing
        has_oracle = data.oracle_df !== nothing
        if has_odds || has_oracle
            push!(archive_rows, (
                race=race.name, year=race.year,
                odds=has_odds ? "$(nrow(data.odds_df)) riders" : "—",
                oracle=has_oracle ? "$(nrow(data.oracle_df)) riders" : "—",
            ))
        end
    end
    !isempty(archive_rows) && write(io, html_table(DataFrame(archive_rows)))
else
    write(io, html_callout(
        "No archived odds or oracle data found. Run <code>solve_oneday</code> with <code>betfair_market_id</code> or <code>oracle_url</code> for upcoming races to start building the archive.";
        type="warning"))
end

# --- Baseline evaluation ---

write(io, html_heading("Baseline evaluation", 3))
write(io, "<p>Running the full prediction pipeline on all historical races and comparing to actual PCS finishing positions.</p>\n")

baseline_signals = [:pcs, :vg_season, :race_history, :vg_history, :form, :trajectory]

@info "Running backtest..."
results = backtest_season(races;
    race_data=race_data,
    signals=baseline_signals,
    n_sims=n_sims,
    store_rider_details=true,
)

summary_df = summarise_backtest(results)

write(io, html_heading("Overall metrics", 4))
agg = filter(:race => r -> startswith(r, "—"), summary_df)
write(io, html_table(agg[:, [:race, :n_riders, :spearman_rho, :top5_overlap, :top10_overlap, :mean_abs_rank_error, :points_captured_ratio]]))

# --- Calibration ---

write(io, html_heading("Calibration", 3))
write(io, "<p>If the model's uncertainty estimates are well-calibrated, z-scores should be approximately standard normal.</p>\n")

all_z = vcat([r.calibration_z_scores for r in results]...)

if !isempty(all_z)
    z_mean = round(mean(all_z), digits=3)
    z_std = round(std(all_z), digits=3)
    cov1 = round(count(z -> abs(z) <= 1.0, all_z) / length(all_z), digits=3)
    cov2 = round(count(z -> abs(z) <= 2.0, all_z) / length(all_z), digits=3)

    cal_df = DataFrame(
        Statistic = ["Mean", "Std", "1σ coverage", "2σ coverage", "Total rider-observations"],
        Observed = [z_mean, z_std, cov1, cov2, length(all_z)],
        Expected = ["0.0", "1.0", "0.683", "0.954", "—"],
    )
    write(io, html_table(cal_df))
end

# --- By strength tier ---

write(io, html_heading("By strength tier", 4))
write(io, "<p>Splitting riders into strength tiers reveals whether calibration problems are concentrated among favourites, mid-pack riders, or outsiders.</p>\n")

all_strengths = vcat([r.calibration_strengths for r in results]...)

if !isempty(all_z) && !isempty(all_strengths) && length(all_z) == length(all_strengths)
    q25_s = quantile(all_strengths, 0.25)
    q75_s = quantile(all_strengths, 0.75)

    tiers = [
        ("Bottom 25% (outsiders)", all_strengths .<= q25_s),
        ("Middle 50%", (all_strengths .> q25_s) .& (all_strengths .< q75_s)),
        ("Top 25% (favourites)", all_strengths .>= q75_s),
    ]

    tier_rows = NamedTuple{(:Tier, :Mean_z, :Std_z, :Coverage_1σ, :n), Tuple{String,Float64,Float64,Float64,Int}}[]
    for (label, mask) in tiers
        tier_z = all_z[mask]
        length(tier_z) < 10 && continue
        push!(tier_rows, (
            Tier=label,
            Mean_z=round(mean(tier_z), digits=3),
            Std_z=round(std(tier_z), digits=3),
            Coverage_1σ=round(count(z -> abs(z) <= 1.0, tier_z) / length(tier_z), digits=3),
            n=length(tier_z),
        ))
    end
    !isempty(tier_rows) && write(io, html_table(DataFrame(tier_rows)))
end

# --- Signal contribution ---

write(io, html_heading("Signal contribution", 3))
write(io, "<p>Mean |shift| per signal shows how much each data source moves predicted strength away from the uninformative prior.</p>\n")

shift_keys = [:shift_pcs, :shift_vg, :shift_form, :shift_trajectory, :shift_history, :shift_vg_history, :shift_oracle, :shift_odds]
shift_labels = Dict(
    :shift_pcs => "PCS specialty", :shift_vg => "VG season points",
    :shift_form => "PCS form", :shift_trajectory => "Trajectory",
    :shift_history => "PCS race history", :shift_vg_history => "VG race history",
    :shift_oracle => "Cycling Oracle", :shift_odds => "Betfair odds",
)

agg_shifts = Dict{Symbol,Vector{Float64}}()
for r in results
    for (k, v) in r.mean_signal_shifts
        push!(get!(agg_shifts, k, Float64[]), v)
    end
end

if !isempty(agg_shifts)
    sig_rows = NamedTuple{(:Signal, :Mean_shift, :Std, :Races), Tuple{String,Float64,Float64,Int}}[]
    for k in shift_keys
        haskey(agg_shifts, k) || continue
        vals = agg_shifts[k]
        nonzero = filter(!=(0.0), vals)
        isempty(nonzero) && continue
        push!(sig_rows, (
            Signal=get(shift_labels, k, string(k)),
            Mean_shift=round(mean(abs, nonzero), digits=3),
            Std=round(std(nonzero), digits=3),
            Races=length(nonzero),
        ))
    end
    !isempty(sig_rows) && write(io, html_table(DataFrame(sig_rows)))
end

# --- Per-race detail ---

write(io, html_heading("Per-race detail", 3))

race_rows = filter(:race => r -> !startswith(r, "—"), summary_df)
display_df = sort(race_rows, :spearman_rho, rev=true)
detail_html = html_table(display_df[:, [:race, :year, :category, :n_riders, :spearman_rho, :top10_overlap, :mean_abs_rank_error]])
write(io, html_callout(detail_html; title="All races", collapsed=true))

# --- Worst predictions ---

write(io, html_heading("Worst predictions", 4))
write(io, "<p>The races with the lowest Spearman ρ, with the biggest individual prediction misses for each.</p>\n")

worst_results = sort(filter(r -> r.rider_details !== nothing, results), by=r -> r.spearman_rho)
n_worst = min(5, length(worst_results))

if n_worst > 0
    for r in worst_results[1:n_worst]
        detail = sort(r.rider_details, :rank_error, rev=true)
        top_misses = first(detail, min(5, nrow(detail)))

        write(io, "<h5>$(r.race.name) $(r.race.year) (ρ = $(round(r.spearman_rho, digits=3)))</h5>\n")
        miss_df = DataFrame(
            Rider=String.(top_misses.riderkey),
            Predicted_rank=top_misses.predicted_rank,
            Actual_rank=top_misses.actual_rank,
            Rank_error=top_misses.rank_error,
        )
        write(io, html_table(miss_df))
    end
else
    write(io, "<p>No rider-level detail available.</p>\n")
end

# --- Prospective evaluation ---

write(io, html_heading("Prospective evaluation", 2))
write(io, "<p>Comparing archived pre-race predictions against actual results. Unlike the historical backtest, these use the full signal set including odds, oracle, and qualitative intelligence.</p>\n")

current_year = year(today())
prospective_df = prospective_season_summary(current_year)

if nrow(prospective_df) > 0
    write(io, html_heading("$current_year season", 3))
    write(io, "<p>$(nrow(prospective_df)) races with archived predictions and results.</p>\n")
    write(io, html_table(prospective_df))
else
    write(io, "<p>No prospective evaluation data available for $current_year yet.</p>\n")
end

# --- VG points calibration (PIT) ---

write(io, html_heading("VG points calibration (PIT)", 3))
write(io, "<p>The PIT histogram aggregates calibration checks across all prospective races. A uniform histogram indicates well-calibrated VG points distributions.</p>\n")

pit_df = prospective_pit_values(current_year)

augmented_pit = DataFrame()

if nrow(pit_df) > 0
    scored_pit = filter(:scored => identity, pit_df)
    n_races = length(unique(pit_df.race))
    n_scored = nrow(scored_pit)

    summary = prospective_pit_summary(pit_df)

    write(io, "<p><strong>$(n_scored) scoring riders across $(n_races) races.</strong> Mean PIT = $(summary.mean_pit) (target: 0.5), variance = $(summary.var_pit) (target: 0.083), KS statistic = $(summary.ks_statistic).</p>\n")
    write(io, pit_histogram_chart(pit_df; title="Aggregate PIT calibration — $current_year", scored_only=true))

    # Zero-score calibration
    n_total = nrow(pit_df)
    n_zero = nrow(filter(:scored => !, pit_df))
    actual_zero_pct = round(100 * n_zero / n_total, digits=1)
    write(io, "<p><strong>Zero-score calibration:</strong> $(actual_zero_pct)% of riders scored zero across all prospective races.</p>\n")

    # Per-race PIT histograms
    race_slugs = sort(unique(pit_df.race))
    if length(race_slugs) > 1
        per_race_io = IOBuffer()
        for slug in race_slugs
            race_pit = filter(:race => ==(slug), pit_df)
            display_name = titlecase(replace(slug, "-" => " "))
            write(per_race_io, "<div>")
            write(per_race_io, pit_histogram_chart(race_pit; title=display_name, scored_only=true, compact=true))
            write(per_race_io, "</div>\n")
        end
        write(io, html_callout(String(take!(per_race_io)); title="Per-race PIT histograms", collapsed=true))
    end

    # --- PIT by strength tier ---

    write(io, html_heading("PIT by strength tier", 3))
    write(io, "<p>Does the model overestimate favourites, mid-pack riders, or outsiders?</p>\n")

    pred_parts = DataFrame[]
    for slug in unique(pit_df.race)
        pred = load_race_snapshot("predictions", slug, current_year)
        pred === nothing && continue
        cols = Symbol[:riderkey, :strength, :uncertainty]
        for c in propertynames(pred)
            startswith(string(c), "shift_") && push!(cols, c)
        end
        cols = intersect(cols, propertynames(pred))
        sub = pred[:, unique(cols)]
        sub[!, :race] .= slug
        push!(pred_parts, sub)
    end
    pred_data = isempty(pred_parts) ? DataFrame() : reduce((a, b) -> vcat(a, b; cols=:union), pred_parts)
    augmented_pit = leftjoin(pit_df, pred_data, on=[:race, :riderkey])

    scored_aug = filter(row -> row.scored && !ismissing(row.strength), augmented_pit)

    if nrow(scored_aug) > 10
        q25_s = quantile(scored_aug.strength, 0.25)
        q75_s = quantile(scored_aug.strength, 0.75)

        tiers = [
            ("Bottom 25% (outsiders)", scored_aug.strength .<= q25_s),
            ("Middle 50%", (scored_aug.strength .> q25_s) .& (scored_aug.strength .< q75_s)),
            ("Top 25% (favourites)", scored_aug.strength .>= q75_s),
        ]

        pit_tier_rows = NamedTuple{(:Tier, :n, :Mean_PIT, :PIT_above_09), Tuple{String,Int,Float64,String}}[]
        for (label, mask) in tiers
            tier = scored_aug[mask, :]
            nrow(tier) < 3 && continue
            mp = round(mean(tier.pit_value), digits=3)
            high = round(100 * count(>(0.9), tier.pit_value) / nrow(tier), digits=1)
            push!(pit_tier_rows, (Tier=label, n=nrow(tier), Mean_PIT=mp, PIT_above_09="$(high)%"))
        end
        !isempty(pit_tier_rows) && write(io, html_table(DataFrame(pit_tier_rows)))
    else
        write(io, "<p>Insufficient data for strength-tier analysis.</p>\n")
    end

    # --- Uncertainty vs calibration ---

    write(io, html_heading("Uncertainty vs calibration", 3))
    write(io, "<p>Per-race comparison of posterior uncertainty width against PIT calibration.</p>\n")

    if :uncertainty in propertynames(augmented_pit)
        race_slugs_unc = sort(unique(augmented_pit.race))
        if length(race_slugs_unc) > 1
            unc_rows = NamedTuple{(:Race, :Mean_uncertainty, :Range, :Mean_PIT, :PIT_above_09), Tuple{String,Float64,String,Float64,String}}[]
            for slug in race_slugs_unc
                rp = filter(row -> row.race == slug, augmented_pit)
                sc = filter(row -> row.scored, rp)
                nrow(sc) < 3 && continue
                unc_vals = filter(!ismissing, rp.uncertainty)
                isempty(unc_vals) && continue
                mu = round(mean(unc_vals), digits=3)
                lo, hi = round.(extrema(unc_vals), digits=2)
                mp = round(mean(sc.pit_value), digits=3)
                high = round(100 * count(>(0.9), sc.pit_value) / nrow(sc), digits=1)
                display_name = titlecase(replace(slug, "-" => " "))
                push!(unc_rows, (Race=display_name, Mean_uncertainty=mu, Range="$(lo)–$(hi)", Mean_PIT=mp, PIT_above_09="$(high)%"))
            end
            !isempty(unc_rows) && write(io, html_table(DataFrame(unc_rows)))
        end
    end

    # --- Signal value analysis ---

    write(io, html_heading("Signal value analysis", 3))
    write(io, "<p>Which signals moved predictions most across archived races?</p>\n")

    sig_df = signal_value_analysis(current_year)
    if nrow(sig_df) > 0
        write(io, html_table(sig_df))
    else
        write(io, "<p>No signal data available yet.</p>\n")
    end

    # --- Signal load vs calibration ---

    write(io, html_heading("Signal load vs calibration", 3))
    write(io, "<p>Do races where signals shift predictions more aggressively show worse calibration?</p>\n")

    if nrow(augmented_pit) > 0
        shift_cols = [c for c in propertynames(augmented_pit) if startswith(string(c), "shift_")]

        if !isempty(shift_cols)
            load_rows = NamedTuple{(:Race, :Signals_active, :Mean_shift, :Mean_uncertainty, :Mean_PIT), Tuple{String,Int,Float64,Any,Float64}}[]
            for slug in sort(unique(augmented_pit.race))
                rp = filter(row -> row.race == slug, augmented_pit)
                sc = filter(row -> row.scored, rp)
                nrow(sc) < 3 && continue

                all_shifts_vec = Float64[]
                active_signals = Set{Symbol}()
                for col in shift_cols
                    col ∉ propertynames(rp) && continue
                    vals = filter(!ismissing, rp[!, col])
                    nonzero = filter(!=(0.0), vals)
                    if !isempty(nonzero)
                        push!(active_signals, col)
                        append!(all_shifts_vec, abs.(nonzero))
                    end
                end
                n_active = length(active_signals)
                mean_shift_val = isempty(all_shifts_vec) ? 0.0 : round(mean(all_shifts_vec), digits=3)
                unc_vals = filter(!ismissing, rp.uncertainty)
                mu = isempty(unc_vals) ? "—" : round(mean(unc_vals), digits=3)
                mp = round(mean(sc.pit_value), digits=3)
                display_name = titlecase(replace(slug, "-" => " "))
                push!(load_rows, (Race=display_name, Signals_active=n_active, Mean_shift=mean_shift_val, Mean_uncertainty=mu, Mean_PIT=mp))
            end
            !isempty(load_rows) && write(io, html_table(DataFrame(load_rows)))
        end
    end

    # --- Big-miss rate ---

    write(io, html_heading("Big-miss rate", 3))
    write(io, "<p>Per-race count of high-strength riders who scored zero VG points.</p>\n")

    if :strength in propertynames(augmented_pit)
        miss_rows = NamedTuple{(:Race, :Top10_zeros, :Top20_zeros, :Top10_scoring_rate), Tuple{String,String,String,String}}[]
        for slug in sort(unique(augmented_pit.race))
            rp = filter(row -> row.race == slug && !ismissing(row.strength), augmented_pit)
            nrow(rp) < 20 && continue
            sorted = sort(rp, :strength, rev=true)
            top10 = first(sorted, min(10, nrow(sorted)))
            top20 = first(sorted, min(20, nrow(sorted)))
            z10 = count(row -> row.actual_vg_points == 0, eachrow(top10))
            z20 = count(row -> row.actual_vg_points == 0, eachrow(top20))
            rate10 = round(100 * (1 - z10 / nrow(top10)), digits=0)
            display_name = titlecase(replace(slug, "-" => " "))
            push!(miss_rows, (Race=display_name, Top10_zeros="$z10 / $(nrow(top10))", Top20_zeros="$z20 / $(nrow(top20))", Top10_scoring_rate="$(rate10)%"))
        end
        !isempty(miss_rows) && write(io, html_table(DataFrame(miss_rows)))
    end

else
    write(io, "<p>No VG points calibration data available for $current_year yet. Requires both archived predictions and VG results.</p>\n")
end

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------

body = String(take!(io))
page = html_page(;
    title="Model backtesting and calibration",
    subtitle="Evaluating prediction quality and signal value",
    body=body,
)

output_dir = joinpath(@__DIR__, "..", "prediction_docs")
mkpath(output_dir)
output_path = joinpath(output_dir, "backtesting.html")
write(output_path, page)
@info "Written to $output_path"
