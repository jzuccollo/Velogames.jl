# Velogames.jl

Fantasy cycling team optimisation for velogames.com. Scrapes rider data from Velogames and ProCyclingStats, estimates rider strength via Bayesian updating, and selects optimal teams using resampled optimisation (JuMP/HiGHS). See `roadmap.md` for architecture decisions, known issues, and validation philosophy.

## Modules

**Data:** `get_data.jl` (scraping), `pcs_scraper.jl` (PCS infra), `data_assembly.jl` (assembly), `completeness.jl` (archive quality), `cache_utils.jl` (caching & archival)

**Model:** `bayesian_core.jl` (Bayesian config, 3 precision scales: market/history/ability), `strength_pipeline.jl` (strength estimation), `simulate_oneday.jl` (1-day MC), `simulate_stage.jl` (stage race sim)

**Optimisation:** `build_model.jl` (JuMP knapsack, lexicographic tiebreaking), `race_solver.jl` (high-level solvers), `backtest.jl` (backtesting harness)

**Reporting:** `report_html.jl`, `report_charts.jl`, `report_formatters.jl`

**Config & utilities:** `race_helpers.jl` (RaceInfo/RaceConfig/RenderConfig), `utilities.jl` (name normalisation, sentinel constants)

**Scripts:** `render_predictor.jl` (one-day), `render_assessor.jl` (team assessment), `render_stagerace.jl` (grand tours), `render_backtesting.jl` (validation), `render_reports.jl` (retired), `league_eval.jl` (offline eval), `ingest.jl` (PCS archival), `ingest_league.jl`, `auto_publish.jl/sh` (unattended publishing), utility scripts for archival maintenance

## Key functions

**Render config:** `load_render_config()` (one typed object all renderers take, parses TOML + odds), `all_races()`, `setup_race()`

**Strength:** `estimate_strengths()` (Bayesian pipeline), `estimate_rider_strength()` (scalar), `estimate_rider_strength_multidim()` (stage races), `predict_expected_points()` (MC simulation for backtesting)

**Simulation:** `simulate_race()` (one-day MC), `simulate_stage_race()` (per-stage, correlated noise, stage-type weights)

**Optimisation:** `resample_optimise!()` (draw strengths → score VG → optimise on risk-adjusted EVG), `build_model_oneday()` (6 riders), `build_model_stage()` (9 riders + class constraints), `compute_structural_forks()`, `compute_filler_pool()`

**Solvers:** `solve_oneday()`, `solve_stage()` (estimate strengths → resampled optimisation → top teams). Fetch-free cores `_oneday_prediction_core` / `_stage_prediction_core` shared by production and backtest.

**Archival:** `save_race_snapshot()`, `load_race_snapshot()`, `archive_path()`, `ARCHIVE_TYPES` (27 types, typed boundary), `audit_archive()`, `atomic_write()`

**Backtesting:** `build_race_catalogue()`, `backtest_season()`, `backtest_oneday_race()`, `backtest_stage_race()`, game-format abstraction prevents one-day/stage-race harnesses from drifting

## Architecture facts

- **Rendering is archive-only**: nothing fetches during a render. Odds/oracle/PCS specialty archived on prediction, PCS/VG results archived as separate phase (`scripts/ingest.jl`).
- **Publishing is unattended**: vgleague ingest → ingest_league.jl → derive winners → render → deploy. No git writes.
- **League data lives in archive**: `league/raw` (dated snapshots), `league/rosters` (entrant × race × rider), `league/winners` (derived)
- **Velogames blocks Julia**: all VG pages return 403 to HTTP clients. Only `vgleague ingest` (Python+Playwright) can fetch. Use `load_vg_*` functions to read archived pools instead.
- **Archive uses Arrow IPC**: `.arrow` extension, 27 typed data types in `ARCHIVE_TYPES`, typed boundary catches drift. Path: `{archive_dir()}/{data_type}/{key}/{year}.arrow`. See `docs/data-dictionary.md` for types.
- **Atomic archive writes**: `atomic_write()` via temporary dot-prefixed file prevents half-written files. Used by `save_race_snapshot`, `save_league_snapshot`, `write_archive_manifest`.
- **Cross-solver consistency**: One-day and stage-race harnesses shared via `GameFormat` abstraction + `_score_team_points_captured` to prevent drift.
- **Model: 3 precision scale factors**: market/history/ability, fixed within-group correlation (0.5), between-group (0.15). Accessor functions (`pcs_variance()`, `odds_variance()`) compute effective variances from config.
- **Lexicographic optimisation**: tiebreaking ensures reproducible team output across solvers (optimal = max score then min cost; cheapest-winning = min cost then max score).
- **Market blend (one-day only)**: when odds present, blend market win probs with risk-adjusted EVG. 0.5 default weight. Evidence: +0.079 team-points vs unblended on 12 marketed 2026 classics.
- **RenderConfig is the typed boundary**: one object wraps race config, all knobs, parsed odds. Every renderer takes this and nothing else.
- **Per-race config**: `data/race_config.toml` (gitignored). Sections: `[race]`, `[output]`, `[data_sources]`, `[optimisation]`, `[team_assessor]`, `[league]`, `[entered_team]`.

## Model basics

**Signals:** PCS seasons (ability), VG season points (ability), PCS race history (history, recency-weighted), similar-race history (history + penalty), betting odds (market, strongest for top 25%), Cycling Oracle (market).

