# Velogames.jl improvement roadmap

## Current state (Feb 2026)

The package implements expected Velogames points prediction using:

- VG scoring system encoded as data (finish position, assists, breakaway points by race category)
- PCS race-specific history for one-day classics and stage races
- Bayesian strength estimation combining PCS, VG, race history, and optional odds
- Monte Carlo race simulation converting strength to position probabilities to expected VG points
- JuMP optimisation over expected VG points (replacing arbitrary composite scores)
- Class-aware PCS blending for stage races (aggregate approach)

## Prediction engine data flows

### Signal inventory

The strength model combines four signals, each with a variance hyperparameter controlling how much it shifts the posterior. All variance parameters are exposed as keyword arguments in `estimate_rider_strength()` for calibration and sensitivity analysis:

| Signal              | Source                    | Variance | Notes                                                                                        |
| ------------------- | ------------------------- | -------- | -------------------------------------------------------------------------------------------- |
| PCS specialty prior | `getpcsriderpts_batch()`  | 4.0      | Z-scored across field. For stage races, class-aware blending via `STAGE_RACE_PCS_WEIGHTS`    |
| VG season points    | `getvgriders()`           | 3.0      | Z-scored VG `points` column                                                                  |
| Race history        | `getpcsracehistory()`     | 1.0-3.0  | Recency-weighted: recent years get lower variance (higher precision)                         |
| Betting odds        | `getodds()`               | 0.5      | Strongest single signal when available. Currently broken (fragile Betfair CSS selectors)     |

Odds are converted to strength via log-odds relative to a uniform baseline, then divided by a normalisation constant (default 2.0, heuristic) to match the z-score scale of other signals. This divisor is also an exposed parameter (`odds_normalisation`).

### Bayesian updating

Normal-normal conjugate model (`estimate_rider_strength()`). Each signal updates the posterior mean and variance:

$$\mu_{\text{post}} = \frac{\mu_{\text{prior}} / \sigma^2_{\text{prior}} + \mu_{\text{obs}} / \sigma^2_{\text{obs}}}{1/\sigma^2_{\text{prior}} + 1/\sigma^2_{\text{obs}}}$$

Missing data leaves the prior unchanged. Output: posterior mean (strength) and variance (uncertainty).

### Monte Carlo simulation

`simulate_race()` adds Gaussian noise scaled by posterior uncertainty to each rider's strength, then ranks to get finishing positions. With 10,000+ simulations this produces smooth probability distributions over positions 1-30.

### Expected VG points decomposition

$$E[\text{VG points}] = E[\text{finish}] + E[\text{assists}] + E[\text{breakaway}]$$

- **Finish**: $\sum_{k=1}^{30} P(\text{position}=k) \times \text{points}_k$ via the scoring table
- **Assists**: $\sum_{k=1}^{3} P(\text{teammate in position } k) \times \text{assist bonus}_k$, computed per-simulation by checking teammate positions
- **Breakaway**: Heuristic based on rider strength and front-group probability (one-day only; skipped for stage races)

### One-day vs stage race differences

| Aspect           | One-day                                 | Stage race                                                  |
| ---------------- | --------------------------------------- | ----------------------------------------------------------- |
| PCS blending     | Single specialty (e.g. one-day points)  | Class-aware blend via `STAGE_RACE_PCS_WEIGHTS`              |
| Scoring table    | Cat 1/2/3 (finish + assist + breakaway) | `SCORING_STAGE` (aggregate GC position to total VG points)  |
| Breakaway points | Heuristic estimate                      | Skipped (included implicitly in aggregate scoring)          |
| Team size        | 6 riders                                | 9 riders                                                    |
| Constraints      | Cost only                               | Cost + classification (2 AR, 2 CL, 1 SP, 3+ UN)             |

## Data source inventory

### Currently used

- **Velogames** (velogames.com) - rider rosters, costs, season points, classifications, ownership %, historical race results
- **ProCyclingStats** (procyclingstats.com) - specialty ratings (one-day/GC/TT/sprint/climber), rankings, race results by year, startlist quality
- **Betfair** (betfair.com) - betting odds for win markets (optional, currently broken)

### Recommended future sources

- **PCS deeper data** - rider recent results (filterable by season/type), race climb profiles (length, gradient, elevation), profile difficulty icons (p0-p5)
- **FirstCycling** (firstcycling.com) - backup/cross-validation. Has unofficial Python API wrapper (github.com/baronet2/FirstCyclingAPI) and MCP server (github.com/r-huijts/firstcycling-mcp)
- **Oddschecker** - aggregated odds from multiple bookmakers, more resilient than Betfair alone
- **OpenWeatherMap** (free tier, 1000 calls/day) - race-day weather for cobbled classics

### Not recommended

- Strava/training data - not publicly available at rider level
- Paid APIs - out of scope
- Social media signals - too noisy

## Known issues

### Broken odds scraper

`getodds()` uses hardcoded Betfair CSS selectors that break when the page structure changes. The pipeline handles failure gracefully (try-catch, continues without odds) and a deprecation warning has been added. Planned replacement: Oddschecker integration with multiple bookmaker sources and overround removal.

