# Velogames.jl

Hacky, personal Julia package to pick a Velogames team. Always in progress, always a bit broken, no guarantees it'll work anywhere else!

## Approach

Estimate expected Velogames points for each rider via Monte Carlo simulation, then solve a linear programme to maximise expected points constrained by budget and rider limits.

The prediction pipeline combines multiple data sources through Bayesian strength estimation: an uninformative prior is updated sequentially with PCS specialty ratings, VG season points, race-specific history from past editions, and where available betting odds and Cycling Oracle predictions. Monte Carlo simulation converts these strength estimates into probability distributions over finishing positions, which map to expected VG points through the scoring tables. An April 2026 ablation retired the PCS form score, qualitative intelligence and trajectory signals; the code and its data collection were deleted in August 2026. VG race history was retired from the one-day estimator only — the stage-race estimator still uses it.

For stage races the model carries a multi-dimensional posterior rather than one number: each PCS specialty source is z-scored separately and routed to strength dimensions through `SIGNAL_DIMENSION_WEIGHTS`, and `compute_stage_strengths` then projects those dimensions onto a per-stage-type strength vector. The race is simulated stage by stage with correlated cross-stage noise, so a rider's contribution reflects which stages actually suit them.

## Usage

Analysis reports are Julia scripts that generate standalone HTML. Output goes to `prediction_docs/` by default (configurable via `[output].dir` in `race_config.toml`):

- `scripts/render_predictor.jl` — pre-race team selection for Sixes Classics one-day races
- `scripts/render_stagerace.jl` — pre-race team selection for grand tours and stage races
- `scripts/render_assessor.jl` — post-race review and result archival for prospective evaluation
- `scripts/render_backtesting.jl` — model calibration: prior predictive checks, backtesting, prospective evaluation
- `scripts/render_reports.jl` → `site/docs/` — public race reports website with per-race retrospectives
- `scripts/league_eval.jl` — offline league evaluation: model team vs realised points, the hindsight-optimal team, and naive baselines
- `scripts/serve.jl` — local web frontend: a config form that adapts to the race format, runs any of the three reports and serves the result

All scripts accept `--fresh` to bypass the cache and fetch everything from the web. The predictor and stagerace scripts also accept `--force` to overwrite an existing prediction archive.

## Features

- **Monte Carlo prediction**: Bayesian strength estimation and race simulation to compute expected VG points per rider
- **Multi-source data integration**: Combines VG costs/season points, PCS specialty ratings, race history, betting odds (Oddschecker paste) and Cycling Oracle predictions
- **Risk-adjusted optimisation**: `risk_aversion` parameter penalises high-variance riders; `domestique_discount` down-weights non-leaders relative to their strength gap
- **Market blend (one-day)**: `market_blend_weight` mixes the bookmaker's implied win probabilities into the final team pick alongside the simulator's expected points. `race_config.toml` ships 0.5; `solve_oneday`'s own default is 1.0, which disables it. One-day races only, and inert without odds
- **One-day and stage race support**: `solve_oneday()` for Sixes Classics, `solve_stage()` for grand tours with classification constraints
- **Robust caching**: Feather-based caching (`CacheConfig`) with configurable TTL to avoid hammering external sites
- **Historical analysis**: Deterministic optimisation on actual results to find optimal and cheapest-winning teams

## Workflow

The prediction and calibration workflow revolves around three scripts, each run at a different point in the race cycle.

### Race configuration

All three renderers share a single configuration file, `data/race_config.toml`, so race settings stay in sync between the pre-race and post-race steps. This file is gitignored because it changes every race. Every script reads it through `load_render_config`, which parses it into one typed `RenderConfig` — including parsing the odds pastes — so no renderer can quietly skip a data source another one uses.

Easiest way to set up a race is the local frontend, which presents the config as a form and only shows the knobs that apply to the chosen race format:

```sh
julia --project scripts/serve.jl   # then open http://localhost:8080
```

It writes the same `race_config.toml`, so the CLI scripts stay usable and unaffected. To edit the file directly instead, copy the example:

```sh
cp data/race_config.toml.example data/race_config.toml
# Edit race_config.toml with race name, year, data source URLs, your team, etc.
```

A race name that does not resolve is an error, not a warning — it will not silently become a stage race with a made-up URL.

The `[race]`, `[data_sources]`, `[output]`, and `[optimisation]` sections are shared by all scripts. The `[team_assessor]` section holds your team roster and the VG race number for retrospective analysis. Two further sections feed `scripts/league_eval.jl`: `[league]` names the minileague to score against and where to read its standings, and `[entered_team]` optionally records the team you actually entered when it differs from the advised one, so the evaluation can report the override delta.

Note that `[league]` describes the season-long league you are competing in — the classics game and a grand tour are separate Velogames competitions with separate leagues, so switching it to score a grand tour discards your classics tracking. Its `vgleague_data_dir` must point at the deploy clone (`~/code/vgleague-deploy/data`), which is what the launchd job actually writes; the `~/code/vgleague` dev clone stopped being updated when scraping moved to a dedicated clone in July 2026.

### Before each race

Edit `data/race_config.toml` with the race name, year, startlist hash, and any data source URLs (odds, oracle). Then run:

```sh
julia --project scripts/render_predictor.jl
# or for stage races:
julia --project scripts/render_stagerace.jl
```

This runs the full pipeline (data fetch, strength estimation, resampled optimisation) and automatically archives predictions, odds and oracle data to `DEFAULT_ARCHIVE_DIR` for later evaluation. The prediction archive is write-once: re-running after the race won't overwrite the pre-race snapshot (pass `--force` to override).

### After each race

