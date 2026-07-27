# Velogames.jl

Fantasy cycling team optimisation for velogames.com. Scrapes rider data from Velogames and ProCyclingStats, estimates rider strength via Bayesian updating, and selects optimal teams using resampled optimisation (JuMP/HiGHS).

## Architecture

- `src/Velogames.jl` - Main module, includes and exports
- `src/get_data.jl` - Data scraping: VG riders, PCS rankings/specialty ratings, Oddschecker odds parsing, Cycling Oracle predictions, VG race results, VG race catalogue and per-race results
- `src/pcs_scraper.jl` - PCS table scraping infrastructure and column aliases
- `src/pcs_extended.jl` - Extended PCS scraping: race history results, startlists, form scores across multiple years
- `src/data_assembly.jl` - Shared data assembly: `RaceData` struct, `join_pcs_specialty`, `assemble_pcs_race_history`, `assemble_vg_race_history`, `prefetch_vg_racelists` (used by both production and backtesting pipelines). Also report data loading and post-race archival: `load_report_data`, `load_stage_race_report_data`, `load_stage_race_per_stage_data`, `list_completed_races`, `compute_cumulative_scores`, `compute_stage_type_scores`, `archive_stage_race_results`, `load_stage_profiles`, `load_league_standings` (reads the sibling `../vgleague` package's JSON cache, with `data/league_standings.toml` manual-paste fallback; consumed by `scripts/league_eval.jl` for cumulative league placement and entered-vs-advised deltas)
- `src/qualitative.jl` - Qualitative intelligence: YouTube transcript fetching (via yt-dlp), Claude API extraction, prompt generation, JSON response parsing, manual workflow support
- `src/scoring.jl` - VG scoring tables by category (one-day Cat 1/2/3, stage race aggregate) and expected points functions
- `src/bayesian_core.jl` - `BayesianConfig` (3 precision scale factors — market, history, ability — with fixed within-group ratios) and variance accessors, `BayesianPosterior`/`StrengthEstimate`/`MultiDimPosterior`, `bayesian_update`, `bayesian_update_multidim_dim`, `multidim_prior`, and dimension tables (`STRENGTH_DIMENSIONS`, `SIGNAL_DIMENSION_WEIGHTS`, `RACE_HISTORY_CLASS_PROJECTION`). Block-correlation discount groups signals into the same 3 clusters.
- `src/strength_pipeline.jl` - Bayesian strength estimation (`estimate_strengths`): uninformative prior with PCS as observation, season-adaptive VG variance, class-aware PCS blending for stage races, domestique strength discount. Signal assembly (`RiderSignalData`, `AssembledSignals`, `_assemble_signals`), scalar + multidim estimators, and `predict_expected_points` (MC simulation) for backtesting. Trajectory signal removed April 2026 (negligible contribution).
- `src/simulate_oneday.jl` - One-day Monte Carlo race simulation (`simulate_race`, `position_to_strength`, `position_probabilities`) and expected VG points (`expected_vg_points`, `breakaway_sectors_from_km`). `_score_vg_draw!` is the shared finish+assist+breakaway scoring rule used by both `expected_vg_points` (backtest) and `resample_optimise!` (production).
- `src/simulate_stage.jl` - Per-stage grand tour simulation (`simulate_stage_race`, `StageRaceDiagnostics`, `stage_dimension_weights`) and stage-type strength projection (`compute_stage_strengths`). The final mountains jersey is ranked by cumulative daily-KOM points. Attrition, the breakaway participation draw, and GC-favourite protection were deleted July 2026 (WP2.3: none moved team-points-captured on the backtest harness).
- `src/prior_checks.jl` - Prior predictive checks, sensitivity sweeps, and simulation-based calibration (SBC). Validates model behaviour by simulating from the generative process without historical data.
- `src/prospective_eval.jl` - Prospective evaluation: compares archived pre-race predictions against actual results. Computes Spearman rho, top-N overlap, signal value analysis.
- `src/build_model.jl` - JuMP optimisation models: `build_model_oneday` (6 riders), `build_model_stage` (9 riders + class constraints), `resample_optimise!` (resampled optimisation that draws noisy strengths, scores VG points, and optimises per draw), `minimise_cost_stage`. Also hindsight-optimal / cheapest-winning team selection for report retrospectives (`compute_optimal_team`, `compute_cheapest_winning_team`, `compute_optimal_stage_team`, `compute_cheapest_winning_stage_team`)
- `src/race_solver.jl` - High-level solvers: `solve_oneday` and `solve_stage` (estimate strengths → resampled optimisation pipeline, returns top teams). Fetch-free prediction cores `_oneday_prediction_core`/`_stage_prediction_core` (estimate_strengths → resample_optimise, no I/O or archival) are shared by the production solvers and the backtest champions. Also archives predictions and qualitative data for prospective evaluation, and provides `archive_race_results` for post-race archival.
- `src/cache_utils.jl` - Feather-based caching with configurable TTL (default ~/.velogames_cache, 7 days), plus permanent archival storage (`DEFAULT_ARCHIVE_DIR`, ~/Dropbox/code/velogames/archive) for odds/oracle snapshots
- `src/race_helpers.jl` - `RaceInfo` struct (canonical race metadata), `RaceConfig` struct, `setup_race()`, URL alias lookup, `CLASSICS_RACES_2026` schedule, `SIMILAR_RACES` (derived from `RaceInfo`), year-aware VG slug/URL/game ID functions
- `src/utilities.jl` - Name normalisation (`normalisename`), key creation (`createkey`), sentinel constants (`DNF_POSITION`, `UNRANKED_POSITION`), and report/display utilities (`suppress_output`, `clean_team_names!`, `round_numeric_columns!`)
- `src/backtest.jl` - Backtesting framework: race catalogue, season-level evaluation, calibration diagnostics, VG race history integration, cumulative VG season points, PCS specialty archiving. Stage-race harness: `prefetch_stage_race_data` (as-of-race-day grand tour reconstruction into `StageRaceBacktestData`), `backtest_stage_race` (team-points-captured + rank metrics for `:simulator`/`:direct`/`:persistence`/`:odds` or custom predictors; targets `:vg_total`/`:gc`/`:points`/`:kom`), `champion_evg` (full production stack as a predictor), `crosscheck_option_ab` (Option A/B drift alarm: pass vs a pinned post-WP2.3 baseline ±0.03, historical roadmap values carried as `rec_*`). One-day harness (the stage twin): `prefetch_oneday_backtest_data` (as-of-race-day classic reconstruction into `OneDayBacktestData`, scoring against TRUE scraped `vg_results` totals incl. assist/breakaway, not the finish-only proxy of `backtest_race`), `backtest_oneday_race`/`backtest_oneday_season` (team-points-captured + rank metrics for `:simulator` (`champion_oneday_evg`, runs `_oneday_prediction_core`)/`:direct` (`direct_oneday_evg`)/`:odds`/`:maxcost` or custom `name => f` predictors)
- `src/direct_evg.jl` - Fitted challenger to the full simulator stack: `direct_evg` (stage races) and `direct_oneday_evg` (classics) map ability + market + own-history straight onto a rank→points curve, no position simulation. Fitted offline, evaluated only through the backtest harnesses — deliberately not wired into `solve_oneday`/`solve_stage` (both champion/challenger gates tied; see roadmap).
- `src/report_html.jl` - HTML page generation primitives (`html_page`, `html_table`, `html_callout`, `html_heading`, `plotly_html`, `_slugify`, `commafmt`)
- `src/report_charts.jl` - SVG/Plotly chart functions (PIT histograms, scatter plots, rank histograms, line charts, team totals, sim distributions), `compute_pit_values`, `simulate_vg_draws`
- `src/report_formatters.jl` - Signal/classification/podium table formatters (`format_signal_waterfall`, `format_classification_table`, `format_stage_podium_picks`, per-dim helpers), `precision_budget`
- `scripts/render_predictor.jl` - One-day prediction report: reads `race_config.toml`, runs prediction pipeline, writes `docs/predictor.html`
- `scripts/render_assessor.jl` - Team assessor report: compares custom team vs optimal, retrospective analysis, writes `docs/assessor.html`
- `scripts/render_stagerace.jl` - Stage race prediction report: reads `race_config.toml`, runs stage race pipeline, writes `docs/stagerace.html`
- `scripts/render_backtesting.jl` - Backtesting and calibration report: prior checks, historical backtest, prospective evaluation, writes `docs/backtesting.html`
- `scripts/render_reports.jl` - Public race reports site: generates per-race HTML retrospectives to `site/docs/`, incremental build (skips existing)
- `scripts/league_eval.jl` - Offline league evaluation: scores archived model teams against realised VG points, the hindsight-optimal team, and max-cost / odds-implied baselines, then reports cumulative league placement and the entered-vs-advised delta from the `[league]` config. Its placement section matches standings race names against `CLASSICS_RACES_2026`, so it is classics-shaped — a grand tour league's per-stage race names will not resolve.
- `scripts/baseline_compare.jl` - Naive-persistence yardstick for grand tours: mean VG points across the two prior Tours, fed through `build_model_stage`, set beside the model's archived optimal team
- `scripts/publish_race.sh` / `scripts/publish_stage_race.sh` - Publish a one-day / stage race report. See the Commands section for which to use and a known bug in the stage-race one.
- `scripts/archive_race.sh` - Archive PCS and VG results for every current-season race that has predictions but no results
- `data/race_config.toml` - Shared per-race configuration (gitignored); `race_config.toml.example` is the committed template. Sections: `[race]`, `[output]`, `[data_sources]`, `[optimisation]`, `[team_assessor]`, `[league]`, `[entered_team]`

## Key functions

### Solvers (src/race_solver.jl)

- `solve_oneday(config; ...)` - Resampled optimisation pipeline for one-day classics. Returns `(predicted, chosenteam, top_teams)`.
- `solve_stage(config; ...)` - Resampled optimisation pipeline for stage races (class constraints). Returns `(predicted, chosenteam, top_teams)`.
- `archive_race_results(pcs_slug, year; vg_race_number)` - Fetch and archive PCS results and VG results for a completed race. Idempotent.

### Optimisation models (src/build_model.jl)

- `resample_optimise!(df, scoring, build_model_fn; team_size, n_resamples=500, max_per_team, n_alternatives=20)` - Draw noisy strengths from posterior, score VG points, tally per-draw selection frequency, then optimise on risk-adjusted expected points. Returns `(df, top_teams)` where df gains `:selection_frequency` and `:expected_vg_points`, and `top_teams` is a `Vector{DataFrame}` of the `n_alternatives` best distinct teams ranked best-first (k-best enumeration via iterated no-good cuts; `top_teams[1]` is the optimal team). Reports use this near-optimal set for the stage-race team switcher, filler pool, and structural-fork analysis.
- `build_model_oneday(df, n, points_col, cost_col; max_per_team, exclude, force_in, force_out)` - Maximise points, one-day (6 riders, cost <= 100, optional per-team cap). `exclude` adds no-good cuts (k-best); `force_in`/`force_out` pin riders (structural forks).
- `build_model_stage(df, n, points_col, cost_col; max_per_team, exclude, force_in, force_out)` - Maximise points, stage race (9 riders, class constraints, optional per-team cap). Same `exclude`/`force_in`/`force_out` hooks as the one-day model.
- `compute_filler_pool(top_teams)` / `compute_structural_forks(predicted, build_model_fn; team_size, max_per_team, n_forks=5)` - Decompose the k-best set into locked core + interchangeable filler pool, and rank the highest-EVG either/or roster decisions (drop-a-rider deltas + the both-GC-leaders-vs-one structural fork). Rendered by `format_near_optimal_section` (report_formatters.jl).
- `minimise_cost_stage(df, target_score, n, cost_col)` - Minimise cost for target score

### Data scraping (src/get_data.jl)

- `get_cycling_oracle(prediction_url)` - Scrape Cycling Oracle blog predictions, returns DataFrame(rider, win_prob, riderkey)
- `getvg_race_list(year)` - Scrape VG races.php for one-day classics, returns DataFrame(race_number, deadline, name, category, namekey)
- `getvg_race_results(year, race_number)` - Fetch VG race results via year-aware ridescore URL
- `match_vg_race_number(race_name, vg_racelist)` - Match a race name to VG race number using normalised string comparison
- `normalise_race_name(name)` - Normalise race names for cross-source matching (strips accents, hyphens, punctuation)

### Simulation (src/bayesian_core.jl, strength_pipeline.jl, simulate_oneday.jl, simulate_stage.jl)

- `estimate_strengths(rider_df; ...)` / `estimate_strengths(data::RaceData; ...)` - Bayesian strength estimation pipeline. Returns DataFrame with `strength`, `uncertainty`, signal flags, signal shifts, and domestique penalty. Used by production solvers.
- `predict_expected_points(df, scoring; ...)` - Backtest entry point: calls `estimate_strengths` then runs MC simulation to compute `expected_vg_points`. Used by backtesting.
- `estimate_rider_strength(...)` - Bayesian posterior from uninformative prior (mean=0, variance=100), updated with PCS specialty (gated on `has_pcs`), VG, PCS form, PCS race history with variance penalties, VG race history, odds, oracle, qualitative intelligence. Trajectory signal removed. Variances accessed via functions: `pcs_variance(config)`, `odds_variance(config)`, etc. When odds are present for a race, non-market signal variances are inflated by `market_discount` (default 8.0) at the race level to prevent double-counting information already reflected in odds. Block-correlation discount groups signals into market/history/ability clusters with within-cluster ρ=0.5 and between-cluster ρ=0.15.
- `simulate_race(strengths, uncertainties; n_sims)` - Monte Carlo position simulation (used by backtesting)
- `estimate_rider_strength_multidim(signals; ...)` - Multi-dimensional Bayesian strength estimation for stage races. Routes each signal to dimensions in `STRENGTH_DIMENSIONS` according to `SIGNAL_DIMENSION_WEIGHTS`. Returns `MultiDimStrengthEstimate` with per-dim mean/variance/shift vectors. The scalar block-correlation discount is applied per dimension (gated by `multidim_block_correlation`, default true; `skip_block_correlation` escape hatch for per-signal SBC).
- `compute_stage_strengths(rider_df)` - Project per-dim strength columns onto per-stage-type strength vectors used by `simulate_stage_race`.
- `simulate_stage_race(stages, stage_strengths, uncertainties, teams, scoring; ...)` - Always returns `(vg_points, diagnostics)`. Per-event scoring delegated to `_score_*` helpers; noise scales live in `StageSimConfig`.

### Prior predictive checks (src/prior_checks.jl)

- `prior_predictive_check(config; n_races, n_riders)` - Simulate races from generative process, compute diagnostics (favourite win rate, top-N overlap, rank correlation, posterior SDs)
- `check_stylised_facts(config; facts)` - Run prior predictive check against domain knowledge targets, returns pass/fail DataFrame
- `sensitivity_sweep(param, values; config)` - Sweep a BayesianConfig parameter and report diagnostics
- `simulation_based_calibration(config; n_sims)` - SBC: check posterior CDF rank uniformity to validate inference pipeline

### Prospective evaluation (src/prospective_eval.jl)

- `evaluate_prospective(pcs_slug, year)` - Compare archived predictions vs PCS results for one race
- `prospective_season_summary(year)` - Aggregate prospective metrics across all archived races for a year
- `prospective_pit_values(year)` - Compute PIT values for all riders across archived races (requires predictions + VG results)
- `prospective_pit_summary(pit_df)` - Summary statistics for aggregate PIT: mean, variance, KS statistic
- `signal_value_analysis(year)` - Per-signal shift magnitudes across archived predictions

### Qualitative intelligence (src/qualitative.jl)

- `get_qualitative_auto(youtube_url, riders, race_name, race_date)` - Full automated pipeline: YouTube transcript → Claude API extraction → DataFrame(riderkey, adjustment, confidence, reasoning)
- `build_qualitative_prompt(riders, race_name, race_date; transcript)` - Generate prompt for Claude API or manual web UI workflow
- `load_qualitative_file(filepath)` - Load manually saved JSON response file
- `parse_qualitative_response(json_text)` - Parse Claude's JSON response into the standard qualitative DataFrame
- `fetch_transcript(youtube_url)` - Download and clean YouTube auto-captions via yt-dlp

### Archival storage (src/cache_utils.jl)

- `save_race_snapshot(df, data_type, pcs_slug, year)` - Permanently archive a DataFrame (e.g. odds, oracle) to `{DEFAULT_ARCHIVE_DIR}/{data_type}/{pcs_slug}/{year}.feather`
- `load_race_snapshot(data_type, pcs_slug, year)` - Load archived data; returns `nothing` if not found
- `archive_path(data_type, pcs_slug, year)` - Compute the archive file path

### Backtesting (src/backtest.jl)

- `build_race_catalogue(years)` - Generate `BacktestRace` entries (with dates) from the classics race schedule
- `prefetch_all_races(races)` - Bulk pre-fetch data (PCS results, rider info, race history, VG race history, cumulative VG season points, archived odds/oracle/PCS specialty)
- `backtest_season(races; race_data, signals, ...)` - Evaluate predictions across all races
- `summarise_backtest(results)` - Convert results to summary DataFrame with aggregates
- `BacktestResult` includes: rank metrics (Spearman ρ, top-N overlap), VG team metrics (actual scoring tables), and calibration diagnostics (z-scores, coverage rates)

## Prediction model

### Signal inventory

The strength model combines multiple signals grouped into three precision families. Effective variances are computed from base values, fixed within-group ratios, and tuneable scale factors. Accessor functions (e.g. `pcs_variance(config)`) compute the effective variance from the config.

**Active signals (after April 2026 ablation):**

| Signal | Source | Group | Base variance | Notes |
| ------ | ------ | ----- | ------------- | ----- |
| PCS seasons | `getpcs_rider_pts_batch()` | Ability | 7.9 | Z-scored across field. Best discriminator across all tiers (ρ=0.16–0.34). For stage races, each PCS specialty source (sprint/oneday/climber/tt/gc) is z-scored separately and routed to dimensions via `SIGNAL_DIMENSION_WEIGHTS`. |
| VG season points | `getvg_riders()` | Ability | 1.4×scale | Season-adaptive: `effective = vg_var * (1 + penalty * (1 - frac_nonzero))`. Strong for top-tier discrimination (ρ=0.287) |
| PCS race history | `getpcs_race_history()` | History | 3.0+decay/yr | Recency-weighted. Strong for bottom/middle tiers (ρ=0.23–0.25), weak for top (ρ=0.004) |
| Similar-race history | `getpcs_race_history()` | History | +penalty | Same as race history but with variance penalty. Races from `SIMILAR_RACES` terrain mapping |
| Betting odds | `parse_oddschecker_odds()` | Market | 0.3 | Strongest top-tier signal (ρ=0.464 for top 25%). Applied uniformly when odds are present |
| Odds floor | Derived (absence signal) | Market | var × 2.0 | When odds data exists but rider absent, floor observation from residual probability mass |
| Cycling Oracle | `get_cycling_oracle()` | Market | `_odds_to_oracle_ratio`/scale | Broader coverage than bookmaker odds. Removal deferred: degrades middle-tier discrimination when combined with other changes. |

**Signals disabled by April 2026 ablation** (code retained for backtesting; data collection continues): PCS form score, VG race history, qualitative intelligence, trajectory.

Odds are converted to strength via log-odds relative to a uniform baseline. When odds are present for a race, non-market signal variances are inflated by `market_discount` (default 8.0) to prevent double-counting. Riders absent from the market receive a floor observation.

### Bayesian updating

Normal-normal conjugate model (`estimate_rider_strength()`). Each signal updates the posterior mean and variance. Missing data leaves the prior unchanged. Output: posterior mean (strength) and variance (uncertainty).

### Monte Carlo simulation

`simulate_race()` adds Student's t noise (df=5) scaled by posterior uncertainty to each rider's strength, then ranks to get finishing positions. Gaussian noise also supported via `simulation_df=nothing`.

### One-day vs stage race differences

| Aspect | One-day | Stage race |
| ------ | ------- | ---------- |
| PCS blending | Single specialty (e.g. one-day points) | Per-source z-scoring routed to dimensions via `SIGNAL_DIMENSION_WEIGHTS` (multi-dim posterior) |
| Scoring table | Cat 1/2/3 (finish + assist + breakaway) | `SCORING_GRAND_TOUR` (per-stage scoring) or `SCORING_STAGE` (aggregate fallback) |
| Simulation | Single race simulation | Per-stage simulation with cross-stage correlated noise (α=0.7) and stage-type strength modifiers |
| Breakaway points | Heuristic estimate | Not modelled (~6 pts/stage gap from sprint/climb/breakaway bonuses) |
| Team size | 6 riders | 9 riders |
| Constraints | Cost only | Cost + classification (grand tours) or cost only (week-long races without VG class data) |

### Parameter settings

| Parameter | Value | Rationale |
| --------- | ----- | --------- |
| `market_precision_scale` | 4.0 | Odds are the best single predictor for top-quartile riders |
| `history_precision_scale` | 2.0 | Controls PCS race history only (form and VG history removed by ablation) |
| `ability_precision_scale` | 1.0 | PCS seasons and VG season points are broad career/season aggregates |
| `within_cluster_correlation` | 0.5 | Prevents false certainty from correlated history observations |
| `between_cluster_correlation` | 0.15 | Modest discount across 2–3 active clusters |
| `hist_decay_rate` | 3.2 | Aggressive: 3-year-old result has variance 11.1 vs 1.5 for current year |
| `market_discount` | 8.0 (uniform) | Applied uniformly when odds are present |

### Data sources

- **Velogames** (velogames.com) — rider rosters, costs, season points, classifications, ownership %, historical race results, per-stage results
- **ProCyclingStats** (procyclingstats.com) — specialty ratings, rankings, race results, startlist quality, form scores, stage profiles (ProfileScore, vertical metres, gradient)
- **Bookmaker odds** — betting odds pasted from Oddschecker or any bookmaker winner market into `oddschecker_paste.txt`
- **Cycling Oracle** (cyclingoracle.com) — race predictions with win probabilities (optional)

## Key patterns

- Per-race config in `data/race_config.toml` (gitignored, shared by render_predictor and render_assessor); `race_config.toml.example` is the committed template
- Analysis reports are standalone Julia scripts (`scripts/render_*.jl`) that generate HTML directly — no Quarto/pandoc dependency
- Public race reports site (`site/docs/`) generated by `scripts/render_reports.jl` with incremental build (skips existing HTML files)
- Anthropic API key via `ANTHROPIC_API_KEY`; see `.envrc.example`
- All data functions use `cached_fetch()` with `CacheConfig` and `force_refresh` parameter
- Rider matching across sources uses `riderkey` (from `createkey()` name normalisation)
- Web scraping: `gettable()` -> `process_rider_table()` via HTTP/Gumbo/Cascadia; `scrape_html_tables()` parses `<table>` elements directly
- Optimisation: JuMP + HiGHS, binary variables for rider selection
- PCS URLs: `https://www.procyclingstats.com/race/{slug}/{year}`
- VG URLs: `https://www.velogames.com/{race-slug}/{year}/riders.php`
- One-day classics races share one VG URL per year: `sixes-classics/{year}/riders.php` (2026+) or `sixes-superclasico/{year}/riders.php` (≤2025), with startlist hash filtering
- Archival storage: `_prepare_rider_data` automatically archives odds/oracle/PCS specialty/qualitative data on successful fetch; solvers archive predictions after `estimate_strengths`; `archive_race_results` archives post-race PCS and VG results; `prefetch_race_data` loads archived data for backtesting
- Archival paths: `{DEFAULT_ARCHIVE_DIR}/{data_type}/{pcs_slug}/{year}.feather` (DEFAULT_ARCHIVE_DIR = ~/Dropbox/code/velogames/archive) — data_type includes odds, oracle, pcs_specialty, vg_results, qualitative, predictions, pcs_results. Prediction archives always write `riderkey, rider, team, cost, chosen, selection_frequency, expected_vg_points` plus `schema_version` (archiving throws if any is missing); readers warn on legacy pre-April-2026 archives, which cannot be re-created
- VG race URLs: `ridescore.php?ga={game_id}&st={race_number}` where game_id is from `vg_classics_game_id(year)`, `st` is race number 1-44 from races.php
- Backtesting temporal integrity: `estimate_strengths`/`predict_expected_points` accept `race_year`/`race_date` for correct recency weighting; cumulative VG season points prevent end-of-year leakage; archived PCS specialty scores prevent current-day leakage
- Production pipeline: `estimate_strengths` → `resample_optimise!` (avoids Jensen's inequality bias from scoring floor at position 31+). Backtesting pipeline: `predict_expected_points` (MC simulation) for rank-based metrics.

## Commands

- Set up for a race: `cp data/race_config.toml.example data/race_config.toml` then edit
- Run predictor: `julia --project scripts/render_predictor.jl`
- Run team assessor: `julia --project scripts/render_assessor.jl`
- Run stage race predictor: `julia --project scripts/render_stagerace.jl`
- Run backtesting: `julia --project scripts/render_backtesting.jl`
- Generate race reports: `julia --project scripts/render_reports.jl` (add `--force` to regenerate all)
- Publish a race: `./scripts/publish_race.sh <pcs_slug> <year> "<winner>" <score>`. Needs a terminal — it prompts before committing and pushing, and with no stdin the prompt hits EOF and `set -e` aborts it after rendering. `publish_stage_race.sh` is the grand-tour variant: it archives the stage data explicitly first and commits without prompting. Either works for a stage race, since `render_reports.jl` calls `archive_stage_race_results` regardless. Both commit `data/league_winners.toml` alongside the rendered site — it is a tracked build input, not an artefact.
- Evaluate the league: `julia --project scripts/league_eval.jl` (reads the `[league]` section; point `vgleague_data_dir` at the deploy clone `~/code/vgleague-deploy/data`, which is what the launchd job writes — `~/code/vgleague` is a dev clone and goes stale)
- Run tests: `julia --project -e "using Pkg; Pkg.test()"`

## Conventions

- Julia naming: snake_case for functions, PascalCase for types
- New data functions must support CacheConfig parameter
- Prefer extending existing files over creating new ones
- Scoring categories: Cat 1 = monuments + worlds + Amstel Gold, Cat 2 = WT classics, Cat 3 = semi-classics
- British English spelling throughout (optimise, normalise, colour)

## Keep it simple

This is a small, personal package. Avoid overengineering:

- **No defensive coding** — don't guard against impossible states, add excessive input validation, or handle hypothetical edge cases. Trust the caller.
- **Delete, don't deprecate** — when removing or renaming something, just do it. No deprecation warnings, shims, or backward-compatibility aliases.
- **No unnecessary flexibility** — don't add parameters, config options, or abstractions "for future use". Add them when actually needed.
- **Minimal error handling** — let Julia's built-in errors propagate naturally. Only catch errors at boundaries where you can do something useful.
- **No boilerplate** — skip docstrings for obvious functions, skip type annotations where Julia infers fine, skip comments that restate the code.

## Validating model changes

Match validation rigour to **effect size × mechanistic clarity, not to a sample/race count** — cycling gives ~3 grand tours a year, so a "wait for N races" gate freezes all progress. Ship large, well-understood changes on theory + directional + do-no-harm checks (top-~20 rank ρ must not degrade; no absurd outputs), then monitor prospectively with a pre-registered revisit trigger. Defer only genuinely small metric-chases, until the effect looks material. Rank ρ is invariant to EVG-level changes, so judge those on points-level metrics (PIT, team-points-captured). See `roadmap.md` "Validation philosophy".

## Roadmap

See `roadmap.md` for known issues, planned improvements, ablation findings, and evidence base.
