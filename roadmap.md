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

The strength model combines multiple signals, each with a variance hyperparameter controlling how much it shifts the posterior. All variance parameters are exposed as keyword arguments in `estimate_rider_strength()` for calibration and sensitivity analysis:

| Signal                | Source                    | Variance  | Notes                                                                                        |
| --------------------- | ------------------------- | --------- | -------------------------------------------------------------------------------------------- |
| PCS specialty prior   | `getpcsriderpts_batch()`  | 5.5       | Z-scored across field. For stage races, class-aware blending via `STAGE_RACE_PCS_WEIGHTS`    |
| VG season points      | `getvgriders()`           | 1.2×scale | Season-adaptive: `effective = 1.2 * (1 + 5.0 * (1 - frac_nonzero))`. Early season ~6.6     |
| PCS form score        | `getpcsraceform()`        | 2.0       | Z-scored across field. Top ~40-60 riders by recent cross-race results from PCS form page     |
| Trajectory            | Derived (PCS vs history)  | 3.0       | `pcs_z - mean(history_z)`, z-scored. Captures improving/declining riders                     |
| PCS race history      | `getpcsracehistory()`     | 4.0+1.2/yr| Recency-weighted: recent years get lower variance (higher precision)                         |
| Similar-race history  | `getpcsracehistory()`     | +1.0      | Same as race history but +1.0 variance penalty. Races from `SIMILAR_RACES` terrain mapping   |
| VG race history       | `getvgracepoints()`       | 3.0+0.65/yr| Z-scored per year. Actual VG points from past editions (finish + assist + breakaway)         |
| Cycling Oracle        | `get_cycling_oracle()`    | 1.5       | Independent signal from cyclingoracle.com predictions. Broader race coverage than Betfair    |
| Betting odds          | `getodds()`               | 0.5       | Strongest single signal when available. Uses Betfair Exchange API (market ID required)       |

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
- **ProCyclingStats** (procyclingstats.com) - specialty ratings (one-day/GC/TT/sprint/climber), rankings, race results by year, startlist quality, recent form scores
- **Betfair Exchange** (betfair.com) - betting odds for win markets via Exchange API (optional, requires credentials)
- **Cycling Oracle** (cyclingoracle.com) - race predictions with win probabilities, scraped from blog prediction pages (optional, broader coverage than Betfair)

### Recommended future sources

- **PCS deeper data** - race climb profiles (length, gradient, elevation), profile difficulty icons (p0-p5)
- **OpenWeatherMap** (free tier, 1000 calls/day) - race-day weather for cobbled classics

## Known issues

### Team dynamics / domestique problem

The model treats riders independently but VG assists create team-level correlations. A strong domestique on a winning team may outscore a weaker leader. Current approach ignores this. Future options include:

- Maximum riders per team constraint in the optimiser
- Points discount for riders likely to sacrifice for a leader
- Team-role detection from PCS data (e.g. rider designated as leader vs domestique)

### Breakaway heuristic limitations

Breakaway points are estimated heuristically from simulated finishing positions, allocating sector credits based on position ranges (see `_breakaway_sectors()` in `src/simulation.jl`). The heuristic has a known sharp boundary at position 20, where riders gain a 4th sector. Actual breakaway data (e.g. from race reports or live timing) would improve this. The heuristic is a small fraction of total expected points for most riders, so the impact is limited.

### Stage race scoring calibration

`SCORING_STAGE` maps overall GC position to approximate total VG points accumulated across the race. Currently calibrated by rough inspection of historical VG grand tour results (winners typically 3000-4000 points, top 10 around 1000-2000). These values have not yet been validated against actual historical VG grand tour data. Systematic calibration against multiple historical VG stage race results would improve this.

### Notebooks excluded from the Quarto build

The following notebooks have been rewritten to the current architecture but are not yet included in `_quarto.yml` and therefore not published to the site:

- `notebooks/stagerace_predictor.qmd` — stage race prediction workflow. Has a small bug: references undefined `vg_history` variable at line 88 in the data sources callout. Fix: replace `$(isempty(vg_history) ? "Not provided" : "Active")` with a check on `n_vg_hist > 0`.
- `notebooks/historical_analysis.qmd` — retrospective optimal team selection. Appears complete; uses `setup_race`, `build_model_oneday`, `build_model_stage`, and `minimise_cost_stage` correctly.
- `notebooks/index.qmd` — overview/landing page. References all five notebooks in its prose, so adding the two above to `_quarto.yml` makes it accurate without edits.