Update `data/race_config.toml` with your chosen team in `[team_assessor].my_team` and set `vg_race_number` (or leave at 0 for auto-detection). Then run:

```sh
julia --project scripts/render_assessor.jl
```

This archives the actual PCS and VG results alongside the pre-race predictions, and shows a per-race comparison of predicted vs actual rider performance. Running it after every race builds up the prospective evaluation dataset over the season.

### Periodically (model calibration)

```sh
julia --project scripts/render_backtesting.jl
```

This generates the full calibration picture, covering:

1. **Prior predictive checks** — `check_stylised_facts()` validates that the model's implied race outcomes match domain knowledge (e.g. favourite win rates, rank correlations). Adjust the three precision scale factors (`market_precision_scale`, `history_precision_scale`, `ability_precision_scale`) and re-run until all checks pass.
2. **Sensitivity sweeps** — `sensitivity_sweep()` shows how each scale factor affects key diagnostics, helping to identify reasonable ranges.
3. **SBC diagnostics** — `simulation_based_calibration()` checks that the Bayesian inference pipeline recovers true parameters from synthetic data (rank histogram should be uniform).
4. **Backtest sanity check** — runs `backtest_season()` against historical data as a directional validation. With only ~100 observations and 5 tuneable parameters, treat results as indicative rather than precise.
5. **Prospective evaluation** — `prospective_season_summary()` compares archived pre-race predictions against actual results for races where all signals were available. This is the most trustworthy evaluation, but requires a season's worth of archived data.
6. **Signal value analysis** — `signal_value_analysis()` shows which signals moved predictions most across the season.

### Race reports website

A separate static website in `site/docs/` provides post-race retrospectives for the minileague. Each race gets an interactive report with the hindsight-optimal team, cheapest winning team, scatter plots (points vs cost, value vs cost), and performance tables.

One-day races publish themselves. `./scripts/auto_publish.sh` reads the `vgleague` scrape, takes the highest-scoring entrant of any race the winners record hasn't caught up with, renders that report and deploys it — the name and score nobody now types were always just `argmax(score)` over the league. Run it with `--dry-run` to see what it would publish and write nothing.

It reads the `[league]` section of `data/race_config.toml` to find the snapshot, and skips a race until 24 hours after its pick deadline (`--min-age-hours`), because Velogames revises scores after a race and the record is append-only — a wrong winner has to be unpicked by hand, and that race's HTML deleted so it rebuilds.

Grand tours stay manual, through `./scripts/publish_stage_race.sh <pcs_slug> <year> "<winner>" <score>`. Their winners are in the snapshots too and the names match, but the scraped totals disagree with the recorded ones by a few points (Giro 8351 against 8359, Tour 11884 against 11880) for reasons nobody has run down. That is three races a year against the risk of publishing a wrong number as fact.

Both go through `scripts/deploy_site.sh`, which uploads `site/docs/` to Netlify from disk and reads its `NETLIFY_AUTH_TOKEN` / `NETLIFY_SITE_ID` from a gitignored `.env` at the repo root (see `.env.example`). Neither writes anything to git: the rendered site is build output, and the winners record lives in the archive beside every other piece of race data. `auto_publish.sh` pulls the code it is about to run and that is all, so no git failure can keep a report offline.

One consequence worth knowing: a clone that has never rendered has an empty `site/docs/`, and deploying that would replace the live site with nothing, so `deploy_site.sh` refuses when `site/docs/index.html` is missing. Run `julia --project scripts/render_reports.jl --force` first on a new machine.

### Running it unattended

Set `POST_UPDATE_HOOK` in the `vgleague` deploy clone's `.env` and both of that repo's launchd jobs will call it once fresh league data has landed:

```sh
POST_UPDATE_HOOK=/Users/you/code/velogames-deploy/scripts/auto_publish.sh
```

Point it at a dedicated deploy clone rather than your working tree, so it only ever runs committed, pushed code. Setting one up is a clone, a `Pkg.instantiate()`, an `.env`, and a `data/race_config.toml` holding the `[league]` block (nothing else in that file is read).

The render script scans `DEFAULT_ARCHIVE_DIR/vg_results/` for completed races and generates an HTML page per race in `site/docs/reports/`. If VG/PCS results haven't been archived yet (e.g. because the assessor wasn't run), the script auto-detects the VG race number and archives them. Incremental build: existing HTML reports are skipped (pass `--force` to regenerate all). League winner data lives in `DEFAULT_ARCHIVE_DIR/league_winners.toml`, alongside every other piece of race data rather than in the repo. Every entry is derivable in principle from the vgleague snapshots, but those sit in a gitignored, machine-local directory that nothing backs up, so this file is the durable record — and it holds no 2025 entries at all, so the whole 2025 back-catalogue renders without a league winner. Full standings are a different matter — `data/league_standings.toml` carries every entrant's real name and stays gitignored. The index page lists all races grouped by year.

## Data storage

The package uses two storage layers:

- **Permanent archive** (`DEFAULT_ARCHIVE_DIR`): race-day snapshots (odds, oracle predictions, PCS specialty scores, pre-race predictions, post-race results) stored as Feather files at `{archive_dir}/{data_type}/{pcs_slug}/{year}.feather`. By default this points to `~/Dropbox/code/velogames/archive/`, so Dropbox provides backup and cross-machine sync automatically. You can point it anywhere by overriding the constant before loading the package.
- **Disk cache** (`~/.velogames_cache/`): short-lived cache of scraped web data (PCS rankings, VG rider lists, race catalogues) with a 7-day TTL. This is purely a performance optimisation — it is expendable and regenerates automatically from the web if deleted.

## Testing

`julia --project -e "using Pkg; Pkg.test()"` should run the tests.
