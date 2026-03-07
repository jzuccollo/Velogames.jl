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

Odds are converted to strength via log-odds relative to a uniform baseline, then divided by a normalisation constant (default 2.0, heuristic) to match the z-score scale of other signals. This divisor is also an exposed parameter (`odds_normalisation`).

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

### Team dynamics / domestique problem

The model treats riders independently but VG assists create team-level correlations. A strong domestique on a winning team may outscore a weaker leader. Current approach ignores this. Future options include:

- Maximum riders per team constraint in the optimiser
- Points discount for riders likely to sacrifice for a leader
- Team-role detection from PCS data (e.g. rider designated as leader vs domestique)

### Breakaway heuristic limitations

Breakaway points are estimated heuristically from simulated finishing positions, allocating sector credits based on position ranges (see `_breakaway_sectors()` in `src/simulation.jl`). The heuristic has a known sharp boundary at position 20, where riders gain a 4th sector. Actual breakaway data (e.g. from race reports or live timing) would improve this. The heuristic is a small fraction of total expected points for most riders, so the impact is limited.

### Uncertainty-as-upside bias (Jensen's inequality) — largely resolved

The Monte Carlo simulation inflates expected VG points for riders with high posterior uncertainty. The mechanism is Jensen's inequality applied to the scoring floor: positions 31+ score 0, so the payoff function is convex around the 30th-place cutoff. A mean-preserving spread in the position distribution increases expected points because upside (scoring when finishing top 30) is captured whilst downside (finishing 31st vs 100th) is capped at zero.

**Mitigations implemented:**

1. **Resampled optimisation** (option 3 below): the optimiser runs many times, each drawing noisy strengths from the posterior. High-uncertainty riders only appear in optimal teams when they happen to draw high strength, so they appear less frequently than riders with reliable expected value. This is the primary fix.

2. **Floor observations** (absence-as-signal): when odds or oracle data exists for a race but a rider is absent, they receive a negative floor observation derived from the residual probability mass. This treats market absence as information — the market evaluated all starters and implicitly priced absent riders below threshold. Floor observations use higher variance than directly priced riders (controlled by `floor_variance_multiplier`, default 2.0). This directly addresses the root cause for riders like Turconi, who previously had high uncertainty from few signals; the floor observations add two additional negative signals, pulling strength down and reducing uncertainty.

3. **Risk-adjusted scoring**: the `E / (1 + γ * CV_down)` penalty discounts high-variance riders.

Together these three mechanisms largely resolve the bias. In testing, riders like Turconi dropped from top-10 to ~84th in expected VG points after floor observations were added.

**Background on the original problem and alternative approaches considered:**

The original symptom was riders with few signals (strength ~0.3, uncertainty ~1.5) receiving ~90-100 expected VG points despite being unlikely to finish top 30. Other approaches considered but not implemented: Bayesian shrinkage (James-Stein factor ~0.98, too mild), uncertainty cap (effective but arbitrary threshold), explicit uncertainty penalty (crude), and tightening the uninformative filter.

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

Betting odds are the strongest single predictive signal because they aggregate private information from many informed participants. The Bayesian infrastructure treats odds as the highest-precision observation (effective variance 0.33 at `market_precision_scale=3.0`).

**Implemented:** `getodds()` now calls the Betfair Exchange API via `betfair_get_market_odds()`. Authentication uses environment variables (`BETFAIR_USERNAME`, `BETFAIR_PASSWORD`, `BETFAIR_APP_KEY`). Users pass a Betfair market ID to the solver; the pipeline falls back gracefully when no market ID is provided or the API is unavailable. Overround removal and log-odds conversion to the Bayesian strength model were already in place.

**Cycling Oracle:** `get_cycling_oracle()` scrapes win probability predictions from cyclingoracle.com blog pages and feeds them as a Bayesian signal (effective variance 0.5 at `market_precision_scale=3.0`, `_odds_to_oracle_ratio=1.5`). This provides broader race coverage than Betfair, covering most European professional races. Both signals can be active simultaneously; when both are available, the model benefits from two independent observations.

