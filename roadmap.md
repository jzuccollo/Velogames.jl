# Velogames.jl improvement roadmap

## Current state (Feb 2026)

The package implements expected Velogames points prediction using:

- VG scoring system encoded as data (finish position, assists, breakaway points by race category)
- PCS race-specific history for one-day classics and stage races, plus terrain-similar race history via `SIMILAR_RACES`
- VG historical race points from past editions as a Bayesian signal
- PCS startlist filtering to remove DNS riders
- Bayesian strength estimation combining PCS, VG season points, PCS form scores, PCS race history (with variance penalties for similar races), VG race history, optional Cycling Oracle predictions, and optional Betfair odds
- Monte Carlo race simulation converting strength to position probabilities to expected VG points
- JuMP optimisation over expected VG points (replacing arbitrary composite scores)
- Risk-adjusted optimisation via ratio-based penalty: `E / (1 + γ * CV_down)` where `CV_down` is the downside coefficient of variation, giving scale-invariant penalisation of outcome variance
- Class-aware PCS blending for stage races (aggregate approach)

## Prediction engine data flows

### Signal inventory

The strength model combines multiple signals grouped into three precision families. Effective variances are computed from base values, fixed within-group ratios, and tuneable scale factors. Accessor functions (e.g. `pcs_variance(config)`) compute the effective variance from the config.

**Signal groups and default effective variances (at scale = 1.0):**

| Signal                | Source                    | Group     | Base variance | Notes                                                                                        |
| --------------------- | ------------------------- | --------- | ------------- | -------------------------------------------------------------------------------------------- |
| PCS specialty prior   | `getpcsriderpts_batch()`  | Ability   | 7.9           | Z-scored across field. For stage races, class-aware blending via `STAGE_RACE_PCS_WEIGHTS`    |
| VG season points      | `getvgriders()`           | Ability   | 1.4×scale     | Season-adaptive: `effective = vg_var * (1 + penalty * (1 - frac_nonzero))`                   |
| PCS form score        | `getpcsraceform()`        | History   | 0.9           | Z-scored across field. Top ~40-60 riders by recent cross-race results from PCS form page     |
| Trajectory            | Derived (PCS vs history)  | History   | 3.5           | `pcs_z - mean(history_z)`, z-scored. Captures improving/declining riders                     |
| PCS race history      | `getpcsracehistory()`     | History   | 3.0+decay/yr  | Recency-weighted: recent years get lower variance (higher precision)                         |
| Similar-race history  | `getpcsracehistory()`     | History   | +penalty      | Same as race history but with variance penalty. Races from `SIMILAR_RACES` terrain mapping   |
| VG race history       | `getvgracepoints()`       | History   | 4.8+decay/yr  | Z-scored per year. Actual VG points from past editions (finish + assist + breakaway)         |
| Cycling Oracle        | `get_cycling_oracle()`    | Market    | 0.5           | Independent signal from cyclingoracle.com predictions. Broader race coverage than Betfair    |
| Betting odds          | `getodds()`               | Market    | 0.3           | Strongest single signal when available. Uses Betfair Exchange API (market ID required)       |
| Odds/Oracle floor     | Derived (absence signal)  | Market    | var × 2.0     | When market data exists but rider absent, floor observation from residual probability mass    |

Odds are converted to strength via log-odds relative to a uniform baseline (`odds_normalisation`, default 1.0). This puts odds on a comparable scale to PCS z-scores and the logit-based position_to_strength (~±5 for a 150-rider field).

When odds or oracle data is available for a race, riders absent from the market receive a floor observation. The floor probability is computed as the residual probability mass (1 − sum of listed probabilities) divided by the number of absent riders. If the overround pushes residual probability below 0.001, the floor defaults to half the minimum listed probability. Floor observations use `floor_variance_multiplier` (default 2.0) times the base odds/oracle variance, reflecting lower precision than direct pricing.

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
- **ProCyclingStats** (procyclingstats.com) - specialty ratings (one-day/GC/TT/sprint/climber), rankings, race results by year, startlist quality, recent form scores
- **Betfair Exchange** (betfair.com) - betting odds for win markets via Exchange API (optional, requires credentials)
- **Cycling Oracle** (cyclingoracle.com) - race predictions with win probabilities, scraped from blog prediction pages (optional, broader coverage than Betfair)

### Recommended future sources

- **PCS deeper data** - race climb profiles (length, gradient, elevation), profile difficulty icons (p0-p5)
- **OpenWeatherMap** (free tier, 1000 calls/day) - race-day weather for cobbled classics

## Known issues

### Breakaway heuristic limitations

Breakaway points are estimated heuristically from simulated finishing positions, allocating sector credits based on position ranges (see `_breakaway_sectors()` in `src/simulation.jl`). The heuristic has a known sharp boundary at position 20, where riders gain a 4th sector. Actual breakaway data (e.g. from race reports or live timing) would improve this. The heuristic is a small fraction of total expected points for most riders, so the impact is limited.

### Notebooks excluded from the Quarto build

`stagerace_predictor.qmd`, `historical_analysis.qmd`, and `index.qmd` exist but are not in `_quarto.yml`. The stage race notebook has a small bug: references undefined `vg_history` variable at line 88 (fix: replace with `n_vg_hist > 0` check). To publish: fix the bug, add all three to `_quarto.yml`, and verify they render.

---

## Improvement phases (ordered by expected impact)

### Completed phases

| Phase | Description | Key details |
|-------|-------------|-------------|
| 1. Odds integration | Betfair Exchange API + Cycling Oracle scraping as Bayesian signals | Strongest single predictor. Betfair coverage limited to major races; Oracle covers most European professional races. Both can be active simultaneously. |
| 2. Calibration framework | Prior predictive checks, SBC, backtesting, prospective evaluation | `BayesianConfig` reparameterised to 3 scale factors + 2 decay rates. `backtesting.qmd` serves as unified calibration frontend. |
| 3. Course profile matching | Terrain-similar race history via `SIMILAR_RACES` | Manual curation of terrain groupings; automatic PCS profile scraping deferred as low priority. |
| 6. Leader/domestique roles | Domestique strength discount + max-per-team constraint | Heuristic leader detection by estimated strength within the field. |
| 7. Recent form signal | PCS form page scraping, z-scored as Bayesian update | Covers top ~40-60 riders; race-agnostic (no terrain filtering). |
| 8. Season-adaptive VG + trajectory | VG variance scales with season progress; trajectory captures improvement/decline | `vg_season_penalty` inflates early-season VG variance; trajectory compares current PCS to historical mean. |

### Open phases

### Phase 4: Stage race prediction (high impact for grand tours)

This is the single largest extension to the package. The current aggregate approach (simulating overall GC position and mapping to total VG points via `SCORING_STAGE`) ignores stage composition entirely. Top VG players emphasise that the parcours determines which rider types accumulate the most points: a Tour with 8 mountain stages and 2 ITTs favours climbers differently from one with 5 flat stages and a long ITT. The aggregate model cannot capture this.

