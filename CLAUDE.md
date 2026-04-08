# Velogames.jl

Fantasy cycling team optimisation for velogames.com. Scrapes rider data from Velogames and ProCyclingStats, estimates rider strength via Bayesian updating, and selects optimal teams using resampled optimisation (JuMP/HiGHS).

## Architecture

- `src/Velogames.jl` - Main module, includes and exports
- `src/betfair.jl` - Betfair Exchange API: authentication, session management, market queries for betting odds
- `src/get_data.jl` - Data scraping: VG riders, PCS rankings/specialty ratings, Betfair odds (via API), Cycling Oracle predictions, VG race results, VG race catalogue and per-race results
- `src/pcs_scraper.jl` - PCS table scraping infrastructure and column aliases
- `src/pcs_extended.jl` - Extended PCS scraping: race history results, startlists, form scores across multiple years
- `src/data_assembly.jl` - Shared data assembly: `RaceData` struct, `join_pcs_specialty!`, `assemble_pcs_race_history`, `assemble_vg_race_history`, `prefetch_vg_racelists` (used by both production and backtesting pipelines)
- `src/qualitative.jl` - Qualitative intelligence: YouTube transcript fetching (via yt-dlp), Claude API extraction, prompt generation, JSON response parsing, manual workflow support
- `src/scoring.jl` - VG scoring tables by category (one-day Cat 1/2/3, stage race aggregate) and expected points functions
- `src/simulation.jl` - Bayesian strength estimation (`estimate_strengths`): uninformative prior with PCS as observation, season-adaptive VG variance, class-aware PCS blending for stage races, domestique strength discount. `BayesianConfig` uses 3 precision scale factors (market, history, ability) with fixed within-group ratios; accessor functions compute effective variances. Block-correlation discount groups signals into the same 3 clusters. Trajectory signal removed April 2026 (negligible contribution). Also retains `predict_expected_points` (MC simulation) for backtesting compatibility.
- `src/prior_checks.jl` - Prior predictive checks, sensitivity sweeps, and simulation-based calibration (SBC). Validates model behaviour by simulating from the generative process without historical data.
- `src/prospective_eval.jl` - Prospective evaluation: compares archived pre-race predictions against actual results. Computes Spearman rho, top-N overlap, signal value analysis.
- `src/build_model.jl` - JuMP optimisation models: `build_model_oneday` (6 riders), `build_model_stage` (9 riders + class constraints), `resample_optimise` (resampled optimisation that draws noisy strengths, scores VG points, and optimises per draw), `minimise_cost_stage`
- `src/race_solver.jl` - High-level solvers: `solve_oneday` and `solve_stage` (estimate strengths → resampled optimisation pipeline, returns top teams). Also archives predictions and qualitative data for prospective evaluation, and provides `archive_race_results` for post-race archival.
- `src/cache_utils.jl` - Feather-based caching with configurable TTL (default ~/.velogames_cache, 24h), plus permanent archival storage (~/.velogames_archive) for odds/oracle snapshots
- `src/classification_utils.jl` - Rider classification (allrounder/sprinter/climber/unclassed) column management
- `src/race_helpers.jl` - `RaceInfo` struct (canonical race metadata), `RaceConfig` struct, `setup_race()`, URL alias lookup, `CLASSICS_RACES_2026` schedule, `SIMILAR_RACES` (derived from `RaceInfo`), year-aware VG slug/URL/game ID functions
- `src/utilities.jl` - Name normalisation (`normalisename`), key creation (`createkey`), sentinel constants (`DNF_POSITION`, `UNRANKED_POSITION`)
- `src/backtest.jl` - Backtesting framework: race catalogue, season-level evaluation, ablation study, hyperparameter tuning, calibration diagnostics, VG race history integration, cumulative VG season points, PCS specialty archiving
- `src/report_helpers.jl` - HTML page generation (`html_page`, `html_table`, `html_callout`, `html_heading`), Plotly chart helpers, SVG chart functions (PIT histograms, scatter plots, rank histograms, line charts, box plots, team totals), signal waterfall, VG simulation draws
- `scripts/render_predictor.jl` - One-day prediction report: reads `race_config.toml`, runs prediction pipeline, writes `docs/predictor.html`
- `scripts/render_assessor.jl` - Team assessor report: compares custom team vs optimal, retrospective analysis, writes `docs/assessor.html`
- `scripts/render_stagerace.jl` - Stage race prediction report: reads `race_config.toml`, runs stage race pipeline, writes `docs/stagerace.html`
- `scripts/render_backtesting.jl` - Backtesting and calibration report: prior checks, historical backtest, prospective evaluation, writes `docs/backtesting.html`
- `scripts/render_reports.jl` - Public race reports site: generates per-race HTML retrospectives to `site/docs/`, incremental build (skips existing)
- `data/race_config.toml` - Shared per-race configuration (gitignored); `race_config.toml.example` is the committed template

