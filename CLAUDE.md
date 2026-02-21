# Velogames.jl

Fantasy cycling team optimisation for velogames.com. Scrapes rider data from Velogames and ProCyclingStats, estimates expected Velogames points via Monte Carlo simulation, and selects optimal teams using JuMP/HiGHS linear programming.

## Architecture

- `src/Velogames.jl` - Main module, includes and exports
- `src/get_data.jl` - Data scraping: VG riders, PCS rankings/specialty ratings, Betfair odds (deprecated), VG race results
- `src/pcs_scraper.jl` - PCS table scraping infrastructure and column aliases
- `src/pcs_extended.jl` - Extended PCS scraping: race history results, startlists across multiple years
- `src/scoring.jl` - VG scoring tables by category (one-day Cat 1/2/3, stage race aggregate) and expected points functions
- `src/simulation.jl` - Monte Carlo race simulation, Bayesian strength estimation, class-aware PCS blending for stage races
- `src/build_model.jl` - JuMP optimisation models: `build_model_oneday` (6 riders), `build_model_stage` (9 riders + class constraints), `minimise_cost_stage`
- `src/race_solver.jl` - High-level solvers: `solve_oneday` and `solve_stage` (MC pipelines), `solve_stage_legacy` (weighted-score fallback)
- `src/cache_utils.jl` - Feather-based caching with configurable TTL (default ~/.velogames_cache, 24h)
- `src/classification_utils.jl` - Rider classification (allrounder/sprinter/climber/unclassed) column management
- `src/race_helpers.jl` - `RaceConfig` struct, `setup_race()`, URL patterns for all Superclassico and grand tour races
- `src/utilities.jl` - Name normalisation (`normalisename`), key creation (`createkey`), PCS specialty mapping
- `src/report_helpers.jl` - Display formatting helpers
- `race_notebooks/` - Quarto notebooks: one-day predictor, stage race predictor, historical analysis

## Key functions

### Solvers (src/race_solver.jl)

- `solve_oneday(config; ...)` - MC prediction pipeline for one-day Superclassico races
- `solve_stage(config; ...)` - MC prediction pipeline for stage races (class-aware strength)
- `solve_stage_legacy(url, racetype, ...)` - Legacy weighted-score solver (deprecated)

### Optimisation models (src/build_model.jl)

- `build_model_oneday(df, n, points_col, cost_col)` - Maximise points, one-day (6 riders, cost <= 100)
- `build_model_stage(df, n, points_col, cost_col)` - Maximise points, stage race (9 riders, class constraints)
- `minimise_cost_stage(df, target_score, n, cost_col)` - Minimise cost for target score

### Simulation (src/simulation.jl)

- `predict_expected_points(df, scoring; race_type=:oneday)` - Full prediction pipeline
- `estimate_rider_strength(...)` - Bayesian posterior from multiple signals
- `simulate_race(strengths, n_sims)` - Monte Carlo position simulation
- `compute_stage_race_pcs_score(row, class)` - Class-aware PCS blending for stage races

## Key patterns

- All data functions use `cached_fetch()` with `CacheConfig` and `force_refresh` parameter
- Rider matching across sources uses `riderkey` (from `createkey()` name normalisation)
- Web scraping: `gettable()` -> `process_rider_table()` via TableScraper/Gumbo/Cascadia
- Optimisation: JuMP + HiGHS, binary variables for rider selection
- PCS URLs: `https://www.procyclingstats.com/race/{slug}/{year}`
- VG URLs: `https://www.velogames.com/{race-slug}/{year}/riders.php`
- Superclassico races share one VG URL: `sixes-superclasico/{year}/riders.php` with startlist hash filtering

## Commands

- Run tests: `julia --project -e "using Pkg; Pkg.test()"`
- Run notebook: `quarto render race_notebooks/oneday_predictor.qmd`

## Conventions

- Julia naming: snake_case for functions, PascalCase for types
- New data functions must support CacheConfig parameter
- Prefer extending existing files over creating new ones
- Scoring categories: Cat 1 = monuments + worlds, Cat 2 = WT classics, Cat 3 = semi-classics
- British English spelling throughout (optimise, normalise, colour)

## Roadmap

See `roadmap.md` for future plans: recent form, course profiles, ownership-adjusted optimisation, backtesting, ML models, stage-by-stage simulation.