The plan below extends the one-day infrastructure rather than replacing it. Each stage is treated as a mini one-day race with its own scoring table, strength weighting, and simulation. Teams are locked at race start (VG's main leaderboard does not allow mid-race changes), so the optimiser selects the team that maximises total expected VG points summed across all stages.

#### Research findings: VG stage race mechanics

Research completed March 2026 by fetching VG scoring/rules pages for TDF 2024, TDF 2025, and Vuelta 2025. The scoring rules are identical across all three grand tours (TDF, Vuelta, Giro).

**Team constraints (confirmed identical to `build_model_stage`):**

- 9 riders, cost ≤ 100 credits
- 2 All-Rounders, 2 Climbers, 1 Sprinter, 3 Unclassed, 1 Wild Card (any class)
- Teams locked at race start for the main leaderboard (VG also runs a separate "Replacements Contest" with transfer windows, but we target the main game)

**Per-stage scoring (same table for ALL stage types — no variation by flat/mountain/ITT):**

Stage finish positions 1–20:

```
220, 180, 160, 140, 120, 110, 95, 80, 70, 60, 50, 40, 35, 30, 25, 20, 16, 12, 8, 4
```

Positions 21+ score 0.

**Daily classification points (awarded after each stage):**

- Daily GC (positions 1–20): `30, 26, 22, 18, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1`
- Daily Points Classification (top 6): `12, 8, 6, 4, 2, 1`
- Daily Mountains Classification (top 6): `12, 8, 6, 4, 2, 1`

**In-stage bonus points:**

- Intermediate sprints (top 10, not on TT stages): `20, 16, 12, 8, 6, 5, 4, 3, 2, 1`
- HC climbs (top 8): `30, 25, 20, 15, 10, 6, 4, 2`
- Cat 1 climbs (top 5, not on TT stages): `15, 10, 6, 4, 2`
- Breakaway at 50% distance (≤30 riders, ≥5s gap): 20 points each

**Assist points (not awarded on ITT/TTT stages):**

- Stage finish assists (teammate in top 3): `8, 4, 2`
- Daily GC assists (teammate in GC top 3): `8, 4, 2`
- Team classification assists (team in top 3): `8, 4, 2`

**Final classification bonuses (end-of-race):**

- Final GC (positions 1–30): `600, 500, 400, 350, 300, 260, 220, 200, 180, 160, 140, 130, 120, 110, 100, 90, 80, 70, 60, 55, 50, 45, 40, 35, 30, 25, 20, 15, 10, 5`
- Final Points Classification (top 10): `120, 100, 80, 60, 40, 30, 20, 15, 10, 5`
- Final Mountains Classification (top 10): `120, 100, 80, 60, 40, 30, 20, 15, 10, 5`
- Final Team Classification (top 5): `50, 40, 30, 20, 10`

**TTT-specific scoring (if a stage is a TTT):**

- Only top 8 teams score: `50, 40, 30, 25, 20, 15, 10, 5` (distributed to finishing team members)

**VG data access patterns (confirmed):**

- Riders page: `https://www.velogames.com/{slug}/{year}/riders.php` with slug = `velogame` (TDF), `spain` (Vuelta), `giro` (Giro)
- Per-stage VG results: `ridescore.php?ga={game_id}&st={stage_number}` where `st=1..21` for stages, `st=0` for overall, and higher values for end-of-tour/final classifications
- Game ID: appears fungible (any valid `ga` parameter works — tested `ga=1`, `ga=13`, `ga=14` all return the same data)
- VG shows only aggregate points per rider per stage (no breakdown by scoring category)
- Columns: Rider, Team, Class, Cost, Selected, Points (same structure as one-day classics)
- ~270 riders per grand tour, cost range 4–32

**PCS data access (confirmed working via Julia HTTP.jl):**

PCS stage pages are accessible via the package's existing HTTP.jl infrastructure (with `User-Agent: Mozilla/5.0 (compatible; VelogamesBot/1.0)`). All URLs return 200:

- **Race overview** (`/race/{slug}/{year}`): stage list table with date, stage name, distance (km), and profile type icon via CSS class `span.icon.profile p{N}`. ITT stages indicated by "(ITT)" in stage name.
- **Individual stage pages** (`/race/{slug}/{year}/stage-{n}`): rich metadata in `<li><div class="title">...</div><div class="value">...</div></li>` pattern:
  - `Distance` (km), `Vertical meters`, `ProfileScore` (numeric difficulty), `Gradient final km` (%)
  - `Won how` (sprint, solo, time trial), `Parcours type`, `Avg. speed winner`
- **Stage profiles page** (`/race/{slug}/{year}/route/stage-profiles`): no tables but has profile image URLs with stage-type hints in filenames (e.g. `tour-de-france-2024-stage-3-climb-...`)

**PCS profile icon codes** (from race overview `span.icon.profile` CSS class):

| Code | Type | ProfileScore range | Vertical meters | Example |
|------|------|-------------------|-----------------|---------|
| `p1` | Flat | 6–53 | 283–2253 | Stage 3: flat sprint, PS=16 |
| `p2` | Hilly | 30–109 | 1859–3123 | Stage 2: hilly, PS=109 |
| `p3` | Hilly/mountain | ~177 | ~3091 | Stage 17: medium mountain, PS=177 |
| `p4` | Mountain/undulating | 73–187 | 720–3904 | Stage 1: hilly, PS=176; Stage 21: ITT, PS=73 |
| `p5` | High mountain | 241–380 | 4050–5071 | Stage 14: mountain top finish, PS=340 |

Note: `p4` is heterogeneous (includes both hilly road stages and mountain ITTs). Detecting ITTs from the stage name "(ITT)" keyword is more reliable than the profile code alone. The `ProfileScore` numeric value from individual stage pages is a better continuous measure than the discrete `p1`–`p5` codes.

**PCS slugs**: `tour-de-france`, `giro-d-italia`, `vuelta-a-espana`

**Implication for Step 2**: stage metadata can be scraped automatically from PCS as the primary approach, with manual encoding as the fallback. See Step 2.

**Key scoring observations for modelling:**

- A stage winner earns 220 points (finish) + up to 30 (GC) + potential climb/sprint/assist bonuses = ~280–320 per stage
- Over 21 stages, a dominant GC rider accumulates ~3000–4000 total VG points (confirmed: Pogačar scored 3841 in TDF 2024)
- Daily GC points (30 for leader, awarded every stage) are a substantial recurring source: 21 × 30 = 630 for a race leader across all stages
- Sprint/KOM classification points are modest daily (12 for leader) but the final classification bonuses are substantial (120 for the jersey winner)
- Breakaway points (20 per stage if in the break) can accumulate meaningfully for breakaway specialists across 21 stages
- The final GC bonus (600 for winner) is ~16% of a race winner's total — large enough to matter but not dominant

#### Step 1: Per-stage VG scoring tables (`src/scoring.jl`)

VG uses a single scoring table for all stages (no variation by stage type), which simplifies this step considerably. The scoring shape differs from one-day classics: stage races have separate categories for stage finish, daily classifications, in-stage bonuses, assists, and final classification bonuses.

**New struct:**

```julia
struct StageRaceScoringTable
    # Per-stage scoring (applied every stage)
    stage_finish_points::Vector{Int}         # length 20: positions 1-20
    daily_gc_points::Vector{Int}             # length 20: GC positions 1-20
    daily_points_class::Vector{Int}          # length 6: points classification top 6
    daily_mountains_class::Vector{Int}       # length 6: mountains classification top 6

    # In-stage bonuses
    intermediate_sprint_points::Vector{Int}  # length 10: sprint positions 1-10
    hc_climb_points::Vector{Int}             # length 8: HC climb positions 1-8
    cat1_climb_points::Vector{Int}           # length 5: Cat 1 climb positions 1-5
    breakaway_points::Int                    # points per rider in break at 50%

    # Assist points (stage finish, GC, team classification)
    stage_assist_points::Vector{Int}         # length 3: teammate in stage top 3
    gc_assist_points::Vector{Int}            # length 3: teammate in GC top 3
    team_class_assist_points::Vector{Int}    # length 3: team in team class top 3

    # Final classification bonuses (end of race)
    final_gc_points::Vector{Int}             # length 30: final GC positions 1-30
    final_points_class::Vector{Int}          # length 10: final points classification
    final_mountains_class::Vector{Int}       # length 10: final mountains classification
    final_team_class::Vector{Int}            # length 5: final team classification

    # TTT stage scoring (if applicable)
    ttt_team_points::Vector{Int}             # length 8: TTT team positions 1-8
end
```

**Changes to `src/scoring.jl`:**

1. Add the `StageRaceScoringTable` struct definition after the existing `ScoringTable` struct (line 27)
2. Add `const SCORING_GRAND_TOUR = StageRaceScoringTable(...)` with all the values from the research above
3. Keep the existing `SCORING_STAGE` (aggregate GC→total points lookup) but mark it as deprecated with a comment pointing to `SCORING_GRAND_TOUR`
4. Add `get_stage_race_scoring()::StageRaceScoringTable` that returns `SCORING_GRAND_TOUR` (single function — no stage-type dispatch needed since VG uses one table)
5. Add helper functions:
   - `stage_finish_points_for_position(position::Int, scoring::StageRaceScoringTable)::Int` — returns stage finish points (0 for positions >20)
   - `daily_gc_points_for_position(position::Int, scoring::StageRaceScoringTable)::Int` — returns daily GC points
   - `final_gc_points_for_position(position::Int, scoring::StageRaceScoringTable)::Int` — returns final GC bonus

**What does NOT change:** The existing `ScoringTable` struct and `SCORING_CAT1/2/3` are untouched. `get_scoring(category::Int)` still works for one-day races. The `get_scoring(:stage)` method continues to return `SCORING_STAGE` for backward compatibility.

**Tests:** Verify that `stage_finish_points_for_position(1, SCORING_GRAND_TOUR) == 220`, `final_gc_points_for_position(1, SCORING_GRAND_TOUR) == 600`, and positions outside the table return 0.

**Incremental:** This step is fully self-contained. No other files need modification.

#### Step 2: Stage metadata and race helpers (`src/race_helpers.jl`, `src/pcs_extended.jl`, `src/get_data.jl`)

PCS stage pages are accessible via the package's HTTP.jl infrastructure (confirmed working March 2026). Stage metadata can be scraped automatically as the primary approach.

**Approach: PCS scraping as primary + manual encoding as fallback**

**New struct in `src/race_helpers.jl`:**

```julia
struct StageProfile
    stage_number::Int
    stage_type::Symbol          # :flat, :hilly, :mountain, :itt, :ttt
    distance_km::Float64
    profile_score::Int          # PCS ProfileScore (0-400+), continuous difficulty measure
    vertical_meters::Int        # total climbing in metres
    gradient_final_km::Float64  # gradient of final km (%)
    n_hc_climbs::Int            # number of HC climbs (for bonus point estimation)
    n_cat1_climbs::Int          # number of Cat 1 climbs
    n_intermediate_sprints::Int # typically 1 per stage, 0 for TTs
    is_summit_finish::Bool      # inferred from gradient_final_km > 3%
end
```

**New struct in `src/race_helpers.jl`:**

```julia
struct StageRaceConfig
    name::String
    year::Int
    pcs_slug::String            # e.g. "tour-de-france"
    vg_slug::String             # e.g. "velogame"
    vg_game_id::Int             # e.g. 13 for TDF
    n_stages::Int               # typically 21
    stages::Vector{StageProfile}
    cache::CacheConfig
end
```

**Grand tour metadata constants in `src/race_helpers.jl`:**

Add a `_GRAND_TOUR_VG_IDS` dict mapping VG slug to game ID:

```julia
const _GRAND_TOUR_VG_IDS = Dict(
    "velogame" => 13,   # TDF — confirmed
    "spain" => 0,       # Vuelta — needs verification
    "giro" => 0,        # Giro — needs verification
)
```

**`setup_stage_race` function in `src/race_helpers.jl`:**

```julia
function setup_stage_race(
    race_name::String,
    year::Int,
    stages::Vector{StageProfile};
    cache_config::CacheConfig = DEFAULT_CACHE,
) -> StageRaceConfig
```

Takes stage profiles from PCS scraping (primary) or manual specification (fallback). Returns a `StageRaceConfig`.

**PCS stage metadata scraper (primary approach) in `src/pcs_extended.jl`:**

Add `getpcs_stage_profiles(pcs_slug::String, year::Int)` that scrapes stage metadata in two passes:

1. **Race overview** (`/race/{slug}/{year}`): parse the stage list table (second `<table>` on page) for stage number, name, distance, and profile code from `span.icon.profile p{N}` CSS class. Detect ITT/TTT from "(ITT)" or "(TTT)" in stage name.

2. **Individual stage pages** (`/race/{slug}/{year}/stage-{n}`): for each stage, parse the `<li><div class="title">...</div><div class="value">...</div></li>` pattern to extract `ProfileScore`, `Vertical meters`, and `Gradient final km`.

Stage type classification from the profile code + stage name:

- Stage name contains "(ITT)" or "Time Trial" (individual) → `:itt`
- Stage name contains "(TTT)" or "Team Time Trial" → `:ttt`
- Profile `p1` → `:flat`
- Profile `p2` → `:hilly`
- Profile `p3`–`p5` → `:mountain`
- Profile `p4` is heterogeneous — if stage name contains "(ITT)", classify as `:itt` rather than `:mountain`

Summit finish inferred from `Gradient final km > 3.0%`.

Returns `Vector{StageProfile}`. Caches via `cached_fetch` (stage profiles don't change once the route is published).

**Manual fallback convenience constructors:**

```julia
flat_stage(n; km=180.0, ps=15, vert=1000, sprints=1) =
    StageProfile(n, :flat, km, ps, vert, 0.2, 0, 0, sprints, false)
mountain_stage(n; km=180.0, ps=300, vert=4000, gradient=5.0, hc=1, cat1=1, sprints=0, summit=true) =
    StageProfile(n, :mountain, km, ps, vert, gradient, hc, cat1, sprints, summit)
hilly_stage(n; km=180.0, ps=100, vert=2500, gradient=1.0, cat1=1, sprints=1) =
    StageProfile(n, :hilly, km, ps, vert, gradient, 0, cat1, sprints, false)
itt_stage(n; km=40.0, ps=15, vert=300) =
    StageProfile(n, :itt, km, ps, vert, 0.2, 0, 0, 0, false)
ttt_stage(n; km=30.0) =
    StageProfile(n, :ttt, km, 5, 200, 0.1, 0, 0, 0, false)
```

These are the fallback for when PCS data is unavailable. Typical notebook usage:

```julia
# Primary: scrape from PCS
stages = getpcs_stage_profiles("tour-de-france", 2026)

# Fallback: manual encoding (if PCS is unavailable)
stages === nothing && (stages = [
    flat_stage(1; km=206),
    mountain_stage(2; km=185, ps=340, vert=4050, hc=2, cat1=1),
    itt_stage(3; km=32),
    # ...
])
```

**Per-stage PCS results scraper in `src/pcs_extended.jl`:**

```julia
function getpcs_stage_results(
    pcs_slug::String,
    year::Int,
    stage_number::Int;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
) -> DataFrame
```

URL: `https://www.procyclingstats.com/race/{slug}/{year}/stage-{n}`. Returns the same schema as `getpcsraceresults`: `DataFrame(position, rider, team, riderkey, in_breakaway, breakaway_km)`. The parsing logic is identical to `getpcsraceresults` — extract rider links from `<a href="rider/...">`, parse position from first `<td>`.

Add batch version:

```julia
function getpcs_all_stage_results(
    pcs_slug::String,
    year::Int,
    n_stages::Int;
    force_refresh::Bool = false,
    cache_config::CacheConfig = DEFAULT_CACHE,
) -> Dict{Int, DataFrame}
```

Returns a `Dict` mapping stage number to results DataFrame. Skips stages that fail to fetch (e.g. 403) with a warning.

**Per-stage VG results in `src/get_data.jl`:**

```julia
function getvg_stage_results(
    year::Int,
    vg_slug::String,
    game_id::Int,
    stage_number::Int;
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
) -> DataFrame
```

URL: `https://www.velogames.com/{slug}/{year}/ridescore.php?ga={game_id}&st={stage_number}`. Delegates to the existing `getvgracepoints` (which parses the `#users li` format). Returns `DataFrame(rider, team, score, riderkey)`.

```julia
function getvg_stage_race_totals(
    year::Int,
    vg_slug::String,
    game_id::Int;
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
) -> DataFrame
```

URL: `ridescore.php?ga={game_id}&st=0` (overall). Same return shape.

**Archival (in `src/cache_utils.jl`):**

New data types for the existing `save_race_snapshot`/`load_race_snapshot` API:

- `"stage_profiles"` — `DataFrame` with one row per stage
- `"pcs_stage_results_s{n}"` — per-stage PCS results (stage number in the data type string)
- `"vg_stage_totals"` — overall VG totals for the race
- `"vg_stage_s{n}"` — per-stage VG results (for retrospective analysis)

All stored under the existing archive path pattern: `{archive_dir}/{data_type}/{pcs_slug}/{year}.feather`.

**Tests:** Verify `setup_stage_race` returns a valid config, convenience constructors produce correct `StageProfile` values, and VG URL construction is correct.

**Incremental:** Step 2 can proceed in parallel with Step 1. The PCS scrapers and VG result scrapers are independent of the scoring tables.

#### Step 3: Stage-type strength modifiers (`src/simulation.jl`)

The current `estimate_strengths` produces a single strength and uncertainty per rider. For per-stage simulation, we need stage-type-specific strengths. Rather than running independent Bayesian estimation per stage type (which would need stage-type-specific signals we don't have), we apply additive modifiers to the base strength.

**New function:**

```julia
function compute_stage_type_modifiers(
    rider_df::DataFrame,
    base_strengths::Vector{Float64},
) -> Dict{Symbol, Vector{Float64}}
```

Takes the rider DataFrame (which has PCS specialty columns `oneday`, `gc`, `tt`, `sprint`, `climber` and a `class` or `classraw` column) and the base strengths from `estimate_strengths`. Returns a `Dict` mapping each stage type (`:flat`, `:hilly`, `:mountain`, `:itt`) to a vector of adjusted strengths.

**Algorithm:**

1. Z-score each PCS specialty column across the field: `gc_z[i] = (gc[i] - mean(gc)) / std(gc)` (with guards for zero std). Only z-score riders with `has_pcs_data == true`; riders without PCS data get modifier 0.0 (no shift from base strength).

2. For each stage type, compute a modifier blend using rider classification:

| Stage type | All-rounder | Climber | Sprinter | Unclassed |
|---|---|---|---|---|
| `:flat` | 0.2×gc_z + 0.4×sprint_z + 0.3×oneday_z + 0.1×tt_z | 0.3×gc_z + 0.1×sprint_z + 0.3×oneday_z + 0.3×climber_z | 0.05×gc_z + 0.7×sprint_z + 0.2×oneday_z + 0.05×tt_z | 0.2×gc_z + 0.3×sprint_z + 0.4×oneday_z + 0.1×tt_z |
| `:hilly` | 0.3×gc_z + 0.1×sprint_z + 0.3×oneday_z + 0.1×tt_z + 0.2×climber_z | 0.2×gc_z + 0.05×sprint_z + 0.2×oneday_z + 0.1×tt_z + 0.45×climber_z | 0.1×gc_z + 0.3×sprint_z + 0.35×oneday_z + 0.1×tt_z + 0.15×climber_z | 0.25×gc_z + 0.15×sprint_z + 0.35×oneday_z + 0.1×tt_z + 0.15×climber_z |
| `:mountain` | 0.25×gc_z + 0.5×climber_z + 0.15×tt_z + 0.1×oneday_z | 0.15×gc_z + 0.7×climber_z + 0.1×tt_z + 0.05×oneday_z | -0.5 (fixed penalty) | 0.2×gc_z + 0.4×climber_z + 0.15×tt_z + 0.25×oneday_z |
| `:itt` | 0.2×gc_z + 0.7×tt_z + 0.1×oneday_z | 0.15×gc_z + 0.35×tt_z + 0.35×climber_z + 0.15×oneday_z | 0.1×gc_z + 0.5×tt_z + 0.25×sprint_z + 0.15×oneday_z | 0.2×gc_z + 0.5×tt_z + 0.15×oneday_z + 0.15×climber_z |

1. `stage_strength[i] = base_strength[i] + modifier_scale * modifier_blend[i]`

`modifier_scale` (default 0.5) controls how much stage-type differentiation matters relative to overall ability. Too high and specialist riders dominate their stage types unrealistically; too low and there's no differentiation. Calibrate against historical stage results in Step 8.

**For `:ttt` stages:** TTT scoring goes to teams, not individual riders. Since we can't model team time trial performance from individual rider data, TTT stages are handled by awarding the team classification assist points to all riders on well-ranked teams. The modifier for TTT is the same as ITT (TT specialists are likely on strong TTT teams).

**Sprinter penalty on mountain stages:** Sprinters receive a fixed negative modifier on mountain stages (default -0.5) rather than a PCS-derived blend, because PCS specialty columns don't capture the binary nature of "can the sprinter survive the mountains at all?" This pushes sprinters towards the back of the field on mountain stages, where they typically finish just inside the time limit.

**Uncertainty:** Base posterior uncertainty is preserved. No stage-type-specific uncertainty adjustment — the modifier shifts the mean but the variance stays the same. This is a simplification: in reality, sprinters have higher uncertainty on mountain stages (they might abandon), but modelling this adds complexity for v1.

**Modifier weight storage:**

```julia
const STAGE_TYPE_MODIFIER_WEIGHTS = Dict{Symbol, Dict{String, Vector{Pair{Symbol, Float64}}}}(
    :flat => Dict(
        "allrounder" => [:gc => 0.2, :sprint => 0.4, :oneday => 0.3, :tt => 0.1],
        # ...
    ),
    # ...
)
```

This makes the weights explicit data, easy to inspect and tune. Store adjacent to `STAGE_RACE_PCS_WEIGHTS` (the existing class-aware blending dict for aggregate stage races) to keep related logic together.

**Relationship to existing `compute_stage_race_pcs_score`:** That function computes a single blended PCS score for the aggregate model. `compute_stage_type_modifiers` replaces it for per-stage prediction. The aggregate function remains for backward compatibility.

**Tests:** Given a rider DataFrame with known PCS values and a known class, verify that modifiers for different stage types have the correct relative ordering (sprinter highest on flat, climber highest on mountain, TT specialist highest on ITT).

**Incremental:** Depends on Step 2 (needs stage type definitions) but not on Step 1 (scoring tables).

#### Step 4: Per-stage simulation (`src/simulation.jl`)

This is the core new logic. Replaces the aggregate GC-position→total-points simulation with per-stage-level simulation.

**New function:**

```julia
function simulate_stage_race(
    rider_df::DataFrame,
    stages::Vector{StageProfile},
    stage_strengths::Dict{Symbol, Vector{Float64}},
    uncertainties::Vector{Float64},
    scoring::StageRaceScoringTable;
    n_sims::Int = 500,
    cross_stage_alpha::Float64 = 0.7,
    rng::AbstractRNG = Random.default_rng(),
) -> Matrix{Float64}  # n_riders × n_sims
```

Returns a matrix of total VG points per rider per simulation draw.

**Algorithm for each simulation draw `r`:**

1. **Draw persistent rider noise:** For each rider `i`, draw `rider_noise[i] ~ N(0, 1)`. This persists across all stages within this draw.

2. **For each stage `s` in `stages`:**
   a. **Draw stage-specific noise:** For each rider `i`, draw `stage_noise[i] ~ N(0, 1)`.
   b. **Compute noisy strength:** `noisy[i] = stage_strengths[stage_type][i] + uncertainties[i] * (α * rider_noise[i] + sqrt(1-α²) * stage_noise[i])` where `α = cross_stage_alpha`. The `sqrt(1-α²)` factor ensures total noise variance is `uncertainties[i]²` regardless of `α`.
   c. **Rank riders** by noisy strength (descending) to get positions.
   d. **Score stage finish points:** `stage_finish_points_for_position(position, scoring)` for positions 1–20.
   e. **Score stage assist points:** For riders whose teammate finishes in the top 3, add the stage assist points. Skip on ITT/TTT stages.
   f. **Track cumulative GC standings:** Maintain a running sum of positions per rider across stages. The rider with the lowest cumulative position sum is the GC leader. Award `daily_gc_points` based on the GC rankings after this stage.
   g. **Score GC assist points:** For riders whose teammate is in the GC top 3, add GC assist points. Skip on ITT stages.

3. **After all stages: Final classification bonuses.**
   a. **Final GC:** Award `final_gc_points` based on cumulative GC rankings.
   b. **Final Points Classification:** Approximate by counting the number of top-5 stage finishes per rider on flat/hilly stages weighted by sprinter profile. Award `final_points_class` to the top 10.
   c. **Final Mountains Classification:** Approximate by counting top-5 finishes on mountain stages. Award `final_mountains_class` to the top 10.
   d. **Final Team Classification:** Sum the top 3 riders' cumulative positions per team. Award `final_team_class` to the top 5 teams.

4. **Sum all points** across stages + final bonuses to get total VG points for this draw.

**What we deliberately skip in v1:**

- **In-stage climb/sprint bonus points** (HC climbs, Cat 1 climbs, intermediate sprints): These require knowing the number and timing of climbs/sprints within each stage, and simulating intermediate results within a stage. The `StageProfile.n_hc_climbs` field captures the count, but simulating who is first over each climb would require a much more complex model. Instead, we approximate their effect: riders who finish well on mountain stages also tend to take climb points, so the stage finish simulation implicitly captures much of this. We can add explicit climb/sprint simulation later.
- **Breakaway modelling:** One-day breakaway modelling (from `compute_breakaway_rates`) does not translate directly to stage races where breakaway dynamics differ per stage. Skip for v1.
- **Abandonment modelling:** Skip for v1. All riders complete all stages.
- **Team classification assists:** Require tracking per-team cumulative times, which adds moderate complexity. Include in v1 since the team classification tracking is needed for final classification anyway.

**Approximation for sprint/KOM classifications:**

The daily points classification points (12 for leader) and daily mountains classification (12 for leader) are modest compared to stage finish points (220 for winner). For v1, approximate:

- **Sprint classification leader:** The rider with the most top-5 finishes on `:flat` stages (weighted by sprint_z). Recalculate after each stage.
- **KOM classification leader:** The rider with the most top-5 finishes on `:mountain` stages (weighted by climber_z). Recalculate after each stage.

These approximations are crude but capture the first-order effect: sprinters accumulate sprint points on flat stages, climbers accumulate KOM points on mountain stages.

**Integration with `resample_optimise`:**

The existing `resample_optimise` draws noisy strengths, scores per draw, and optimises. For stage races, we replace the inner scoring loop with `simulate_stage_race`. However, the architecture differs: `resample_optimise` draws strengths once per resample and scores a single "race"; for stage races, each resample draw involves 21 stages with correlated noise.

Add `resample_optimise_stage`:

```julia
function resample_optimise_stage(
    df::DataFrame,
    stages::Vector{StageProfile},
    stage_strengths::Dict{Symbol, Vector{Float64}},
    scoring::StageRaceScoringTable,
    build_model_fn::Function;
    team_size::Int = 9,
    n_resamples::Int = 500,
    cross_stage_alpha::Float64 = 0.7,
    rng::AbstractRNG = Random.default_rng(),
    max_per_team::Int = 0,
    risk_aversion::Float64 = 0.5,
) -> (DataFrame, Vector{DataFrame}, Matrix{Float64})
```

Internally calls `simulate_stage_race` for all `n_resamples` draws at once, then for each draw optimises the team using `build_model_fn`. Same output shape as `resample_optimise`: `(df, top_teams, sim_vg_points)`.

**Computational cost:** 21 stages × 500 resamples × ~170 riders ≈ 1.8M sortperm operations. Each sortperm of 170 elements takes ~1μs, so total ≈ 2 seconds. The optimisation (500 ILP solves) dominates at ~10–15 seconds total. Acceptable.

**Tests:**

- Verify that a rider with high climber strength and low sprint strength accumulates more points on mountain stages than flat stages.
- Verify that the GC leader after all stages receives the final GC bonus.
- Verify that `cross_stage_alpha=1.0` produces identical rankings across all stages (full correlation) and `cross_stage_alpha=0.0` produces independent rankings.
- Verify total points for a dominant GC rider are in the 3000–4000 range (matching historical VG data).

**Incremental:** Depends on Steps 1 (scoring tables), 2 (stage profiles), and 3 (stage-type modifiers).

#### Step 5: Solver integration (`src/race_solver.jl`)

Modify `solve_stage` to use per-stage simulation when stage profiles are provided.

**Changes to `solve_stage`:**

Add a `stages::Vector{StageProfile} = StageProfile[]` keyword parameter. When `stages` is non-empty, use the per-stage pipeline; when empty, fall back to the existing aggregate approach.

Per-stage pipeline:

1. Call `_prepare_rider_data(...)` as before — the data fetching is identical.
2. Call `estimate_strengths(data; race_type=:stage, ...)` as before to get base strengths.
3. Call `compute_stage_type_modifiers(predicted, predicted.strength)` to get per-stage-type strengths.
4. Call `resample_optimise_stage(predicted, stages, stage_strengths, SCORING_GRAND_TOUR, build_model_stage; ...)`.
5. Extract chosen team and return.

**New `solve_stage` signature:**

```julia
function solve_stage(
    config::RaceConfig;
    stages::Vector{StageProfile} = StageProfile[],  # NEW: empty = aggregate approach
    racehash::String = "",
    history_years::Int = 3,
    betfair_market_id::String = "",
    oracle_url::String = "",
    n_resamples::Int = 500,
    excluded_riders::Vector{String} = String[],
    filter_startlist::Bool = true,
    cache_config::CacheConfig = config.cache,
    force_refresh::Bool = false,
    qualitative_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    max_per_team::Int = 0,
    risk_aversion::Float64 = 0.5,
    breakaway_dir::String = "",
    cross_stage_alpha::Float64 = 0.7,  # NEW
    modifier_scale::Float64 = 0.5,     # NEW
) -> (DataFrame, DataFrame, Vector{DataFrame}, Matrix{Float64})
```

Return type unchanged: `(predicted, chosenteam, top_teams, sim_vg_points)`. The `predicted` DataFrame gains new columns:

- `stage_strength_flat`, `stage_strength_mountain`, `stage_strength_hilly`, `stage_strength_itt`: per-stage-type adjusted strengths
- `expected_vg_points`: now represents total across all stages (rather than GC-position lookup)

**Archival:** Archive stage profiles alongside predictions:

```julia
if !isempty(stages) && !isempty(config.pcs_slug)
    stage_df = DataFrame(
        stage_number = [s.stage_number for s in stages],
        stage_type = [String(s.stage_type) for s in stages],
        distance_km = [s.distance_km for s in stages],
        # ...
    )
    save_race_snapshot(stage_df, "stage_profiles", config.pcs_slug, config.year)
end
```

**`build_model_stage` is unchanged.** It still enforces classification constraints (2 AR, 2 CL, 1 SP, 3 UN) and the cost limit. The only change is that the `expected_vg_points` column it optimises now reflects per-stage simulation rather than aggregate GC lookup.

**Backward compatibility:** When `stages` is empty, the function behaves exactly as before (aggregate approach). No existing code breaks.

**Tests:** Run `solve_stage` with and without stages on the same rider data. Verify the per-stage version produces different (and hopefully better) team selections. Verify the aggregate fallback still works.

**Incremental:** Depends on Step 4. The data fetching, strength estimation, and optimisation infrastructure are all reused.

#### Step 6: Notebooks (`notebooks/stagerace_predictor.qmd`, `notebooks/team_assessor.qmd`)

**Stage race predictor notebook (`stagerace_predictor.qmd`):**

Rewrite from scratch. Structure mirrors `oneday_predictor.qmd`:

**Configuration section:**

```julia
race_name = "tdf"
race_year = 2025
racehash = ""

# Stage profiles — define manually from the published route
stages = [
    flat_stage(1; km=206),
    mountain_stage(2; km=185, hc=2, cat1=1, summit=true),
    # ... all 21 stages
]

# Optional data sources
betfair_market_id = ""
oracle_url = ""
odds_df = nothing
qualitative_df = nothing

# Optimisation
n_resamples = 500
history_years = 3
domestique_discount = 0.3
risk_aversion = 0.5
max_per_team = 0
cross_stage_alpha = 0.7
modifier_scale = 0.5

# Cache
race_cache = CacheConfig(joinpath(homedir(), ".velogames_cache"), 6)
```

**Stage profile summary section:**

- Table showing all 21 stages: number, type, distance, n_hc_climbs, n_cat1_climbs, summit finish
- Summary: "X flat stages, Y mountain stages, Z hilly stages, W ITTs"

**Prediction section:**

- Call `solve_stage(config; stages=stages, ...)` with the per-stage pipeline
- Show data sources, signal impact (same structure as one-day notebook)
- Show per-stage-type strength distributions (Plotly box plots of flat/mountain/ITT strengths by rider class)

**Optimal team section:**

- Team table with classification breakdown
- **Stage-type contribution table**: for each selected rider, show expected points broken down by stage type (flat, mountain, hilly, ITT). Requires running `simulate_stage_race` once more with per-stage tracking.
- Signal waterfall (reuse `format_signal_waterfall`)

**Full rankings and alternative picks:**

- Same structure as one-day notebook

**Fix the existing `vg_history` bug at line 87** (references undefined variable `vg_history` — should be `n_vg_hist` or similar).

**Team assessor (`team_assessor.qmd`):**

The team assessor needs to handle both one-day and stage races. Decision: **extend the existing notebook rather than creating a separate stage race version.** Rationale:

- The retrospective analysis structure (your team vs model's team vs hindsight-optimal) applies to both race types
- Code duplication between two notebooks would be worse than a few `if config.type == :stage` branches
- The stage-race-specific features (per-stage performance breakdown) are additive — they don't conflict with the one-day flow

**Changes to `team_assessor.qmd`:**

1. Add a `stages` variable in the configuration section (empty vector for one-day, populated for stage races)
2. In the prediction section, detect `config.type == :stage` and call `solve_stage(config; stages=stages, ...)` instead of `solve_oneday`
3. In the retrospective section:
   - Fetch per-stage VG results via `getvg_stage_results` for each stage
   - Show a per-stage performance table: for each rider in your team, show their VG points per stage
   - Show which stages each rider contributed most/least
   - Aggregate metrics (actual total, hindsight optimal, points captured ratio) work the same as one-day
4. Archive results: call `archive_race_results` with the new stage race data types

**Decision: team_assessor vs separate notebook:** Extend the existing notebook. The per-stage retrospective analysis is an additive feature that slots into the existing structure. A separate `stagerace_assessor.qmd` would duplicate ~70% of the code.

#### Step 7: Backtesting and prospective evaluation (`src/backtest.jl`, `src/prospective_eval.jl`)

**Decision: backtesting.qmd — extend, don't duplicate.** Rationale:

- Backtesting metrics are conceptually identical for one-day and stage races (Spearman rho, top-N overlap, points captured ratio on total VG points)
- The data pipeline differs (need stage profiles and per-stage VG results), but the evaluation logic is shared
- The notebook already has a clear section structure that can accommodate a "Stage race backtest" section
- Combining avoids duplicating the prospective evaluation, calibration, and signal analysis sections

**New functions in `src/backtest.jl`:**

```julia
struct BacktestStageRace
    name::String              # e.g. "Tour de France"
    year::Int
    pcs_slug::String          # e.g. "tour-de-france"
    vg_slug::String           # e.g. "velogame"
    vg_game_id::Int
    n_stages::Int
    stages::Vector{StageProfile}
end
```

```julia
function build_stage_race_catalogue(
    years::Vector{Int};
) -> Vector{BacktestStageRace}
```

Generates entries for TDF, Giro, Vuelta across the requested years. Stage profiles must be manually encoded for each historical race (or loaded from archived stage profile data). For the initial implementation, encode profiles for TDF 2023, 2024, 2025 (3 races) — enough for initial validation. Giro and Vuelta can be added incrementally.

```julia
function backtest_stage_race(
    race::BacktestStageRace;
    cache_config::CacheConfig = DEFAULT_CACHE,
    n_sims::Int = 500,
    cross_stage_alpha::Float64 = 0.7,
) -> BacktestResult
```

Runs the per-stage prediction pipeline on historical data and compares against actual VG totals. Returns a `BacktestResult` with the same metrics as one-day backtesting. The function:

1. Fetches VG rider data for the race
2. Runs `estimate_strengths` + `compute_stage_type_modifiers`
3. Runs `simulate_stage_race` to get predicted total VG points
4. Fetches actual VG totals via `getvg_stage_race_totals`
5. Computes Spearman rho, top-N overlap, points captured ratio

**Aggregate vs per-stage comparison:**

Also run the existing aggregate model (`predict_expected_points` with `SCORING_STAGE`) on the same races to measure improvement. Report side-by-side in the notebook.

**Prospective evaluation (`src/prospective_eval.jl`):**

No code changes needed. The existing `evaluate_prospective` and `prospective_season_summary` functions work on archived predictions and PCS results, both of which use the same schema for stage races as for one-day races. The `predictions` archive contains `strength` and `uncertainty` columns regardless of race type, and the PCS results archive contains `position` columns.

The PIT calibration (`prospective_pit_values`) requires simulation draws, which uses `simulate_vg_draws`. For stage races, we would need a `simulate_vg_draws_stage` variant that uses per-stage simulation. This is a follow-up enhancement — for v1, the prospective PIT calibration applies only to one-day races.

**Changes to `backtesting.qmd`:**

Add a "Stage race backtest" section after the one-day backtest:

1. Build stage race catalogue for available years
2. Run `backtest_stage_race` on each
3. Show the same metric tables as the one-day backtest
4. Show aggregate-vs-per-stage comparison table

#### Implementation order and dependencies

```
Step 1: Scoring tables (scoring.jl)          ← self-contained
Step 2: Stage metadata + scrapers            ← self-contained
    ↓
Step 3: Stage-type modifiers (simulation.jl) ← depends on Step 2
    ↓
Step 4: Per-stage simulation (simulation.jl) ← depends on Steps 1, 2, 3
    ↓
Step 5: Solver integration (race_solver.jl)  ← depends on Step 4
    ↓
Step 6: Notebooks                            ← depends on Step 5
    ↓
Step 7: Backtesting + prospective eval       ← depends on Steps 5, 6
```

Steps 1 and 2 can proceed in parallel. Steps 3–5 are sequential. Steps 6 and 7 can proceed in parallel once the solver works.

**Minimum viable version (v1):** Steps 1–6. This gives a working stage race predictor notebook and team assessor support for stage races.

**Follow-up enhancements (v2):**

- In-stage climb/sprint bonus simulation (requires per-stage climb/sprint counts)
- Breakaway modelling for stage races
- Abandonment modelling (survival probability per stage)
- Stage-race-specific PIT calibration in prospective evaluation
- Giro and Vuelta stage profiles for backtesting (extend the 3-race TDF-only catalogue)
- Automatic stage profile fetching from PCS when their 403 block is relaxed

#### Design decisions (resolved)

1. **Single strength vs per-stage strength:** Base strength + stage-type modifiers (decided). Avoids needing stage-type-specific signals. Modifier weights are the main calibration target.

2. **Cross-stage correlation (α=0.7):** Captures persistent grand tour form. Too high (α→1) = identical rankings every stage; too low (α→0) = independent stages. Calibrate against historical TDF data in Step 7.

3. **Scoring table uniformity:** VG uses a single scoring table for all stage types (confirmed). No per-stage-type scoring dispatch needed.

4. **Team constraints:** Identical to the existing `build_model_stage` (confirmed: 2 AR, 2 CL, 1 SP, 3 UN, 1 wild card, 9 riders, 100 credits).

5. **Team lock-in:** Teams locked at race start for main leaderboard (confirmed). The VG "Replacements Contest" is a separate game that we ignore.

6. **Notebook strategy:** Extend existing team_assessor.qmd and backtesting.qmd rather than creating separate stage race versions. Rewrite stagerace_predictor.qmd from scratch.

7. **PCS stage data:** Manual stage profile encoding as the primary approach, with optional PCS scraping as a fallback (PCS currently blocks automated requests). Stage profiles are published months before the race, so manual encoding is feasible.

8. **v1 scope:** Skip in-stage bonuses (climb/sprint point simulation), breakaway modelling, and abandonment. Focus on: per-stage finish simulation, daily GC tracking, final classification bonuses, and stage-type strength differentiation. These skipped features are additive and can be layered on once the basic pipeline works.

### Phase 5: Ownership-adjusted optimisation (high impact, contest-dependent)

The impact of ownership adjustment depends entirely on the contest type. Haugh & Singal (2021, *Management Science*) demonstrated a 7x return differential (350% vs 50%) from ownership-adjusted play in large-field GPP tournaments. However, for the small private leagues typical of VG, the effect is substantially smaller.

VG's `selected` column gives ownership percentages. Simple leverage scoring (`E[VG_points] * (1 - ownership)`) captures most of the benefit. More sophisticated approaches (probability-of-winning optimisation, opponent modelling via Dirichlet-multinomial) are warranted only for large-field contests.

### Phase 9: Correlated position simulation (low-moderate impact)

The current approach of independent position simulation with per-simulation assist computation already captures the most important correlation effect (teammate assists). Adding explicit rider-rider correlation via Cholesky decomposition would produce more realistic variance profiles but the incremental gain is modest.

The Sharpstack paper and DFS community research shows that ignoring correlation can approximately double the standard deviation of simulation outputs in team sports (NFL, NBA). However, cycling correlation structure differs from team sports: the main correlation is through team tactics and race dynamics rather than through mechanical scoring links (like quarterback-receiver in NFL). For one-day classics, independent position simulation is a reasonable approximation.

**Where correlation matters more:**

- Stage races: crash/illness correlations persist across stages
- Team-heavy strategies: when stacking 3+ riders from one team, correlated simulation better estimates the variance profile
- Weather-dependent races: cobbled classics where rain creates correlated outcomes for specialists

**Implementation if pursued:**

- Estimate pairwise correlation from historical results (same-team bonus, race-type clustering)
- Use Cholesky decomposition to generate correlated noise vectors in `simulate_race()`
- The assist computation already runs per-simulation, so it would automatically benefit from correlated positions

### Phase 10: Machine learning (unknown impact, requires prerequisites)

Replacing the Bayesian strength model with a trained ML model requires a backtesting dataset of 90-135+ races (2-3 full Superclasico seasons), which does not yet exist. Academic results in cycling prediction show marginal gains from ML over well-tuned baselines: Kholkine et al. (2021) achieved 0.82 NDCG@10 with learn-to-rank, but this was only ~3% above a tuned logistic regression baseline. The FPL literature confirms that Bayesian approaches provide "strong and stable baselines" and that ML augmentation yields "modest but consistent improvements."

**Prerequisites:**

- Backtesting dataset of 90-135+ races (2-3 full Superclasico seasons)
- Feature engineering pipeline from Phases 1-7

**Approach:**

- Train XGBoost or Random Forest: features -> actual VG points
- Julia's MLJ.jl ecosystem
- Cross-validate by race to avoid overfitting
- Features: PCS specialty, race history, recent form, course profile similarity, VG cost/points, odds, ownership %
- Could augment rather than replace Bayesian model (ML predictions as an additional signal)

**Alternative: ensemble approach:**

Rather than replacing the Bayesian model entirely, use ML predictions as an additional signal in the Bayesian framework. This preserves the principled uncertainty quantification whilst allowing ML to capture nonlinear feature interactions. The FPL literature found this hybrid approach consistently outperformed either pure Bayesian or pure ML.

---

## Additional ideas from the literature

### VG cost model exploitation

Top VG community players (The Pelotonian, Sicycle, ProCyclingUK) consistently emphasise that value identification is more important than picking the race winner. VG costs are set by an algorithm based on historical performance, creating systematic mispricings:

- **Young riders on upward trajectories** are underpriced because the cost model is backward-looking
- **Classification category mispricings**: the mandatory class constraints (2 AR, 2 CL, 1 SP, 3+ UN) create within-category pricing inefficiencies that the optimiser already exploits, but identifying which categories are systematically cheaper in a given race could inform pre-optimisation analysis
- **Rider returning from injury**: riders whose cost reflects a period of absence but who are now fully fit

An explicit "value model" that predicts VG cost based on current ability (and compares to actual cost) would highlight where the pricing algorithm is most wrong.

### Startlist-adjusted strength

The current model does not account for who else is in the race when estimating strength. A Cat 1 monument with a full WorldTour field is substantially harder than a Cat 3 semi-classic. PCS startlist quality data (already available via `getpcsracestartlist()`) could adjust the prior: a rider's expected position in a weak field should be higher than in a strong field, even with the same underlying strength.

**Implementation:** Compute field strength as the mean or median PCS points of the startlist, then adjust the position-to-strength mapping accordingly. Alternatively, use field strength as a scaling factor on the simulation noise (stronger fields compress the position distribution).

### Weather-dependent race modelling

Cobbled classics (Flanders, Roubaix) have dramatically different dynamics in wet vs dry conditions. Rain on cobbles amplifies the advantage of specialists and increases attrition. The roadmap already lists OpenWeatherMap as a potential source. The impact is narrow (only a handful of races per season) but the signal is strong for those races.

### Multi-objective optimisation

The current optimiser maximises a single objective (expected points or leverage-weighted points). An alternative is to present the Pareto frontier between expected points and variance (or between expected points and ownership differentiation), allowing the user to choose their preferred risk profile. JuMP supports multi-objective optimisation, and the MC framework already produces the variance estimates needed.

### Transfer learning from team sports DFS

The NFL/NBA DFS literature is substantially more developed than cycling-specific research. Key transferable concepts not yet in the roadmap:

- **Late swap / news integration**: incorporating last-minute information (DNS, weather changes, tactical announcements) just before the lock. The current pipeline could be re-run with updated data but there is no structured workflow for this.
- **Opponent modelling**: estimating the distribution of opponent teams from ownership data, then optimising against that distribution rather than in isolation. This is the sophisticated version of ownership-adjusted optimisation.
- **Bankroll management**: Kelly criterion or fractional Kelly for sizing bets across multiple contests. Not directly relevant to VG (no monetary stakes) but the underlying principle of diversifying across races (entering multiple leagues with different strategies) applies.

### Bayesian model extensions

The current normal-normal conjugate model could be extended in several directions without moving to full ML:

- **Heavy-tailed distributions**: Replace Gaussian noise in `simulate_race()` with Student-t distributions to better model the long tails of cycling results (crashes, breakaways, exceptional performances). This would naturally produce higher-variance predictions for less predictable riders.
- **Hierarchical priors**: Share information across riders of the same team, nationality, or specialty class. A strong Ineos GC result could partially inform expectations for other Ineos GC riders.
- **Time-varying strength**: Allow rider strength to drift over the season rather than treating it as static. This partially addresses the recent form question without requiring a separate form signal.

---

## Signal precision rationale (March 2026)

The Bayesian model combines signals from three precision groups. This section documents the evidence and reasoning behind the current parameter settings, so that future calibration work can build on it rather than re-deriving from scratch.

### Evidence on relative signal quality

**Betting odds are the strongest available predictor of sports outcomes.** This is one of the most robust findings in sports forecasting research. A systematic review of ML in sports betting (arxiv:2410.21484) found that prediction accuracy from ML models "reaches not more than about 70% and is at the same level as model-free bookmaker odds alone." In direct comparisons, the best gradient boosting model achieved RPS of 0.2156 vs bookmaker 0.2012 — models cannot reliably outperform the market. Franck et al. (2010) found betting exchanges are more accurate than bookmakers, and both outperform statistical models. Betting odds aggregate private information (team tactics, form, injury knowledge, insider assessments) that no public data source can replicate.

**The favourite-longshot bias** means odds overestimate longshot chances and slightly underestimate favourites. This implies odds are most accurate for the top ~20-30 riders who matter most for fantasy team selection.

**For cycling specifically**, Kholkine et al. (2021) tested 15 feature categories using learn-to-rank (LambdaMART) on six spring classics. Feature importance findings:

- Overall PCS performance (career and season-long points) was consistently important across all races
- Race-specific history was the single most important feature for Tour of Flanders and Paris-Roubaix
- Results from terrain-similar races were strongly predictive (LBL relied on Flèche Wallonne results)
- **6-week pre-race form received minimal weight** — "the model does not seem to learn a lot from" short-term form features
- Career trajectory had minor influence; the model "gives priority to consistency"
- The model only marginally beat fan predictions (NDCG 0.55 vs 0.52)

**Key implication for signal design**: odds already incorporate form, history, and ability. For riders with odds, the non-market signals are largely redundant because odds-makers watch all the same data. The marginal value of additional signals comes from (a) riders without odds coverage (~80% of the field), and (b) very recent information not yet reflected in pre-race odds.

### Current parameter settings and justification

**Scale factors** (higher = more trust in the signal group):

| Factor | Value | Rationale |
|--------|-------|-----------|
| `market_precision_scale` | 4.0 | Odds are the best single predictor. At 4.0, odds variance = 0.25, giving precision 4.0 per observation. Higher values risk overconfidence for favourites. |
| `history_precision_scale` | 2.0 | Controls form, race history, VG history, and trajectory. At 2.0, form gets precision 2.0 (slightly below odds) and race history ~0.67 per year (~2.0 over 3 years). Calibration was good. The main tension: form is almost as precise as odds (2.0 vs 3.0), but the ML evidence says form is weak. However, lowering this scale would also weaken race history, which IS one of the best predictors. |
| `ability_precision_scale` | 1.0 | PCS specialty and VG season points are broad career/season aggregates. At precision 1.0 they're one-third of odds. Research supports career consistency mattering for identifying contenders, but the signal is too crude to deserve high precision. |

**Within-group ratios** (fixed domain knowledge, not tuned):

| Ratio | Value | Rationale |
|-------|-------|-----------|
| `_odds_to_oracle_ratio` | 2.0 | Oracle is a single algorithm; odds aggregate many models and private information. Research says models don't beat odds, suggesting Oracle should be less precise. The practical difference between 1.5 and 2.0 is small since both are in the high-precision market group. |
| `_form_to_hist_ratio` | 3.0 | Per observation, form (current 6-week fitness) is more precise than a single year of race history (stale, different conditions, different pelotons). But 3 years of history collectively match form's precision, which the research supports — race-specific results are among the best predictors. |
| `_form_to_vg_hist_ratio` | 5.0 | VG history adds noise through the nonlinear VG scoring transformation (top-10 finishes heavily rewarded, scoring floor at position 31+). 1.67x noisier than PCS race history per observation. |
| `_form_to_trajectory_ratio` | 3.0 | Career trajectory (improving vs declining) is a blunt signal for predicting a single race. ML research found minor importance. |
| `_pcs_to_vg_ratio` | 1.0 | Both are broad ability measures — PCS is lifetime by race type, VG is season cumulative. Roughly comparable in informativeness. The `vg_season_penalty` handles early-season noise by inflating VG variance when few riders have points. |

**Other key parameters**:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `within_cluster_correlation` | 0.5 | Signals within each cluster (market, history, ability) are highly redundant. With ρ_w=0.5 and e.g. 5 history observations, the within-cluster discount is 1 + 0.5×4 = 3.0, reducing effective history precision to 1/3. This prevents adding more years of race history from producing false certainty. |
| `between_cluster_correlation` | 0.15 | Clusters carry partially independent information (odds reflect different knowledge than PCS specialty). With 3 active clusters, the between-cluster discount is 1 + 0.15×2 = 1.3 — a modest additional correction. |
| `hist_decay_rate` | 3.2 | Race history variance increases by 3.2 per year ago. A result from 3 years ago has variance 1.5 + 9.6 = 11.1 vs 1.5 for the current year — it's essentially noise. Aggressive decay is appropriate: rider form changes substantially year to year. |
| `vg_hist_decay_rate` | 1.3 | VG history decays more slowly than PCS history. VG scoring is more stable across years (same scoring system, same field composition) than raw PCS finishing positions. |

### What the evidence does NOT support changing

With only 3 prospective races (Omloop, Kuurne, Laigueglia 2026) and calibration that already looks good, there is no evidence-based case for parameter changes. The prospective Spearman correlations (0.257–0.473) are consistent with the prior predictive checks and historical backtest results. Specific findings:

- **Form precision is arguably too high** relative to its ML-measured importance, but it's bundled with race history (which IS important) under the same scale factor. Separating them would add a fourth scale factor with no data to calibrate it.
- **Oracle ratio could be 2.0 instead of 1.5**, but the practical impact is small (both are high-precision market signals, and the block-correlation discount already dampens their combined effect).
- **The deeper structural issue** is that the Bayesian framework treats signals as conditionally independent given true strength, when in reality odds already incorporate the information from other signals. The block-correlation discount and `market_discount` are complementary corrections: the former handles within- and between-cluster redundancy, the latter directly reduces non-market signal precision when odds are available.

### Market discount (March 2026)

The block-correlation discount partially addresses the double-counting problem, but analysis of early 2026 predictions revealed that non-market signals were still systematically pulling strength estimates away from odds — particularly PCS specialty (high career points for established riders) and race history. The model was overvaluing riders like Van Aert relative to their odds, because lifetime PCS points were overwhelming current market information.

The `market_discount` parameter (default 8.0) provides a direct fix: when odds exist for a race, all non-market signal variances are multiplied by this factor at the **race level** (not per-rider). This reflects the reasoning that the market already incorporates career record, form, race history, and trajectory, so these signals carry little marginal information beyond what odds convey. A value of 8.0 means non-market signals carry ~1/64 of their usual precision when odds are present.

For races **without** odds data, all signal precisions remain at their original values, so the non-market signals drive predictions for the full startlist.

**Decision**: maintain current parameters; revisit after 15–20 prospective races with full signal coverage provide enough data to detect systematic patterns.

---

## Evidence appendix

### Key academic references

**Sports forecasting and market efficiency** (see also "Signal precision rationale" section above)

A systematic review of ML in sports betting (Hubáček et al., 2024, arxiv:2410.21484) found that ML prediction accuracy "reaches not more than about 70% and is at the same level as model-free bookmaker odds alone." Franck et al. (2010, *International Journal of Forecasting*) showed betting exchanges provide more accurate predictions than bookmakers, using 5,478 football matches. Constantinou & Fenton (2013, *Journal of Forecasting*) developed the Betting Odds Rating System showing bookmaker odds are the best source of probabilistic forecasts for sports matches, outperforming ELO-based models on highly significant levels. Forrest & Simmons (2000) found no statistically significant evidence to reject market efficiency for English football betting.

**Kholkine et al. (2021) - "A machine learning approach to predict the outcome of professional cycling races"**
*Frontiers in Sports and Active Living* (also PMC8527032)

Tested 15 feature categories for predicting top-10 finishers in six spring classics using learn-to-rank (LambdaMART). Key findings for this project:

- Overall PCS performance (career and season-long points) was important across all six races
- Best historical result in the specific race was the single most important feature for Tour of Flanders and Paris-Roubaix
- Results from related races were strongly predictive for some events: LBL relied heavily on Fleche Wallonne results rather than overall performance, demonstrating that course-type matching carries significant weight
- 6-week pre-race form received minimal weight — the model "does not seem to learn a lot from" short-term form features
- Achieved 0.82 NDCG@10, approximately 3% above a tuned logistic regression baseline

**Rize, Saldanha & Moskovitch (2025) - "VeloRost: a Bayesian dual-skill framework for roster-based cycling race outcome prediction"**
*ISACE 2025 / Springer*

Achieved NDCG@10 of 0.443 by separately modelling leader skill and helper/domestique contributions, and by clustering races by elevation and road surface type before applying TrueSkill ratings. Two key findings:

- Modelling leader vs helper roles separately "significantly outperforms" treating riders independently
- Two-stage approach (cluster races by terrain, then estimate skill within clusters) outperformed single global skill ratings

**Haugh & Singal (2021) - "How to play fantasy sports strategically (and win)"**
*Management Science, 67(1)*

Definitive result on ownership-adjusted optimisation. Modelled opponents' team selections using a Dirichlet-multinomial process and optimised for expected reward conditional on outperforming the field:

- 350% returns over 17 weeks in top-heavy GPP contests vs 50% for an ownership-blind benchmark
- 7x performance differential from ownership adjustment alone, without improving underlying player projections
- Effect is strongest in large-field tournaments; negligible in head-to-head or small-league formats

**Baronchelli et al. (2025) - "Data-driven team selection in Fantasy Premier League"**
*arXiv:2505.02170v1*

Found that recency-weighted Bayesian models provide "strong and stable baselines" for expected points forecasting. Hybrid approaches augmenting Bayesian estimates with additional features yield "modest but consistent improvements." Optimal blend: roughly two-thirds model-based scores, one-third realised recent points.

### DFS community sources

Sharpstack (Ash, 2021) demonstrated that using Cholesky decomposition to generate correlated player projections (rather than independent simulations) produces substantially more realistic tournament outcome distributions. Ignoring correlation can approximately double the standard deviation of simulation outputs.

FantasyLabs defines "leverage score" as the gap between a player's optimal lineup percentage and their ownership projection, making it the primary tool for GPP construction. The simple `leverage = E[pts] * (1 - ownership)` captures most of the benefit of more sophisticated opponent modelling.

Consistent themes from experienced VG players (The Pelotonian, Sicycle, ProCyclingUK, Marginal Brains):

- Value identification (spending less budget for more points) matters more than picking the winner
- Balance over star power: low-cost GC contenders who grind out daily points are undervalued
- Stage composition analysis: counting sprint/mountain/TT stages to calibrate rider-type allocation
- Young riders on upward trajectories are systematically underpriced by VG's backward-looking cost algorithm
- Classification constraints create within-category pricing inefficiencies

### Conditional VG-points calibration (Tier 3)

The per-race PIT histogram and aggregate PIT across prospective races (now implemented) answer whether the model is calibrated on average. Conditional calibration asks whether it is calibrated *for specific strata of riders*, which matters because miscalibration may be concentrated in ways that affect team selection.

**Natural strata to check:**

- **By predicted strength**: are the top-10 predicted riders' distributions well-calibrated? The Strade Bianche 2026 data suggests favourites may be under-dispersed (actuals exceeding the simulated range).
- **By cost**: cheap riders (cost 4–6) are where VG points calibration most affects team selection, since the optimiser frequently swaps between similarly-priced alternatives.
- **By signal coverage**: riders with odds vs without. The `market_discount` parameter changes the model's behaviour substantially when odds are present, and the VG-points calibration could differ systematically between these groups.

This does not need its own infrastructure — it is filtering PIT values before plotting. The implementation would add faceted PIT histograms or a calibration table by stratum to the prospective evaluation section of `backtesting.qmd`. It should only be pursued once the aggregate PIT histogram reveals problems, since the stratum sample sizes will be small (10–15 riders per stratum per race) and require at least 15–20 prospective races to be statistically meaningful.

**Potential model changes motivated by conditional calibration:**

- **Uncertainty scaling for top riders**: if favourites are consistently under-dispersed, the posterior uncertainty for high-strength riders may need inflating (strength-dependent uncertainty floor, or Student-t noise in `simulate_vg_draws`).
- **Scoring-aware variance adjustment**: the scoring non-linearity means a 1-position error near the top (80 VG points in Cat 1) matters far more than at position 25 vs 26 (12 points). If VG-points calibration is worse for top positions, it might motivate position-dependent uncertainty scaling.

### Impact estimates summary

| Priority | Improvement | Expected impact | Evidence strength | Status |
| --- | --- | --- | --- | --- |
| 1 | Odds integration | Very high | Strong (market efficiency literature) | Done |
| 2 | Calibration framework | High (indirect) | Strong (enables calibration) | Done |
| 3 | Course profile matching | High | Strong (Kholkine, VeloRost) | Done (manual similar-races); PCS profile scraping deferred |
| 4 | Stage race prediction | High (grand tours) | Moderate (community consensus) | Planned — see detailed Phase 4 plan |
| 5 | Ownership-adjusted optimisation | Very high for GPPs, low for small leagues | Strong (Haugh & Singal) | Not done |
| 6 | Leader/domestique roles | Moderate | Moderate (VeloRost) | Done |
| 7 | Recent form signal | Moderate-low | Weak (Kholkine: minimal weight) | Done |
| 8 | Season-adaptive VG + trajectory | Moderate | Post-Kuurne analysis | Done |
| 9 | Correlated simulation | Low-moderate | Moderate (Sharpstack, but cycling differs) | Not done |
| 10 | ML models | Unknown | Weak (+3% over baseline) | Not done |
| 11 | Conditional VG-points calibration | Medium (diagnostic) | Depends on aggregate PIT findings | Not done — requires 15+ prospective races |
