# Velogames.jl

Fantasy cycling team optimisation for velogames.com. Scrapes rider data from Velogames and ProCyclingStats, estimates rider strength via Bayesian updating, and selects optimal teams using resampled optimisation (JuMP/HiGHS).

## Architecture

- `src/Velogames.jl` - Main module, includes and exports
- `src/get_data.jl` - Data scraping: VG riders, PCS rankings/specialty ratings, Oddschecker odds parsing, Cycling Oracle predictions, VG race results, VG race catalogue and per-race results
- `src/pcs_scraper.jl` - PCS table scraping infrastructure and column aliases
- `src/pcs_extended.jl` - Extended PCS scraping: race history results, startlists across multiple years
- `src/data_assembly.jl` - Shared data assembly: `RaceData` struct, `join_pcs_specialty`, `assemble_pcs_race_history`, `assemble_vg_race_history`, `assemble_season_vg_points` (mean VG points per round across other rounds of a season-long series — see "Season-round VG points" below), `prefetch_vg_racelists` (used by both production and backtesting pipelines). Also report data loading and post-race archival: `load_report_data`, `load_stage_race_report_data`, `load_stage_race_per_stage_data`, `list_completed_races`, `compute_cumulative_scores`, `compute_stage_type_scores`, `archive_stage_race_results`, `load_stage_profiles`, `load_league_standings` (reads the sibling `../vgleague` package's JSON cache, with `data/league_standings.toml` manual-paste fallback; consumed by `scripts/league_eval.jl` for cumulative league placement and entered-vs-advised deltas), `load_league_team` (the entered roster for one entrant and race from that same cache — see "Pulling the entered team from the league" below)
- `src/scoring.jl` - VG scoring tables by category (one-day Cat 1/2/3, stage race aggregate) and expected points functions
- `src/bayesian_core.jl` - `BayesianConfig` (3 precision scale factors — market, history, ability — with fixed within-group ratios) and variance accessors, `BayesianPosterior`/`StrengthEstimate`/`MultiDimPosterior`, `bayesian_update`, `bayesian_update_multidim_dim`, `multidim_prior`, and dimension tables (`STRENGTH_DIMENSIONS`, `SIGNAL_DIMENSION_WEIGHTS`, `RACE_HISTORY_CLASS_PROJECTION`). Block-correlation discount groups signals into the same 3 clusters.
- `src/strength_pipeline.jl` - Bayesian strength estimation (`estimate_strengths`): uninformative prior with PCS as observation, season-adaptive VG variance, class-aware PCS blending for stage races, domestique strength discount. Signal assembly (`RiderSignalData`, `AssembledSignals`, `_assemble_signals`), scalar + multidim estimators, and `predict_expected_points` (MC simulation) for backtesting. PCS form, qualitative and trajectory signals deleted (April 2026 ablation, code removed August 2026).
- `src/simulate_oneday.jl` - One-day Monte Carlo race simulation (`simulate_race`, `position_to_strength`, `position_probabilities`) and expected VG points (`expected_vg_points`, `breakaway_sectors_from_km`). `_score_vg_draw!` is the shared finish+assist+breakaway scoring rule used by both `expected_vg_points` (backtest) and `resample_optimise!` (production).
- `src/simulate_stage.jl` - Per-stage grand tour simulation (`simulate_stage_race`, `StageRaceDiagnostics`, `stage_dimension_weights`) and stage-type strength projection (`compute_stage_strengths`). The final mountains jersey is ranked by cumulative daily-KOM points. Attrition, the breakaway participation draw, and GC-favourite protection were deleted July 2026 (WP2.3: none moved team-points-captured on the backtest harness).
- `src/prior_checks.jl` - Prior predictive checks, sensitivity sweeps, and simulation-based calibration (SBC). Validates model behaviour by simulating from the generative process without historical data.
- `src/prospective_eval.jl` - Prospective evaluation: compares archived pre-race predictions against actual results. Computes Spearman rho, top-N overlap, signal value analysis.
- `src/build_model.jl` - JuMP optimisation models: `_build_team_model` (the shared budget knapsack) with the `build_model_oneday` (6 riders) / `build_model_stage` (9 riders + class constraints) wrappers over it, `resample_optimise!` (resampled optimisation that draws noisy strengths, scores VG points, and optimises per draw), `minimise_cost_stage`. Also hindsight-optimal / cheapest-winning team selection for report retrospectives (`compute_optimal_team`, `compute_cheapest_winning_team`, `compute_optimal_stage_team`, `compute_cheapest_winning_stage_team`)
- `src/race_solver.jl` - High-level solvers: `solve_oneday` and `solve_stage` (estimate strengths → resampled optimisation pipeline, returns top teams). Fetch-free prediction cores `_oneday_prediction_core`/`_stage_prediction_core` (estimate_strengths → resample_optimise, no I/O or archival) are shared by the production solvers and the backtest champions. Also archives predictions for prospective evaluation, and provides `archive_race_results` for post-race archival.
- `src/cache_utils.jl` - Feather-based caching with configurable TTL (default ~/.velogames_cache, 7 days), plus permanent archival storage (`DEFAULT_ARCHIVE_DIR`, ~/Dropbox/code/velogames/archive) for odds/oracle snapshots
- `src/race_helpers.jl` - `RaceInfo` struct (canonical race metadata), `RaceConfig` struct, `setup_race()`, `RenderConfig` / `load_render_config()` (the single typed object every renderer takes — see "Render configuration" below), `all_races()` (the 44 classics + 11 stage races as one catalogue), URL alias lookup, `CLASSICS_RACES_2026` schedule, `SIMILAR_RACES` (derived from `RaceInfo`), year-aware VG slug/URL/game ID functions
- `src/utilities.jl` - Name normalisation (`normalisename`), key creation (`createkey`), sentinel constants (`DNF_POSITION`, `UNRANKED_POSITION`), and report/display utilities (`suppress_output`, `clean_team_names!`, `round_numeric_columns!`)
- `src/backtest.jl` - Backtesting framework: race catalogue, season-level evaluation, calibration diagnostics, VG race history integration, cumulative VG season points, PCS specialty archiving. Stage-race harness: `prefetch_stage_race_data` (as-of-race-day grand tour reconstruction into `StageRaceBacktestData`), `backtest_stage_race` (team-points-captured + rank metrics for `:simulator`/`:persistence`/`:odds` or custom predictors; targets `:vg_total`/`:gc`/`:points`/`:kom`), `champion_evg` (full production stack as a predictor), `crosscheck_option_ab` (Option A/B drift alarm: pass vs a pinned post-WP2.3 baseline ±0.03, historical roadmap values carried as `rec_*`). Both harnesses score team-points-captured through one shared core: `GameFormat` (team size, model function, name, predictor table) + `_score_team_points_captured`, so the two cannot drift apart — a divergence there would be invisible, producing plausible numbers rather than an error. The top-N overlap column is named for the team size (`overlap6` / `overlap9`). One-day harness: `prefetch_oneday_backtest_data` (as-of-race-day classic reconstruction into `OneDayBacktestData`, scoring against TRUE scraped `vg_results` totals incl. assist/breakaway, not the finish-only proxy of `backtest_race`), `backtest_oneday_race`/`backtest_oneday_season` (team-points-captured + rank metrics for `:simulator` (`champion_oneday_evg`, runs `_oneday_prediction_core`)/`:simulator_market` (`champion_oneday_market_evg` — the shipped market-blended rule, marketed editions only)/`:odds`/`:maxcost` or custom `name => f` predictors)
- `src/report_html.jl` - HTML page generation primitives (`html_page`, `html_table`, `html_callout`, `html_heading`, `plotly_html`, `_slugify`, `commafmt`, `write_report`)
- `src/report_charts.jl` - SVG/Plotly chart functions (PIT histograms, scatter plots, rank histograms, line charts, team totals, sim distributions), `compute_pit_values`, `simulate_vg_draws`
- `src/report_formatters.jl` - Signal/classification/podium table formatters (`format_signal_waterfall`, `format_classification_table`, `format_stage_podium_picks`, per-dim helpers), `precision_budget`, `format_near_optimal_section` (team switcher + core/filler + structural forks) and `format_rankings_and_alternatives` (full rankings + best-value/upside/budget picks) — the last two are shared verbatim by both prediction reports
- `scripts/render_predictor.jl` - One-day prediction report: reads `race_config.toml`, runs prediction pipeline, writes `prediction_docs/predictor.html` (`[output] dir` overrides)
- `scripts/render_assessor.jl` - Team assessor report: compares custom team vs optimal, retrospective analysis, writes `prediction_docs/assessor.html` (`[output] dir` overrides)
- `scripts/render_stagerace.jl` - Stage race prediction report: reads `race_config.toml`, runs stage race pipeline, writes `prediction_docs/stagerace.html` (`[output] dir` overrides)
- `scripts/render_backtesting.jl` - Backtesting and calibration report: prior checks, historical backtest, prospective evaluation, writes `prediction_docs/backtesting.html` (`[output] dir` overrides)
- `scripts/render_reports.jl` - Public race reports site: generates per-race HTML retrospectives to `site/docs/`, incremental build (skips existing)
- `scripts/league_eval.jl` - Offline league evaluation: scores archived model teams against realised VG points, the hindsight-optimal team, and max-cost / odds-implied baselines, then reports cumulative league placement and the entered-vs-advised delta from the `[league]` config. Its placement section matches standings race names against `CLASSICS_RACES_2026`, so it is classics-shaped — a grand tour league's per-stage race names will not resolve.
- `scripts/baseline_compare.jl` - Naive-persistence yardstick for grand tours: mean VG points across the two prior Tours, fed through `build_model_stage`, set beside the model's archived optimal team
- `scripts/auto_publish.jl` / `scripts/auto_publish.sh` - **The** publishing path for one-day races: derive each race's league winner from the `vgleague` snapshot instead of typing it, record it in the archive, render and deploy. See "Unattended publishing" below
- `scripts/publish_stage_race.sh` - The one manual publishing path, for grand tours only (see "Unattended publishing" for why they are excluded from the automatic one)
- `scripts/deploy_site.sh` - Upload `site/docs/` to Netlify from disk. The single deploy step every publish path goes through
- `data/race_config.toml` - Shared per-race configuration (gitignored); `race_config.toml.example` is the committed template. Sections: `[race]`, `[output]`, `[data_sources]`, `[optimisation]`, `[team_assessor]`, `[league]`, `[entered_team]`

## Key functions

### Render configuration (src/race_helpers.jl)

- `load_render_config(path=data/race_config.toml; fresh=false) -> RenderConfig` - The one place TOML key names appear. Parses the file, builds the `RaceConfig` via `setup_race`, **parses the odds paste files into DataFrames**, and validates. Every renderer takes the resulting object and nothing else.
- `RenderConfig` wraps `race::RaceConfig` plus every render-time knob: output dir, the three oracle URLs, four parsed odds frames, `season_round_slugs`, the optimisation settings, `vg_race_number`, `my_team`, `breakaway_dir`, `fresh`. Odds are stored **parsed rather than as filenames**, which is what stops a renderer silently skipping a market it never read.
- Why one object: `RaceConfig` already derived `team_size` correctly from race format while a parallel untyped TOML `Dict` supplied everything else by hand, and the two drifted — `render_assessor`'s fresh-solve path was passing a strict subset of the kwargs `render_stagerace` passed, so its "fresh" prediction silently differed. Consolidating fixed that by construction.
- `all_races() -> Vector` of `(slug, name, type)` across the 44 classics and 11 stage races. Used by the web frontend's race picker; its absence is why `league_eval.jl` once reached into `Velogames._find_race_by_slug`.
- An unrecognised race name **throws** (listing near-matches) rather than warning and fabricating a URL.

### Pulling the entered team from the league (August 2026)

`[team_assessor] use_league_team = true` makes `_resolve_my_team` fill `my_team`
from the `vgleague` scrape of the `[league]` section, via `load_league_team`,
instead of the hand-typed list. Exposed as a checkbox in `scripts/serve.jl`'s
Team assessor fieldset.

- **Velogames publishes rosters only after the entry deadline**, so before the
  race the pull legitimately returns nothing. It warns and falls back to the
  typed `my_team` rather than silently handing the assessor an empty team.
- League race names are matched to `pcs_slug` through `CLASSICS_RACES_2026`,
  which carries the VG display names — all 43 scraped 2026 names resolve, so no
  fuzzy fallback is needed.
- Grand tour snapshots record the same locked roster against every stage, so
  `pcs_slug` is ignored there and the latest stage's roster is returned. This
  means the `[league]` `game_slug`, not the race, decides which GT is read.

### Unattended publishing (August 2026)

One-day races publish themselves, with nobody at the keyboard and nothing
written to git. The winner name and score a human used to type are already in
the `vgleague` snapshot — just `argmax(score)` over that race's entrants — so
`scripts/auto_publish.jl` derives them, appends every `[[winners]]` entry the
scrape has that the archive's record lacks, and the wrapper renders and
deploys. Triggered by `POST_UPDATE_HOOK` in the `vgleague` deploy clone's
`.env`, which both of that repo's launchd jobs run after fresh data lands.

- **It waits 24h after the pick deadline** (`--min-age-hours`). Velogames
  revises scores after a race and the record is append-only, so a wrong winner
  published the same evening has to be unpicked by hand. The `local_update.sh`
  backstop, not the probe, is what fires a deferred publish: `local_check.sh`
  exits at "nothing due, no new code" *before* it reaches the hook, so on a
  quiet day the hook never runs from the hourly job at all.
- **A race already rendered without a winner gets its HTML deleted** before the
  build. `render_reports.jl` skips existing files, so appending alone would
  leave the winner-less page up for ever.
- **Grand tours are skipped** — `league_race_slug` returns `""` for a stage
  name, which is the gate. They publish through `publish_stage_race.sh`, one
  entry per tour rather than per stage.
- **Nothing writes to git.** The only git operation is the `--ff-only` pull
  that fetches the code about to run. That is what the winners record moving to
  the archive bought: no commit, no push, no dirty-tree guard, and no way for a
  git failure to keep a report offline or wedge the next run.

### Site deployment (August 2026)

`site/docs/` is **build output, not source**: gitignored, rendered by
`render_reports.jl`, uploaded by `scripts/deploy_site.sh` (`netlify deploy
--prod --dir=site/docs`, credentials from a gitignored `.env`). It was tracked
until the move off GitHub Pages, which could only publish what was in the repo —
so every race cost a push of megabytes of generated HTML, and the unattended
publish could not run without git succeeding.

`league_winners.toml` followed it out of the repo, to
`DEFAULT_ARCHIVE_DIR/league_winners.toml` (`league_winners_path`,
`load_league_winners`, `append_league_winner` in `cache_utils.jl` are the only
things that know that path).

- Every entry in it is 2026 and, in principle, re-derivable from the vgleague
  snapshots — but those live in a gitignored, machine-local `data/` dir that
  nothing backs up, so this file is the durable record. (There are **no** 2025
  entries: all 43 of those reports render without a league winner.)
- Grand tour winners are derivable from the same snapshots and the names match,
  but the recorded scores don't: Giro 8351 vs 8359 scraped, Tour 11884 vs
  11880, Femmes 4382 both. `scored_races = []` for those leagues, so it is not
  a scoring filter. Unexplained — which is why `auto_publish.jl` still skips
  grand tours rather than deriving them.
- Keeping it in git was never what made the site rebuildable, whatever the old
  README said: `list_completed_races` scans `DEFAULT_ARCHIVE_DIR/vg_results/`,
  so a clone without the Dropbox archive renders nothing at all.
- `deploy_site.sh` refuses to deploy when `site/docs/index.html` is missing.
  Pulling the commit that untracked these files **deletes them from every
  existing clone**, so a deploy from a clone that hasn't re-rendered would have
  replaced the live site with an empty one.

### Solvers (src/race_solver.jl)

- `solve_oneday(rc::RenderConfig)` / `solve_stage(rc::RenderConfig, stages, stage_scoring)` - **What the renderers call.** Forwarding methods that unpack every knob from one config object; the kwarg forms below stay for the backtest harness, which legitimately varies knobs one at a time.
- `solve_oneday(config; ..., market_blend_weight=1.0)` - Resampled optimisation pipeline for one-day classics. Returns `(predicted, chosenteam, top_teams)`. `market_blend_weight < 1` blends the bookmaker market into the final team pick (see "Market blend" below); `race_config.toml` supplies 0.5.
- `solve_stage(config; ..., season_round_slugs=String[])` - Resampled optimisation pipeline for stage races (class constraints). Returns `(predicted, chosenteam, top_teams)`. `season_round_slugs` supplies the VG slugs of the other rounds of a season-long series (see "Season-round VG points" below); `race_config.toml`'s `[data_sources]` provides it.
- `archive_race_results(pcs_slug, year; vg_race_number)` - Fetch and archive PCS results and VG results for a completed race. Idempotent.

### Optimisation models (src/build_model.jl)

- `resample_optimise!(df, scoring, build_model_fn; team_size, n_resamples=500, max_per_team, n_alternatives=20, market_probs, market_blend_weight=1.0)` - Draw noisy strengths from posterior, score VG points, tally per-draw selection frequency, then optimise on risk-adjusted expected points. Returns `(df, top_teams)` where df gains `:selection_frequency` and `:expected_vg_points`, and `top_teams` is a `Vector{DataFrame}` of the `n_alternatives` best distinct teams ranked best-first (k-best enumeration via iterated no-good cuts; `top_teams[1]` is the optimal team). Both report types use this near-optimal set for the team switcher, filler pool, and structural-fork analysis.
- `market_win_probs(odds_df, riderkeys)` / `blend_market_points(pts, market_probs, w)` - Implied win probability (`1/max(odds, 1.01)`, 0 for unpriced riders; empty when there is no market) and the unit-normalised blend `w·unitnorm(pts) + (1−w)·unitnorm(probs)`. Both arms MUST be unit-normalised — a knapsack is invariant to scaling one column but not to mixing two on different scales. `DEFAULT_MARKET_BLEND_WEIGHT` (0.5) is the single source for the shipped weight — the config default and the harness's `simulator_market` arm both read it, so they cannot drift apart.
- `build_model_oneday(df, n, points_col, cost_col; max_per_team, exclude, force_in, force_out)` - Maximise points, one-day (6 riders, cost <= 100, optional per-team cap). `exclude` adds no-good cuts (k-best); `force_in`/`force_out` pin riders (structural forks).
- `build_model_stage(...)` - Same, stage race (9 riders + VG class minimums). Both are thin wrappers over `_build_team_model(...; classes)` — the class constraint is the *only* structural difference between the two games' knapsacks. Keep them as separate named functions: they are passed around as `build_model_fn` values and carry the right team size.
- `compute_filler_pool(top_teams)` / `compute_structural_forks(predicted, build_model_fn; team_size, max_per_team, points_col=:expected_vg_points, n_forks=5)` - Decompose the k-best set into locked core + interchangeable filler pool, and rank the highest-EVG either/or roster decisions (drop-a-rider deltas + the both-GC-leaders-vs-one structural fork, the latter only when `:strength_gc` is present). Returns `best_obj` alongside, so the report can print each delta as a share of the team total. Rendered by `format_near_optimal_section` (report_formatters.jl) from **both** renderers. `points_col` must be the column the team was actually picked on — `:market_blend_points` on the one-day path when the blend is live — or the forks describe a different roster from the one displayed.
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
- `estimate_rider_strength(...)` - Bayesian posterior from uninformative prior (mean=0, variance=100), updated with PCS specialty (gated on `has_pcs`), VG season points, PCS race history with variance penalties, odds and oracle. VG race history is applied by the multi-dim (stage-race) estimator only. Variances accessed via functions: `pcs_variance(config)`, `odds_variance(config)`, etc. When odds are present for a race, non-market signal variances are inflated by `market_discount` (default 8.0) at the race level to prevent double-counting information already reflected in odds. Block-correlation discount groups signals into market/history/ability clusters with within-cluster ρ=0.5 and between-cluster ρ=0.15.
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
| VG season points | `getvg_riders()`, or `assemble_season_vg_points()` when this game's own `points` is all zeros | Ability | 1.4×scale | Season-adaptive: `effective = vg_var * (1 + penalty * (1 - frac_nonzero))`. Strong for top-tier discrimination (ρ=0.287) |
| PCS race history | `getpcs_race_history()` | History | 3.0+decay/yr | Recency-weighted. Strong for bottom/middle tiers (ρ=0.23–0.25), weak for top (ρ=0.004) |
| Similar-race history | `getpcs_race_history()` | History | +penalty | Same as race history but with variance penalty. Races from `SIMILAR_RACES` terrain mapping |
| Betting odds | `parse_oddschecker_odds()` | Market | 0.3 | Strongest top-tier signal (ρ=0.464 for top 25%). Applied uniformly when odds are present |
| Odds floor | Derived (absence signal) | Market | var × 2.0 | When odds data exists but rider absent, floor observation from residual probability mass |
| Cycling Oracle | `get_cycling_oracle()` | Market | `_odds_to_oracle_ratio`/scale | Broader coverage than bookmaker odds. Removal deferred: degrades middle-tier discrimination when combined with other changes. |

**Removed by the April 2026 ablation and deleted from the codebase in August 2026**: PCS form score, qualitative intelligence, trajectory. VG race history was dropped from the scalar one-day estimator only — the multi-dim stage-race estimator still consumes it, which is why `RiderSignalData` keeps `vg_race_history`.

### Season-round VG points (stage races, July 2026)

Single-race VG games — the Femmes/GT format, and each round of the Velogames
Womens Cycling Championship — open with `points` at zero for the whole field,
which z-scores to a constant and switches the VG-season signal off. When
`[data_sources] season_round_slugs` is set and the column is all zeros,
`_prepare_rider_data` substitutes each rider's **mean points per scored round**
across those other rounds (`assemble_season_vg_points`).

Three things that matter:

- **Mean, not sum.** Rounds-ridden is negatively rank-correlated with strength
  (ρ = −0.28 vs the market on the 2026 Femmes field), so a total scores volume.
- **Rounds with no scores yet are skipped.** `ridescore.php` serves the full
  roster at zero for an unridden round; counting it would deflate exactly the
  riders entered in the most upcoming rounds.
- **Uncovered riders get the covered-field mean, and `:vg_points_observed`
  records who was actually observed.** The mean-fill makes absence neutral
  (z = 0) instead of reading as weakness; the flag stops `frac_nonzero` seeing a
  fully-substituted column as full season coverage and cancelling the
  `vg_season_penalty` variance widening. The substitution runs *after* every row
  filter, so the fill value is the mean of the frame that is actually z-scored.

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
| Market blend | `market_blend_weight` (0.5) mixes the market into the final pick | Not blended — only 2 marketed GT editions, nowhere near enough evidence |
| Near-optimal set | Same section, `build_model_oneday`, no GC-leader fork | Team switcher, core/filler split, structural forks incl. the GC-leader fork |

### Market blend (one-day only, July 2026)

When a one-day race has bookmaker odds and `market_blend_weight < 1`, the final
team optimisation maximises `w·unitnorm(risk-adjusted EVG) + (1−w)·unitnorm(implied win prob)`
instead of risk-adjusted EVG alone, and `predicted` gains a `:market_blend_points`
column. Applied in `_resample_core!`, *after* the risk adjustment, so `w = 1`
is bit-identical to the unblended path. Marketless races are unaffected at any `w`.

Evidence: +0.079 team-points-captured over the unblended simulator on the 12
marketed 2026 classics (0.572 → 0.651), CI [+0.028, +0.136], 7 wins / 0 losses.
It does **not** clearly beat odds alone (+0.024, CI includes zero) — that weaker
claim is what justifies simulating marketed classics at all, and it is not
established.

**Pre-registered revert trigger: back the blend out if `simulator_market` −
`simulator_risk` falls below +0.02 on the 2027 classics.** Against
`simulator_risk`, not `simulator`: the blend is applied on top of the
risk-adjusted column, so differencing against the unadjusted arm bundles the
risk adjustment into the measured effect. The quoted +0.079 is the
`simulator` difference (what the experiment reported); the harness now renders
both, paired on the editions where each arm produced a row — arms cover
different edition sets, so subtracting the summary means is not a valid
comparison. See `roadmap.md` "SHIPPED: one-day market blend".

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
| `max_per_team` | 2 | A **diversification preference, not a Velogames rule** — so it does not derive from race format. Both formats race under the same cap, and the backtest harness defaults to the same 2 so its metric matches production |

### Data sources

- **Velogames** (velogames.com) — rider rosters, costs, season points, classifications, ownership %, historical race results, per-stage results
- **ProCyclingStats** (procyclingstats.com) — specialty ratings, rankings, race results, startlist quality, form scores, stage profiles (ProfileScore, vertical metres, gradient)
- **Bookmaker odds** — betting odds pasted from Oddschecker or any bookmaker winner market into `oddschecker_paste.txt`
- **Cycling Oracle** (cyclingoracle.com) — race predictions with win probabilities (optional)

## Key patterns

- Per-race config in `data/race_config.toml` (gitignored, shared by all three renderers); `race_config.toml.example` is the committed template. It is read **only** through `load_render_config` — no renderer parses TOML itself, and no solver call site hand-assembles kwargs
- Analysis reports are standalone Julia scripts (`scripts/render_*.jl`) that generate HTML directly — no Quarto/pandoc dependency. Each exposes `render_<name>(rc::RenderConfig) -> output_path` guarded by `abspath(PROGRAM_FILE) == @__FILE__`, so `scripts/serve.jl` can `include` them once and call them per request. A renderer given the wrong race format throws
- Public race reports site (`site/docs/`) generated by `scripts/render_reports.jl` with incremental build (skips existing HTML files), gitignored, deployed to Netlify by `scripts/deploy_site.sh`
- All data functions use `cached_fetch()` with `CacheConfig` and `force_refresh` parameter
- Rider matching across sources uses `riderkey` (from `createkey()` name normalisation)
- Web scraping: `gettable()` -> `process_rider_table()` via HTTP/Gumbo/Cascadia; `scrape_html_tables()` parses `<table>` elements directly
- Optimisation: JuMP + HiGHS, binary variables for rider selection
- One-day and stage-race paths are deliberately shared where the difference is incidental (`_build_team_model`, `_score_team_points_captured`, `format_rankings_and_alternatives`, `format_near_optimal_section`) and deliberately separate where it is real (`_oneday_prediction_core` vs `_stage_prediction_core` — one simulates a single race, the other 21 correlated stages). When touching one twin, check whether the other is meant to follow
- PCS URLs: `https://www.procyclingstats.com/race/{slug}/{year}`
- VG URLs: `https://www.velogames.com/{race-slug}/{year}/riders.php`
- One-day classics races share one VG URL per year: `sixes-classics/{year}/riders.php` (2026+) or `sixes-superclasico/{year}/riders.php` (≤2025), with startlist hash filtering
- Archival storage: `_prepare_rider_data` automatically archives odds/oracle/PCS specialty data on successful fetch; solvers archive predictions after `estimate_strengths`; `archive_race_results` archives post-race PCS and VG results; `prefetch_race_data` loads archived data for backtesting
- Archival paths: `{DEFAULT_ARCHIVE_DIR}/{data_type}/{pcs_slug}/{year}.feather` (DEFAULT_ARCHIVE_DIR = ~/Dropbox/code/velogames/archive) — data_type includes odds, oracle, pcs_specialty, vg_results, predictions, pcs_results. Prediction archives always write `riderkey, rider, team, cost, chosen, selection_frequency, expected_vg_points` plus `schema_version` (archiving throws if any is missing); readers warn on legacy pre-April-2026 archives, which cannot be re-created
- VG race URLs: `ridescore.php?ga={game_id}&st={race_number}` where game_id is from `vg_classics_game_id(year)`, `st` is race number 1-44 from races.php
- Backtesting temporal integrity: `estimate_strengths`/`predict_expected_points` accept `race_year`/`race_date` for correct recency weighting; cumulative VG season points prevent end-of-year leakage; archived PCS specialty scores prevent current-day leakage
- Production pipeline: `estimate_strengths` → `resample_optimise!` (avoids Jensen's inequality bias from scoring floor at position 31+). Backtesting pipeline: `predict_expected_points` (MC simulation) for rank-based metrics.

## Commands

- Set up for a race: `cp data/race_config.toml.example data/race_config.toml` then edit
- Run predictor: `julia --project scripts/render_predictor.jl`
- Run team assessor: `julia --project scripts/render_assessor.jl`
- Run stage race predictor: `julia --project scripts/render_stagerace.jl`
- Run backtesting: `julia --project scripts/render_backtesting.jl`
- Local web frontend: `julia --project scripts/serve.jl [--port 8080]`, then open `http://localhost:8080`. Serves a format-adaptive config form, writes `data/race_config.toml`, runs the chosen renderer in-process and serves the report. Long-lived, so it pays the package load and JIT once — but nothing caches the resampled optimisation, so each render is a full solve. Every control carries hover help. Served reports get a back-to-form / re-run bar injected on the way out (never written to the report file, so published reports are unaffected). **`TOML.print` strips comments**: the first save copies the hand-written file to `data/race_config.toml.backup`. A `/render` POST rewrites the config only when it carries the form's hidden `form=1` marker — the bar's Re-run button omits it and so re-runs the config as it stands, rather than reading its absent fields as cleared ones.
- Generate race reports: `julia --project scripts/render_reports.jl` (add `--force` to regenerate all)
- Publish every one-day race the league has scored: `./scripts/auto_publish.sh` (add `--dry-run` to see what it would do). Normally runs itself from the vgleague hook; see "Unattended publishing" above
- Publish a grand tour: `./scripts/publish_stage_race.sh <pcs_slug> <year> "<winner>" <score>`. The only manual path left, and the only one that takes a hand-typed winner
- Correct a published winner: edit `DEFAULT_ARCHIVE_DIR/league_winners.toml`, `rm site/docs/reports/<slug>-<year>.html`, then `julia --project scripts/render_reports.jl && ./scripts/deploy_site.sh`. The record is append-only and the build skips existing HTML, so both halves are needed
- Deploy the site without publishing a race (template or style change): `julia --project scripts/render_reports.jl --force && ./scripts/deploy_site.sh`
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