**Limitations:** Betfair cycling coverage is limited to grand tours, monuments, and some major classics. Most Superclasico races will not have a Betfair market. Cycling Oracle has broader coverage but only provides predictions for the top ~16 riders per race. Future work could add additional odds sources for even broader coverage.

**Evidence:** Betting markets consistently outperform public statistical models across sports prediction research (see "Signal precision rationale" section below for full evidence review). In cycling specifically, odds were not tested by Kholkine et al. (2021) but are widely regarded in the DFS community as the strongest single signal because they aggregate private information (team tactics, form, injury knowledge) unavailable in public data.

### Phase 2: Model calibration framework (done)

The calibration approach combines principled defaults from domain knowledge with three validation layers:

1. **Prior predictive checks** (`src/prior_checks.jl`): Simulate from the generative process and check implied outcomes against cycling domain knowledge (favourite win rates, top-N overlap, rank correlations, posterior SDs). No historical data needed.
2. **Simulation-based calibration (SBC)**: Verify the Bayesian inference pipeline correctly recovers true parameters from synthetic data. Rank histogram should be uniform.
3. **Historical backtesting** (`src/backtest.jl`): Season-level evaluation, ablation study, and directional hyperparameter search as a sanity check. Not the primary tuning mechanism due to data poverty (missing odds/oracle/qualitative in history, small sample size).
4. **Prospective evaluation** (`src/prospective_eval.jl`): Compare archived pre-race predictions (with full signal set) against actual results. Built incrementally as `archive_race_results` is called from `team_assessor.qmd` after each race.

**Reparameterised BayesianConfig:** 12 independent variance parameters replaced with 3 precision scale factors (market, history, ability) plus fixed within-group ratios from domain knowledge. Only 5 tuneable parameters total (3 scales + 2 decay rates), giving ~20 observations per parameter in backtesting.

**`backtesting.qmd`** serves as the primary calibration frontend: prior checks, SBC, sensitivity sweeps, historical ablation, backtest sanity check, and prospective evaluation in one notebook.

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
| `market_precision_scale` | 3.0 | Odds are the best single predictor. At 3.0, odds variance = 0.33, giving precision 3.0 per observation. Calibration at this value produced z std ≈ 0.978 and correct 1σ/2σ coverage. Higher values risk overconfidence for favourites (negative mean z in calibration). |
| `history_precision_scale` | 2.0 | Controls form, race history, VG history, and trajectory. At 2.0, form gets precision 2.0 (slightly below odds) and race history ~0.67 per year (~2.0 over 3 years). Calibration was good. The main tension: form is almost as precise as odds (2.0 vs 3.0), but the ML evidence says form is weak. However, lowering this scale would also weaken race history, which IS one of the best predictors. |
| `ability_precision_scale` | 1.0 | PCS specialty and VG season points are broad career/season aggregates. At precision 1.0 they're one-third of odds. Research supports career consistency mattering for identifying contenders, but the signal is too crude to deserve high precision. |

**Within-group ratios** (fixed domain knowledge, not tuned):

| Ratio | Value | Rationale |
|-------|-------|-----------|
| `_odds_to_oracle_ratio` | 1.5 | Oracle is a single algorithm; odds aggregate many models and private information. Research says models don't beat odds, suggesting Oracle should be less precise. 1.5x is at the generous end — 2.0 would also be defensible, but the practical difference is small since both are in the high-precision market group. |
| `_form_to_hist_ratio` | 3.0 | Per observation, form (current 6-week fitness) is more precise than a single year of race history (stale, different conditions, different pelotons). But 3 years of history collectively match form's precision, which the research supports — race-specific results are among the best predictors. |
| `_form_to_vg_hist_ratio` | 5.0 | VG history adds noise through the nonlinear VG scoring transformation (top-10 finishes heavily rewarded, scoring floor at position 31+). 1.67x noisier than PCS race history per observation. |
| `_form_to_trajectory_ratio` | 5.0 | Career trajectory (improving vs declining) is a very blunt signal for predicting a single race. ML research found minor importance. Same ratio as VG history. |
| `_pcs_to_vg_ratio` | 1.0 | Both are broad ability measures — PCS is lifetime by race type, VG is season cumulative. Roughly comparable in informativeness. The `vg_season_penalty` handles early-season noise by inflating VG variance when few riders have points. |

