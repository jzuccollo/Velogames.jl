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
write(
    io,
    """<p>This report validates the Bayesian strength estimation model at three levels:</p>
<ol>
<li><strong>Prior predictive checks</strong> (no data needed) — simulate from the model's generative process and check whether implied outcomes match domain knowledge.</li>
<li><strong>Historical backtest</strong> (PCS results 2023–2025) — a sanity check that predictions beat random and that rank correlations look reasonable.</li>
<li><strong>Prospective evaluation</strong> (archived predictions vs results) — the most trustworthy evaluation, comparing pre-race predictions against actual outcomes.</li>
</ol>
<p>The model has three tuneable precision scale factors (<code>market_precision_scale</code>, <code>history_precision_scale</code>, <code>ability_precision_scale</code>) plus two decay rates.</p>
"""
)

# --- Precision budget ---

write(io, html_heading("Precision budget", 2))
write(
    io,
    """<p>Each signal updates the rider's estimated strength via a Bayesian update. <strong>Precision</strong> (1/variance) controls how much each signal pulls the estimate — higher precision means the signal has more influence. <strong>Share</strong> is each signal's precision as a percentage of the total. Signals with low share contribute little and could potentially be removed.</p>
<p>The "with market" columns show effective weights when betting odds are available. The market discount ($(DEFAULT_BAYESIAN_CONFIG.market_discount)×) inflates non-market variances on the assumption that odds already incorporate the information in those signals.</p>\n"""
)
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
write(io, "<p>Each row tests whether the model's simulated race outcomes fall within a domain-knowledge target range. <strong>Pass = 1</strong> means the observed value is within bounds. Failed checks suggest the model's uncertainty or signal precision is miscalibrated for that aspect of cycling.</p>\n")
write(io, "<p>$status</p>\n")
write(io, html_table(facts_df))

# --- Sensitivity sweeps ---

write(io, html_heading("Sensitivity sweeps", 3))
write(io, "<p>Each table sweeps one precision scale factor from near-zero to very high whilst holding the others at their defaults. <code>favourite_win_rate</code> should be 10–35% (cycling is unpredictable but not random), <code>rank_correlation</code> 0.3–0.75, and <code>posterior_sd</code> should stay above 0.3 (below that the model is overconfident). A parameter value where metrics plateau has diminishing returns — pushing it higher just shrinks uncertainty without improving rank ordering.</p>\n")

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
write(io, "<p>SBC checks whether the Bayesian inference pipeline correctly recovers true parameters from synthetic data. The all-signals test uses independently generated signals but the estimator applies a block-correlation discount, so failure here is expected. Per-signal tests isolate each conjugate update.</p>\n")

sbc = suppress_output() do
    simulation_based_calibration(DEFAULT_BAYESIAN_CONFIG;
        n_sims=500, rng=MersenneTwister(42))
end

sbc_df = DataFrame(
    Diagnostic=["Mean CDF rank", "Chi-squared p-value", "Uniform?"],
    Value=[round(sbc.mean_rank, digits=3), round(sbc.chi_squared_p, digits=3),
        sbc.chi_squared_p > 0.05 ? "Yes" : "No"],
    Expected=["0.5", "> 0.05", "Yes"],
)
write(io, html_table(sbc_df))
write(io, rank_histogram_chart(sbc.rank_histogram; title="All-signals SBC rank histogram", expected=sbc.n_sims / sbc.n_bins))

# Per-signal SBC
write(io, html_heading("Per-signal SBC", 4))
write(io, "<p>Each signal tested individually with the block-correlation discount skipped, isolating the conjugate update. Signals disabled in production (PCS form, VG history) are excluded — the estimator no-ops them so SBC would test nothing.</p>\n")

per_signal_sbc_rows = NamedTuple{(:Signal, :Mean_rank, :p_value, :Uniform),Tuple{String,Float64,Float64,String}}[]
per_signal_names = Dict(:pcs => "PCS seasons", :vg => "VG season",
    :history => "Race history", :odds => "Odds", :oracle => "Oracle")

for (sig, label) in sort(collect(per_signal_names), by=last)
    sig_sbc = suppress_output() do
        simulation_based_calibration(DEFAULT_BAYESIAN_CONFIG;
            n_sims=500, rng=MersenneTwister(42),
            available_signals=Set([sig]),
            skip_block_correlation=true)
    end
    push!(per_signal_sbc_rows, (
        Signal=label,
        Mean_rank=round(sig_sbc.mean_rank, digits=3),
        p_value=round(sig_sbc.chi_squared_p, digits=3),
        Uniform=sig_sbc.chi_squared_p > 0.05 ? "Yes" : "No",
    ))
end
write(io, html_table(DataFrame(per_signal_sbc_rows)))

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
    Signal=[
        "PCS results (ground truth)", "PCS season points", "VG season points (cumulative)",
        "PCS race history", "VG race history", "Archived PCS form",
        "Archived PCS seasons", "Archived odds", "Archived Cycling Oracle",
    ],
    Races=[
        "$n_fetched / $n_total", "$n_fetched / $n_fetched", "$n_fetched / $n_fetched",
        "$n_with_history / $n_fetched", "$n_with_vg_history / $n_fetched", "$n_with_form / $n_fetched",
        "$n_with_seasons / $n_fetched", "$n_with_odds / $n_fetched", "$n_with_oracle / $n_fetched",
    ],
    Coverage=[
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
    archive_rows = NamedTuple{(:race, :year, :odds, :oracle),Tuple{String,Int,String,String}}[]
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
        "No archived odds or oracle data found. Run <code>solve_oneday</code> with <code>odds_df</code> or <code>oracle_url</code> for upcoming races to start building the archive.";
        type="warning"))
end

# --- Baseline evaluation ---

write(io, html_heading("Baseline evaluation", 3))
write(io, "<p>Running the full prediction pipeline on all historical races and comparing to actual PCS finishing positions.</p>\n")

baseline_signals = [:pcs, :vg_season, :race_history, :vg_history, :form]

@info "Running backtest..."
results = backtest_season(races;
    race_data=race_data,
    signals=baseline_signals,
    n_sims=n_sims,
    store_rider_details=true,
)

summary_df = summarise_backtest(results)

write(io, html_heading("Overall metrics", 4))
write(io, """<p><strong>Spearman ρ</strong> measures rank correlation between predicted and actual finishing positions (1.0 = perfect, 0.0 = random; typical good models achieve 0.4–0.6). <strong>Top-N overlap</strong> counts how many of the predicted top 5/10 appear in the actual top 5/10. <strong>Mean abs rank error</strong> is the average number of positions a rider's prediction was off. <strong>Points captured ratio</strong> is the fraction of the optimal team's VG points that the model's chosen team would have scored.</p>\n""")
agg = filter(:race => r -> startswith(r, "—"), summary_df)
write(io, html_table(agg[:, [:race, :n_riders, :spearman_rho, :top5_overlap, :top10_overlap, :mean_abs_rank_error, :points_captured_ratio]]))

# --- Calibration ---

write(io, html_heading("Calibration", 3))
write(io, """<p>For each rider, the z-score is <code>(actual_strength − predicted_strength) / uncertainty</code>. If the model is well-calibrated, z-scores should follow a standard normal distribution: mean ≈ 0 (no systematic bias), std ≈ 1.0 (uncertainty width is correct), and 68% of observations within ±1σ. A mean below zero means the model overestimates strength (riders finish worse than predicted). Std above 1.0 means uncertainty is too narrow (overconfident).</p>\n""")