To publish: fix the `stagerace_predictor.qmd` bug, add all three to `_quarto.yml` render list and sidebar, and verify they render cleanly.

---

## Improvement phases (ordered by expected impact)

The phases below are ordered by expected return on selection quality and win probability, drawing on the evidence reviewed in the appendix. The original phase numbering has been replaced with a priority ranking.

### Phase 1: Fix odds integration (high impact, low effort) — done

Betting odds are the strongest single predictive signal because they aggregate private information from many informed participants. The Bayesian infrastructure treats odds as the highest-precision observation (variance 0.5).

**Implemented:** `getodds()` now calls the Betfair Exchange API via `betfair_get_market_odds()`. Authentication uses environment variables (`BETFAIR_USERNAME`, `BETFAIR_PASSWORD`, `BETFAIR_APP_KEY`). Users pass a Betfair market ID to the solver; the pipeline falls back gracefully when no market ID is provided or the API is unavailable. Overround removal and log-odds conversion to the Bayesian strength model were already in place.

**Cycling Oracle:** `get_cycling_oracle()` scrapes win probability predictions from cyclingoracle.com blog pages and feeds them as an independent Bayesian signal (variance 1.5). This provides broader race coverage than Betfair, covering most European professional races. Both signals can be active simultaneously; when both are available, the model benefits from two independent observations.

**Limitations:** Betfair cycling coverage is limited to grand tours, monuments, and some major classics. Most Superclasico races will not have a Betfair market. Cycling Oracle has broader coverage but only provides predictions for the top ~16 riders per race. Future work could add additional odds sources for even broader coverage.

**Evidence:** Betting markets consistently outperform public statistical models across sports prediction research. In cycling specifically, odds were not tested by Kholkine et al. (2021) but are widely regarded in the DFS community as the strongest single signal because they aggregate private information (team tactics, form, injury knowledge) unavailable in public data. The current variance of 0.5 (vs 3.0-4.0 for other signals) is directionally correct.

### Phase 2: Historical backtesting (high indirect impact) (done)

Every other improvement is flying blind without systematic evaluation. We cannot currently measure whether the MC predictions are well-calibrated, whether variance hyperparameters are optimal, or whether model changes actually improve selection quality. The cycling prediction literature (Kholkine et al., 2021) and FPL research (Baronchelli et al., 2025) both emphasise that ablation studies are essential for confident iteration.

**Pipeline:**

For each past Superclasico race:

1. Reconstruct pre-race available data
2. Run prediction pipeline
3. Compare predicted team vs actual optimal team (from `build_model_oneday` / `build_model_stage`)
4. Metrics: points captured, rank vs optimal, prediction correlation

**Calibration:**

- Tune variance hyperparameters exposed in `estimate_rider_strength()` (PCS, VG, history, odds variances and odds normalisation divisor)
- Ablation study: which features improve predictions?
- Requires: systematically scraping VG historical results for all Superclasico races (2+ seasons)

**Additional metrics to consider:**

- Spearman rank correlation between predicted and actual VG points
- Fraction of optimal team points captured by predicted team
- Calibration plots: predicted win probability vs observed win frequency
- Expected points of predicted team as a percentile of the actual leaderboard

### Phase 3: Course profile matching (high impact) (part done)

Academic evidence strongly supports terrain-aware prediction. Kholkine et al. (2021) found that for Liege-Bastogne-Liege, results from Fleche Wallonne (a similar hilly Ardennes race) were more predictive than overall PCS performance. The VeloRost paper (Rize, Saldanha & Moskovitch, 2025) achieved its best results partly by clustering races by elevation and surface type before applying TrueSkill ratings, outperforming approaches that used a single global skill rating.

**Implemented — terrain-similar race history:** `SIMILAR_RACES` in `src/race_helpers.jl` maps each race to a list of terrain-similar races derived from `RaceInfo.similar_races`. The prediction pipeline fetches race history for these similar races and feeds them into the Bayesian model with an additional +1.0 variance penalty. This is the most impactful part of the phase and is live for all classics.

**Not yet implemented — PCS profile scraping:**

- `getpcsraceprofile(pcs_slug, year)` — scrape PCS p0–p5 difficulty icons and climb data
- `course_similarity(race_a, race_b)` — data-driven similarity metric from profile features
- Automatic terrain clustering to replace the manually curated `SIMILAR_RACES` lists

