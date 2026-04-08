# Velogames.jl improvement roadmap

See `CLAUDE.md` for current architecture, prediction model details, signal inventory, and parameter settings.

## Known issues

### VG points distributions underestimate scoring riders (March–April 2026)

The most significant calibration problem, now confirmed across 10 prospective races (Omloop, Kuurne, Strade, Trofeo, Nokere, MSR, Brugge De Panne, Dwars Door Vlaanderen, E3, Gent-Wevelgem). Aggregate mean PIT for scoring riders is 0.828 (target: 0.5), consistent across all 10 races. The drop from 0.86 (6 races) is composition effects from the more predictable Flemish races, not model improvement.

The underestimation is worst for outsiders and mid-tier riders: bottom-25% mean PIT = 0.9, middle-50% mean PIT = 0.9, top-25% mean PIT = 0.7. The favourite z-score bias (-0.6 in the historical backtest) and PIT right-skew (0.7) are consistent: the model slightly overestimates favourite *position* but underestimates their *VG points* due to the convex scoring table at top positions.

Higher posterior uncertainty correlates with *worse* PIT, not better (Trofeo mean uncertainty 1.3, PIT 0.9 vs Dwars 0.6, PIT 0.8). This confirms the problem is asymmetric: unknown riders in stochastic races have heavily right-skewed outcomes that symmetric noise cannot capture.

Three race-type clusters emerge from big-miss rates:

| Cluster | Races | Big-miss rate | Characteristic |
|---------|-------|---------------|----------------|
| Selective | Strade, Dwars, E3 | 0–10% | Hard course thins the bunch; favourites nearly always score |
| Standard | Brugge, MSR, Omloop | 20% | Mix of selection and bunch dynamics |
| Stochastic | Kuurne, Nokere, Gent-Wevelgem, Trofeo | 30–60% | Bunch sprints or minor races; favourites frequently blank |

### SBC test failure explained (April 2026)

The SBC reports chi-squared p = 0.0 (non-uniform CDF ranks). This is a test bug, not a model bug: the SBC generates *independent* synthetic signals but `estimate_rider_strength` applies a *block-correlation discount* (within ρ=0.5, between ρ=0.15), making the posterior systematically wider than warranted by the uncorrelated DGP. Additionally, the SBC generates odds+oracle but never sets `race_has_market=true`. Per-signal SBC (one signal at a time) has been added to the backtesting report to verify each conjugate update individually.

### Breakaway heuristic limitations

Breakaway points are estimated heuristically from simulated finishing positions, allocating sector credits based on position ranges (see `_breakaway_sectors()` in `src/simulation.jl`). The heuristic has a known sharp boundary at position 20, where riders gain a 4th sector. Actual breakaway data (e.g. from race reports or live timing) would improve this.

The impact is larger than previously thought. In MSR 2026, 8 riders scored exactly 120 VG points each purely from breakaway sectors (Tarozzi, Maestri, Marcellusi, Faure Prost, Belletta, Milesi, Moro, Tronchon). The model predicted these riders at 0.5–65 expected VG points. PCS breakaway data for the race was entirely missing (zero riders flagged), so the model fell back on the position-based heuristic alone. For Cat 1 races where breakaway points are 60 per sector (max 240 per rider), the heuristic is inadequate.

---

## Improvement plan

### Overall assessment

The system's rank ordering is reasonable (Spearman ρ 0.2–0.5 across 11 prospective races, median 0.5 in the 120-race historical backtest). The model's team-selection value comes almost entirely from correctly ranking the top ~20 riders (ρ=0.4 for positions 1–10, dropping to 0.1 for positions 21–40).

A signal ablation study (April 2026, 11 prospective races) led to pruning three low-value signals and identified two deferred improvements. A red team review flagged statistical limitations: most claimed ρ improvements are within 1–2 SEs, 20×4 comparisons were tested with no correction, and the 6-race market sample is too small for reliable market-signal conclusions. Bootstrap CIs and a combined configuration test have been added to `render_backtesting.jl` to track these as more data accumulates.

### Active signal set (after April 2026 pruning)

PCS seasons + VG season + PCS race history + Cycling Oracle + Betfair odds. Three signals were disabled:

