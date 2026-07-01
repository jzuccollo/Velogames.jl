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

### Stage-race sprinter over-prediction: the aleatoric-noise diagnosis (June 2026)

A full investigation into why the stage-race model over-rates grand-tour sprinters. The headline conclusion is that **the simulator's per-stage outcome noise is 2.5–3× too small**, and the fix is a per-stage-type aleatoric noise calibrated to observed dispersion. This is the single most important stage-race calibration finding to date. Everything a future analyst needs to reproduce, act on, or extend it is below.

#### The symptom

The 2026 Tour predictor put four sprinters (Philipsen 1670, Kooij 1429, Merlier 1301, Pedersen 1289) at near-green-jersey level, compressed into a 1.3× band. Reality (TdF/Giro 2023–2025): one sprinter dominates at 1.5–2× the next, the sprint field is deep, and ~32% of elite sprinters abandon before Paris (persistent, not a 2025 artefact — measured across 6 GTs). So the model both over-predicted the *level* and over-compressed the *spread* of sprinter scores.

#### Theoretical framework: epistemic vs aleatoric noise

A rider's expected VG score is

$$\mathbb{E}[\text{VG}_i]=\sum_{\text{stages}}\sum_k f(k)\,P(\text{rank}_{i,\text{stage}}=k),$$

where $f$ is the VG scoring table — dominated by stage-finish points, which are **shallow at the top** (220/180/160/140/120 for positions 1–5, down to 60 at 10th). The simulator generates $P(\text{rank})$ by sorting $X_i=\mu_i+\text{noise}$. The behaviour is governed by a single ratio: **(strength gap between riders) / (noise scale)**.

The critical error is that the model uses one quantity — the Bayesian posterior standard deviation $\sigma_i$ (≈0.68 for most riders) — for two conceptually distinct roles:

- **Epistemic uncertainty**: how unsure we are of a rider's *mean* ability. This correctly belongs in the resample/optimise outer loop (draw $\theta_i\sim N(\mu_i,\sigma_i)$) and in the persistent cross-stage term ($\alpha$-correlated noise, $\alpha=0.7$).
- **Aleatoric variability**: the genuine race-day scatter of finishing positions (positioning, crashes, echelons, breakaways, sitting up). This should drive the *per-stage* noise, and it is **much larger** than the epistemic $\sigma$. It is a property of the race, not of how much data we hold on the rider.

Because the per-stage aleatoric term is scaled by the epistemic $\sigma_i$ (via the $\beta$ component), it is far too small. With the sprinter-to-field strength gap ≈2.2 and $\sigma$≈0.68, the ratio ≈3.2. At a ratio ≫1, $P(\text{top-}10)$ collapses to a **step function**: →1 for the top ~6 riders, →0 for the rest. The placing floor **saturates** — the same handful of riders lock the top-10 on every flat stage. Saturation destroys information: when four sprinters all sit at $P(\text{top-}10)\approx1$, their true strength differences cannot express, so their scores inflate to a common high level and compress together.

This framework explains every observation: the win-share was actually fine (Philipsen won 39% of simulated flat stages vs Pedersen 7% — wins are decided at the very top by small gaps plus a little noise), but the *placing floor* — 92% of a sprinter's EVG — was saturated.

#### What was ruled out — the strength ($\mu$) axis

Three interventions on the strength estimates were tried and **none moved the symptom**, which is itself the key diagnostic that the problem is on the noise axis, not the strength axis:

- **Softening the `log1p` transform on PCS specialty.** PCS specialty is `rider_currency`-scaled then `log1p`-transformed then z-scored (`simulation.jl` ~L2412), which compresses all good sprinters into a narrow ~1.4–2.0 band. Softening the transform *sharpens the top* (Philipsen 2.1→4.5 at λ=0.5) but does **not** lift the second tier — z-scoring lets the top outliers inflate the field SD, so mid-tier riders stagnate. It also blows up the GC dimension (Vingegaard 2.4→4.3). Net: makes the cliff worse.
- **Per-rider / per-dimension market discount.** The `market_discount` (×8) is applied race-wide, not per-rider (`simulation.jl` L855 / L561), so a rider with no odds still has their PCS variance inflated because *other* riders have a market. A per-rider + per-dimension version was prototyped (config flags `market_discount_per_dim`, `market_discount_routing_threshold`; helper `_market_discount_dims`) and **verified correct**, but it moved second-tier sprinters by only ~0.05. Removing the discount globally actually *lowers* elite sprinters (Philipsen 3.4→2.7) — its real job is to let the market signal dominate for priced riders. The prototype was reverted. It remains a principled cleanup (and would fix a backtest train/serve inconsistency: backtests have no odds, so `race_has_market=false` and non-market riders keep full signal, unlike production) but it is not the sprinter fix.
- The `rider_currency` decline factor works correctly (Gaviria's career sprint score exceeds Kooij's, but after currency 0.47 vs 0.83 Kooij correctly ranks above — the model is not naively using career-cumulative specialty).

#### Calibration: real dispersion targets and the fitted noise

The saturation was measured directly. For real GT stages (2023–2025, 6 GTs, classified by PCS stage profile), the **mean top-10 overlap between same-type stage pairs** (1.0 = identical top-10 every stage = fully saturated; lower = more rotation):