The remaining work (automatic profile-driven clustering) would reduce manual curation effort but would not substantially change the model outputs, since the manually curated `SIMILAR_RACES` already captures the key terrain groupings. Low priority unless manual maintenance becomes burdensome.

### Phase 4: Stage-by-stage simulation (high impact for grand tours)

The current aggregate approach (simulating overall GC position and mapping to total VG points) is the weakest part of the model. `solve_stage()` and `stagerace_predictor.qmd` are implemented and usable, but the underlying scoring model maps simulated overall GC rank directly to total VG points via `SCORING_STAGE`, which ignores stage composition entirely. Top VG players emphasise analysing the parcours to calibrate sprinter/climber allocation, and the stage composition directly determines which rider types accumulate the most points.

PCS provides stage profile data at `/race/{slug}/{year}/route/stage-profiles` with difficulty, distance, elevation, and finish type. A proper stage race predictor would:

1. Scrape stage profiles and classify each stage (flat, hilly, mountain, TT, sprint finish)
2. For each stage, weight rider strengths by stage type (e.g. climbers favoured on mountain stages)
3. Simulate each stage independently to get per-stage VG points
4. Accumulate VG points across all stages for each rider
5. Optimise team selection over total accumulated expected points

This is a significant extension warranting its own PR. The current aggregate approach serves as a reasonable placeholder for one-day races but is the weakest part of the model for grand tours.

**Stage-level correlation considerations:**

Within a single stage, independent simulation is a reasonable approximation (the main correlation effect, assists, is already handled per-simulation). Across stages, however, outcomes are correlated: a rider who crashes in stage 3 is more likely to abandon or lose time in subsequent stages. A simple approach would be to add a per-rider "race survival" probability that attenuates expected points from later stages.

### Phase 5: Ownership-adjusted optimisation (high impact, contest-dependent)

The impact of ownership adjustment depends entirely on the contest type. Haugh & Singal (2021, *Management Science*) demonstrated a 7x return differential (350% vs 50%) from ownership-adjusted play in large-field GPP tournaments. However, for the small private leagues typical of VG, the effect is substantially smaller.

**Leverage scoring:**

- VG `selected` column gives ownership percentages
- `leverage = E[VG_points] * (1 - ownership)` for tournament differentiation
- From DFS literature: in large tournaments, maximise $P(\text{winning})$ not $E[\text{points}]$

**Variance-aware optimisation:**

- MC framework enables this: for each sim, compute team score vs estimated field
- Optimise for $P(\text{your\_team} > \text{field})$
- Favours high-variance, low-correlation picks

**Team correlation / stacking:**

- Same-team riders have correlated outcomes AND generate assist points
- Optimiser could prefer same-team stacking when assist bonus outweighs diversification

**When to use ownership adjustment:**

| Contest type | Field size | Ownership impact | Recommended objective |
| --- | --- | --- | --- |
| Head-to-head | 2 | None | Maximise $E[\text{points}]$ |
| Small league | 5-20 | Low | Maximise $E[\text{points}]$, mild leverage tilt |
| Medium league | 20-100 | Moderate | Leverage-weighted $E[\text{points}]$ |
| Large GPP | 100+ | Very high | Maximise $P(\text{winning})$ via simulation |

### Phase 6: Leader/domestique role modelling (moderate impact) — done

The VeloRost paper (Rize, Saldanha & Moskovitch, 2025) found that separately modelling leader skill and helper/domestique contributions "significantly outperforms" approaches that treat riders independently. The current model already computes assist points per-simulation (the correct approach for capturing teammate correlation), but does not account for domestiques sacrificing individual results for their leader.

**Implemented:** Two complementary mechanisms address the domestique problem:

1. **Domestique strength discount** (`domestique_discount` parameter, default 0.0): After Bayesian strength estimation and before Monte Carlo simulation, identifies team roles by finding the strongest rider per team (the leader). Non-leaders receive a strength penalty proportional to their gap from the leader: `penalty = discount × (leader_strength − rider_strength)`. This is self-scaling: co-leaders with similar strength get small penalties, clear domestiques get large penalties. Applied in `predict_expected_points()` and threaded through the full pipeline including backtesting and hyperparameter tuning. The `domestique_penalty` column is added to the output DataFrame for transparency.

2. **Max-per-team constraint** (`max_per_team` parameter, default 0 = no limit): Optional constraint in `build_model_oneday()` and `build_model_stage()` that limits how many riders can be selected from any single team. Directly limits concentration risk.

