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
- `src/simulation.jl` - Bayesian strength estimation (`estimate_strengths`): uninformative prior with PCS as observation, trajectory signal, season-adaptive VG variance, class-aware PCS blending for stage races, domestique strength discount. Also retains `predict_expected_points` (MC simulation) for backtesting compatibility.
- `src/build_model.jl` - JuMP optimisation models: `build_model_oneday` (6 riders), `build_model_stage` (9 riders + class constraints), `resample_optimise` (resampled optimisation that draws noisy strengths, scores VG points, and optimises per draw), `minimise_cost_stage`
- `src/race_solver.jl` - High-level solvers: `solve_oneday` and `solve_stage` (estimate strengths → resampled optimisation pipeline, returns top teams)
- `src/cache_utils.jl` - Feather-based caching with configurable TTL (default ~/.velogames_cache, 24h), plus permanent archival storage (~/.velogames_archive) for odds/oracle snapshots
- `src/classification_utils.jl` - Rider classification (allrounder/sprinter/climber/unclassed) column management
- `src/race_helpers.jl` - `RaceInfo` struct (canonical race metadata), `RaceConfig` struct, `setup_race()`, URL alias lookup, `CLASSICS_RACES_2026` schedule, `SIMILAR_RACES` (derived from `RaceInfo`), year-aware VG slug/URL/game ID functions
- `src/utilities.jl` - Name normalisation (`normalisename`), key creation (`createkey`), sentinel constants (`DNF_POSITION`, `UNRANKED_POSITION`)
- `src/backtest.jl` - Backtesting framework: race catalogue, season-level evaluation, ablation study, hyperparameter tuning, calibration diagnostics, VG race history integration, cumulative VG season points, PCS specialty archiving
- `src/report_helpers.jl` - Display formatting: `round_numeric_columns!`, `clean_team_names!`
- `notebooks/` - Quarto notebooks: one-day predictor, stage race predictor, historical analysis, backtesting and calibration

## Key functions

### Solvers (src/race_solver.jl)

- `solve_oneday(config; ...)` - Resampled optimisation pipeline for one-day classics. Returns `(predicted, chosenteam, top_teams)`.
- `solve_stage(config; ...)` - Resampled optimisation pipeline for stage races (class constraints). Returns `(predicted, chosenteam, top_teams)`.

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
- `estimate_rider_strength(...)` - Bayesian posterior from uninformative prior (mean=0, variance=100), updated with PCS specialty (gated on `has_pcs`), VG, PCS form, trajectory, PCS race history with variance penalties, VG race history, odds, oracle, qualitative intelligence
- `simulate_race(strengths, uncertainties; n_sims)` - Monte Carlo position simulation (used by backtesting)
- `compute_stage_race_pcs_score(row, class)` - Class-aware PCS blending for stage races

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
- `tune_hyperparameters(races; ...)` - Two-stage hyperparameter optimisation with cross-validation
- `tune_domestique_discount(races; discounts, ...)` - Grid search over domestique discount values, optimising points_captured_ratio via backtest_season
- `BacktestResult` includes: rank metrics (Spearman ρ, top-N overlap), VG team metrics (actual scoring tables), and calibration diagnostics (z-scores, coverage rates)

## Key patterns

- Betfair API credentials via environment variables (`BETFAIR_USERNAME`, `BETFAIR_PASSWORD`, `BETFAIR_APP_KEY`); Anthropic API key via `ANTHROPIC_API_KEY`; see `.envrc.example`
- All data functions use `cached_fetch()` with `CacheConfig` and `force_refresh` parameter
- Rider matching across sources uses `riderkey` (from `createkey()` name normalisation)
- Web scraping: `gettable()` -> `process_rider_table()` via HTTP/Gumbo/Cascadia; `scrape_html_tables()` parses `<table>` elements directly
- Optimisation: JuMP + HiGHS, binary variables for rider selection
- PCS URLs: `https://www.procyclingstats.com/race/{slug}/{year}`
- VG URLs: `https://www.velogames.com/{race-slug}/{year}/riders.php`
- One-day classics races share one VG URL per year: `sixes-classics/{year}/riders.php` (2026+) or `sixes-superclasico/{year}/riders.php` (≤2025), with startlist hash filtering
- Archival storage: `_prepare_rider_data` automatically archives odds/oracle/PCS specialty data on successful fetch; `prefetch_race_data` loads archived data for backtesting
- Archival paths: `~/.velogames_archive/{data_type}/{pcs_slug}/{year}.feather` — data_type includes odds, oracle, pcs_specialty, vg_results
- VG race URLs: `ridescore.php?ga={game_id}&st={race_number}` where game_id is from `vg_classics_game_id(year)`, `st` is race number 1-44 from races.php
- Backtesting temporal integrity: `estimate_strengths`/`predict_expected_points` accept `race_year`/`race_date` for correct recency weighting; cumulative VG season points prevent end-of-year leakage; archived PCS specialty scores prevent current-day leakage
- Production pipeline: `estimate_strengths` → `resample_optimise` (avoids Jensen's inequality bias from scoring floor at position 31+). Backtesting pipeline: `predict_expected_points` (MC simulation) for rank-based metrics.

## Commands

- Run tests: `julia --project -e "using Pkg; Pkg.test()"`
- Run notebook: `quarto render notebooks/oneday_predictor.qmd`
- Run backtesting: `quarto render notebooks/backtesting.qmd`

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

See `roadmap.md` for future plans: recent form, course profiles, ownership-adjusted optimisation, backtesting, ML models, stage-by-stage simulation.