| stage type | real top-10 overlap | interpretation |
|------------|--------------------|----------------|
| flat | 0.37 | recurring sprinters + rotating lead-outs |
| hilly | 0.15 | most chaotic — breakaways, varied puncheur terrain |
| mountain | 0.37 | stable GC core + rotating breakaway winners |
| itt | 0.53 | most deterministic — same TT specialists (small sample) |

For flat specifically, direct sprinter metrics: the *best* sprinter each race finishes top-10 on 0.70–0.88 of sprint stages, the typical elite sprinter on 0.42 (median 0.38), and ~5.2–5.8 recognised fast-finishers occupy the top-10 per stage. The current model gives 0.93–1.00 top-10 rates and 8.8 distinct — fully saturated.

Fitting the added stage-finish aleatoric SD on the 2026 field to match these targets gives:

| stage type | **fitted `a`** (added SD) | current `BREAKAWAY_NOISE_BY_EVENT.stage_finish` | total per-stage noise, fitted ($\sqrt{0.68^2+a^2}$) |
|------------|--------------------------|-------------------------------------------------|------|
| flat | **1.5** | 0.0 | ~1.65 |
| hilly | **2.1** | 1.0 | ~2.20 |
| mountain | **1.2** | 1.5 | ~1.38 |
| itt | **0.4** | 0.0 | ~0.79 |

The existing hand-tuned values had the **ranking inverted**: they use mountain > hilly > flat = 0, but the data says **hilly > flat ≈ mountain > itt**. The biggest miss is flat (0 → 1.5, the entire sprinter bug); mountain is slightly *over*-noised. At the fitted flat noise the sprinter stage-finish EVG (797/662/631/601) almost exactly reproduces the real TdF-2025 haul (Milan 800 / Van Aert 710 / De Lie 655 / Groves 639) — the simulator, given the right noise, reconstructs the observed distribution.

Note that fitting corrects the *level* (the dominant error) but leaves the residual ~1.3× spread among the top four sprinters. That residual is **not a bug** — real TdF-2025 also had four sprinters bunched at 639–800 (1.25×), with the green-jersey winner rising above only via the jersey bonus the simulator adds separately. Once the level is right, a mild cluster of co-favourites is exactly what the data shows.

#### Validation: impact by rider archetype

Running the full `simulate_stage_race` on the 2026 field, current noise vs fitted noise (mean EVG over top-50 riders by archetype; field total EVG conserved at 45.7k — this is redistribution, not inflation):

| archetype | current → fitted | change | notes |
|-----------|------------------|--------|-------|
| Sprinter | 688 → 527 | **−23%** | elite −34% (Philipsen 1662→1089); 2nd-tier Gaviria +10% (field thickens) |
| GC / all-rounder | 1808 → 1734 | −4% | most flat; Pogačar −11% (see below) |
| Climber | 506 → 546 | +8% | Carapaz +9%, L. Martinez +8% |
| Puncheur / classics | 459 → 477 | +4% | Healy +26% — breakaway/puncheur types get the top-10s the data says they earn |
| TT | 343 → 360 | +5% | — |

The fix deflates the over-predicted elite sprinters, thickens the field (second-tier sprinters, puncheurs, breakaway climbers gain), and behaves sensibly for every archetype.

#### The Pogačar check, and why ability-margin-dependent noise was rejected

The one non-trivial GC move was Pogačar −11% (4185→3735). Verified against his real 2025 stage-finish points by type (flat 152 / hilly 760 / mountain 860 / itt 400 = **2172**): the fitted model gives 436/536/1145/77 = **2194 ≈ real**, whereas the current model gives 2781 — over-crediting him by ~600, chiefly via an absurd **0.97 top-10 rate on bunch sprints** (real ~0.17; he sits up in the peloton). So the −11% is a **genuine correction**. His residual total shortfall (3735 vs real 4153) is in the GC/jersey scoring components, which the noise change does not touch — a *separate* issue.

The only soft spot is that fitted noise under-shoots Pogačar's hilly points (536 vs real 760) by spreading his hilly results across placings rather than letting him win decisively. This motivated a prototype of **ability-margin-dependent dispersion** (reduce the aleatoric noise for riders with a large stage-strength margin, so dominant riders hold their level). It was **rejected**: raising the margin sensitivity does pull Pogačar's hilly up (536→689 at γ=0.25) but simultaneously **re-saturates the sprinter floor** (Philipsen flat top-10 rate springs back 0.70→0.89, EVG 672→868 — undoing the fix) and *worsens* his mountain over-prediction (1143→1389). The reason: margin is measured against the whole field, and sprinters are high-margin-on-flat too, so reducing "dominant rider" noise re-locks the sprint top-10. Separating the "contest among genuine contenders" from the "breakaway lottery" would need substantially more machinery for a small, self-cancelling gain. **Uniform per-type noise is the sweet spot.**

#### Recommended change