**Limitations:** The heuristic identifies leaders purely by estimated strength within the field. It cannot distinguish a genuine secondary leader (e.g. a sprinter on a team with a strong GC rider in a flat race) from a domestique. The `domestique_discount` parameter should be calibrated via backtesting. No leader boost is applied because leaders' historical results already reflect having team support.

### Phase 7: Recent form signal (moderate-low impact) — done

Academic evidence on recent form is surprisingly lukewarm. Kholkine et al. (2021) found that 6-week pre-race form features received "minimal weight" in their learn-to-rank models for spring classics — overall PCS performance and race-specific history dominated. FPL research (Baronchelli et al., 2025) found the optimal hybrid model placed roughly two-thirds weight on model-based scores and one-third on realised recent points, suggesting form is informative but should not dominate.

**Implemented:** `getpcsraceform()` scrapes the PCS `/startlist/form` page, which ranks the top ~40-60 starters by recent cross-race results (last ~6 weeks). Form scores are z-scored across the field and fed as a Bayesian update with variance 2.0, positioned between VG season points and PCS race history. The signal is automatically fetched and archived in the production pipeline, loaded from archive in backtesting, and gated on `:form` in the ablation study.

**Limitations:** The PCS form page only covers the top ~40-60 riders; those not listed receive no form update (the prior passes through unchanged). The signal is race-agnostic — it does not distinguish between terrain types, so a sprint result contributes equally to form for a hilly classic. A future refinement could filter form by terrain-similar race types (combining with phase 3 course profile matching) or weight by race quality.

### Phase 8: Season-adaptive VG variance and trajectory signal — done

Post-Kuurne 2026 analysis revealed systematic prediction errors: overpredicting riders who had a lucky day at the previous race (VG season points too influential early in the season), underpredicting breakout riders (Brennan-type), and overpredicting fading veterans (Degenkolb-type).

**Implemented — season-adaptive VG variance:** VG season points variance now scales with the fraction of riders who have non-zero points. Early in the season (few riders with points), the effective variance is much higher (signal treated as noisy). Late in the season, it converges toward the base value. Formula: `effective_vg_variance = vg_variance * (1 + vg_season_penalty * (1 - frac_nonzero))`. The `vg_season_penalty` parameter (default 5.0) is exposed for hyperparameter tuning.

**Implemented — trajectory signal:** A new Bayesian signal captures improving vs declining riders by comparing a rider's current PCS z-score to the mean of their race history z-scores. Positive trajectory (current PCS exceeds historical performance) suggests improvement; negative suggests decline. Z-scored across the field and fed as a Bayesian update with `trajectory_variance` (default 3.0). Only active for riders with race history; riders without history receive no trajectory update.

**Also:** Widened hyperparameter search bounds for `hist_decay_rate` (0.3–3.5, up from 2.0) and `vg_hist_decay_rate` (0.3–3.0, up from 2.0) to allow the tuner to find steeper recency decay if warranted.

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

## Evidence appendix

### Key academic references

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

### Impact estimates summary

| Priority | Improvement | Expected impact | Evidence strength | Status |
| --- | --- | --- | --- | --- |
| 1 | ~~Fix odds integration~~ | Very high | Strong (market efficiency literature) | Done |
| 2 | ~~Backtesting framework~~ | High (indirect) | Strong (enables calibration) | Done |
| 3 | Course profile matching | High | Strong (Kholkine, VeloRost) | Partial — similar-race history done; PCS profile scraping not done |
| 4 | Stage-by-stage simulation | High (grand tours) | Moderate (community consensus) | Not done — aggregate GC model only |
| 5 | Publish missing notebooks | Medium | — | Small — fix `vg_history` bug, add to `_quarto.yml` |
| 6 | Ownership-adjusted optimisation | Very high for GPPs, low for small leagues | Strong (Haugh & Singal) | Not done |
| 7 | ~~Leader/domestique roles~~ | Moderate | Moderate (VeloRost) | Done |
| 8 | ~~Recent form signal~~ | Moderate-low | Weak (Kholkine: minimal weight) | Done |
| 9 | ~~Season-adaptive VG variance + trajectory~~ | Moderate | Post-Kuurne analysis | Done |
| 10 | Correlated simulation | Low-moderate | Moderate (Sharpstack, but cycling differs) | Not done |
| 11 | ML models | Unknown | Weak (+3% over baseline) | Not done |
