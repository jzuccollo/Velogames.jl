# Velogames.jl

Hacky, personal Julia package to pick a Velogames team. Always in progress, always a bit broken, no guarantees it'll work anywhere else!

## Approach

Estimate expected Velogames points for each rider via Monte Carlo simulation, then solve a linear programme to maximise expected points constrained by budget and rider limits.

The prediction pipeline combines multiple data sources through Bayesian strength estimation: an uninformative prior is updated sequentially with PCS specialty ratings, VG season points, recent form, race-specific history from past editions, and optionally betting odds, algorithmic predictions, and qualitative intelligence. Monte Carlo simulation converts these strength estimates into probability distributions over finishing positions, which map to expected VG points through the scoring tables.

For stage races, PCS specialty scores are blended according to each rider's VG classification (all-rounder, climber, sprinter, unclassed) to produce a single strength estimate reflecting their likely contribution across the whole race.

## Usage

Outputs calculated in the Quarto files in the `notebooks/` directory:

- `oneday_predictor.qmd` - Pre-race team selection for Sixes Classics one-day races
- `stagerace_predictor.qmd` - Pre-race team selection for grand tours and stage races
- `team_assessor.qmd` - Post-race review and result archival for prospective evaluation
- `historical_analysis.qmd` - Retrospective analysis of completed races (both types)
- `backtesting.qmd` - Model calibration: prior predictive checks, backtesting, prospective evaluation

No guarantee they'll re-render because they pull from the moving target of velogames.com rider pages, so URLs typically need to be updated for every render.

## Features

- **Monte Carlo prediction**: Bayesian strength estimation and race simulation to compute expected VG points per rider
- **Multi-source data integration**: Combines VG costs/season points, PCS specialty ratings, race history, betting odds (Betfair API or Oddschecker paste), and qualitative intelligence from YouTube or web articles
- **Qualitative intelligence**: YouTube transcripts and web articles fed to the Claude API to extract structured rider assessments, integrated as Bayesian signals
- **Risk-adjusted optimisation**: `risk_aversion` parameter penalises high-variance riders; `domestique_discount` down-weights non-leaders relative to their strength gap
- **One-day and stage race support**: `solve_oneday()` for Sixes Classics, `solve_stage()` for grand tours with classification constraints
- **Robust caching**: Feather-based caching (`CacheConfig`) with configurable TTL to avoid hammering external sites
- **Historical analysis**: Deterministic optimisation on actual results to find optimal and cheapest-winning teams

## Workflow

The prediction and calibration workflow revolves around three notebooks, each run at a different point in the race cycle.

### Race configuration

The predictor and team assessor notebooks share a single configuration file, `notebooks/race_config.toml`, so race settings stay in sync between the pre-race and post-race steps. This file is gitignored because it changes every race.

To set up for a new race, copy the example and edit:

```sh
cp notebooks/race_config.toml.example notebooks/race_config.toml
# Edit race_config.toml with race name, year, data source URLs, your team, etc.
```

The `[race]`, `[data_sources]`, and `[optimisation]` sections are shared by both notebooks. The `[team_assessor]` section holds your team roster and the VG race number for retrospective analysis.

### Before each race

Edit `notebooks/race_config.toml` with the race name, year, startlist hash, and any data source URLs (odds, oracle, qualitative). Then render the appropriate predictor notebook:

- `notebooks/oneday_predictor.qmd` for Sixes Classics one-day races
- `notebooks/stagerace_predictor.qmd` for grand tours and stage races

These notebooks run the full pipeline (data fetch, strength estimation, resampled optimisation) and automatically archive predictions, odds, oracle, and qualitative data to `DEFAULT_ARCHIVE_DIR` for later evaluation.

### After each race

Update `notebooks/race_config.toml` with your chosen team in `[team_assessor].my_team` and set `vg_race_number` (or leave at 0 for auto-detection). Then render `notebooks/team_assessor.qmd` to review how the selected team performed. This notebook archives the actual PCS and VG results alongside the pre-race predictions, and shows a per-race comparison of predicted vs actual rider performance. Running it after every race builds up the prospective evaluation dataset over the season.

### Periodically (model calibration)

Render `notebooks/backtesting.qmd` for the full calibration picture. The notebook is structured in sections that can be run independently:

1. **Prior predictive checks** — `check_stylised_facts()` validates that the model's implied race outcomes match domain knowledge (e.g. favourite win rates, rank correlations). Adjust the three precision scale factors (`market_precision_scale`, `history_precision_scale`, `ability_precision_scale`) and re-run until all checks pass.
2. **Sensitivity sweeps** — `sensitivity_sweep()` shows how each scale factor affects key diagnostics, helping to identify reasonable ranges.
3. **SBC diagnostics** — `simulation_based_calibration()` checks that the Bayesian inference pipeline recovers true parameters from synthetic data (rank histogram should be uniform).
4. **Historical ablation** — tests which always-available signals (PCS, race history, VG history) add predictive value.
5. **Backtest sanity check** — runs `backtest_season()` against historical data as a directional validation. With only ~100 observations and 5 tuneable parameters, treat results as indicative rather than precise.
6. **Prospective evaluation** — `prospective_season_summary()` compares archived pre-race predictions against actual results for races where all signals were available. This is the most trustworthy evaluation, but requires a season's worth of archived data.
7. **Signal value analysis** — `signal_value_analysis()` shows which signals moved predictions most across the season.

### Race reports website

A separate static website in `site/` provides post-race retrospectives for the minileague. Each race gets an interactive report with the hindsight-optimal team, cheapest winning team, scatter plots (points vs cost, value vs cost), and performance tables.

The workflow after each race:

1. **Archive results** (already part of `team_assessor.qmd`): `archive_race_results("pcs-slug", 2026; vg_race_number=N)`
2. **Record league winner** (optional): add an entry to `LEAGUE_WINNERS` in `scripts/render_reports.jl`
3. **Generate reports**: `julia --project scripts/render_reports.jl --years=2026`
4. **Render the site**: `cd site && quarto render`
5. **Preview locally**: `cd site && quarto preview`

The render script scans `DEFAULT_ARCHIVE_DIR/vg_results/` for completed races and generates a `.qmd` per race in `site/reports/`. The index page at `site/index.qmd` lists all races grouped by year. Reports are rendered to `site/docs/` for deployment via GitHub Pages.

## Data storage

The package uses two storage layers:

- **Permanent archive** (`DEFAULT_ARCHIVE_DIR`): race-day snapshots (odds, oracle predictions, PCS specialty scores, pre-race predictions, post-race results) stored as Feather files at `{archive_dir}/{data_type}/{pcs_slug}/{year}.feather`. By default this points to `~/Dropbox/code/velogames/archive/`, so Dropbox provides backup and cross-machine sync automatically. You can point it anywhere by overriding the constant before loading the package.
- **Disk cache** (`~/.velogames_cache/`): short-lived cache of scraped web data (PCS rankings, VG rider lists, race catalogues) with a 7-day TTL. This is purely a performance optimisation — it is expendable and regenerates automatically from the web if deleted.

## Testing

`julia --project -e "using Pkg; Pkg.test()"` should run the tests.
