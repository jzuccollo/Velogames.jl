# Velogames.jl

Hacky, personal Julia package to pick a Velogames team. Always in progress, always a bit broken, no guarantees it'll work anywhere else!

## Approach

Estimate expected Velogames points for each rider via Monte Carlo simulation, then solve a linear programme to maximise expected points constrained by budget and rider limits.

The prediction pipeline combines multiple data sources through Bayesian strength estimation: PCS specialty ratings provide a prior, updated by VG season points, race-specific history from past editions, and optionally betting odds. Monte Carlo simulation converts these strength estimates into probability distributions over finishing positions, which map to expected VG points through the scoring tables.

For stage races, PCS specialty scores are blended according to each rider's VG classification (all-rounder, climber, sprinter, unclassed) to produce a single strength estimate reflecting their likely contribution across the whole race.

## Usage

Outputs calculated in the Quarto files in the `notebooks/` directory:

- `oneday_predictor.qmd` - Pre-race team selection for Sixes Classics one-day races
- `stagerace_predictor.qmd` - Pre-race team selection for grand tours and stage races
- `team_assessor.qmd` - Compare a custom team against the model's optimal selection
- `historical_analysis.qmd` - Retrospective analysis of completed races (both types)

No guarantee they'll re-render because they pull from the moving target of velogames.com rider pages, so URLs typically need to be updated for every render.

## Features

- **Monte Carlo prediction**: Bayesian strength estimation and race simulation to compute expected VG points per rider
- **Multi-source data integration**: Combines VG costs/season points, PCS specialty ratings, race history, betting odds (Betfair API or Oddschecker paste), and qualitative intelligence from YouTube or web articles
- **Qualitative intelligence**: YouTube transcripts and web articles fed to the Claude API to extract structured rider assessments, integrated as Bayesian signals
- **Risk-adjusted optimisation**: `risk_aversion` parameter penalises high-variance riders; `domestique_discount` down-weights non-leaders relative to their strength gap
- **One-day and stage race support**: `solve_oneday()` for Sixes Classics, `solve_stage()` for grand tours with classification constraints
- **Robust caching**: Feather-based caching (`CacheConfig`) with configurable TTL to avoid hammering external sites
- **Historical analysis**: Deterministic optimisation on actual results to find optimal and cheapest-winning teams

## Testing

`julia --project -e "using Pkg; Pkg.test()"` should run the tests.