all_z = vcat([r.calibration_z_scores for r in results]...)

if !isempty(all_z)
    z_mean = round(mean(all_z), digits=3)
    z_std = round(std(all_z), digits=3)
    cov1 = round(count(z -> abs(z) <= 1.0, all_z) / length(all_z), digits=3)
    cov2 = round(count(z -> abs(z) <= 2.0, all_z) / length(all_z), digits=3)

    cal_df = DataFrame(
        Statistic=["Mean", "Std", "1σ coverage", "2σ coverage", "Total rider-observations"],
        Observed=[z_mean, z_std, cov1, cov2, length(all_z)],
        Expected=["0.0", "1.0", "0.683", "0.954", "—"],
    )
    write(io, html_table(cal_df))
end

# --- By strength tier ---

write(io, html_heading("By strength tier", 4))
write(io, "<p>Breaking z-scores by predicted strength tier. A negative mean z for favourites means the model predicts them too strong (they finish worse than expected). Low 1σ coverage means the model is overconfident for that tier. Ideally all tiers should have mean z ≈ 0 and coverage ≈ 0.68.</p>\n")

all_strengths = vcat([r.calibration_strengths for r in results]...)

if !isempty(all_z) && !isempty(all_strengths) && length(all_z) == length(all_strengths)
    q25_s = quantile(all_strengths, 0.25)
    q75_s = quantile(all_strengths, 0.75)

    tiers = [
        ("Bottom 25% (outsiders)", all_strengths .<= q25_s),
        ("Middle 50%", (all_strengths .> q25_s) .& (all_strengths .< q75_s)),
        ("Top 25% (favourites)", all_strengths .>= q75_s),
    ]

    tier_rows = NamedTuple{(:Tier, :Mean_z, :Std_z, :Coverage_1σ, :n),Tuple{String,Float64,Float64,Float64,Int}}[]
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

# --- Discrimination by position band ---

write(io, html_heading("Discrimination by position band", 4))
write(io, "<p>Spearman ρ computed within bands of actual finishing position. High ρ for positions 1–10 means the model correctly orders the top finishers relative to each other. Low ρ for positions 10–20 means the model cannot differentiate within the scoring boundary. This matters more for team selection than overall ρ because the optimiser primarily cares about the top 20–30 riders.</p>\n")

begin
    all_details = DataFrame[]
    for r in results
        r.rider_details === nothing && continue
        push!(all_details, r.rider_details)
    end
    if !isempty(all_details)
        combined = vcat(all_details...)
        bands = [
            ("Positions 1–10 (podium contenders)", 1, 10),
            ("Positions 11–20 (scoring boundary)", 11, 20),
            ("Positions 21–40 (near miss)", 21, 40),
            ("Positions 41+ (outsiders)", 41, 999),
        ]
        band_rows = NamedTuple{(:Band, :Spearman_ρ, :Mean_abs_rank_error, :n),Tuple{String,Float64,Float64,Int}}[]
        for (label, lo, hi) in bands
            mask = (combined.actual_rank .>= lo) .& (combined.actual_rank .<= hi)
            band_df = combined[mask, :]
            nrow(band_df) < 10 && continue
            rho = spearman_correlation(Float64.(band_df.predicted_rank), Float64.(band_df.actual_rank))
            mae = mean(band_df.rank_error)
            push!(band_rows, (Band=label, Spearman_ρ=round(rho, digits=3), Mean_abs_rank_error=round(mae, digits=1), n=nrow(band_df)))
        end
        !isempty(band_rows) && write(io, html_table(DataFrame(band_rows)))
    end
end

# --- Signal directional accuracy (historical) ---

write(io, html_heading("Signal directional accuracy", 4))
write(io, "<p>For riders with a signal shift > 0.1, does the shift direction match the actual outcome? A <em>correct direction</em> means: signal shifted strength up and the rider finished higher than the prior predicted (or vice versa). Accuracy near 50% means the signal is no better than random for direction; above 60% suggests genuine information. Computed from the historical backtest using rider-level shift and rank data.</p>\n")

begin
    # Collect rider-level predictions with shift columns from the backtest
    bt_shift_cols = [:shift_pcs, :shift_vg, :shift_form, :shift_history, :shift_vg_history]
    dir_accuracy_rows = NamedTuple{(:Signal, :n_riders, :Directional_accuracy),Tuple{String,Int,String}}[]
    dir_shift_labels = Dict(
        :shift_pcs => "PCS seasons", :shift_vg => "VG season points",
        :shift_form => "PCS form",
        :shift_history => "PCS race history", :shift_vg_history => "VG race history",
    )

    # We need rider-level shift data + actual rank. The backtest stores rider_details
    # (predicted_rank, actual_rank) but not per-signal shifts. We can approximate directional
    # accuracy using the aggregate mean_signal_shifts from BacktestResult — but that's per-race,
    # not per-rider. For a proper per-rider analysis we'd need to store shifts in rider_details.
    # For now, report a note that this requires rider-level shift data.
    #
    # Alternative: re-run estimate_strengths on rider_details to recover shifts. But that's
    # expensive and duplicates the backtest. Instead, add shift columns to rider_details.

    write(io, html_callout(
        "Per-rider signal directional accuracy requires storing per-rider shift columns in <code>BacktestResult.rider_details</code>. Currently only aggregate mean |shift| per race is stored. The prospective evaluation section below has per-rider directional accuracy for the 10 archived races.";
        type="info"))
end

# --- Signal contribution ---

write(io, html_heading("Signal contribution", 3))
write(io, "<p>Mean |shift| is how far each signal moves the posterior mean (on a z-score scale) averaged across riders. A larger shift means the signal has more influence on the final prediction. Signals with very small shifts (< 0.1) are adding complexity without meaningfully changing predictions. Note that the historical backtest lacks market signals (odds, oracle), so only non-market signals appear here.</p>\n")

shift_keys = [:shift_pcs, :shift_vg, :shift_form, :shift_history, :shift_vg_history, :shift_oracle, :shift_odds]
shift_labels = Dict(
    :shift_pcs => "PCS seasons", :shift_vg => "VG season points",
    :shift_form => "PCS form",
    :shift_history => "PCS race history", :shift_vg_history => "VG race history",
    :shift_oracle => "Cycling Oracle", :shift_odds => "Odds",
)

agg_shifts = Dict{Symbol,Vector{Float64}}()
for r in results
    for (k, v) in r.mean_signal_shifts
        push!(get!(agg_shifts, k, Float64[]), v)
    end
end