## Key functions

### Solvers (src/race_solver.jl)

- `solve_oneday(config; ...)` - Resampled optimisation pipeline for one-day classics. Returns `(predicted, chosenteam, top_teams)`.
- `solve_stage(config; ...)` - Resampled optimisation pipeline for stage races (class constraints). Returns `(predicted, chosenteam, top_teams)`.
- `archive_race_results(pcs_slug, year; vg_race_number)` - Fetch and archive PCS results and VG results for a completed race. Idempotent.

### Optimisation models (src/build_model.jl)

- `resample_optimise(df, scoring, build_model_fn; team_size, n_resamples=500, max_per_team)` - Draw noisy strengths from posterior, score VG points, optimise team per draw, repeat. Returns `(df, top_teams)` where df gains `:selection_frequency` and `:expected_vg_points`, and `top_teams` is a `Vector{DataFrame}` of the most frequently selected teams.
- `build_model_oneday(df, n, points_col, cost_col; max_per_team)` - Maximise points, one-day (6 riders, cost <= 100, optional per-team cap)
- `build_model_stage(df, n, points_col, cost_col; max_per_team)` - Maximise points, stage race (9 riders, class constraints, optional per-team cap)
- `minimise_cost_stage(df, target_score, n, cost_col)` - Minimise cost for target score

### Betfair odds (src/betfair.jl)

- `betfair_login(; username, password, app_key)` - Authenticate with Betfair Exchange (reads from ENV by default)
- `betfair_get_market_odds(market_id)` - Fetch odds for a Betfair market, returns DataFrame(rider, odds, riderkey)

### Data scraping (src/get_data.jl)

- `get_cycling_oracle(prediction_url)` - Scrape Cycling Oracle blog predictions, returns DataFrame(rider, win_prob, riderkey)
- `getvgracelist(year)` - Scrape VG races.php for one-day classics, returns DataFrame(race_number, deadline, name, category, namekey)
- `getvgraceresults(year, race_number)` - Fetch VG race results via year-aware ridescore URL
- `match_vg_race_number(race_name, vg_racelist)` - Match a race name to VG race number using normalised string comparison
- `normalise_race_name(name)` - Normalise race names for cross-source matching (strips accents, hyphens, punctuation)

### Simulation (src/simulation.jl)

- `estimate_strengths(rider_df; ...)` / `estimate_strengths(data::RaceData; ...)` - Bayesian strength estimation pipeline. Returns DataFrame with `strength`, `uncertainty`, signal flags, signal shifts, and domestique penalty. Used by production solvers.
- `predict_expected_points(df, scoring; ...)` - Backward-compatible wrapper: calls `estimate_strengths` then runs MC simulation to compute `expected_vg_points`. Used by backtesting.
- `estimate_rider_strength(...)` - Bayesian posterior from uninformative prior (mean=0, variance=100), updated with PCS specialty (gated on `has_pcs`), VG, PCS form, PCS race history with variance penalties, VG race history, odds, oracle, qualitative intelligence. Trajectory signal removed. Variances accessed via functions: `pcs_variance(config)`, `odds_variance(config)`, etc. When odds are present for a race, non-market signal variances are inflated by `market_discount` (default 8.0) at the race level to prevent double-counting information already reflected in odds. Block-correlation discount groups signals into market/history/ability clusters with within-cluster ρ=0.5 and between-cluster ρ=0.15.
- `simulate_race(strengths, uncertainties; n_sims)` - Monte Carlo position simulation (used by backtesting)
- `compute_stage_race_pcs_score(row, class)` - Class-aware PCS blending for stage races

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

