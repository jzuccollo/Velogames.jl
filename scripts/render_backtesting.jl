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
write(io, """<p>Each signal updates the rider's estimated strength via a Bayesian update. <strong>Precision</strong> (1/variance) controls how much each signal pulls the estimate — higher precision means the signal has more influence. <strong>Share</strong> is each signal's precision as a percentage of the total. Signals with low share contribute little and could potentially be removed.</p>
<p>The "with market" columns show effective weights when betting odds are available. The market discount ($(DEFAULT_BAYESIAN_CONFIG.market_discount)×) inflates non-market variances on the assumption that odds already incorporate the information in those signals.</p>\n""")
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
    Diagnostic = ["Mean CDF rank", "Chi-squared p-value", "Uniform?"],
    Value = [round(sbc.mean_rank, digits=3), round(sbc.chi_squared_p, digits=3),
             sbc.chi_squared_p > 0.05 ? "Yes" : "No"],
    Expected = ["0.5", "> 0.05", "Yes"],
)
write(io, html_table(sbc_df))
write(io, rank_histogram_chart(sbc.rank_histogram; title="All-signals SBC rank histogram", expected=sbc.n_sims / sbc.n_bins))

# Per-signal SBC
write(io, html_heading("Per-signal SBC", 4))
write(io, "<p>Each signal tested individually (no block-correlation discount active with a single signal).</p>\n")

per_signal_sbc_rows = NamedTuple{(:Signal, :Mean_rank, :p_value, :Uniform), Tuple{String,Float64,Float64,String}}[]
per_signal_names = Dict(:pcs => "PCS seasons", :vg => "VG season", :form => "PCS form",
    :history => "Race history", :vg_history => "VG history", :odds => "Odds", :oracle => "Oracle")

