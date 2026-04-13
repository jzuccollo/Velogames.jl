# Velogames.jl

Hacky, personal Julia package to pick a Velogames team. Always in progress, always a bit broken, no guarantees it'll work anywhere else!

## Approach

Estimate expected Velogames points for each rider via Monte Carlo simulation, then solve a linear programme to maximise expected points constrained by budget and rider limits.

The prediction pipeline combines multiple data sources through Bayesian strength estimation: an uninformative prior is updated sequentially with PCS specialty ratings, VG season points, recent form, race-specific history from past editions, and optionally betting odds, algorithmic predictions, and qualitative intelligence. Monte Carlo simulation converts these strength estimates into probability distributions over finishing positions, which map to expected VG points through the scoring tables.

For stage races, PCS specialty scores are blended according to each rider's VG classification (all-rounder, climber, sprinter, unclassed) to produce a single strength estimate reflecting their likely contribution across the whole race.

## Usage

Analysis reports are Julia scripts that generate standalone HTML. Output goes to `prediction_docs/` by default (configurable via `[output].dir` in `race_config.toml`):

- `scripts/render_predictor.jl` — pre-race team selection for Sixes Classics one-day races
- `scripts/render_stagerace.jl` — pre-race team selection for grand tours and stage races
- `scripts/render_assessor.jl` — post-race review and result archival for prospective evaluation
- `scripts/render_backtesting.jl` — model calibration: prior predictive checks, backtesting, prospective evaluation
- `scripts/render_reports.jl` → `site/docs/` — public race reports website with per-race retrospectives

All scripts accept `--fresh` to bypass the cache and fetch everything from the web. The predictor and stagerace scripts also accept `--force` to overwrite an existing prediction archive.

## Features

- **Monte Carlo prediction**: Bayesian strength estimation and race simulation to compute expected VG points per rider
- **Multi-source data integration**: Combines VG costs/season points, PCS specialty ratings, race history, betting odds (Oddschecker paste), and qualitative intelligence from YouTube or web articles
- **Qualitative intelligence**: YouTube transcripts and web articles fed to the Claude API to extract structured rider assessments, integrated as Bayesian signals
- **Risk-adjusted optimisation**: `risk_aversion` parameter penalises high-variance riders; `domestique_discount` down-weights non-leaders relative to their strength gap
- **One-day and stage race support**: `solve_oneday()` for Sixes Classics, `solve_stage()` for grand tours with classification constraints
- **Robust caching**: Feather-based caching (`CacheConfig`) with configurable TTL to avoid hammering external sites
- **Historical analysis**: Deterministic optimisation on actual results to find optimal and cheapest-winning teams

## Workflow

The prediction and calibration workflow revolves around three scripts, each run at a different point in the race cycle.

### Race configuration

The predictor and team assessor share a single configuration file, `data/race_config.toml`, so race settings stay in sync between the pre-race and post-race steps. This file is gitignored because it changes every race.

To set up for a new race, copy the example and edit:

```sh
cp data/race_config.toml.example data/race_config.toml
# Edit race_config.toml with race name, year, data source URLs, your team, etc.
```

The `[race]`, `[data_sources]`, `[output]`, and `[optimisation]` sections are shared by all scripts. The `[team_assessor]` section holds your team roster and the VG race number for retrospective analysis.

### Before each race

Edit `data/race_config.toml` with the race name, year, startlist hash, and any data source URLs (odds, oracle, qualitative). Then run:

```sh
julia --project scripts/render_predictor.jl
# or for stage races:
julia --project scripts/render_stagerace.jl
```

This runs the full pipeline (data fetch, strength estimation, resampled optimisation) and automatically archives predictions, odds, oracle, and qualitative data to `DEFAULT_ARCHIVE_DIR` for later evaluation. The prediction archive is write-once: re-running after the race won't overwrite the pre-race snapshot (pass `--force` to override).

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

Publish a race report in one step (results are auto-archived if not already done):

```sh
./scripts/publish_race.sh gent-wevelgem 2026 "Team Name" 1234
```

This appends the league winner to `data/league_winners.toml`, generates the HTML report, commits, and pushes. The GitHub Pages deploy action fires on push.

The render script scans `DEFAULT_ARCHIVE_DIR/vg_results/` for completed races and generates an HTML page per race in `site/docs/reports/`. If VG/PCS results haven't been archived yet (e.g. because the assessor wasn't run), the script auto-detects the VG race number and archives them. Incremental build: existing HTML reports are skipped (pass `--force` to regenerate all). League winner data lives in `data/league_winners.toml`. The index page lists all races grouped by year.

## Data storage

The package uses two storage layers:

- **Permanent archive** (`DEFAULT_ARCHIVE_DIR`): race-day snapshots (odds, oracle predictions, PCS specialty scores, pre-race predictions, post-race results) stored as Feather files at `{archive_dir}/{data_type}/{pcs_slug}/{year}.feather`. By default this points to `~/Dropbox/code/velogames/archive/`, so Dropbox provides backup and cross-machine sync automatically. You can point it anywhere by overriding the constant before loading the package.
- **Disk cache** (`~/.velogames_cache/`): short-lived cache of scraped web data (PCS rankings, VG rider lists, race catalogues) with a 7-day TTL. This is purely a performance optimisation — it is expendable and regenerates automatically from the web if deleted.

## Testing

`julia --project -e "using Pkg; Pkg.test()"` should run the tests.