### Team dynamics / domestique problem

The model treats riders independently but VG assists create team-level correlations. A strong domestique on a winning team may outscore a weaker leader. Current approach ignores this. Future options include:

- Maximum riders per team constraint in the optimiser
- Points discount for riders likely to sacrifice for a leader
- Team-role detection from PCS data (e.g. rider designated as leader vs domestique)

### Breakaway heuristic limitations

Breakaway points are estimated heuristically from simulated finishing positions, allocating sector credits based on position ranges (see the docstring on `estimate_breakaway_points()` for the full allocation table). The heuristic has a known sharp boundary at position 20, where riders gain a 4th sector. Actual breakaway data (e.g. from race reports or live timing) would improve this. The heuristic is a small fraction of total expected points for most riders, so the impact is limited.

### Stage race scoring calibration

`SCORING_STAGE` maps overall GC position to approximate total VG points accumulated across the race. Currently calibrated by rough inspection of historical VG grand tour results (winners typically 3000-4000 points, top 10 around 1000-2000). These values have not yet been validated against actual historical VG grand tour data. Systematic calibration against multiple historical VG stage race results would improve this.

### No backtesting

There is no systematic evaluation of prediction quality. We cannot currently measure whether the MC predictions are well-calibrated or whether the model improvements are actually helping.

## Phase 2: Better feature engineering

### Race-level history (implemented)

`getpcsracehistory()` fetches multi-year results for a specific race from PCS. This is already integrated into the Bayesian strength model as the "race history" signal, with recency weighting via the `hist_base_variance` and `hist_decay_rate` parameters.

### Recent form (not yet implemented)

- `getpcsrecentresults(rider_name; months=3)` - scrape rider's recent results from PCS
- Compute: race days, average position in similar races, recent PCS points, win/podium count
- Feed as additional signal into Bayesian strength model

### Course profile matching (not yet implemented)

- PCS profile icons (p0-p5 difficulty) and race climb data
- `getpcsraceprofile(pcs_slug, year)` - scrape profile data
- `course_similarity(race_a, race_b)` - similarity metric
- Weight specialty scores based on course fit; use results from similar courses as evidence

### Improved odds integration

- Multiple sources: Betfair Exchange + Oddschecker for resilience
- Implied probability with overround removal: `implied_prob = 1/odds`, normalise to sum = 1
- Treat as high-precision observation in Bayesian model
- Graceful fallback when sources are down

## Phase 3: Stage-by-stage simulation

PCS provides stage profile data at `/race/{slug}/{year}/route/stage-profiles` with difficulty, distance, elevation, and finish type. A proper stage race predictor would:

1. Scrape stage profiles and classify each stage (flat, hilly, mountain, TT, sprint finish)
2. For each stage, weight rider strengths by stage type (e.g. climbers favoured on mountain stages)
3. Simulate each stage independently to get per-stage VG points
4. Accumulate VG points across all stages for each rider
5. Optimise team selection over total accumulated expected points

This is a significant extension warranting its own PR. The current aggregate approach (simulating overall finishing positions) serves as a reasonable placeholder.

## Phase 4: Ownership-adjusted optimisation

### Leverage scoring

- VG `selected` column gives ownership percentages
- `leverage = E[VG_points] * (1 - ownership)` for tournament differentiation
- From DFS literature: in large tournaments, maximise P(winning) not E[points]

### Variance-aware optimisation

- MC framework enables this: for each sim, compute team score vs estimated field
- Optimise for P(your_team > field)
- Favours high-variance, low-correlation picks

### Team correlation / stacking

- Same-team riders have correlated outcomes AND generate assist points
- Optimiser could prefer same-team stacking when assist bonus outweighs diversification

## Phase 5: Historical backtesting

### Pipeline

For each past Superclassico race:

1. Reconstruct pre-race available data
2. Run prediction pipeline
3. Compare predicted team vs actual optimal team (from `build_model_oneday` / `build_model_stage`)
4. Metrics: points captured, rank vs optimal, prediction correlation

### Calibration

- Tune variance hyperparameters exposed in `estimate_rider_strength()` (PCS, VG, history, odds variances and odds normalisation divisor)
- Ablation study: which features improve predictions?
- Requires: systematically scraping VG historical results for all Superclassico races (2+ seasons)

## Phase 6: Machine learning

### Prerequisites

- Backtesting dataset of 90-135+ races (2-3 full Superclassico seasons)
- Feature engineering pipeline from Phases 2-4

### Approach

- Train XGBoost or Random Forest: features -> actual VG points
- Julia's MLJ.jl ecosystem
- Cross-validate by race to avoid overfitting
- Features: PCS specialty, race history, recent form, course profile similarity, VG cost/points, odds, ownership %
- Replaces Bayesian strength model

## DFS techniques (from DraftKings/FanDuel literature)

- **Leverage**: E[pts] * (1 - ownership) for differentiation
- **Ceiling vs floor**: high-variance for GPPs, consistent for cash
- **Correlation stacking**: same-team for correlated upside
- **Contrarian plays**: fade heavily-owned in large fields