Wire the fitted per-type stage-finish aleatoric noise into `simulate_stage_race` as a config-driven parameter (fold `BREAKAWAY_NOISE_BY_EVENT` into the proposed `StageRaceConfig`, see Phase 6), defaulting to `stage_finish = (flat=1.5, hilly=2.1, mountain=1.2, itt=0.4)`. Conceptually this term is the *aleatoric* per-stage scatter and should be documented as decoupled from the epistemic posterior $\sigma$ (which remains the resample and $\alpha$-persistent term). Prototyped by editing the `const` directly and reverted; not yet in production.

#### SHIPPED (July 2026 — Phase A1)

Implemented. `simulate_stage_race` per-stage performance is now `α·σ·rider_noise` (persistent epistemic, correlated across stages) `+ a_stage·stage_noise` (independent aleatoric, a flat per-type scale NOT scaled by σ, drawn `_rand_t(rng, 5)` for fat tails), replacing the old `σ·(α·rider + β·stage)`. The aleatoric scale, breakaway noise, jersey allocation, and intermediate-sprint points live in a new `StageSimConfig` (`race_helpers.jl`, `DEFAULT_STAGE_SIM_CONFIG`), threaded `render_stagerace`→`solve_stage`→`resample_optimise_stage`→`simulate_stage_race`.

`a_type` was **re-fitted by top-K (K=20) Plackett–Luce ranking-likelihood MLE** on archived GT finishing orders (finishers only; μ reconstructed via `estimate_strengths(:stage)` on archived specialty), superseding the overlap-matched estimates above. The top-K PL ignores the meaningless flat bunch-sprint tail, giving much smaller, K-robust values — clean giro-2026 fit: flat 0.54 / hilly 1.06 / mtn 0.50 / itt 0.49 (ordering hilly>flat≈mtn>itt; itt under-identified). Because `a_type ∝ μ-scale` (an identifiability confound the sweep bounds) and specialty-only μ understates production sprinter sharpening, the **shipped defaults sit at the upper-middle of the fitted range: `aleatoric_noise = (flat=0.8, hilly=1.1, mountain=0.7, itt=0.5)`**. Validation (giro-2026, market-sharpened μ): the dominant sprinter's flat top-10 rate de-saturates from 1.00 (a_type≈0) to 0.82 under the fitted config vs real 0.67; do-no-harm top-20 EVG↔actual ρ unchanged within noise. **Pre-registered revisit trigger: if the next 2 GTs show top sprinters now under-predicting, or top-20 ρ drops materially, revisit `a_type` (esp. flat).** Next: B1 (oneday→flat trim), then A2 (correlated attrition).

#### A2 SHIPPED (July 2026 — attrition / DNF hazard)

Implemented in `simulate_stage_race` via a new `rider_classes` kwarg (gates attrition; empty = off, so tests keep old behaviour) threaded from `resample_optimise_stage` (reads `df.classraw`). Per not-yet-abandoned rider each stage, DNF hazard = `base_type × class_mult × brutal_day_shock`; abandoned riders are frozen out (`-Inf`) of every per-stage event and all final classifications, but keep points earned before abandoning. A single shared per-stage Gamma(shape 2)/2 shock (mean 1, var 0.5) eliminates sprinters in correlated cohorts. Params live in `StageSimConfig` (`attrition_hazard`, `attrition_class_mult`, `attrition_shock_shape`).

**Empirical hazards** (fitted from archived `pcs_abandons` × VG class labels, 4 GTs): base per-rider-stage by type flat 0.0035 / hilly 0.0075 / mtn 0.0092 / itt 0.0018; class multipliers sprinter 1.29 / climber 1.19 / allrounder 1.53 / unclassed 0.86 (field DNF 14.8%). **Important reset of the plan's premise: the *VG sprinter class* DNFs at only 19% (1.29× field), not the assumed 32% — that figure is elite-only.** Validation: simulated field survival 0.86-0.87 (obs 0.82-0.88), sprinter survival 0.83 (obs mean 0.82), over-dispersion 1.82 (obs 1.66). EVG impact: top riders −5 to −8% (expected haircut < DNF rate, since pre-abandon points stand), survivors redistribute upward, field total ~conserved.