| Signal removed | Evidence | Decision |
| -------------- | -------- | -------- |
| PCS form | Near-zero within-tier ρ across all tiers (−0.014, 0.003, 0.106) | Removed — adds noise via block-correlation discount without improving ordering |
| VG race history | Near-zero everywhere, anti-informative for top riders (−0.071) | Removed — same rationale |
| Qualitative | Anti-informative for top riders (ρ=−0.291, n=60) | Removed — pipeline complexity for no benefit |

Code and data collection retained for backtesting re-evaluation.

### Deferred improvements

**1. Drop oracle signal.** Individual ablation shows oracle is inconsistent (within-tier ρ: 0.136, −0.088, 0.119) and "odds only" beats "odds+oracle" for top/middle tiers. However, the combined configuration test showed 5/6 races with odds worsen when oracle is removed alongside other signal changes. Oracle may contribute through block-correlation structure when paired with odds. **Re-evaluate after 20+ races with odds** (likely end of 2026 season).

**2. Position-dependent market discount.** The only configuration that improves all tiers simultaneously (overall ρ 0.518 vs 0.473 for uniform d=8.0). The mechanism is sound: odds differentiate among favourites (ρ=0.464) but are uninformative for the rest, so applying full discount only to the top quartile by PCS z-score preserves PCS seasons' influence for mid-field riders. However, the red team flagged methodological concerns:

- Circularity: tier assignment uses model-predicted strengths correlated with outcomes
- Overfitting risk: adds a tunable threshold parameter on 6 races with odds (~250 riders per tier)
- Per-race heterogeneity: odds improve ρ for 2/6 races (E3: +0.059, RVV: +0.071) but hurt for 4/6 (Strade: −0.136, Dwars: −0.145, MSR: −0.051, GW: −0.090)

**Defer until n≥20 races with odds.** Implementation would replace the uniform `md` variable in `estimate_rider_strength` with a per-rider `md_i` based on PCS z-score quartile.

**3. Correlated position simulation.** Low-moderate impact; more useful for stage races and team-heavy strategies. Not started.

**4. ML augmentation.** ~3% above tuned baseline per Kholkine; requires 90+ race training set. Not started — prerequisites missing.

### Deprioritised (not planned)

- **VG points calibration**: The PIT right-skew (mean 0.828 across 11 races) is real but roughly uniform across cheap riders. Correcting it changes budget allocation but not rider selection where signals are sparse. Second-order compared to correctly ranking top riders.
- **Race-type selectivity adjustment**: Three clusters are observable (selective/standard/stochastic) but per-race noise adjustment makes all weak riders look more likely to score without helping pick which ones.
- **Ownership-adjusted optimisation**: VG is cumulative points across ~40 races, not per-race GPP. Other players' picks have no bearing on your score.

### Completed improvements

| Phase | Description | Key details |
|-------|-------------|-------------|
| 1. Odds integration | Betfair Exchange API + Cycling Oracle scraping as Bayesian signals | Strongest single predictor. Betfair coverage limited to major races; Oracle covers most European professional races. Both can be active simultaneously. |
| 2. Calibration framework | Prior predictive checks, SBC, backtesting, prospective evaluation | `BayesianConfig` reparameterised to 3 scale factors + 2 decay rates. `render_backtesting.jl` serves as unified calibration frontend. |
| 3. Course profile matching | Terrain-similar race history via `SIMILAR_RACES` | Manual curation of terrain groupings; automatic PCS profile scraping deferred as low priority. |
| 4. Leader/domestique roles | Domestique strength discount + max-per-team constraint | Heuristic leader detection by estimated strength within the field. |
| 5. Recent form signal | PCS form page scraping, z-scored as Bayesian update | Covers top ~40-60 riders; race-agnostic (no terrain filtering). |
| 6. Season-adaptive VG | VG variance scales with season progress | `vg_season_penalty` inflates early-season VG variance. Trajectory signal removed April 2026 (negligible contribution). |
| 7. Student's t noise | Heavy-tailed simulation noise via `simulation_df` parameter | `_rand_t(rng, df)` in `simulation.jl`. Default `simulation_df=nothing` (Gaussian); render scripts use df=5. |
| 8. Qualitative intelligence | YouTube transcript → Claude API extraction → rider adjustments | Automated pipeline via `get_qualitative_auto()` or manual workflow via `build_qualitative_prompt()`. |
| 9. Signal cleanup (April 2026) | Trajectory removed, oracle precision reduced, VG history decay reduced | `_odds_to_oracle_ratio` 2.0 → 3.5; `vg_hist_decay_rate` 1.3 → 0.8; trajectory signal fully deleted. |
| 10. Enhanced backtesting report (April 2026) | Per-signal SBC, predicted-vs-actual scatter, signal directional accuracy, race selectivity clustering, calibration history tracking | Standalone HTML report via `render_backtesting.jl`. 11 prospective races archived. |
| 11. Discrimination diagnostics (April 2026) | Per-position-band ρ, within-tier signal discrimination, signal ablation study | Revealed PCS form, VG race history, and qualitative are noise. Position-dependent market discount shows promise but deferred pending more data. |
| 12. Signal pruning (April 2026) | Disabled PCS form, VG race history, qualitative from estimation pipeline | Red team review + bootstrap CIs confirmed low-value signals. Data collection/archival continues; backtesting can re-enable via signal flags. Retained signal set: PCS seasons + VG season + PCS race history + oracle + odds. |
| 13. Per-stage simulation (April 2026) | Per-stage scoring, PCS stage scraping, stage-type strength modifiers, cross-stage correlated simulation | `StageRaceScoringTable`, `simulate_stage_race`, `resample_optimise_stage`. Validated against TDF 2024/2025 (scoring ρ=0.94–0.96, prediction ρ=0.77 vs aggregate 0.66). Extended to all VG stage races including week-long races (Itzulia, Catalunya, etc.) with optional class constraints. |

