# Velogames.jl

Fantasy cycling team optimization for velogames.com. Scrapes rider data from Velogames and ProCyclingStats, estimates expected Velogames points via Monte Carlo simulation, and selects optimal teams using JuMP/HiGHS linear programming.

## Architecture

- `src/Velogames.jl` - Main module, includes and exports
- `src/get_data.jl` - Data scraping: VG riders, PCS rankings/specialty ratings, Betfair odds, VG race results
- `src/pcs_extended.jl` - Extended PCS scraping: race history results, startlists across multiple years
- `src/scoring.jl` - Velogames Superclassico scoring tables (finish, assist, breakaway by category) and expected points functions
- `src/simulation.jl` - Monte Carlo race simulation, Bayesian strength estimation, expected VG points pipeline
- `src/build_model.jl` - JuMP optimization models (one-day 6-rider, stage 9-rider, historical, min-cost)
- `src/race_solver.jl` - High-level orchestrator: data -> strength estimation -> simulation -> optimization
- `src/cache_utils.jl` - Feather-based caching with configurable TTL (default ~/.velogames_cache, 24h)
- `src/classification_utils.jl` - Rider classification (allrounder/sprinter/climber/unclassed)
- `src/race_helpers.jl` - RaceConfig struct with category/pcs_slug, URL patterns for all Superclassico races
- `src/utilities.jl` - Name normalization (`normalisename`), key creation (`createkey`), PCS specialty mapping
- `src/report_helpers.jl` - Display formatting
- `race_notebooks/` - Quarto notebooks for race prediction and historical analysis

## Key Patterns

- All data functions use `cached_fetch()` with `CacheConfig` and `force_refresh` parameter
- Rider matching across sources uses `riderkey` (from `createkey()` name normalization)
- Web scraping: `gettable()` -> `process_rider_table()` via TableScraper/Gumbo/Cascadia
- Optimization: JuMP + HiGHS, binary variables for rider selection
- PCS URLs: `https://www.procyclingstats.com/race/{slug}/{year}`
- VG URLs: `https://www.velogames.com/{race-slug}/{year}/riders.php`
- Superclassico races all share one VG URL: `sixes-superclasico/{year}/riders.php` with startlist hash filtering

## Commands

- Run tests: `julia --project -e "using Pkg; Pkg.test()"`
- Run notebook: `quarto render race_notebooks/oneday_predictor.qmd`

## Conventions

- Julia naming: snake_case for functions, PascalCase for types
- New data functions must support CacheConfig parameter
- Prefer extending existing files over creating new ones
- Scoring categories: Cat 1 = monuments + worlds, Cat 2 = WT classics, Cat 3 = semi-classics

## Roadmap

See `docs/roadmap.md` for future plans: recent form features, course profile matching, ownership-adjusted optimization, backtesting framework, ML models.