**Residual (logged, not fixed): class-based hazard mis-attritions the tails.** It under-attritions elite sprinters (they DNF ~32%, get the class's 19%) and over-attritions the exceptionally-durable GC leader (Pogačar −8%, though he rarely abandons) — class can't identify exceptional durability/fragility. An "elite-aware" hazard (scale with strength/cost within class) was offered and deliberately not chosen (thin data). This slightly worsens the C2 GC-star under-prediction below.

**Ability-based hazard tested and rejected (July 2026).** The intuitive hypothesis — DNF hazard should fall with climbing quality (weak climbers time-cut on mountains) — is **contradicted by the data**: corr(cost, DNF) = +0.066, corr(overall-quality, DNF) = +0.124, corr(climber, DNF) = +0.056 (giro-2026); quality tertiles run worst 11.5% → best 27.4% DNF. Stronger/marquee riders abandon *more* (strategic abandonment once goals evaporate), not less; climbing ability offers no protection, and the durable exception is simply the rider still winning — which no ability variable can identify ex-ante. Decision: **keep the class-based hazard**; do not re-propose a climbing-quality hazard without new evidence. (Data-consistent alternatives, if revisited: market-favourite GC protection, or a quality-*increasing* hazard paired with favourite protection.)

#### Separate residual issues surfaced (do not conflate with the noise fix)

1. **GC/jersey scoring under-predicts dominant all-rounders.** After stage-finish is corrected, Pogačar's total still trails real by ~400 in the daily-GC/final-GC/points-jersey terms. Independent of the noise model.

   **C2 INVESTIGATED (July 2026) — the daily/final-GC hypothesis does NOT hold; the real omission was daily KOM.** Decomposing Pogačar's simulated points by component: **daily GC 626 (≈ the 630 max — he leads GC nearly every day) and final GC 599 (≈600 — wins ~99.8%) are near-maximal, not under-predicted.** The genuine gap was that the per-stage sim scored *none* of `daily_mountains_class`, `hc_climb_points`, or `cat1_climb_points` — only a crude `mountain_top5_counts` proxy feeding the final KOM. **Fix shipped: daily mountains classification** (`_score_daily_mountains!`) now awards `daily_mountains_class` (up to 33/climbing-stage) ranked by climbing ability + stage luck on mountain/hilly stages — ~100/tour for Pogačar, up to ~252 for a KOM specialist, materially lifting pure climbers/polka-dot contenders who were badly under-scored. **HC/Cat-1 per-climb points remain unscoreable** — the PCS scraper leaves `n_hc_climbs`/`n_cat1_climbs` at 0, so there's no per-climb data (a scraper-side fix would be a prerequisite). Any residual Pogačar gap is now attributable to points-jersey contribution + A2's durable-GC-leader over-attrition, not GC scoring.
2. **Flat-strength leakage.** GC ability leaks into the `:flat` dimension (Pogačar's flat strength 2.43 sits above every second-tier sprinter; his fitted-model flat top-10 rate is 0.49 vs real 0.17). A `SIGNAL_DIMENSION_WEIGHTS` / routing cleanup, on the $\mu$ axis.

   **B1 SHIPPED (July 2026) — `pcs_oneday → :flat` weight 0.2 → 0.0.** Swept the weight on the TdF-2026 field. Two findings: (a) A1's aleatoric noise already de-saturated the *backtest-regime* symptom — Pogačar's PCS-only flat top-10 was 0.13 even at weight 0.2, not 0.49 (the 0.49 was pre-A1). (b) The trim is the right conceptual cleanup regardless: it removes the all-rounder one-day → flat-sprint leak (Pogačar backtest flat 1.02 → 0.75) with **elite-sprinter flat strength unchanged** (Philipsen 2.12→2.15, Kooij 1.52→1.68 — their flat comes from `pcs_sprint`, weight 1.0). It is **inert in production** (Pogačar production flat = 2.46 at both 0.0 and 0.2, since `market_discount` suppresses PCS for priced riders), so it only helps backtests, as the plan anticipated.

   **NEW residual surfaced by the sweep — the real *production* flat leak is `odds_points → :flat` (weight 0.4), not `pcs_oneday`.** Pogačar is listed in the green-jersey (points) betting market (info_share_odds_points ≈ 0.155), and that pricing routes onto `:flat`, giving him a production flat top-10 rate of ≈0.50. B1 does not touch this (market signals bypass `market_discount`). A future cleanup could route `odds_points`/`oracle_points` to `:flat` only for riders *classed* as sprinters (as B2's stage-win channel does via `RACE_HISTORY_CLASS_PROJECTION`), so a GC rider's green-jersey pricing informs points-jersey scoring without inflating his flat-sprint ability. Not in this plan's scope; logged for a future μ-routing pass.
3. **`points_jersey` noise not recalibrated (C1 — BLOCKED on data, July 2026).** Only `stage_finish` was fitted. The points-jersey breakaway shock (`StageSimConfig.breakaway_noise.points_jersey`, hilly 1.5 / mtn 2.5) plus `points_jersey_allocation` / `intermediate_sprint_points` drive green-jersey scoring. The A1b-style ranking-likelihood recalibration is **blocked**: no per-stage points/KOM classification standings are archived (only the `odds_points`/`oracle_points` betting markets, which are predictions not results), so there's no target to fit. Prerequisite: a PCS scraper for daily points/mountains classification standings. Also note post-A1 the points-jersey shock now stacks on top of the new aleatoric `noisy`, so it may be mildly over-dispersed — revisit once classification data exists.

#### How to reproduce or recalibrate (e.g. for Giro/Vuelta specifics)

1. **Real targets.** For target GTs: `getpcs_all_stage_results(slug, year, 21)` + `getpcs_stage_profiles(slug, year)` to classify stages; compute the mean top-10 overlap between same-type stage pairs, and for flat also the per-sprinter top-10 rate and distinct-fast-finishers-in-top-10. Watch out: the `vg_results` archive for GTs is stale/wrong (classics-game numbers, max ~585, no Pogačar) — use PCS stage results as ground truth, not that archive.
2. **Fit.** Run `simulate_stage_race` (or a per-stage Monte Carlo replicating the stage-finish ranking) on the target field, sweep the added aleatoric SD per stage type, and match the model's overlap to the real targets.
3. The fitted values were measured across TdF + Giro 2023–2025 and are treated as race-type-general; the *method* is the deliverable, so Giro/Vuelta can be re-checked if their dispersion differs. This is the empirical calibration of `BREAKAWAY_NOISE_BY_EVENT.stage_finish` that Phase 6 called for — now done for `stage_finish`; `points_jersey` remains.

---

## Validation philosophy

Cycling supplies only ~3 grand tours and a few dozen classics a year, and market signals cover even fewer races. We will never have large-sample statistical power for most changes, so validation is deliberately pragmatic: **match the rigour of the check to the change's effect size × mechanistic clarity, never to a race count.** A "wait for N races" gate is a counsel of perfection that freezes all progress; it is justified only where the effect is genuinely too small to see.

### Triage each change

- **Large, mechanistically-understood bias** — e.g. the June 2026 aleatoric-noise fix (model sprinter top-10 rate ~0.98 vs real ~0.42, a factor-of-two error with a clear mechanism). The effect dwarfs sampling noise. Ship on theory + directional confirmation + do-no-harm, then monitor. Does **not** need power.
- **Small metric-chasing tuning** — e.g. non-uniform market discount (overall ρ 0.518 vs 0.473, within 1–2 SEs, tuning a threshold on ~6 races). Genuinely needs power. Defer — but on the grounds of **effect size**, revisited when it looks material, not merely when a race counter ticks over.

### The toolkit (all cheap; none needs a large sample)

1. **Directional + magnitude reality checks** on the races we have — right sign, sensible size, consistent across races. Evaluate at the rider-stage level (thousands of observations) where possible; "6 GTs" badly undercounts the information (a per-stage-type dispersion fit uses ~40 stages and every placement).
2. **Do-no-harm guard rails** — top-~20 rank ρ must not degrade (the model's value rests on ranking the top riders); no absurd outputs (a domestique winning bunch sprints, a sprinter leading GC); field totals conserved (mechanical — a sanity check that catches bugs, **not** evidence of correctness).
3. **Selection-impact, read directionally** — does a team chosen under the change beat the current model's pick on held-out actuals? This is the decision-relevant signal; 5/6 in the right direction is meaningful without significance, and it answers the standing objection that point-level calibration "changes budget allocation but not selection" (it flows through the optimiser into team composition).
4. **Leave-one-out as information, not a veto** — does a fit on the other races roughly predict the held-out one? A wild miss flags a race to investigate.
5. **Estimate ranges, not points** — when fitting a parameter, use a likelihood/CI to bound what is identifiable and pick a defensible value in range; don't agonise over a point estimate the data cannot distinguish.
6. **Ship-then-monitor** — the prospective harness (`src/prospective_eval.jl`) is the real long-run validator and accumulates each race. Ship the well-justified change with a **pre-registered revisit trigger** (e.g. "if the next 2 GTs show sprinters now under-predicting, or top-20 ρ drops, revisit"). Monitoring is non-blocking.

Metric note: rank correlation (ρ) is invariant to the monotonic EVG-level changes that calibration fixes make, so it **cannot** confirm them — use points-level metrics (PIT, team-points-captured) as the acceptance criterion for those.

### Sequencing

Ship one change at a time, for **attribution** (so prospective movement is interpretable and debuggable), not to accumulate power. Each ships behind its own directional + do-no-harm judgement call, then is monitored before the next lands.

---

## Improvement plan

### Overall assessment

The system's rank ordering is reasonable (Spearman ρ 0.2–0.5 across 11 prospective races, median 0.5 in the 120-race historical backtest). The model's team-selection value comes almost entirely from correctly ranking the top ~20 riders (ρ=0.4 for positions 1–10, dropping to 0.1 for positions 21–40).

A signal ablation study (April 2026, 11 prospective races) led to pruning three low-value signals and identified two deferred improvements. A red team review flagged statistical limitations: most claimed ρ improvements are within 1–2 SEs, 20×4 comparisons were tested with no correction, and the 6-race market sample is too small for reliable market-signal conclusions. Bootstrap CIs and a combined configuration test have been added to `render_backtesting.jl` to track these as more data accumulates.

### Active signal set (after April 2026 pruning)

PCS seasons + VG season + PCS race history + Cycling Oracle + bookmaker odds. Three signals were disabled:

| Signal removed | Evidence | Decision |
| -------------- | -------- | -------- |
| PCS form | Near-zero within-tier ρ across all tiers (−0.014, 0.003, 0.106) | Removed — adds noise via block-correlation discount without improving ordering |
| VG race history | Near-zero everywhere, anti-informative for top riders (−0.071) | Removed — same rationale |
| Qualitative | Anti-informative for top riders (ρ=−0.291, n=60) | Removed — pipeline complexity for no benefit |

Code and data collection retained for backtesting re-evaluation.

### Deferred improvements

**1. Drop oracle signal — or disable just the floor path.** A May 2026 listed-vs-floor split across 18 prospective races (n=2302 rider-observations) reframes the previous diagnosis: oracle's negative middle-tier ρ is entirely a floor-mechanism artefact, not a problem with oracle's published predictions. Riders with a real oracle entry (listed, n=110) show middle-tier ρ ≈ 0.004; riders pinned to the floor strength (n=2192) show middle-tier ρ = −0.159. The earlier finding that "odds only" beat "odds+oracle" for top and middle tiers (within-tier ρ: 0.136, −0.088, 0.119) reflected the floor-strength signal degrading mid-field discrimination, not oracle's listed predictions doing so. The bottom-tier listed ρ of −0.408 is striking but n=28 is too small to act on.

Two interventions are now distinguishable rather than one: drop the oracle signal entirely, or disable only the floor path so that riders absent from oracle receive no oracle observation. The combined configuration test had previously shown 5/6 races with odds worsen when oracle is removed alongside other signal changes, suggesting oracle contributes via block-correlation structure when paired with odds — but that test could not separate listed from floor contributions. **Re-evaluate after 20+ races with odds** (likely end of 2026 season). The listed-vs-floor evidence should inform the choice between the two interventions.

**2. Position-dependent market discount.** The only configuration that improves all tiers simultaneously (overall ρ 0.518 vs 0.473 for uniform d=8.0). The mechanism is sound: odds differentiate among favourites (ρ=0.464) but are uninformative for the rest, so applying full discount only to the top quartile by PCS z-score preserves PCS seasons' influence for mid-field riders. However, the red team flagged methodological concerns:

- Circularity: tier assignment uses model-predicted strengths correlated with outcomes
- Overfitting risk: adds a tunable threshold parameter on 6 races with odds (~250 riders per tier)
- Per-race heterogeneity: odds improve ρ for 2/6 races (E3: +0.059, RVV: +0.071) but hurt for 4/6 (Strade: −0.136, Dwars: −0.145, MSR: −0.051, GW: −0.090)

**Defer until n≥20 races with odds.** Implementation would replace the uniform `md` variable in `estimate_rider_strength` with a per-rider `md_i` based on PCS z-score quartile.

**3. Correlated position simulation.** Low-moderate impact; more useful for stage races and team-heavy strategies. Not started.

**4. ML augmentation.** ~3% above tuned baseline per Kholkine; requires 90+ race training set. Not started — prerequisites missing.

**5. Profile-aware PCS specialty blend for one-day races.** Stage races route per-source PCS specialty columns (`:gc`, `:climber`, `:sprint`, `:oneday`, `:tt`) to per-stage strength dimensions via `SIGNAL_DIMENSION_WEIGHTS` (Phase 5). One-day races use only the generic `:oneday` column for every classic from Roubaix to Scheldeprijs, so the prior does not distinguish cobbled, flat-sprint, puncheur, or Ardennes-style courses. Adding a per-race blend (e.g. Eschborn / Brabantse Pijl / Quebec: `:oneday` 0.5 + `:climber` 0.3 + `:sprint` 0.2) would give the prior some terrain awareness, particularly valuable for younger riders missing race-history coverage. Risk of double-counting with the `SIMILAR_RACES` signal, which already provides terrain matching from observed results. Implement as a small ablation on 3–4 puncheur races and reject if Spearman ρ does not improve relative to the current single-column setup.

**6. Data-driven `SIMILAR_RACES` via latent-factor model.** The current similar-races list is hand-curated terrain guesswork (cobbled / Ardennes / sprint clusters). Neither Kholkine nor VeloRost actually defines similarity from rider results — Kholkine hand-picks related-race features, and VeloRost clusters by elevation and road surface attributes. A result-driven approach would be moderately novel relative to those baselines.

Build a rider × race × year tensor of normalised finishing positions or PCS race points (PCS points preferred — it concentrates information at the top of the field where it matters). Residualise on rider × year mean to remove form/peaking effects, then fit probabilistic matrix factorisation with 5–10 latent factors and exponential recency weighting on race-year (handles course evolution like Eschborn pre/post-2023 automatically). Race similarity becomes cosine distance in factor space.

Two qualitative wins over the manual list: (a) automatic adaptation to course changes via the recency weighting, (b) continuous similarity scores enable weighted history observations (a Quebec result counts 0.8 toward Eschborn evidence, a Roubaix result 0.1) rather than a hard top-k threshold. The continuous weighting is the bigger structural improvement; the top-k list itself is probably mostly right at the macro level.

Validation: backtest with (a) manual `SIMILAR_RACES`, (b) factor-model top-k, (c) factor-model continuous-weighted. Reject if (b) and (c) do not beat (a) by more than the bootstrap CI.

Sparsity is the main risk: cross-region race pairs share 15–30 common riders per year, so factors may be unstable. Mitigate by densifying with non-prediction-set races (Tour stages, lower-tier events). Cost ~1 week to prototype (scraping infrastructure exists; PMF in `MultivariateStats.jl` or hand-rolled Gibbs sampler), plus 2 days validation.

### Deprioritised (not planned)

- **VG points calibration**: The PIT right-skew (mean 0.828 across 11 races) is real but roughly uniform across cheap riders. Correcting it changes budget allocation but not rider selection where signals are sparse. Second-order compared to correctly ranking top riders.
- **Race-type selectivity adjustment**: Three clusters are observable (selective/standard/stochastic) but per-race noise adjustment makes all weak riders look more likely to score without helping pick which ones.
- **Ownership-adjusted optimisation**: VG is cumulative points across ~40 races, not per-race GPP. Other players' picks have no bearing on your score.

### Completed improvements

| Phase | Description | Key details |
|-------|-------------|-------------|
| 1. Odds integration | Oddschecker paste + Cycling Oracle scraping as Bayesian signals | Strongest single predictor. Odds pasted from any bookmaker; Oracle covers most European professional races. Both can be active simultaneously. |
| 2. Calibration framework | Prior predictive checks, SBC, backtesting, prospective evaluation | `BayesianConfig` reparameterised to 3 scale factors + 2 decay rates. `render_backtesting.jl` serves as unified calibration frontend. |
| 3. Course profile matching | Terrain-similar race history via `SIMILAR_RACES` | Manual curation of terrain groupings; automatic PCS profile scraping deferred as low priority. |
| 4. Leader/domestique roles | Domestique strength discount + max-per-team constraint | Heuristic leader detection by estimated strength within the field. |
| 5. Recent form signal | PCS form page scraping, z-scored as Bayesian update | Covers top ~40-60 riders; race-agnostic (no terrain filtering). |
| 6. Season-adaptive VG | VG variance scales with season progress | `vg_season_penalty` inflates early-season VG variance. Trajectory signal removed April 2026 (negligible contribution). |
| 7. Student's t noise | Heavy-tailed simulation noise via `simulation_df` parameter | `_rand_t(rng, df)` in `simulation.jl`. Default `simulation_df=nothing` (Gaussian); render scripts use df=5. |
| 8. Qualitative intelligence | YouTube transcript → Claude API extraction → rider adjustments | Automated pipeline via `get_qualitative_auto()` or manual workflow via `build_qualitative_prompt()`. |
| 9. Signal cleanup (April 2026) | Trajectory removed, oracle precision reduced, VG history decay reduced | `_odds_to_oracle_ratio` 2.0 → 3.5 (April) → 5.0 (post 13-race review); `vg_hist_decay_rate` 1.3 → 0.8; trajectory signal fully deleted. |
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

#### Stage-type strength modifiers (deprecated — replaced in Phase 5)

- The original Phase 4 design used `compute_stage_type_modifiers` to apply additive ±0.5σ modifiers on top of a single Bayesian latent strength (since deleted). Phase 5 replaced this with a multi-dimensional posterior over `STRENGTH_DIMENSIONS`; per-stage strengths come from a continuous PCS-ProfileScore-weighted blend across `:flat/:hilly/:mountain/:itt` rather than discrete modifiers.

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

## Phase 5: Multi-dimensional rider strength for stage races (May 2026)

The Phase 4 stage-race model produced a single Bayesian latent strength per rider, with a thin per-stage-type modifier layer adding ±0.5σ shifts on top from PCS specialty z-scores. The architecture failed for non-GC riders. On the Giro 2026 prediction, Cycling Oracle listed only 15 GC contenders; the remaining 168 riders absorbed an oracle-floor observation of strength=−4.69 across their entire base strength, which the +0.7 sprint modifier on flat stages could not recover. Mads Pedersen — second-overall for VG points in the 2025 Tour — was ranked alongside mid-tier domestiques. Phase 5 replaces the scalar posterior with a multi-dimensional one aligned to stage profile types.

### What was built

Each rider now carries a Gaussian posterior over five dimensions (`STRENGTH_DIMENSIONS = (:flat, :hilly, :mountain, :itt, :gc)`) rather than a single strength. Four dimensions match `StageProfile.stage_type`; `:gc` tracks cumulative ranking ability. The prior is independent across dimensions (`N(0, prior_variance)` per dim). Cross-dimension information flow happens only through the explicit `SIGNAL_DIMENSION_WEIGHTS` routing table, not via a hierarchical prior or covariance structure — earlier covariance designs were tried and abandoned because the implicit leakage overpowered the explicit routing for strong signals (a rider's huge PCS GC score would leak into ITT and swamp a true TT specialist's PCS TT direct evidence).

Each signal carries a weight vector across the five dimensions (`SIGNAL_DIMENSION_WEIGHTS`), and each non-zero weight produces a per-dimension Bayesian update with effective variance $v / w$. PCS specialty signals route to their natural dimensions: PCS sprint to `:flat` (1.0) and `:hilly` (0.1), PCS climber to `:hilly` (0.5) and `:mountain` (1.0), PCS GC to `:hilly` (0.3), `:mountain` (0.7), and `:gc` (1.0). The Cycling Oracle splits into three independent sources: GC oracle routes mainly to `:gc` with light cross-routing to `:hilly`/`:mountain`, points-jersey oracle to `:flat`/`:hilly`, and KOM oracle to `:mountain`. Bookmaker GC odds use the same routing as oracle GC.

Two routing mechanisms coexist by design. PCS specialty / oracles / odds use direct (signal-specific) weights because the signal source itself carries dimension information — sprint points means flat ability for every rider regardless of class. VG season points and PCS race history use per-rider class projection (`RACE_HISTORY_CLASS_PROJECTION`) because the signal is dimension-agnostic — the rider's classification acts as an attribution prior over an otherwise undifferentiated total. The principle is documented inline in `src/simulation.jl`.

The keystone fix is the floor mechanism. When a rider is absent from the GC oracle, the floor observation now updates only `:gc`, not the entire strength vector. A sprinter outside the GC contenders no longer takes a hit on `:flat`. The new test `test_stage_race.jl` "Pedersen-shaped sprinter sanity check" pins this behaviour: a high-sprint, low-GC rider absent from oracle ranks in the top decile on `:flat` despite the GC oracle floor pushing his `:gc` down.

`simulate_stage_race` accumulates per-stage GC contributions from the `:gc` dimension rather than summing stage finish positions. A sprinter winning a flat stage no longer accumulates GC points he should not have. The per-stage strength used for ranking comes from a continuous PCS-ProfileScore-weighted blend across `:flat/:hilly/:mountain/:itt`, so a low-PS "hilly" stage (Giro 2026 stage 6, PS=14) is treated as mostly flat while a high-PS hilly with summit finish blends toward mountain. Per-event breakaway noise (consolidated in `BREAKAWAY_NOISE_BY_EVENT`) is added to specific ranking events (stage finish, points jersey) to prevent dominant climbers sweeping mountain stages and the points jersey in simulation.

### Code surface

`src/simulation.jl`: `STRENGTH_DIMENSIONS`, `STAGE_TYPES`, `MultiDimPosterior`, `bayesian_update_multidim_dim`, `SIGNAL_DIMENSION_WEIGHTS`, `RACE_HISTORY_CLASS_PROJECTION`, `MultiDimStrengthEstimate`, `estimate_rider_strength_multidim`, `_estimate_strengths_multidim`, `compute_stage_strengths`, `stage_dimension_weights`, `BREAKAWAY_NOISE_BY_EVENT`, `STAGE_POINTS_JERSEY_ALLOCATION`, `INTERMEDIATE_SPRINT_POINTS`, `StageRaceDiagnostics`. `simulate_stage_race` always returns `(vg_points, diagnostics)`. `_assemble_signals` is the shared signal-prep helper used by both the scalar one-day and multidim stage paths. `STAGE_RACE_PCS_WEIGHTS`, `compute_stage_race_pcs_score`, `STAGE_TYPE_MODIFIER_WEIGHTS`, `SPRINTER_MOUNTAIN_PENALTY`, and `compute_stage_type_modifiers` were deleted; their roles are subsumed by direct per-dimension routing. `RaceData` gains `points_oracle_df` and `kom_oracle_df` slots.

`src/race_solver.jl`'s `solve_stage` accepts `points_oracle_url` and `kom_oracle_url` keyword arguments, fetches each independently via the existing `get_cycling_oracle`, and archives them under `oracle_points` and `oracle_kom` data types. The `_archive_predictions` column allowlist includes per-dimension `strength_<dim>` and `uncertainty_<dim>` columns.

`src/report_helpers.jl` adds `format_classification_table`, `format_team_classification`, `format_stage_podium_picks`, and `format_signal_impact_per_dim` so the stage-race report builds classification tables and per-dimension signal panels via reusable helpers rather than inline script logic.

### Validation

Rider-level multidim test on a Pedersen-shaped synthetic sprinter (high PCS sprint, low PCS GC, absent from oracle and odds): the new test asserts `strength_flat > 1.0`, `strength_gc < strength_flat`, and `strength_flat > strength_gc + 0.5` — the GC oracle floor pushes `:gc` down without dragging `:flat` with it. The full test suite passes. The one-day pipeline shares `_assemble_signals` with the multidim path but keeps its own PCS handling (raw decay-weighted points substitution) and signal set.

### What remains for Phase 6

See the dedicated Phase 6 section below.

---

## Phase 6: Empirical calibration and architectural follow-ups

Deferred work surfaced by the May 2026 cleanup. Listed roughly in priority order; each item is independent of the others.

- Empirical calibration of `SIGNAL_DIMENSION_WEIGHTS`, `RACE_HISTORY_CLASS_PROJECTION`, `STAGE_POINTS_JERSEY_ALLOCATION`, and `BREAKAWAY_NOISE_BY_EVENT` against historical per-stage VG points (Tour and Vuelta 2025 plus aggregate Giro 2023–2025; ~350 rider-race pairs available). Today these tables are hand-tuned against specific failure modes; calibration would let the data set them.
- Hierarchical prior with per-rider ability $\tau^2$ and per-dimension deviation $\sigma_d^2$. The current independent-prior design works for data-rich riders (top contenders have lots of signal) but is weakest for sparse-data riders. A hierarchy would couple dimensions structurally so a rider with only VG points still gets a coherent strength vector. Add as part of the calibration work so $\tau^2/\sigma_d^2$ have empirical guidance.
- PCS race history projection through the actual stage-type mix of each past race rather than the Phase 5 fallback of projecting via the rider's own class profile.
- Stage-winner bookmaker markets routed per stage type (no infrastructure exists yet).
- Multi-dim prior predictive checks and SBC.
- Promote per-stage scoring tables (`STAGE_POINTS_JERSEY_ALLOCATION`, `INTERMEDIATE_SPRINT_POINTS`, `BREAKAWAY_NOISE_BY_EVENT`) into a `StageRaceConfig` struct alongside `BayesianConfig`, so race-specific scoring (Giro vs Tour vs Vuelta) is one parameter swap rather than five `const` reassignments.
- Routing-principle empirical validation: should VG season points stay on per-class projection or move to direct weights?
- Migrate one-day races to the multi-dim model if the architecture proves robust on stage races.

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