---

## Phase 4: Per-stage simulation (completed April 2026)

Per-stage simulation replaces the aggregate GC-position model for stage races. Each stage is simulated independently with stage-type strength modifiers and cross-stage correlated noise. The optimiser selects teams maximising total expected VG points summed across all stages.

### What was built

#### Scoring and data infrastructure

- `StageRaceScoringTable` struct and `SCORING_GRAND_TOUR` constant in `src/scoring.jl` with all per-stage, daily classification, in-stage bonus, assist, and final classification scoring values
- `StageProfile` struct capturing stage number, type, distance, ProfileScore, vertical metres, gradient, climb counts, and summit finish flag
- PCS stage profile scraper (`getpcs_stage_profiles`) with two-pass approach: overview page for stage list + profile codes, individual stage pages for ProfileScore/vert/gradient
- PCS stage results scraper (`getpcs_stage_results`, `getpcs_all_stage_results`) for per-stage finishing positions
- VG per-stage results fetcher (`getvg_stage_results`) and overall totals (`getvg_stage_race_totals`)
- Stage type classification from PCS profile codes: p1=flat, p2/p3=hilly, p4/p5=mountain, with ITT/TTT detection from stage name
- `getpcsraceresults` falls back from `/result` to `/gc` URL for stage races where PCS uses a different results page structure

#### Stage-type strength modifiers

- `compute_stage_type_modifiers` in `src/simulation.jl` applies additive modifiers to base strength using class-aware PCS specialty blending (flat/hilly/mountain/ITT weights per rider classification)
- `modifier_scale` parameter (default 0.5) controls differentiation vs overall ability

#### Per-stage simulation

- `simulate_stage_race` in `src/simulation.jl` runs full per-stage simulation: stage finish points, stage/GC assist points, daily GC tracking, cumulative GC standings, and final classification bonuses (GC, points, mountains, team)
- Cross-stage correlated noise via α-blending of persistent rider noise + independent stage noise (`cross_stage_alpha`, default 0.7)
- `resample_optimise_stage` wraps the simulation in the resampled optimisation framework

#### Solver and race configuration

- `solve_stage` in `src/race_solver.jl` dispatches to per-stage pipeline when stages are provided, falls back to aggregate when empty
- `_STAGE_RACE_PATTERNS` dict covers all 2026 VG stage races: grand tours (TDF, Giro, Vuelta) plus week-long races (Paris-Nice, Tirreno-Adriatico, Catalunya, Itzulia, Romandie, Dauphiné, Tour de Suisse)
- `_STAGE_RACE_PCS_SLUGS` and `_STAGE_RACE_VG_SLUGS` map aliases to PCS/VG slugs with automatic PCS slug propagation for stage profile scraping
- `build_model_stage` classification constraints are optional — skipped for week-long races without VG class data (e.g. Itzulia), enforced for grand tours
- `render_stagerace.jl` reads shared `race_config.toml` and generates standalone HTML reports

#### Validation findings (TDF 2024/2025)