if !isempty(agg_shifts)
    sig_rows = NamedTuple{(:Signal, :Mean_shift, :Std, :Races),Tuple{String,Float64,Float64,Int}}[]
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
write(io, """<p>The Probability Integral Transform (PIT) checks whether simulated VG points distributions match reality. For each rider, PIT = the fraction of simulated draws that fell below the actual VG points scored. If the model is well-calibrated, PIT values should be uniformly distributed (flat histogram) with mean 0.5. A right-skewed histogram (bars rising towards 1.0) means the model systematically underestimates VG points — riders score more than the simulation predicted.</p>\n""")

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

    # --- Predicted vs actual VG points scatter ---

    write(io, html_heading("Predicted vs actual VG points", 3))
    write(io, "<p>Each point is a scoring rider. The dashed line shows y=x (perfect calibration). Points above the line scored more than predicted.</p>\n")

    # Load predicted expected VG points from archived predictions
    scatter_io = IOBuffer()
    for slug in race_slugs
        pred = load_race_snapshot("predictions", slug, current_year)
        pred === nothing && continue
        race_pit = filter(:race => ==(slug), pit_df)
        scored_race = filter(:scored => identity, race_pit)
        nrow(scored_race) < 3 && continue

        # Match predictions to PIT data
        if :expected_vg_points in propertynames(pred)
            merged = innerjoin(
                select(scored_race, :riderkey, :actual_vg_points),
                select(pred, :riderkey, :expected_vg_points, :strength),
                on=:riderkey,
            )
            nrow(merged) < 3 && continue

            # Colour by strength tier
            q25 = quantile(merged.strength, 0.25)
            q75 = quantile(merged.strength, 0.75)
            cols = [s >= q75 ? "#e15759" : s <= q25 ? "#4e79a7" : "#999" for s in merged.strength]

            display_name = titlecase(replace(slug, "-" => " "))
            write(scatter_io, "<div style=\"display:inline-block;margin:5px;\">")
            write(scatter_io, scatter_chart(
                Float64.(merged.expected_vg_points),
                Float64.(merged.actual_vg_points);
                title=display_name,
                xlabel="Predicted VG pts",
                ylabel="Actual VG pts",
                colours=cols,
                reference_line=true,
            ))
            write(scatter_io, "</div>\n")
        end
    end
    scatter_html = String(take!(scatter_io))
    if !isempty(scatter_html)
        write(io, "<p><span style=\"color:#e15759\">●</span> Top 25% (favourites) <span style=\"color:#999\">●</span> Middle 50% <span style=\"color:#4e79a7\">●</span> Bottom 25% (outsiders)</p>\n")
        write(io, scatter_html)
    end

    # --- PIT by strength tier ---

    write(io, html_heading("PIT by strength tier", 3))
    write(io, "<p><strong>Mean PIT</strong> above 0.5 means the model underestimates that tier's VG points; below 0.5 means overestimation. <strong>PIT above 0.9</strong> is the fraction of riders whose actual score exceeded 90% of the simulated draws — a high percentage here indicates severe underestimation. Well-calibrated tiers would show Mean PIT ≈ 0.5 and PIT above 0.9 ≈ 10%.</p>\n")

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

        pit_tier_rows = NamedTuple{(:Tier, :n, :Mean_PIT, :PIT_above_09),Tuple{String,Int,Float64,String}}[]
        for (label, mask) in tiers
            tier = scored_aug[mask, :]
            nrow(tier) < 3 && continue
            mp = round(mean(tier.pit_value), digits=3)
            high = round(100 * count(>(0.9), tier.pit_value) / nrow(tier), digits=1)
            push!(pit_tier_rows, (Tier=label, n=nrow(tier), Mean_PIT=mp, PIT_above_09="$(high)%"))
        end
        !isempty(pit_tier_rows) && write(io, html_table(DataFrame(pit_tier_rows)))

        # Per-race PIT by tier (collapsed)
        if length(unique(scored_aug.race)) > 1
            per_race_tier_io = IOBuffer()
            for slug in sort(unique(scored_aug.race))
                race_scored = filter(row -> row.race == slug, scored_aug)
                nrow(race_scored) < 10 && continue
                rq25 = quantile(race_scored.strength, 0.25)
                rq75 = quantile(race_scored.strength, 0.75)
                race_tiers = [
                    ("Bottom 25%", race_scored.strength .<= rq25),
                    ("Middle 50%", (race_scored.strength .> rq25) .& (race_scored.strength .< rq75)),
                    ("Top 25%", race_scored.strength .>= rq75),
                ]
                rtier_rows = NamedTuple{(:Tier, :n, :Mean_PIT, :PIT_above_09),Tuple{String,Int,Float64,String}}[]
                for (label, mask) in race_tiers
                    rt = race_scored[mask, :]
                    nrow(rt) < 3 && continue
                    mp = round(mean(rt.pit_value), digits=3)
                    high = round(100 * count(>(0.9), rt.pit_value) / nrow(rt), digits=1)
                    push!(rtier_rows, (Tier=label, n=nrow(rt), Mean_PIT=mp, PIT_above_09="$(high)%"))
                end
                if !isempty(rtier_rows)
                    display_name = titlecase(replace(slug, "-" => " "))
                    write(per_race_tier_io, "<h5>$(display_name)</h5>\n")
                    write(per_race_tier_io, html_table(DataFrame(rtier_rows)))
                end
            end
            per_race_tier_html = String(take!(per_race_tier_io))
            !isempty(per_race_tier_html) && write(io, html_callout(per_race_tier_html; title="Per-race PIT by strength tier", collapsed=true))
        end
    else
        write(io, "<p>Insufficient data for strength-tier analysis.</p>\n")
    end

    # --- Uncertainty vs calibration ---

    write(io, html_heading("Uncertainty vs calibration", 3))
    write(io, "<p>If wider uncertainty improved calibration, we would expect races with higher mean uncertainty to have PIT closer to 0.5. An inverse relationship (higher uncertainty → worse PIT) suggests the problem is not about uncertainty width but about the shape of the scoring distribution — symmetric noise cannot capture asymmetric outcomes.</p>\n")

    if :uncertainty in propertynames(augmented_pit)
        race_slugs_unc = sort(unique(augmented_pit.race))
        if length(race_slugs_unc) > 1
            unc_rows = NamedTuple{(:Race, :Mean_uncertainty, :Range, :Mean_PIT, :PIT_above_09),Tuple{String,Float64,String,Float64,String}}[]
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
            if !isempty(unc_rows)
                write(io, html_table(DataFrame(unc_rows)))
                # Scatter chart: uncertainty vs PIT
                unc_x = [r.Mean_uncertainty for r in unc_rows]
                unc_y = [r.Mean_PIT for r in unc_rows]
                write(io, scatter_chart(
                    unc_x, unc_y;
                    title="Uncertainty vs PIT (per race)",
                    xlabel="Mean posterior uncertainty",
                    ylabel="Mean PIT",
                ))
            end
        end
    end

    # --- Signal value analysis ---

    write(io, html_heading("Signal value analysis", 3))
    write(io, "<p>Mean absolute shift per signal across all prospective races. Unlike the historical backtest's signal contribution (which lacks market signals), this includes odds, oracle, and qualitative intelligence. A large mean shift indicates the signal is influential — but influential is not necessarily accurate. Compare with the directional accuracy table below to assess whether the signal's influence is well-directed.</p>\n")

    sig_df = signal_value_analysis(current_year)
    if nrow(sig_df) > 0
        write(io, html_table(sig_df))
    else
        write(io, "<p>No signal data available yet.</p>\n")
    end

    # --- Signal directional accuracy ---

    write(io, html_heading("Signal directional accuracy", 3))
    write(io, "<p>Two measures of whether each signal shifts riders in the correct direction. <strong>VG scoring</strong>: when a signal shifts strength up by > 0.5, what fraction of those riders scored VG points? <strong>Rank-based</strong>: for all riders with a non-trivial shift (|shift| > 0.1), what fraction had the shift direction match their actual PCS finishing position relative to the field median? Rank-based accuracy near 50% means the signal is no better than random; above 60% suggests genuine information.</p>\n")

    if nrow(augmented_pit) > 0
        shift_cols_dir = [c for c in propertynames(augmented_pit) if startswith(string(c), "shift_") && c != :shift_trajectory]
        dir_labels = Dict(
            :shift_pcs => "PCS seasons", :shift_vg => "VG season",
            :shift_form => "PCS form", :shift_history => "PCS race history",
            :shift_vg_history => "VG race history", :shift_oracle => "Oracle",
            :shift_odds => "Odds", :shift_qualitative => "Qualitative",
        )

        # Build rank-based directional accuracy using PCS results
        rank_dir_data = DataFrame[]
        for slug in sort(unique(augmented_pit.race))
            pcs = load_race_snapshot("pcs_results", slug, current_year)
            pcs === nothing && continue
            pos_col = hasproperty(pcs, :position) ? :position : hasproperty(pcs, :rnk) ? :rnk : nothing
            pos_col === nothing && continue
            race_aug = filter(row -> row.race == slug, augmented_pit)
            matched = innerjoin(race_aug, select(pcs, :riderkey, pos_col); on=:riderkey, makeunique=true)
            nrow(matched) < 10 && continue
            matched[!, :actual_position] = Float64.(matched[!, pos_col])
            median_pos = median(matched.actual_position)
            # above_median = finished better (lower position) than median
            matched[!, :above_median] = matched.actual_position .< median_pos
            push!(rank_dir_data, matched)
        end
        rank_combined = isempty(rank_dir_data) ? DataFrame() : reduce((a, b) -> vcat(a, b; cols=:union), rank_dir_data)

        dir_rows = NamedTuple{(:Signal, :n_up, :scoring_pct, :n_down, :zero_pct, :n_rank, :rank_accuracy),Tuple{String,Int,String,Int,String,Int,String}}[]
        for col in shift_cols_dir
            col ∉ propertynames(augmented_pit) && continue
            vals = augmented_pit[!, col]
            scored_flags = augmented_pit.scored

            # VG scoring-based: shifts UP > 0.5 → scoring rate
            pos_mask = [!ismissing(v) && v > 0.5 for v in vals]
            n_pos = count(pos_mask)
            pos_rate = if n_pos >= 5
                pos_scoring = count(i -> pos_mask[i] && scored_flags[i], 1:nrow(augmented_pit))
                round(100 * pos_scoring / n_pos, digits=1)
            else
                NaN
            end

            # VG scoring-based: shifts DOWN > 0.5 → zero rate
            neg_mask = [!ismissing(v) && v < -0.5 for v in vals]
            n_neg = count(neg_mask)
            neg_rate = if n_neg >= 5
                neg_zero = count(i -> neg_mask[i] && !scored_flags[i], 1:nrow(augmented_pit))
                round(100 * neg_zero / n_neg, digits=1)
            else
                NaN
            end

            # Rank-based: does shift direction match above/below median position?
            n_rank = 0
            rank_acc = NaN
            if nrow(rank_combined) > 0 && col in propertynames(rank_combined)
                rvals = rank_combined[!, col]
                rmask = [!ismissing(v) && abs(v) > 0.1 for v in rvals]
                n_rank = count(rmask)
                if n_rank >= 10
                    correct = count(i -> rmask[i] && (
                            (rvals[i] > 0 && rank_combined.above_median[i]) ||
                            (rvals[i] < 0 && !rank_combined.above_median[i])
                        ), 1:nrow(rank_combined))
                    rank_acc = round(100 * correct / n_rank, digits=1)
                end
            end

            (n_pos < 5 && n_neg < 5 && n_rank < 10) && continue
            label = get(dir_labels, col, string(col))
            push!(dir_rows, (
                Signal=label,
                n_up=n_pos,
                scoring_pct=isnan(pos_rate) ? "—" : "$(pos_rate)%",
                n_down=n_neg,
                zero_pct=isnan(neg_rate) ? "—" : "$(neg_rate)%",
                n_rank=n_rank,
                rank_accuracy=isnan(rank_acc) ? "—" : "$(rank_acc)%",
            ))
        end
        if !isempty(dir_rows)
            dir_df = DataFrame(dir_rows)
            rename!(dir_df,
                :n_up => Symbol("n (shift > 0.5)"),
                :scoring_pct => Symbol("% scoring"),
                :n_down => Symbol("n (shift < -0.5)"),
                :zero_pct => Symbol("% zero-scored"),
                :n_rank => Symbol("n (rank-based)"),
                :rank_accuracy => Symbol("Rank accuracy"),
            )
            write(io, html_table(dir_df))
        end
    end

    # --- Within-tier signal discrimination ---

    write(io, html_heading("Within-tier signal discrimination", 4))
    write(io, "<p>Within-tier Spearman ρ between each signal's shift value and actual PCS finishing position, split by predicted strength quartile. Measures whether a signal helps order riders <em>within</em> each tier — a positive ρ means larger positive shifts predict better finishes among similarly-ranked riders. ρ near zero means the signal adds no discrimination within that tier. A signal that is useful overall but poor within the top tier suggests it separates favourites from the field but cannot differentiate among favourites.</p>\n")

    if nrow(rank_combined) > 0 && :strength in propertynames(rank_combined)
        str_q25 = quantile(skipmissing(rank_combined.strength), 0.25)
        str_q75 = quantile(skipmissing(rank_combined.strength), 0.75)
        tier_defs = [
            ("Bottom 25%", rank_combined.strength .<= str_q25),
            ("Middle 50%", (rank_combined.strength .> str_q25) .& (rank_combined.strength .< str_q75)),
            ("Top 25%", rank_combined.strength .>= str_q75),
        ]

        tier_rho_rows = NamedTuple{(:Signal, :Bottom_25_rho, :Bottom_25_n, :Middle_50_rho, :Middle_50_n, :Top_25_rho, :Top_25_n),Tuple{String,String,Int,String,Int,String,Int}}[]
        for col in shift_cols_dir
            col ∉ propertynames(rank_combined) && continue
            label = get(dir_labels, col, string(col))
            rhos = String[]
            ns = Int[]
            for (_, tier_mask) in tier_defs
                tier_df = rank_combined[tier_mask, :]
                # Filter to riders with non-missing, non-zero shifts
                valid = [!ismissing(tier_df[i, col]) && tier_df[i, col] != 0.0 for i in 1:nrow(tier_df)]
                valid_df = tier_df[valid, :]
                n_tier = nrow(valid_df)
                if n_tier >= 10
                    shifts = Float64.([valid_df[i, col] for i in 1:nrow(valid_df)])
                    positions = Float64.(valid_df.actual_position)
                    # Positive shift = stronger prediction, lower position = better finish
                    # So we correlate shift with -position (higher shift should mean lower position)
                    rho = spearman_correlation(shifts, -positions)
                    push!(rhos, "$(round(rho, digits=3))")
                else
                    push!(rhos, "—")
                end
                push!(ns, n_tier)
            end
            any(r -> r != "—", rhos) || continue
            push!(tier_rho_rows, (Signal=label, Bottom_25_rho=rhos[1], Bottom_25_n=ns[1], Middle_50_rho=rhos[2], Middle_50_n=ns[2], Top_25_rho=rhos[3], Top_25_n=ns[3]))
        end
        if !isempty(tier_rho_rows)
            tier_rho_df = DataFrame(tier_rho_rows)
            rename!(tier_rho_df,
                :Bottom_25_rho => Symbol("ρ (bottom 25%)"),
                :Bottom_25_n => Symbol("n (bottom)"),
                :Middle_50_rho => Symbol("ρ (middle 50%)"),
                :Middle_50_n => Symbol("n (middle)"),
                :Top_25_rho => Symbol("ρ (top 25%)"),
                :Top_25_n => Symbol("n (top)"),
            )
            write(io, html_table(tier_rho_df))
        end
    end

    # --- Signal load vs calibration ---

    write(io, html_heading("Signal load vs calibration", 3))
    write(io, "<p>Per-race comparison of signal activity against calibration quality. If more active signals or larger mean shifts correlate with worse Mean PIT, it suggests the signals are collectively pushing predictions in an overconfident direction. No clear correlation would indicate the calibration problem is independent of signal load.</p>\n")

    if nrow(augmented_pit) > 0
        shift_cols = [c for c in propertynames(augmented_pit) if startswith(string(c), "shift_")]

        if !isempty(shift_cols)
            load_rows = NamedTuple{(:Race, :Signals_active, :Mean_shift, :Mean_uncertainty, :Mean_PIT),Tuple{String,Int,Float64,Any,Float64}}[]
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
    write(io, "<p>How often do predicted favourites blank entirely? <strong>Top10 zeros</strong> counts how many of the 10 strongest-predicted riders scored zero VG points. A top-10 scoring rate below 70% suggests the race is highly stochastic (bunch sprints, crashes) or the model is overrating certain riders. Selective races like Strade Bianche typically show 90–100%; flat sprinters' classics like Kuurne can drop to 40%.</p>\n")

    if :strength in propertynames(augmented_pit)
        miss_rows = NamedTuple{(:Race, :Top10_zeros, :Top20_zeros, :Top10_scoring_rate),Tuple{String,String,String,String}}[]
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

    # --- Race selectivity clustering ---

    write(io, html_heading("Race selectivity clustering", 3))
    write(io, "<p>Races grouped by big-miss rate into selectivity clusters. Selective races (hard courses) have low big-miss rates; stochastic races (bunch sprints, minor races) have high big-miss rates. This informs whether race-type-specific uncertainty is needed.</p>\n")

    if :strength in propertynames(augmented_pit) && nrow(prospective_df) > 0
        cluster_rows = NamedTuple{(:Race, :Category, :Big_miss_rate, :Spearman_rho, :Mean_PIT, :Mean_uncertainty, :Cluster),Tuple{String,Any,String,Any,Float64,Any,String}}[]
        for slug in sort(unique(augmented_pit.race))
            rp = filter(row -> row.race == slug && !ismissing(row.strength), augmented_pit)
            nrow(rp) < 20 && continue
            sorted = sort(rp, :strength, rev=true)
            top10 = first(sorted, min(10, nrow(sorted)))
            z10 = count(row -> row.actual_vg_points == 0, eachrow(top10))
            miss_rate = z10 / nrow(top10)

            sc = filter(row -> row.race == slug && row.scored, augmented_pit)
            mp = nrow(sc) > 0 ? round(mean(sc.pit_value), digits=3) : NaN
            unc_vals = filter(!ismissing, rp.uncertainty)
            mu = isempty(unc_vals) ? "—" : round(mean(unc_vals), digits=3)

            # Match to prospective_df for rho
            display_name = titlecase(replace(slug, "-" => " "))
            prosp_row = filter(:race => ==(display_name), prospective_df)
            rho = nrow(prosp_row) > 0 ? prosp_row.spearman_rho[1] : "—"
            cat = nrow(prosp_row) > 0 && :category in propertynames(prosp_row) ? prosp_row.category[1] : "—"

            cluster = miss_rate <= 0.1 ? "Selective" : miss_rate <= 0.25 ? "Standard" : "Stochastic"
            push!(cluster_rows, (Race=display_name, Category=cat, Big_miss_rate="$(round(Int, 100*miss_rate))%", Spearman_rho=rho, Mean_PIT=mp, Mean_uncertainty=mu, Cluster=cluster))
        end
        if !isempty(cluster_rows)
            cluster_df = sort(DataFrame(cluster_rows), :Big_miss_rate)
            write(io, html_table(cluster_df))
        end
    end

    # --- Prospective discrimination by position band ---

    write(io, html_heading("Discrimination by position band", 3))
    write(io, "<p>Spearman ρ within bands of actual PCS finishing position, aggregated across all prospective races. High ρ for positions 1–10 means the model correctly orders podium contenders relative to each other. Low ρ for positions 10–20 means the model cannot differentiate within the scoring boundary. This matters more for team selection than overall ρ because the optimiser primarily cares about the top 20–30 riders.</p>\n")

    begin
        band_parts = DataFrame[]
        for slug in sort(unique(augmented_pit.race))
            pred = load_race_snapshot("predictions", slug, current_year)
            pcs = load_race_snapshot("pcs_results", slug, current_year)
            pred === nothing && continue
            pcs === nothing && continue
            !hasproperty(pred, :strength) && continue

            pos_col = hasproperty(pcs, :position) ? :position : hasproperty(pcs, :rnk) ? :rnk : nothing
            pos_col === nothing && continue

            matched = innerjoin(
                select(pred, :riderkey, :strength),
                select(pcs, :riderkey, pos_col);
                on=:riderkey, makeunique=true,
            )
            nrow(matched) < 10 && continue
            matched[!, :actual_position] = Int.(matched[!, pos_col])
            matched[!, :predicted_rank] = invperm(sortperm(matched.strength, rev=true))
            matched[!, :race] .= slug
            push!(band_parts, matched[:, [:race, :riderkey, :strength, :actual_position, :predicted_rank]])
        end

        if !isempty(band_parts)
            band_combined = vcat(band_parts...)
            bands = [
                ("Positions 1–10 (podium contenders)", 1, 10),
                ("Positions 11–20 (scoring boundary)", 11, 20),
                ("Positions 21–40 (near miss)", 21, 40),
                ("Positions 41+ (outsiders)", 41, 999),
            ]
            band_rows = NamedTuple{(:Band, :Spearman_ρ, :Mean_abs_rank_error, :n),Tuple{String,Float64,Float64,Int}}[]
            for (label, lo, hi) in bands
                mask = (band_combined.actual_position .>= lo) .& (band_combined.actual_position .<= hi)
                band_df = band_combined[mask, :]
                nrow(band_df) < 10 && continue
                rho = spearman_correlation(Float64.(band_df.predicted_rank), Float64.(band_df.actual_position))
                mae = mean(abs.(band_df.predicted_rank .- band_df.actual_position))
                push!(band_rows, (Band=label, Spearman_ρ=round(rho, digits=3), Mean_abs_rank_error=round(mae, digits=1), n=nrow(band_df)))
            end
            !isempty(band_rows) && write(io, html_table(DataFrame(band_rows)))
        else
            write(io, "<p>Insufficient data for per-position-band analysis.</p>\n")
        end
    end

    # --- Signal ablation study ---

    write(io, html_heading("Signal ablation study", 3))
    write(io, """<p>Systematic ablation testing which signals improve discrimination and how market signals should interact with non-market signals. Re-runs the prediction pipeline on all prospective races with different signal configurations.</p>\n""")

    begin
        # Build BacktestRace entries for prospective races
        prosp_slugs = sort(unique(augmented_pit.race))
        ablation_races = BacktestRace[]
        for slug in prosp_slugs
            ri = Velogames._find_race_by_slug(slug)
            ri === nothing && continue
            race_date = try
                Date(ri.date)
            catch
                nothing
            end
            push!(ablation_races, BacktestRace(
                ri.name, current_year, slug, ri.category, history_years, race_date,
            ))
        end

        if !isempty(ablation_races)
            @info "Running signal ablation on $(length(ablation_races)) prospective races..."

            # Prefetch data (uses cache)
            vg_racelists = Velogames.prefetch_vg_racelists(unique([current_year]))
            ablation_data = Dict{BacktestRace,RaceData}()
            for race in ablation_races
                try
                    ablation_data[race] = prefetch_race_data(race; vg_racelists=vg_racelists, cache_config=bt_cache)
                catch e
                    @warn "Ablation prefetch failed for $(race.name): $e"
                end
            end

            # Helper: run a signal config across all races, return rider-level DataFrame
            function _run_ablation(signals, bc; race_filter=nothing)
                parts = DataFrame[]
                for (race, data) in sort(collect(ablation_data), by=p -> p.first.name)
                    data.actual_df === nothing && continue
                    race_filter !== nothing && !race_filter(race) && continue
                    try
                        r = backtest_race(race, data; signals=signals, bayesian_config=bc, n_sims=n_sims, store_rider_details=true)
                        r.rider_details === nothing && continue
                        detail = r.rider_details
                        detail[!, :race] .= race.pcs_slug
                        push!(parts, detail)
                    catch e
                        @warn "Ablation failed for $(race.name): $e"
                    end
                end
                isempty(parts) ? DataFrame() : vcat(parts...)
            end

            # Helper: position-dependent stitching
            function _run_pos_dependent(no_mkt_signals, mkt_signals, high_bc, low_bc; top_quantile=0.75)
                parts = DataFrame[]
                for (race, data) in sort(collect(ablation_data), by=p -> p.first.name)
                    data.actual_df === nothing && continue
                    try
                        r_base = backtest_race(race, data; signals=no_mkt_signals, bayesian_config=DEFAULT_BAYESIAN_CONFIG, n_sims=n_sims, store_rider_details=true)
                        r_base.rider_details === nothing && continue
                        q_thresh = quantile(r_base.rider_details.strength, top_quantile)
                        top_keys = Set(r_base.rider_details[r_base.rider_details.strength.>=q_thresh, :riderkey])

                        r_high = backtest_race(race, data; signals=mkt_signals, bayesian_config=high_bc, n_sims=n_sims, store_rider_details=true)
                        r_low = backtest_race(race, data; signals=mkt_signals, bayesian_config=low_bc, n_sims=n_sims, store_rider_details=true)
                        (r_high.rider_details === nothing || r_low.rider_details === nothing) && continue

                        stitched = vcat(
                            filter(:riderkey => k -> k in top_keys, r_high.rider_details),
                            filter(:riderkey => k -> !(k in top_keys), r_low.rider_details),
                        )
                        stitched[!, :predicted_rank] = invperm(sortperm(stitched.strength, rev=true))
                        stitched[!, :actual_rank] = invperm(sortperm(stitched.actual_rank))
                        stitched[!, :race] .= race.pcs_slug
                        push!(parts, stitched)
                    catch e
                        @warn "Position-dependent ablation failed for $(race.name): $e"
                    end
                end
                isempty(parts) ? DataFrame() : vcat(parts...)
            end

            # Helper: compute per-tier ρ from rider-level DataFrame (point estimate)
            function _tier_rho_point(df)
                nrow(df) < 20 && return Dict{String,Any}()
                result = Dict{String,Any}()
                for (label, q_lo, q_hi) in [("Bottom 25%", 0.0, 0.25), ("Middle 50%", 0.25, 0.75), ("Top 25%", 0.75, 1.0), ("Overall", 0.0, 1.0)]
                    if label == "Overall"
                        tier_df = df
                    else
                        lo = q_lo > 0 ? quantile(df.strength, q_lo) : minimum(df.strength) - 1
                        hi = q_hi < 1 ? quantile(df.strength, q_hi) : maximum(df.strength) + 1
                        tier_df = df[(df.strength.>lo).&(df.strength.<=hi), :]
                    end
                    result[label] = nrow(tier_df) >= 10 ?
                                    round(spearman_correlation(Float64.(tier_df.predicted_rank), Float64.(tier_df.actual_rank)), digits=3) : NaN
                end
                result
            end

            # Race-stratified bootstrap: resample whole races (correct unit — riders
            # within a race are correlated) and recompute tier ρ values.
            function _tier_rhos(df; n_boot=1000, rng=Random.MersenneTwister(42))
                point = _tier_rho_point(df)
                isempty(point) && return point

                # Need a :race column for stratified bootstrap
                if !hasproperty(df, :race)
                    return point
                end

                races = unique(df.race)
                n_races = length(races)
                n_races < 3 && return point  # too few races to bootstrap

                tier_defs = [("Bottom 25%", 0.0, 0.25), ("Middle 50%", 0.25, 0.75), ("Top 25%", 0.75, 1.0), ("Overall", 0.0, 1.0)]
                boot_samples = Dict(label => Float64[] for (label, _, _) in tier_defs)

                for _ in 1:n_boot
                    # Resample races with replacement
                    sampled_races = races[rand(rng, 1:n_races, n_races)]
                    parts = DataFrame[]
                    for r in sampled_races
                        push!(parts, filter(:race => ==(r), df))
                    end
                    boot_df = vcat(parts...)
                    nrow(boot_df) < 20 && continue

                    # Keep per-race ranks as-is (matching the point estimate).
                    # When a race appears twice, its riders are duplicated with
                    # identical per-race ranks, double-weighting that race.

                    for (label, q_lo, q_hi) in tier_defs
                        if label == "Overall"
                            tier_df = boot_df
                        else
                            lo = q_lo > 0 ? quantile(boot_df.strength, q_lo) : minimum(boot_df.strength) - 1
                            hi = q_hi < 1 ? quantile(boot_df.strength, q_hi) : maximum(boot_df.strength) + 1
                            tier_df = boot_df[(boot_df.strength.>lo).&(boot_df.strength.<=hi), :]
                        end
                        rho = nrow(tier_df) >= 10 ?
                              spearman_correlation(Float64.(tier_df.predicted_rank), Float64.(tier_df.actual_rank)) : NaN
                        push!(boot_samples[label], rho)
                    end
                end

                # Format as "point [lo, hi]"
                result = Dict{String,Any}()
                for (label, _, _) in tier_defs
                    pv = get(point, label, NaN)
                    samples = filter(!isnan, boot_samples[label])
                    if isnan(pv) || length(samples) < 100
                        result[label] = pv
                    else
                        lo = round(quantile(samples, 0.025), digits=3)
                        hi = round(quantile(samples, 0.975), digits=3)
                        result[label] = "$(round(pv, digits=3)) [$lo, $hi]"
                    end
                end
                result
            end

            # ============================================================
            # Part 1: Non-market signal selection (baseline for all races)
            # ============================================================

            write(io, html_heading("Non-market signal selection", 4))
            write(io, "<p>Which non-market signals improve discrimination? Tests signal subsets without odds or oracle — the configuration used for most races. Signals with near-zero within-tier ρ (PCS form, VG race history, qualitative) may be adding noise.</p>\n")

            nm_configs = [
                ("All non-market", [:pcs, :vg_season, :race_history, :vg_history, :form]),
                ("Drop form", [:pcs, :vg_season, :race_history, :vg_history]),
                ("Drop VG history", [:pcs, :vg_season, :race_history, :form]),
                ("Drop qualitative", [:pcs, :vg_season, :race_history, :vg_history, :form]),  # qual not in non-market anyway
                ("Drop form+VG hist", [:pcs, :vg_season, :race_history]),
                ("PCS + race hist only", [:pcs, :race_history]),
                ("PCS + VG season only", [:pcs, :vg_season]),
            ]

            nm_results = Dict{String,Dict{String,Any}}()
            for (label, signals) in nm_configs
                @info "  Non-market: $label"
                df = _run_ablation(signals, DEFAULT_BAYESIAN_CONFIG)
                nm_results[label] = _tier_rhos(df)
            end

            # Build table
            _format_rho(v) = v isa String ? v : (v isa Number && isnan(v)) ? "—" : "$v"
            nm_labels = [l for (l, _) in nm_configs]
            tier_names = ["Bottom 25%", "Middle 50%", "Top 25%", "Overall"]
            nm_rows = []
            for tier in tier_names
                row = Dict{String,Any}("Tier" => tier)
                for label in nm_labels
                    rhos = get(nm_results, label, Dict())
                    v = get(rhos, tier, NaN)
                    row[label] = _format_rho(v)
                end
                push!(nm_rows, row)
            end
            if !isempty(nm_rows)
                col_order = ["Tier"; nm_labels]
                nm_df = DataFrame([col => [r[col] for r in nm_rows] for col in col_order])
                write(io, html_table(nm_df))
            end

            # ============================================================
            # Part 2: Market signal configurations (races with odds)
            # ============================================================

            write(io, html_heading("Market signal configurations", 4))
            write(io, """<p>How should market signals (odds, oracle) be integrated? Tests uniform discount values and position-dependent discount (full discount for top-quartile riders only). Also tests odds-only and oracle-only to identify which market signal adds value.</p>\n""")

            all_signals = [:pcs, :vg_season, :race_history, :vg_history, :form, :odds, :oracle]
            odds_only = [:pcs, :vg_season, :race_history, :vg_history, :form, :odds]
            oracle_only = [:pcs, :vg_season, :race_history, :vg_history, :form, :oracle]
            no_market_signals = [:pcs, :vg_season, :race_history, :vg_history, :form]

            mkt_results = Dict{String,Dict{String,Any}}()

            @info "  Market: no market (baseline)"
            mkt_results["No market"] = _tier_rhos(_run_ablation(no_market_signals, DEFAULT_BAYESIAN_CONFIG))

            for md in [8.0, 4.0, 2.0]
                for (label_prefix, sigs) in [("All mkt", all_signals), ("Odds only", odds_only), ("Oracle only", oracle_only)]
                    label = "$label_prefix d=$md"
                    @info "  Market: $label"
                    bc = BayesianConfig(; market_discount=md)
                    mkt_results[label] = _tier_rhos(_run_ablation(sigs, bc))
                end
            end

            # Position-dependent variants
            for (pd_label, top_q) in [("Pos-dep top25%", 0.75), ("Pos-dep top33%", 0.67)]
                @info "  Market: $pd_label"
                high_bc = BayesianConfig(; market_discount=8.0)
                low_bc = BayesianConfig(; market_discount=1.0)
                df = _run_pos_dependent(no_market_signals, all_signals, high_bc, low_bc; top_quantile=top_q)
                mkt_results[pd_label] = _tier_rhos(df)
            end

            # Also test pos-dep with odds only
            @info "  Market: Pos-dep odds-only top25%"
            high_bc = BayesianConfig(; market_discount=8.0)
            low_bc = BayesianConfig(; market_discount=1.0)
            df = _run_pos_dependent(no_market_signals, odds_only, high_bc, low_bc; top_quantile=0.75)
            mkt_results["Pos-dep odds top25%"] = _tier_rhos(df)

            # Build table
            mkt_labels = ["No market",
                "All mkt d=8.0", "Odds only d=8.0", "Oracle only d=8.0",
                "All mkt d=4.0", "Odds only d=4.0", "Oracle only d=4.0",
                "All mkt d=2.0", "Odds only d=2.0", "Oracle only d=2.0",
                "Pos-dep top25%", "Pos-dep top33%", "Pos-dep odds top25%",
            ]
            mkt_rows = []
            for tier in tier_names
                row = Dict{String,Any}("Tier" => tier)
                for label in mkt_labels
                    rhos = get(mkt_results, label, Dict())
                    v = get(rhos, tier, NaN)
                    row[label] = _format_rho(v)
                end
                push!(mkt_rows, row)
            end
            if !isempty(mkt_rows)
                col_order = ["Tier"; mkt_labels]
                mkt_df = DataFrame([col => [r[col] for r in mkt_rows] for col in col_order])
                write(io, html_table(mkt_df))
            end

            # ============================================================
            # Part 3: Per-race breakdown (best configs only)
            # ============================================================

            write(io, html_heading("Per-race ablation (best configs)", 4))
            write(io, "<p>Per-race Spearman ρ for the most promising configurations, to check whether results are consistent across selective vs stochastic races.</p>\n")

            best_configs = [
                ("No market", no_market_signals, DEFAULT_BAYESIAN_CONFIG),
                ("All mkt d=8.0", all_signals, BayesianConfig(; market_discount=8.0)),
                ("Odds only d=8.0", odds_only, BayesianConfig(; market_discount=8.0)),
            ]

            per_race_rows = []
            for (race, data) in sort(collect(ablation_data), by=p -> p.first.name)
                data.actual_df === nothing && continue
                row = Dict{String,Any}("Race" => race.name)
                # Check if race has market data
                has_odds = data.odds_df !== nothing && nrow(data.odds_df) > 0
                has_oracle = data.oracle_df !== nothing && nrow(data.oracle_df) > 0
                row["Has odds"] = has_odds ? "✓" : "—"
                row["Has oracle"] = has_oracle ? "✓" : "—"

                for (label, signals, bc) in best_configs
                    try
                        r = backtest_race(race, data; signals=signals, bayesian_config=bc, n_sims=n_sims, store_rider_details=false)
                        row["ρ ($label)"] = "$(round(r.spearman_rho, digits=3))"
                    catch
                        row["ρ ($label)"] = "—"
                    end
                end
                push!(per_race_rows, row)
            end

            if !isempty(per_race_rows)
                pr_col_order = vcat(["Race", "Has odds", "Has oracle"], ["ρ ($l)" for (l, _, _) in best_configs])
                pr_df = DataFrame([col => [r[col] for r in per_race_rows] for col in pr_col_order])
                write(io, html_table(pr_df))
            end

            # ============================================================
            # Part 4: Combined configuration test
            # ============================================================
            # Tests findings 1-3 together (drop form + VG history + oracle +
            # qualitative) rather than assuming individual improvements are
            # additive. The block-correlation discount changes when signals are
            # removed, so the combined effect may differ from the sum of parts.

            write(io, html_heading("Combined configuration test", 4))
            write(io, "<p>Tests the proposed signal set (PCS seasons + VG season + PCS race history + odds) against the current default, with bootstrap 95% CIs. Individual ablation improvements interact through the block-correlation discount, so the combined effect is not necessarily the sum of individual improvements.</p>\n")

            combined_configs = [
                ("Current default (no market)", [:pcs, :vg_season, :race_history, :vg_history, :form], DEFAULT_BAYESIAN_CONFIG),
                ("Proposed (no market)", [:pcs, :vg_season, :race_history], DEFAULT_BAYESIAN_CONFIG),
                ("Current default + odds d=8", [:pcs, :vg_season, :race_history, :vg_history, :form, :odds, :oracle], BayesianConfig(; market_discount=8.0)),
                ("Proposed + odds d=8", [:pcs, :vg_season, :race_history, :odds], BayesianConfig(; market_discount=8.0)),
            ]

            combined_results = Dict{String,Dict{String,Any}}()
            for (label, signals, bc) in combined_configs
                @info "  Combined: $label"
                combined_results[label] = _tier_rhos(_run_ablation(signals, bc))
            end

            combined_labels = [l for (l, _, _) in combined_configs]
            combined_rows = []
            for tier in tier_names
                row = Dict{String,Any}("Tier" => tier)
                for label in combined_labels
                    rhos = get(combined_results, label, Dict())
                    v = get(rhos, tier, NaN)
                    row[label] = _format_rho(v)
                end
                push!(combined_rows, row)
            end
            if !isempty(combined_rows)
                col_order = ["Tier"; combined_labels]
                combined_df = DataFrame([col => [r[col] for r in combined_rows] for col in col_order])
                write(io, html_table(combined_df))
            end

            # Per-race breakdown for combined configs
            write(io, html_heading("Per-race combined comparison", 4))
            write(io, "<p>Per-race Spearman ρ for current vs proposed signal sets. Improvement sign consistency across races is more informative than the pooled average.</p>\n")

            combined_race_rows = []
            for (race, data) in sort(collect(ablation_data), by=p -> p.first.name)
                data.actual_df === nothing && continue
                row = Dict{String,Any}("Race" => race.name)
                has_odds = data.odds_df !== nothing && nrow(data.odds_df) > 0
                row["Has odds"] = has_odds ? "✓" : "—"

                for (label, signals, bc) in combined_configs
                    try
                        r = backtest_race(race, data; signals=signals, bayesian_config=bc, n_sims=n_sims, store_rider_details=false)
                        row["ρ ($label)"] = "$(round(r.spearman_rho, digits=3))"
                    catch
                        row["ρ ($label)"] = "—"
                    end
                end
                push!(combined_race_rows, row)
            end

            if !isempty(combined_race_rows)
                cr_col_order = vcat(["Race", "Has odds"], ["ρ ($l)" for (l, _, _) in combined_configs])
                cr_df = DataFrame([col => [r[col] for r in combined_race_rows] for col in cr_col_order])
                write(io, html_table(cr_df))
            end
        end
    end