**Other key parameters**:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `signal_correlation` | 0.25 | The critical parameter for preventing double-counting. Odds already incorporate form, history, and ability, so the signals are not conditionally independent. With n signals at pairwise correlation ρ, effective precision = Στ / (1 + ρ(n-1)). At ρ=0.25 with 8 signals, the denominator is 2.75, roughly halving the naive combined precision. This was calibrated to produce correct favourite-tier z-scores (1σ coverage = 0.683 at ρ=0.25 vs too narrow at ρ=0.1). |
| `hist_decay_rate` | 3.2 | Race history variance increases by 3.2 per year ago. A result from 3 years ago has variance 1.5 + 9.6 = 11.1 vs 1.5 for the current year — it's essentially noise. Aggressive decay is appropriate: rider form changes substantially year to year. |
| `vg_hist_decay_rate` | 1.3 | VG history decays more slowly than PCS history. VG scoring is more stable across years (same scoring system, same field composition) than raw PCS finishing positions. |

### What the evidence does NOT support changing

With only 3 prospective races (Omloop, Kuurne, Laigueglia 2026) and calibration that already looks good, there is no evidence-based case for parameter changes. The prospective Spearman correlations (0.257–0.473) are consistent with the prior predictive checks and historical backtest results. Specific findings:

- **Form precision is arguably too high** relative to its ML-measured importance, but it's bundled with race history (which IS important) under the same scale factor. Separating them would add a fourth scale factor with no data to calibrate it.
- **Oracle ratio could be 2.0 instead of 1.5**, but the practical impact is small (both are high-precision market signals, and signal_correlation already dampens their combined effect).
- **The deeper structural issue** is that the Bayesian framework treats signals as conditionally independent given true strength, when in reality odds already incorporate the information from other signals. The `signal_correlation` parameter is a rough correction. A theoretically better approach would model odds as the primary signal and only add marginal information from other sources, but that's a substantially more complex model with no calibration data.

### Market discount (March 2026)

The `signal_correlation` parameter partially addresses the double-counting problem, but analysis of early 2026 predictions revealed that non-market signals were still systematically pulling strength estimates away from odds — particularly PCS specialty (high career points for established riders) and race history (5 years × precision 0.67 = total precision 3.33, exceeding odds at 3.0). The model was overvaluing riders like Van Aert relative to their odds, because lifetime PCS points were overwhelming current market information.

The `market_discount` parameter (default 3.0) provides a direct fix: when a rider has odds coverage, all non-market signal variances are multiplied by this factor, reducing their precision to ~1/3 of their usual value. This reflects the reasoning that the market already incorporates career record, form, race history, and trajectory, so these signals carry little marginal information beyond what odds convey.

With `market_discount=3.0` and odds available, the effective precision budget shifts substantially towards market signals:

- Odds: 3.0 (unchanged) — now ~45% of total precision
- Oracle: 1.5 (unchanged) — ~23%
- PCS specialty: 0.33 (was 1.0) — ~5%
- Race history (5y): 1.11 (was 3.33) — ~17%
- Form, VG, trajectory: minimal

For riders **without** odds (~60-80% of the field), all signal precisions remain at their original values, so the non-market signals still drive predictions for the bulk of the startlist. This two-tier approach matches the evidence: odds are the best predictor where available, and other signals fill the gap where they're not.

This is an interim solution. A more principled approach would model the conditional information content of each signal given odds (i.e. what does PCS specialty tell you that odds don't?), but that requires substantially more prospective data to calibrate.

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