- **Scoring accuracy**: Spearman ρ = 0.94–0.96 between calculated VG points (from PCS positions) and actual VG scores. Per-stage sums + final classification pseudo-stage (st=22) match overall totals exactly for all riders.
- **Scoring gap**: ~6 pts/stage mean gap from sprint/climb/breakaway bonuses we cannot reconstruct from PCS finishing positions. Largest for mountain stages (8–15 pts) due to HC/Cat1 climb bonuses, smallest for ITT stages (~3 pts).
- **Prediction quality**: Per-stage model ρ=0.77 vs aggregate ρ=0.66 (2024); per-stage ρ=0.77 vs aggregate ρ=0.68 (2025). Top-9 team points captured ratio 0.95–0.96.

### What remains (v2 enhancements)

- In-stage climb/sprint bonus simulation (requires per-stage climb/sprint counts from PCS — HC/Cat1 data is scraped but not yet used in scoring)
- Breakaway modelling for stage races
- Abandonment modelling (survival probability per stage)
- Stage-race-specific PIT calibration in prospective evaluation
- Stage race backtesting (extend `backtest.jl` to compare per-stage vs aggregate predictions across historical grand tours)
- Tour de Pologne and Renewi Tour VG slug mappings (VG pages not yet created for 2026)

---

## Evidence appendix

### Key academic references

#### Sports forecasting and market efficiency

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

**Applicability to VG:** These results do not transfer to VG's format. VG scores accumulate across ~40 races in a season — the objective is to maximise total points, not to beat the field in any single race. Ownership-adjusted optimisation only helps when your payoff depends on relative performance within a single contest. In a cumulative format, what other players pick has no bearing on your score. The cumulative format also favours consistency over variance, further penalising the contrarian picks that ownership adjustment promotes.

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

### Conditional VG-points calibration

The per-race PIT histogram and aggregate PIT across prospective races (now implemented) answer whether the model is calibrated on average. Conditional calibration asks whether it is calibrated *for specific strata of riders*, which matters because miscalibration may be concentrated in ways that affect team selection.

Natural strata to check once sufficient data is available (15+ prospective races):

- **By predicted strength**: are the top-10 predicted riders' distributions well-calibrated? The Strade Bianche 2026 data suggests favourites may be under-dispersed (actuals exceeding the simulated range).
- **By cost**: cheap riders (cost 4–6) are where VG points calibration most affects team selection, since the optimiser frequently swaps between similarly-priced alternatives.
- **By signal coverage**: riders with odds vs without. The `market_discount` parameter changes the model's behaviour substantially when odds are present, and the VG-points calibration could differ systematically between these groups.

The implementation would add faceted PIT histograms or a calibration table by stratum to the prospective evaluation section of `render_backtesting.jl`.

### Impact estimates summary

| Priority | Improvement | Expected impact | Evidence strength | Status |
| --- | --- | --- | --- | --- |
| 1 | Odds integration | Very high | Strong (market efficiency literature) | Done |
| 2 | Calibration framework | High (indirect) | Strong (enables calibration) | Done |
| 3 | Course profile matching | High | Strong (Kholkine, VeloRost) | Done (manual similar-races); PCS profile scraping deferred |
| 4 | Stage race prediction | High (grand tours) | Moderate (community consensus) | Done — per-stage ρ=0.77 vs aggregate 0.66 |
| 5 | Ownership-adjusted optimisation | Irrelevant — VG is cumulative points across ~40 races, not per-race GPP | Strong for GPPs (Haugh & Singal) but inapplicable here | Dropped |
| 6 | Leader/domestique roles | Moderate | Moderate (VeloRost) | Done |
| 7 | Recent form signal | Moderate-low | Weak (Kholkine: minimal weight) | Done |
| 8 | Season-adaptive VG | Moderate | Post-Kuurne analysis | Done (trajectory removed April 2026 — negligible contribution) |
| 9 | Student's t noise | Low-moderate | Moderate (fat-tailed cycling outcomes) | Done |
| 10 | Correlated simulation | Low-moderate | Moderate (Sharpstack, but cycling differs) | Not done |
| 11 | ML models | Unknown | Weak (+3% over baseline) | Not done — prerequisites missing |
| 12 | Conditional VG-points calibration | Medium (diagnostic) | Depends on aggregate PIT findings | Not done — requires 15+ prospective races |