- `save_race_snapshot(df, data_type, pcs_slug, year)` - Permanently archive a DataFrame (e.g. odds, oracle) to `~/.velogames_archive/{data_type}/{pcs_slug}/{year}.feather`
- `load_race_snapshot(data_type, pcs_slug, year)` - Load archived data; returns `nothing` if not found
- `archive_path(data_type, pcs_slug, year)` - Compute the archive file path

### Backtesting (src/backtest.jl)

- `build_race_catalogue(years)` - Generate `BacktestRace` entries (with dates) from the classics race schedule
- `prefetch_all_races(races)` - Bulk pre-fetch data (PCS results, rider info, race history, VG race history, cumulative VG season points, archived odds/oracle/PCS specialty)
- `backtest_season(races; race_data, signals, ...)` - Evaluate predictions across all races
- `summarise_backtest(results)` - Convert results to summary DataFrame with aggregates
- `ablation_study(races; ...)` - Test 9 signal subsets to measure marginal signal value
- `tune_hyperparameters(races; ...)` - Random search over 5 parameters (3 scale factors + 2 decay rates) with cross-validation. Directional guidance, not precision tuning.
- `tune_domestique_discount(races; discounts, ...)` - Grid search over domestique discount values, optimising points_captured_ratio via backtest_season
- `BacktestResult` includes: rank metrics (Spearman ρ, top-N overlap), VG team metrics (actual scoring tables), and calibration diagnostics (z-scores, coverage rates)

## Prediction model

### Signal inventory

The strength model combines multiple signals grouped into three precision families. Effective variances are computed from base values, fixed within-group ratios, and tuneable scale factors. Accessor functions (e.g. `pcs_variance(config)`) compute the effective variance from the config.

**Active signals (after April 2026 ablation):**

| Signal | Source | Group | Base variance | Notes |
| ------ | ------ | ----- | ------------- | ----- |
| PCS seasons | `getpcsriderpts_batch()` | Ability | 7.9 | Z-scored across field. Best discriminator across all tiers (ρ=0.16–0.34). For stage races, class-aware blending via `STAGE_RACE_PCS_WEIGHTS` |
| VG season points | `getvgriders()` | Ability | 1.4×scale | Season-adaptive: `effective = vg_var * (1 + penalty * (1 - frac_nonzero))`. Strong for top-tier discrimination (ρ=0.287) |
| PCS race history | `getpcsracehistory()` | History | 3.0+decay/yr | Recency-weighted. Strong for bottom/middle tiers (ρ=0.23–0.25), weak for top (ρ=0.004) |
| Similar-race history | `getpcsracehistory()` | History | +penalty | Same as race history but with variance penalty. Races from `SIMILAR_RACES` terrain mapping |
| Betting odds | `getodds()` | Market | 0.3 | Strongest top-tier signal (ρ=0.464 for top 25%). Applied uniformly when odds are present |
| Odds floor | Derived (absence signal) | Market | var × 2.0 | When odds data exists but rider absent, floor observation from residual probability mass |
| Cycling Oracle | `get_cycling_oracle()` | Market | `_odds_to_oracle_ratio`/scale | Broader coverage than Betfair. Removal deferred: degrades middle-tier discrimination when combined with other changes. |

**Signals disabled by April 2026 ablation** (code retained for backtesting; data collection continues): PCS form score, VG race history, qualitative intelligence, trajectory.

Odds are converted to strength via log-odds relative to a uniform baseline. When odds are present for a race, non-market signal variances are inflated by `market_discount` (default 8.0) to prevent double-counting. Riders absent from the market receive a floor observation.

### Bayesian updating