for (sig, label) in sort(collect(per_signal_names), by=last)
    sig_sbc = suppress_output() do
        simulation_based_calibration(DEFAULT_BAYESIAN_CONFIG;
            n_sims=500, rng=MersenneTwister(42),
            available_signals=Set([sig]))
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
    Signal = [
        "PCS results (ground truth)", "PCS season points", "VG season points (cumulative)",
        "PCS race history", "VG race history", "Archived PCS form",
        "Archived PCS seasons", "Archived Betfair odds", "Archived Cycling Oracle",
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
        Statistic = ["Mean", "Std", "1σ coverage", "2σ coverage", "Total rider-observations"],
        Observed = [z_mean, z_std, cov1, cov2, length(all_z)],
        Expected = ["0.0", "1.0", "0.683", "0.954", "—"],
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
write(io, "<p>Mean |shift| is how far each signal moves the posterior mean (on a z-score scale) averaged across riders. A larger shift means the signal has more influence on the final prediction. Signals with very small shifts (< 0.1) are adding complexity without meaningfully changing predictions. Note that the historical backtest lacks market signals (odds, oracle), so only non-market signals appear here.</p>\n")

shift_keys = [:shift_pcs, :shift_vg, :shift_form, :shift_history, :shift_vg_history, :shift_oracle, :shift_odds]
shift_labels = Dict(
    :shift_pcs => "PCS seasons", :shift_vg => "VG season points",
    :shift_form => "PCS form",
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

        pit_tier_rows = NamedTuple{(:Tier, :n, :Mean_PIT, :PIT_above_09), Tuple{String,Int,Float64,String}}[]
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
                rtier_rows = NamedTuple{(:Tier, :n, :Mean_PIT, :PIT_above_09), Tuple{String,Int,Float64,String}}[]
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
    write(io, "<p>When a signal shifts the posterior by > 0.5 (positive = stronger), what fraction of those riders actually scored VG points? A good signal pushes strength up for riders who score and down for riders who don't.</p>\n")

    if nrow(augmented_pit) > 0
        shift_cols_dir = [c for c in propertynames(augmented_pit) if startswith(string(c), "shift_") && c != :shift_trajectory]
        dir_labels = Dict(
            :shift_pcs => "PCS seasons", :shift_vg => "VG season",
            :shift_form => "PCS form", :shift_history => "PCS race history",
            :shift_vg_history => "VG race history", :shift_oracle => "Oracle",
            :shift_odds => "Odds", :shift_qualitative => "Qualitative",
        )

        dir_rows = NamedTuple{(:Signal, :n_positive, :scoring_rate, :n_negative, :zero_rate), Tuple{String,Int,String,Int,String}}[]
        for col in shift_cols_dir
            col ∉ propertynames(augmented_pit) && continue
            vals = augmented_pit[!, col]
            scored_flags = augmented_pit.scored

            # Riders where signal pushed strength UP by > 0.5
            pos_mask = [!ismissing(v) && v > 0.5 for v in vals]
            n_pos = count(pos_mask)
            if n_pos >= 5
                pos_scoring = count(i -> pos_mask[i] && scored_flags[i], 1:nrow(augmented_pit))
                pos_rate = round(100 * pos_scoring / n_pos, digits=1)
            else
                pos_rate = NaN
            end

            # Riders where signal pushed strength DOWN by > 0.5
            neg_mask = [!ismissing(v) && v < -0.5 for v in vals]
            n_neg = count(neg_mask)
            if n_neg >= 5
                neg_zero = count(i -> neg_mask[i] && !scored_flags[i], 1:nrow(augmented_pit))
                neg_rate = round(100 * neg_zero / n_neg, digits=1)
            else
                neg_rate = NaN
            end

            (n_pos < 5 && n_neg < 5) && continue
            label = get(dir_labels, col, string(col))
            push!(dir_rows, (
                Signal=label,
                n_positive=n_pos,
                scoring_rate=isnan(pos_rate) ? "—" : "$(pos_rate)%",
                n_negative=n_neg,
                zero_rate=isnan(neg_rate) ? "—" : "$(neg_rate)%",
            ))
        end
        if !isempty(dir_rows)
            dir_df = DataFrame(dir_rows)
            rename!(dir_df, :n_positive => Symbol("n (shift > 0.5)"),
                :scoring_rate => Symbol("% scoring"),
                :n_negative => Symbol("n (shift < -0.5)"),
                :zero_rate => Symbol("% zero-scored"))
            write(io, html_table(dir_df))
        end
    end

    # --- Signal load vs calibration ---

    write(io, html_heading("Signal load vs calibration", 3))
    write(io, "<p>Per-race comparison of signal activity against calibration quality. If more active signals or larger mean shifts correlate with worse Mean PIT, it suggests the signals are collectively pushing predictions in an overconfident direction. No clear correlation would indicate the calibration problem is independent of signal load.</p>\n")

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
    write(io, "<p>How often do predicted favourites blank entirely? <strong>Top10 zeros</strong> counts how many of the 10 strongest-predicted riders scored zero VG points. A top-10 scoring rate below 70% suggests the race is highly stochastic (bunch sprints, crashes) or the model is overrating certain riders. Selective races like Strade Bianche typically show 90–100%; flat sprinters' classics like Kuurne can drop to 40%.</p>\n")

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

    # --- Race selectivity clustering ---

    write(io, html_heading("Race selectivity clustering", 3))
    write(io, "<p>Races grouped by big-miss rate into selectivity clusters. Selective races (hard courses) have low big-miss rates; stochastic races (bunch sprints, minor races) have high big-miss rates. This informs whether race-type-specific uncertainty is needed.</p>\n")

    if :strength in propertynames(augmented_pit) && nrow(prospective_df) > 0
        cluster_rows = NamedTuple{(:Race, :Category, :Big_miss_rate, :Spearman_rho, :Mean_PIT, :Mean_uncertainty, :Cluster), Tuple{String,Any,String,Any,Float64,Any,String}}[]
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