**Parameters:** `market_precision_scale=4.0`, `history_precision_scale=2.0`, `ability_precision_scale=1.0`, `within_cluster_correlation=0.5`, `between_cluster_correlation=0.15`, `hist_decay_rate=3.2`, `market_discount=8.0` (uniform when odds present).

**Bayesian update:** Normal-normal conjugate model. Each signal updates posterior mean/variance. Missing data leaves prior unchanged. Output: strength (mean) + uncertainty (variance).

**Monte Carlo:** `simulate_race()` adds t-distributed noise (df=5) scaled by uncertainty, ranks to positions. Gaussian also supported via `simulation_df=nothing`.

**One-day:** 6 riders, single-race simulation, one PCS specialty per rider, market blend when odds present (0.5 weight). Stage race: 9 riders, per-stage simulation, cross-stage correlated noise (α=0.7), multi-dim strength estimates (PCS per specialty routed via `SIGNAL_DIMENSION_WEIGHTS`).

**Season-round VG points:** When `[data_sources] season_round_slugs` set and field is all zeros, use mean VG points per scored round across those rounds. Uncovered riders get field mean; `:vg_points_observed` flag stops variance inflation.

**Data sources:** Velogames (rider rosters, costs, points, results), ProCyclingStats (specialty, rankings, race results, profiles), Oddschecker odds paste, Cycling Oracle predictions.

## Patterns

- **Config:** Read `data/race_config.toml` **only** via `load_render_config()`. No renderer parses TOML directly.
- **Renderers:** Standalone scripts (`render_*.jl`) with `render_<name>(rc::RenderConfig)` signature, guarded by `abspath(PROGRAM_FILE) == @__FILE__`. `serve.jl` includes once and re-calls per request.
- **Rider matching:** `riderkey` from `createkey()` normalisation. Used for joins across PCS/VG/odds.
- **Caching:** All data functions use `cached_fetch()` with `CacheConfig` and `force_refresh` kwarg.
- **Optimisation:** JuMP + HiGHS, lexicographic tiebreaking. Knapsack constraint: cost ≤ 100, max 2 per team (both formats), + class constraints for stage races.
- **Shared infra:** One-day and stage-race code shares `_build_team_model`, `_score_team_points_captured`, `format_rankings_and_alternatives`, `format_near_optimal_section`. Separate: `_oneday_prediction_core` vs `_stage_prediction_core`.
- **Archival:** `_prepare_rider_data` archives odds/oracle/PCS specialty on fetch. Solvers archive predictions. `archive_race_results()` skips existing unless `force_refresh`. Render path archives nothing; ingest phase does it all.
- **Temporal integrity:** `estimate_strengths` takes `race_year`/`race_date` for recency weighting. VG cumulative prevents end-of-year leakage. Archived PCS specialty prevents current-day leakage.
- **Pipeline:** Production: `estimate_strengths` → `resample_optimise!`. Backtest: `predict_expected_points` (MC simulation).
- **Public site:** Built by `vgleague build` (Python), deployed from vgleague clone. Covers 2023–2026. `site/docs/` (Julia) is retired and not deployed.

## Commands

**Setup & rendering:**
- `cp data/race_config.toml.example data/race_config.toml` then edit
- `julia --project scripts/render_predictor.jl`, `render_assessor.jl`, `render_stagerace.jl`, `render_backtesting.jl`
- `julia --project scripts/serve.jl [--port 8080]` — config form + in-process rendering

**Ingestion & publishing:**
- `julia --project scripts/ingest.jl --race=<slug> --year=<yyyy>` — fetch and archive one race
- `julia --project scripts/ingest.jl --pending` — every unsettled race
- `./scripts/auto_publish.sh [--dry-run]` — ingest league, derive winners, ingest races (runs from vgleague hook before build)
- `./scripts/auto_publish.sh --redrive=<pcs_slug>` — correct a recorded winner
- `julia --project scripts/ingest_league.jl [--force] [--dry-run]` — take league snapshot into archive

**Cross-language checks (from vgleague clone):**
- `vgleague verify-keys <league>`, `verify-races`, `verify-results`, `verify-field`, `verify-report`, `verify-dossier`

**Archival & evaluation:**
- `julia --project scripts/archive_audit.jl [--write-manifest] [--check]` — audit & export archive manifest
- `julia --project scripts/league_eval.jl` — offline league evaluation vs archive (point `vgleague_data_dir` at deploy clone)
- `julia --project scripts/field_digest.jl`, `report_dump.jl` — cross-language check halves

**Tests:** `julia --project -e "using Pkg; Pkg.test()"`

## Style

- Julia: snake_case for functions, PascalCase for types
- British English (optimise, normalise, colour)
- New data functions must support `CacheConfig` parameter
- Cat 1 = monuments + worlds + Amstel Gold; Cat 2 = WT classics; Cat 3 = semi-classics

**Keep it simple:** No defensive coding, delete don't deprecate, minimal error handling, no boilerplate. This is a small personal package.

**Validating changes:** Match rigour to effect size × mechanistic clarity, not N races (cycling has ~3 GTs/year). Ship large changes on theory + directional checks + pre-registered triggers. Judge EVG changes on PIT/team-points-captured (rank ρ is invariant). See `roadmap.md`.

**Roadmap:** See `roadmap.md` for known issues, ablation findings, architecture decisions, validation results.