Normal-normal conjugate model (`estimate_rider_strength()`). Each signal updates the posterior mean and variance. Missing data leaves the prior unchanged. Output: posterior mean (strength) and variance (uncertainty).

### Monte Carlo simulation

`simulate_race()` adds Student's t noise (df=5) scaled by posterior uncertainty to each rider's strength, then ranks to get finishing positions. Gaussian noise also supported via `simulation_df=nothing`.

### One-day vs stage race differences

| Aspect | One-day | Stage race |
| ------ | ------- | ---------- |
| PCS blending | Single specialty (e.g. one-day points) | Class-aware blend via `STAGE_RACE_PCS_WEIGHTS` |
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
- **Betfair Exchange** (betfair.com) — betting odds for win markets via Exchange API (optional, requires credentials)
- **Cycling Oracle** (cyclingoracle.com) — race predictions with win probabilities (optional, broader coverage than Betfair)

## Key patterns

- Per-race config in `data/race_config.toml` (gitignored, shared by render_predictor and render_assessor); `race_config.toml.example` is the committed template
- Analysis reports are standalone Julia scripts (`scripts/render_*.jl`) that generate HTML directly — no Quarto/pandoc dependency
- Public race reports site (`site/docs/`) generated by `scripts/render_reports.jl` with incremental build (skips existing HTML files)
- Betfair API credentials via environment variables (`BETFAIR_USERNAME`, `BETFAIR_PASSWORD`, `BETFAIR_APP_KEY`); Anthropic API key via `ANTHROPIC_API_KEY`; see `.envrc.example`
- All data functions use `cached_fetch()` with `CacheConfig` and `force_refresh` parameter
- Rider matching across sources uses `riderkey` (from `createkey()` name normalisation)
- Web scraping: `gettable()` -> `process_rider_table()` via HTTP/Gumbo/Cascadia; `scrape_html_tables()` parses `<table>` elements directly
- Optimisation: JuMP + HiGHS, binary variables for rider selection
- PCS URLs: `https://www.procyclingstats.com/race/{slug}/{year}`
- VG URLs: `https://www.velogames.com/{race-slug}/{year}/riders.php`
- One-day classics races share one VG URL per year: `sixes-classics/{year}/riders.php` (2026+) or `sixes-superclasico/{year}/riders.php` (≤2025), with startlist hash filtering
- Archival storage: `_prepare_rider_data` automatically archives odds/oracle/PCS specialty/qualitative data on successful fetch; solvers archive predictions after `estimate_strengths`; `archive_race_results` archives post-race PCS and VG results; `prefetch_race_data` loads archived data for backtesting
- Archival paths: `~/.velogames_archive/{data_type}/{pcs_slug}/{year}.feather` — data_type includes odds, oracle, pcs_specialty, vg_results, qualitative, predictions, pcs_results
- VG race URLs: `ridescore.php?ga={game_id}&st={race_number}` where game_id is from `vg_classics_game_id(year)`, `st` is race number 1-44 from races.php
- Backtesting temporal integrity: `estimate_strengths`/`predict_expected_points` accept `race_year`/`race_date` for correct recency weighting; cumulative VG season points prevent end-of-year leakage; archived PCS specialty scores prevent current-day leakage
- Production pipeline: `estimate_strengths` → `resample_optimise` (avoids Jensen's inequality bias from scoring floor at position 31+). Backtesting pipeline: `predict_expected_points` (MC simulation) for rank-based metrics.

## Commands

- Set up for a race: `cp data/race_config.toml.example data/race_config.toml` then edit
- Run predictor: `julia --project scripts/render_predictor.jl`
- Run team assessor: `julia --project scripts/render_assessor.jl`
- Run stage race predictor: `julia --project scripts/render_stagerace.jl`
- Run backtesting: `julia --project scripts/render_backtesting.jl`
- Generate race reports: `julia --project scripts/render_reports.jl` (add `--force` to regenerate all)
- Publish a race: `./scripts/publish_race.sh <pcs_slug> <year> "<winner>" <score>`
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

## Roadmap

See `roadmap.md` for known issues, planned improvements, ablation findings, and evidence base.
