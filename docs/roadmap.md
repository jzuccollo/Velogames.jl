# Velogames.jl Improvement Roadmap

## Current State (MVP - Feb 2026)

The MVP implements expected Velogames points prediction using:
- Velogames scoring system encoded as data (finish position, assists, breakaway points by race category)
- PCS race-specific history for one-day classics
- Bayesian strength estimation combining PCS, VG, race history, and optional odds
- Monte Carlo race simulation converting strength to position probabilities to expected VG points
- JuMP optimization over expected VG points (replacing arbitrary composite scores)

## Data Source Inventory

### Currently Used
- **Velogames** (velogames.com) - rider rosters, costs, season points, classifications, ownership %, historical race results
- **ProCyclingStats** (procyclingstats.com) - specialty ratings (one-day/GC/TT/sprint/climber), rankings, race results by year, startlist quality
- **Betfair** (betfair.com) - betting odds for win markets (optional, fragile)

### Recommended Future Sources
- **PCS deeper data** - rider recent results (filterable by season/type), race climb profiles (length, gradient, elevation), profile difficulty icons (p0-p5)
- **FirstCycling** (firstcycling.com) - backup/cross-validation. Has unofficial Python API wrapper (github.com/baronet2/FirstCyclingAPI) and MCP server (github.com/r-huijts/firstcycling-mcp)
- **Oddschecker** - aggregated odds from multiple bookmakers, more resilient than Betfair alone
- **OpenWeatherMap** (free tier, 1000 calls/day) - race-day weather for cobbled classics

### Not Recommended
- Strava/training data - not publicly available at rider level
- Paid APIs - out of scope
- Social media signals - too noisy

## Phase 2: Better Feature Engineering

### Recent Form
- `getpcsrecentresults(rider_name; months=3)` - scrape rider's recent results from PCS
- Compute: race days, average position in similar races, recent PCS points, win/podium count
- Feed as additional signal into Bayesian strength model

### Course Profile Matching
- PCS profile icons (p0-p5 difficulty) and race climb data
- `getpcsraceprofile(pcs_slug, year)` - scrape profile data
- `course_similarity(race_a, race_b)` - similarity metric
- Weight specialty scores based on course fit; use results from similar courses as evidence

### Improved Odds Integration
- Multiple sources: Betfair Exchange + Oddschecker for resilience
- Implied probability with overround removal: `implied_prob = 1/odds`, normalize to sum = 1
- Treat as high-precision observation in Bayesian model
- Graceful fallback when sources are down

## Phase 3: Ownership-Adjusted Optimization

### Leverage Scoring
- VG `selected` column gives ownership percentages
- `leverage = E[VG_points] * (1 - ownership)` for tournament differentiation
- From DFS literature: in large tournaments, maximize P(winning) not E[points]

### Variance-Aware Optimization
- Monte Carlo framework enables this: for each sim, compute team score vs estimated field
- Optimize for P(your_team > field)
- Favors high-variance, low-correlation picks

### Team Correlation / Stacking
- Same-team riders have correlated outcomes AND generate assist points
- Optimizer could prefer same-team stacking when assist bonus outweighs diversification

## Phase 4: Historical Backtesting

### Pipeline
For each past Superclassico race:
1. Reconstruct pre-race available data
2. Run prediction pipeline
3. Compare predicted team vs actual optimal team (from `buildmodelhistorical`)
4. Metrics: points captured, rank vs optimal, prediction correlation

### Calibration
- Tune strength model weights, simulation noise parameters, odds weighting
- Ablation study: which features improve predictions?
- Requires: systematically scraping VG historical results for all Superclassico races (2+ seasons)

## Phase 5: Machine Learning

### Prerequisites
- Backtesting dataset of 90-135+ races (2-3 full Superclassico seasons)
- Feature engineering pipeline from Phases 2-3

### Approach
- Train XGBoost or Random Forest: features -> actual VG points
- Julia's MLJ.jl ecosystem
- Cross-validate by race to avoid overfitting
- Features: PCS specialty, race history, recent form, course profile similarity, VG cost/points, odds, ownership %
- Replaces Bayesian strength model

## Methodology Notes

### Bayesian Strength Estimation
Normal-normal conjugate model. Prior from PCS ranking, updated by VG points (moderate precision), race history (high precision, recency-weighted), and odds (highest precision). Missing data = prior unchanged. Output: posterior mean + variance.

### Monte Carlo Simulation
Gaussian noise (scaled by posterior uncertainty) added to strength. Sort = finishing positions. 10,000+ sims give smooth probability distributions. Handles assists (check teammate positions per sim).

### DFS Techniques (from DraftKings/FanDuel)
- **Leverage**: E[pts] * (1 - ownership) for differentiation
- **Ceiling vs floor**: high-variance for GPPs, consistent for cash
- **Correlation stacking**: same-team for correlated upside
- **Contrarian plays**: fade heavily-owned in large fields

### Scoring Decomposition
E[VG_points] = E[finish_points] + E[assist_points] + E[breakaway_points]
- Finish: P(position k) * points_for_k, summed over k=1..30
- Assists: P(teammate top-3) * assist_bonus
- Breakaway: heuristic based on rider type and front-group probability