else
    write(io, "<p>No VG points calibration data available for $current_year yet. Requires both archived predictions and VG results.</p>\n")
end

# ---------------------------------------------------------------------------
# Calibration history tracking
# ---------------------------------------------------------------------------

history_path = joinpath(@__DIR__, "..", "prediction_docs", "calibration_history.csv")

if nrow(pit_df) > 0 && nrow(prospective_df) > 0
    # Compute summary metrics for this run
    scored_pit_all = filter(:scored => identity, pit_df)
    run_mean_pit = nrow(scored_pit_all) > 0 ? round(mean(scored_pit_all.pit_value), digits=4) : NaN
    run_mean_rho = round(mean(prospective_df.spearman_rho), digits=4)

    # Compute aggregate big-miss rate
    local total_top10 = 0
    local total_zeros = 0
    if :strength in propertynames(augmented_pit)
        for slug in unique(augmented_pit.race)
            rp = filter(row -> row.race == slug && !ismissing(row.strength), augmented_pit)
            nrow(rp) < 20 && continue
            sorted = sort(rp, :strength, rev=true)
            top10 = first(sorted, min(10, nrow(sorted)))
            total_top10 += nrow(top10)
            total_zeros += count(row -> row.actual_vg_points == 0, eachrow(top10))
        end
    end
    run_big_miss = total_top10 > 0 ? round(total_zeros / total_top10, digits=4) : NaN

    # Config hash for tracking parameter changes
    config_hash = string(hash((
            DEFAULT_BAYESIAN_CONFIG.market_precision_scale,
            DEFAULT_BAYESIAN_CONFIG.history_precision_scale,
            DEFAULT_BAYESIAN_CONFIG.ability_precision_scale,
            DEFAULT_BAYESIAN_CONFIG._odds_to_oracle_ratio,
            DEFAULT_BAYESIAN_CONFIG.vg_hist_decay_rate,
            DEFAULT_BAYESIAN_CONFIG.market_discount,
        )), base=16)[1:8]

    # Append to history CSV
    new_row = "$(today()),$(nrow(prospective_df)),$(run_mean_pit),$(run_mean_rho),$(run_big_miss),$(config_hash)\n"

    if !isfile(history_path)
        open(history_path, "w") do f
            write(f, "date,n_races,mean_pit,mean_rho,big_miss_rate,config_hash\n")
            write(f, new_row)
        end
    else
        # Only append if the most recent entry is for a different date or config
        existing = readlines(history_path)
        last_line = length(existing) > 1 ? existing[end] : ""
        if !startswith(last_line, "$(today()),") || !endswith(last_line, ",$(config_hash)")
            open(history_path, "a") do f
                write(f, new_row)
            end
        end
    end

    # Render calibration history chart if we have > 1 data point
    if isfile(history_path)
        hist_lines = readlines(history_path)
        if length(hist_lines) > 2  # header + at least 2 data rows
            write(io, html_heading("Calibration history", 2))
            write(io, "<p>Each time this report runs, it appends a row with the key metrics. The <strong>config hash</strong> is a fingerprint of the model's hyperparameters — when it changes, a parameter was modified. Look for metric improvements that coincide with config hash changes to assess whether parameter tweaks are helping. Mean PIT should trend towards 0.5, mean ρ towards 1.0, and big-miss rate towards 0.0.</p>\n")

            dates = String[]
            pit_vals = Float64[]
            rho_vals = Float64[]
            miss_vals = Float64[]
            for line in hist_lines[2:end]
                parts = split(line, ",")
                length(parts) >= 5 || continue
                push!(dates, String(parts[1]))
                push!(pit_vals, parse(Float64, parts[3]))
                push!(rho_vals, parse(Float64, parts[4]))
                push!(miss_vals, parse(Float64, parts[5]))
            end

            if length(dates) > 1
                write(io, line_chart(
                    dates,
                    [("Mean PIT", pit_vals), ("Mean ρ", rho_vals), ("Big-miss rate", miss_vals)];
                    title="Calibration metrics over time",
                    ylabel="Value",
                ))
            end

            # Also show the raw table
            write(io, html_callout("<pre>" * join(hist_lines, "\n") * "</pre>"; title="Raw calibration history", collapsed=true))
        end
    end
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
