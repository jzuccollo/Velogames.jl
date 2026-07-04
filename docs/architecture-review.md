# Architecture review: is the Velogames prediction system still fit for purpose?

*Prepared July 2026. Reviewer brief: assess the statistical architecture from the perspective of an expert in prediction models, judge it against the agreed success criterion (performance in the fantasy league against other humans), and recommend whether to persist, simplify, or change approach. Constraints agreed in advance: Julia and the data layer stay; the modelling paradigm is open.*

---

## Executive summary

The system contains two models of very different maturity wearing one architecture, and the right course of action differs between them.

**The one-day classics model is earning its complexity.** Across the twelve 2026 classics where the archived pre-race team can be scored, it captured 52% of the hindsight-optimal score — comfortably ahead of naive strategies (an odds-implied team managed 39% on the same races where odds exist; buying the most expensive riders managed 32%) and within reach of the best human in the league each week (66%). Its picks equalled the league-winning score outright at Brugge-De Panne. It is mature, adequately evaluated, and needs pruning rather than redesign.

**The stage-race model is not earning its complexity.** It is roughly three times the mechanism — seventeen distinct simulation layers, most with hand-set parameters, several added in the last two months — yet on the only completed grand tour of 2026 it was beaten by a team picked naively from the bookmaker's GC market (model 7,398 points; odds team 7,684; league winner 8,351), and it produced the worst rank correlation of all 24 prospectively evaluated races this season (Spearman ρ = 0.20 at the Giro, against a season median of 0.35). It has no backtest harness, so none of its recent layers has been validated against anything except the anecdotes that motivated them.

**The estimation core is not what its vocabulary claims.** A code audit found that the genuinely Bayesian content — the conjugate updates — is about 32 lines; the surrounding ~2,100 lines are signal assembly, hand-set routing tables, one-sided clamps, order-dependent updates, and post-hoc precision surgery. Roughly 76 hand-set constants govern the estimation path alone, with another ~30 in the stage simulation config. This would be defensible if the evaluation machinery could distinguish good settings from bad, but by the project's own analysis most configuration differences fall within one to two standard errors on the available race sample. The parameter count has decisively outrun the data's ability to identify parameters.

**Recommendation: consolidate, then run a controlled challenge — not a rewrite.** Specifically:

1. **Freeze the mechanism count.** No new signals or simulation layers until a stage-race evaluation harness exists. The recent cadence (aleatoric noise, attrition, GC protection, protection floor, breakaway draws, Option A, Option B — seven mechanisms in roughly two months, each patching the residual of the last) is the classic patch cascade of a model past its architectural limits.
2. **Measure the actual objective.** The success criterion is league placement, and the repo cannot currently compute it — only per-race winning scores are recorded. Archive the full league standings and the team actually entered each race. This is the cheapest, highest-value change in this review.
3. **Build the stage-race harness and fix the found bugs.** Fold the three self-labelled "TEMPORARY" evaluation scripts into `backtest.jl`, then fix the five concrete defects listed in §7 (one of which — the final mountains jersey ignoring the KOM strength dimension entirely — silently wastes three signals the model pays for).
4. **Run a direct-points challenger for grand tours.** The evidence (§5) points to the position-simulation paradigm being wrong for stage-race VG points, and the project's own most successful recent change (the Option B propensity layer) is already a direct-points model in embryo. Generalise it into a standalone challenger — predicted points as a shrunken log-space blend of market-implied, ability-implied, and own-history points — and let it fight the seventeen-layer simulator on the new harness. Keep whichever wins; pre-register the criterion.

The one thing not to do is a ground-up rewrite. The data layer (~4,300 lines of model-agnostic scraping, caching, archival, and temporal-integrity machinery) is the project's genuine asset and transfers unchanged under any modelling approach; the one-day model works; and the evaluation philosophy in `roadmap.md` is better than most professional shops manage. The problem is concentrated and recent, and so is the remedy.

---

## 1. What the system is

Five layers, ~23,000 lines of Julia (≈15,500 in `src/`, ≈7,500 in `scripts/`):

| Layer | Files | Size | Health |
| --- | --- | --- | --- |
| Data acquisition | `get_data.jl`, `pcs_scraper.jl`, `pcs_extended.jl`, `cache_utils.jl`, `data_assembly.jl` | ~4,300 | Good: alias-based column resolution, heading-driven parsing (after a real positional-corruption incident), failures degrade to missing signals. Model-agnostic and reusable. |
| Strength estimation | `bayesian_core.jl`, `strength_pipeline.jl` | ~2,650 | Works, but is a heuristic precision-weighted blender with Bayesian notation (§4). Scalar and multidim paths behave inconsistently. |
| Simulation | `simulate_oneday.jl`, `simulate_stage.jl` | ~1,100 | One-day path simple and adequate. Stage path is a 390-line core loop carrying 17 stacked mechanisms, mostly uncalibrated (§4.2). |
| Optimisation | `build_model.jl`, `race_solver.jl` | ~1,900 | Sound. JuMP/HiGHS, resampled optimisation, k-best enumeration. The least problematic statistical component. |
| Evaluation & reporting | `backtest.jl`, `prospective_eval.jl`, `prior_checks.jl`, `report_*.jl`, `scripts/` | ~9,000 | Strong for one-day races (prospective archival, temporal integrity, PIT). **No stage-race path at all** — the largest, newest code path is evaluated only by three duplicated scripts marked TEMPORARY. |

In production, essentially every mechanism is switched on simultaneously: per-stage aleatoric noise, correlated epistemic noise, attrition with class multipliers and a shared gamma day-shock, GC-favourite protection with a floor, discrete breakaway draws with a strength boost, a flat breakaway bonus, daily KOM, intermediate sprints at an undocumented half-rate, TTT handling, jersey allocations, the Option A GT-history strength signal, and the Option B points-propensity multiplier.

## 2. Performance against the objective

The agreed success bar is league performance. The best available evidence is the archive: for each race, score the model's archived pre-race team against actual VG results and set it beside the league-winning score and the hindsight optimum. (Reproduce with `scripts/league_eval.jl`, offline against the archive.)

### 2.1 One-day classics, 2026

| Race | Model team | League winner | Hindsight optimum | Model / optimum |
| --- | ---: | ---: | ---: | ---: |
| Kuurne-Brussel-Kuurne | 237 | 488 | 1,440 | 0.16 |
| Trofeo Laigueglia | 459 | 1,126 | 1,575 | 0.29 |
| Milano-Sanremo | 1,285 | 1,515 | 2,430 | 0.53 |
| Brugge-De Panne | **1,734** | **1,734** | 2,091 | 0.83 |
| E3 Harelbeke | 1,266 | 1,668 | 2,271 | 0.56 |
| Gent-Wevelgem | 859 | 1,166 | 1,992 | 0.43 |
| Amstel Gold Race | 2,070 | 2,220 | 3,075 | 0.67 |
| La Flèche Wallonne | 1,381 | 1,530 | 2,049 | 0.67 |
| Liège-Bastogne-Liège | 2,010 | 2,064 | 2,604 | 0.77 |
| Eschborn-Frankfurt | 756 | 1,248 | 2,499 | 0.30 |
| GP de Plumelec | 866 | 983 | 1,440 | 0.60 |
| Tro-Bro Léon | 648 | 1,041 | 1,569 | 0.41 |
| **Total** | **13,571** | **16,783** | **25,035** | **0.52 (mean)** |

Four further races (Ronde, Roubaix, Scheldeprijs, Brabantse Pijl) have archived predictions but no recorded chosen team — an archival-schema inconsistency worth fixing (§7). Since two of those are selective monuments where the model does best, the table above, if anything, understates it.

Three readings:

- **Against naive baselines, the model wins clearly.** On the seven races with archived odds, the model's teams scored 9,627 against 8,344 for teams that simply maximise bookmaker-implied win probability under the budget — a 15% edge over the market-following strategy. Max-cost "star-buying" captures 32% of the optimum against the model's 52%. The one-day machinery is adding real value beyond its strongest single input.
- **Against the best human each week, it does not win** — 0 outright wins and 1 tie in 12. But this comparator is the *maximum* of the league each race, a bar no individual player clears either (the sum of per-race winning scores, 16,783, is an upper bound that no actual entrant attains; the winner's name changes week to week). Where the model would place *cumulatively* — the thing VG actually rewards — is currently unknowable from the data the repo keeps (§2.4).
- **The shortfall is structured, not uniform.** In selective, favourite-driven races the model is within 3–10% of the winning human (Liège, Amstel, Flèche, Brugge). In stochastic sprints and semi-classics it collapses to 30–60% below (Kuurne, Trofeo, Eschborn, Tro-Bro). This is exactly the documented calibration failure — mean PIT 0.826 (target 0.5, n = 1,012, KS = 0.56) — the model systematically under-rates cheap and mid-tier riders' points, so in the races where the winning team is built from them it has nothing to offer. The known weakness and the league gap are the same fact.

### 2.2 The Giro: the one completed grand tour

| Strategy | Points |
| --- | ---: |
| League winner | 8,351 |
| **Naive odds-implied team** (maximise GC win probability, budget 100, 9 riders) | **7,684** |
| Model team | 7,398 |
| Hindsight optimum (without class constraints, so mildly inflated) | 14,004 |

The seventeen-layer simulator was outscored by a team you could pick from a bookmaker's screen in five minutes. One race decides nothing — but the burden of proof sits with the complex model, and there is no harness on which it could discharge that burden. The Giro also recorded the *worst* prospective rank correlation of all 24 evaluated races in 2026 (ρ = 0.198; season median 0.349; the week-long Romandie, run through the same pipeline, managed 0.642, and Itzulia 0.432 — the failure looks Giro/GT-specific rather than stage-races-in-general).

### 2.3 Rank and calibration metrics, 2026 season

From `prospective_season_summary(2026)` (24 races): Spearman ρ mean 0.38, median 0.35, range 0.20–0.64. Top-10 overlap typically 4–6 of 10. These are respectable numbers for cycling — consistent with the academic ceiling (Hubáček et al. 2024: ML accuracy in sports "at the same level as model-free bookmaker odds") — and they have been roughly stable all season. The PIT calibration failure (0.826) has likewise been stable across 10+ races despite substantial model surgery in between. Both stabilities point the same way: **the current architecture is at its performance plateau. Further mechanism is not moving the numbers.**

### 2.4 What cannot currently be measured

The success criterion is league placement, and the repo does not record it. `league_winners.toml` keeps only each race's winning name and score; the standings table behind it, and the team the user actually entered (as opposed to the model's recommendation), are both unrecorded. Consequences: we cannot say whether the model's 13,571 would sit 2nd or 9th in the league; we cannot measure the human-override delta (does the user's judgement improve on the model's raw pick?); and the repeated winner names (Mud Springs Eternal ×4, Cobbles & Wobbles ×4, Rounded-up Riders ×3) hint at consistently strong opponents whose season totals would be the true benchmark. For a project whose stated objective is league performance, this is the largest measurement gap, and it costs one page-save per race to close.

## 3. Statistical assessment of the estimation core

A full code audit of `bayesian_core.jl` and `strength_pipeline.jl` found the following (file/line references verified at review time).

**It is a heuristic blender, not a probabilistic model.** The conjugate normal-normal updates total ~32 lines; over 90% of the pipeline is assembly, routing, clamps, floors, discounts, and diagnostic bookkeeping. Several core mechanisms are not valid Bayesian operations, by design:

- **Order-dependent, belief-dependent updates.** The GT VG-history signal is deliberately applied *last*, after the market signals, and each observation is included only if it would raise the current posterior mean (`strength_pipeline.jl:844`). Conditioning inclusion of data on the running posterior is one-sided censoring, not inference; the comment openly relies on the update order. A coherent posterior is order-invariant.
- **Post-hoc precision surgery.** The block-correlation discount reconstructs the posterior from deflated cluster precisions after all updates (a design-effect correction with two hand-set ρ values, not a joint likelihood) — and it is applied **only in the scalar path**. The multidim estimator used for stage races has no correlation discount at all, so stage-race posteriors are systematically overconfident relative to one-day posteriors, and it is exactly that overconfident `:gc` variance which feeds the GC simulation that was found to be over-deterministic (Pogačar 93% vs the market's ~55%). The documented GC-determinism problem and this omission are plausibly the same defect.
- **The market discount is a blanket haircut.** When any odds exist, every non-market signal's variance is inflated ×8 for *every* rider — including the unpriced majority, who receive no compensating market observation and are simply crushed toward the prior. This is the single most consequential modelling choice for the mid-field, and the mid-field is precisely where the league gap lives (§2.1). The per-rider version was prototyped, verified correct, and reverted as "not the sprinter fix" — it deserves reconsideration as *the mid-field fix* instead.
- **Domestique discount subtracts from the mean and leaves the variance untouched**, so the simulator treats a discounted rider as confidently weak rather than uncertain.

**The knob count has outrun identifiability.** ~76 hand-set constants in the estimation path (23 config fields — two of them dead code, `form_absence_floor` and `qualitative_absence_floor` — plus 4 hardcoded base variances, 43 non-zero routing-table cells, and assorted magic numbers), plus ~30 more in `StageSimConfig`, plus Option B's (κ, decay, floor). Against this: ~40 classics per year of which ~15 have odds, and 3 grand tours. The project's own red-team notes that most configuration comparisons land within 1–2 standard errors. When the free-parameter count exceeds what the data can distinguish by an order of magnitude, hand-tuning degenerates into fitting anecdotes — each knob is set against the specific failure that motivated it, with no capacity to detect what it breaks elsewhere.

**The calibration harness validates a different model from the one in production.** Prior-predictive checks and SBC exercise the scalar estimator with signals that production has disabled (form, VG history, qualitative), never set `race_has_market=true` (so the market discount is never exercised), and never touch the multidim path, the floors, or the GT-history clamp. A comment in `prior_checks.jl:116` even refers to bypassing a production odds clamp that does not exist anywhere in `src/`. The stylised-fact guarantees therefore cover the model's least-used configuration.

## 4. The stage-race simulator: a patch cascade

### 4.1 The layer stack

Seventeen distinct mechanisms are live simultaneously in production (§1). The audit's most important structural findings:

- **The same physical phenomena are modelled three times.** Crashes, breakaways, and echelons are cited as the rationale for (i) the fat-tailed aleatoric stage noise, (ii) the separate Gaussian "breakaway noise" on stage finish and points jersey, and (iii) the discrete breakaway participation draw — three independently parameterised noise sources for one reality, with the effective finish-order dispersion on hilly/mountain stages being their uncalibrated convolution.
- **The break-hunter archetype is lifted four times over.** A rider with breakaway history on a mountain stage receives the Option A strength lift at estimation, the breakaway noise, the +2.5 discrete boost (which propagates into stage finish, points jersey, *and* daily KOM rankings simultaneously), and finally the Option B multiplier on the aggregate. The A→B stacking is only partially guarded (B's baseline is A-lifted, shrinking but not eliminating double-counting of the same historical evidence). Nobody has jointly calibrated this, and no harness exists on which it could be done.
- **Controlled experiments are structurally blocked.** The attrition layer's gamma sampler consumes a variable number of RNG draws, so with attrition on, a fixed seed no longer holds downstream layers constant — ablating one layer perturbs every later layer's noise. The pipeline cannot run the clean A/B comparisons its own validation philosophy prescribes.
- **Validated: almost nothing.** Unit tests are genuinely good (1,300 lines, including do-no-harm bit-identity checks for individual toggles). But empirically, only the aleatoric noise (Plackett–Luce fit — whose fitting script is not in the repo; the values survive only as literals with a comment) and attrition hazards (fitted from archived abandons) have any data behind them. Option B passed a thoughtful one-year-ahead do-no-harm check. Everything else — protection, floor, boost, jersey allocations, intermediate sprints, KOM — is hand-set and exercised only in live production.

### 4.2 Confirmed defects

Verified directly in the code during this review:

1. **The final mountains jersey never reads the KOM strength dimension.** `simulate_stage.jl:750–759` allocates the polka-dot bonus from `mountain_top5_counts` — top-5 *finishes on mountain stages* — while `kom_s` (the dimension purpose-built from KOM odds, KOM oracle, and KOM history, and part-funded by Option A's 0.5 routing weight) drives only the small daily KOM points. A breakaway KOM specialist who never cracks a summit top-5 is structurally shut out of the final jersey. Three paid-for signals are largely wasted.
2. **KOM stage-set inconsistency.** Daily KOM scores on hilly *and* mountain stages (`:241`); the final-jersey proxy counts mountain only (`:678`).
3. **Intermediate sprints award half the documented points.** `0.5 * int_points[rank]` at `simulate_stage.jl:216`; the config documents the full vector with no mention of halving — anyone tuning it will be off by 2×.
4. **GC-favourite protection is skipped when `gc_strengths` is empty** because the fallback populates it *after* the protection block (`:443–462`). Latent for non-production callers — i.e. exactly the backtest harness this review recommends building.
5. **Prediction-archive schema drift**: four 2026 races archived without the `chosen` flag, two legacy races without `cost`/`team`; the MSR archive has 38 columns against 14 for Roubaix. The prospective harness warns that assist simulation is inaccurate for the legacy archives.

## 5. Is the paradigm right for stage races?

The one-day paradigm — signals → latent strength → simulated finish order → scoring table — is sound because one-day VG points are, to first order, a function of finish position. The stage-race failures all share a signature: **they occur in the strength→points transform, not in strength estimation.** Break-hunters (Eenkhoorn predicted 33 against real totals of ~290), sprinter compression, GC over-determinism, the ~6 points/stage unmodelled bonus gap — in each case the model ranks riders tolerably but cannot convert rank into the role-conditional, event-driven points that VG actually awards for three weeks of racing. The roadmap says this itself: a grand tour generates points "ROLE-conditionally", and a strength nudge "can only lift a rider's finish-position ranking so far".

The project's response has been to bolt the missing physics onto the simulator one mechanism at a time. But its own most successful recent change points the other way. Option B — predicted points multiplied by a shrunken log-ratio of the rider's *realised historical VG totals* to the model's prediction — is algebraically a log-space convex blend of ability-implied points and own-history points. It is a **direct points model wearing a correction-layer costume**, it delivered the cleanest do-no-harm result of the three stage-race changes (rank ρ improved at every tier), and it is ~40 lines. This mirrors the fantasy-sports literature the roadmap already cites (Baronchelli et al. 2025: recency-weighted Bayesian baselines blended with realised recent points are the strong, stable performer) and the market-efficiency finding that dominates sports prediction generally.

The implication is not "delete the simulator". The optimiser needs per-rider expected points above all (its selection is driven by the EVG column; per-draw selection frequency is secondary), and a direct model supplies that cheaply:

> **EVG(rider) = exp[ w₁·log(market-implied points) + w₂·log(ability-implied points) + w₃·log(own GT history points) ]**, with weights shrunk by data availability per rider, a floor constant for near-zero components, and recency decay on history — i.e. Option B's learner promoted from correction to model, with the market added as a first-class component.

That is a ~200-line model with perhaps six genuinely free parameters, fittable and *checkable* on the archived 2023–2025 GT data (~350 rider-race pairs per edition). The seventeen-layer simulator then has to demonstrate, on a real harness, that its extra thousand lines beat this on team-points-captured. Perhaps it does — per-stage simulation demonstrably beat the aggregate model in 2024/25 (ρ 0.77 vs 0.66), and simulation is the natural home for variance and correlation if team-level risk ever matters. But right now the complex model holds the field by default, not by evidence, and on the only 2026 data point it lost to a bookmaker's screen.

## 6. Options considered

**A. Persist with the current trajectory** — keep adding mechanisms as failures surface. Rejected. The performance metrics have been flat through the recent burst of mechanism-building; the layers now interact multiplicatively on the same archetypes; the parameter count is an order of magnitude beyond identifiability; and there is no harness that could detect a regression. The next layers (points-jersey recalibration is already "BLOCKED on data", per-climb KOM needs a new scraper) have visibly worse cost-benefit than the last.

**B. Consolidate within the current architecture** — freeze, measure, prune, fix. Necessary but not sufficient. It stabilises the system and restores the ability to run controlled experiments, but it does not by itself address the paradigm mismatch in §5, and the effort would be spent polishing a stage-race model that has not yet beaten a naive baseline.

**C. Replace the stage-race points engine with a direct model, keep everything else.** The data layer, estimation of *relative ability* (which works — the rank metrics are fine), the optimiser, and the whole one-day pipeline stay. Only the GT strength→points transform is contested, via a challenger that mostly already exists in embryo.

**Recommended: B and C together, sequenced, with a decision gate** — consolidation first (it creates the harness the challenge needs), then the champion–challenger comparison decides C on evidence rather than taste. A full rewrite (new language, new estimation framework, hierarchical/PPL model) is rejected outright: it forfeits the mature data layer and one-day model for speculative gains the race calendar cannot validate.

## 7. Recommended course of action

Phased, each with a pre-registered acceptance criterion, in the spirit of the existing validation philosophy.

### Phase 0 — measure the objective (days)

- Record full league standings per race (a `league_standings.toml` or scraped league page), and the team actually entered. Backfill what memory allows. *Deliverable: "where would the model's team have placed cumulatively?" becomes a computable number, and §2.1's table gains its missing final column.*
- Fix the prediction-archive schema: always write `chosen`, `cost`, `team`; version the schema. Re-archive is impossible for past races, so also make readers tolerant.

### Phase 1 — freeze and consolidate (1–2 weeks of effort, spread as convenient)

- **Moratorium on new signals and simulation layers** until Phase 2's harness exists. Pre-registered exception: genuine bug fixes.
- Fix the five confirmed defects in §4.2 — the KOM one first; it likely changes polka-dot pick quality for the Tour, and the Tour is live.
- Delete dead knobs and dead-signal scaffolding (the two dead config fields; the disabled form/VG-history/qualitative branches can collapse behind a single `force_enable` shim used only by backtesting); proceed with the existing `REFACTOR_PLAN.md` Phases 1 and 3 (its diagnosis is accurate).
- Make the RNG stream layer-stable (pre-draw per-layer substreams or counter-based draws) so ablations hold everything else fixed. Without this, Phase 2's comparisons are noisy by construction.
- Port the block-correlation discount (or a justified successor) to the multidim path, or explicitly document why stage posteriors should be narrower. This is the cheapest candidate fix for the GC over-determinism already on the roadmap.

### Phase 2 — stage-race harness, then champion vs challenger (the decisive phase)

- Fold the three TEMPORARY scripts into `backtest.jl` as a stage-race harness parameterised by target (`:gc`/`:points`/`:kom`/VG totals), exactly as the roadmap's item 5 envisages. Targets exist in the archive (per-stage results, VG totals 2023–2025).
- Build the direct-EVG challenger of §5 (generalised Option B + market component; ~200 lines; fit on 2023–2024, validate on 2025).
- **Gate (pre-registered): on team-points-captured across the archived GTs, and prospectively on the Vuelta 2026, does the full simulator stack beat the challenger by more than the bootstrap CI?** If yes — keep it, and the exercise has finally produced the evidence that justifies its complexity. If no — the challenger becomes the GT points engine; the simulator is retained only if something the optimiser measurably uses (variance, correlation, jersey interactions) needs it, and is otherwise retired to ~200 lines of archive.
- Either way: prune the losing mechanisms. A layer that does not move team-points-captured on the harness is deleted, per the project's own "delete, don't deprecate" ethos.

### Phase 3 — one-day refinements (only after the gate)

The one league-relevant weakness of the one-day model is the stochastic-race mid-field (§2.1), and the two shelved candidates aimed at exactly that — the per-rider/per-dimension market discount (prototyped, verified, reverted) and the oracle floor disablement (listed-vs-floor analysis already done) — should be re-run on the 20+ odds races the 2026 season will have banked by autumn, as the roadmap already planned. Both *remove* distortion rather than add mechanism, which is the right direction for this codebase.

### What not to do

- No hierarchical prior, latent-factor race similarity, or ML augmentation yet — all are parked behind sample sizes cycling will not deliver soon, and all add knobs to a system whose problem is knobs.
- No ownership-adjusted optimisation — the roadmap's dismissal is correct for a cumulative-points format.
- No estimator rewrite in a probabilistic programming framework. The estimator's sins (§3) are real but survivable at current performance; the fix priority is measurement and the points transform, not inferential purity. Revisit only if Phase 2 leaves the simulator in place *and* its calibration problems persist.

## 8. Concluding assessment

The question posed was whether to persist, simplify, or change approach. The answer is: **persist with the one-day system (pruned), simplify the whole system's parameter surface, and put the stage-race paradigm on trial rather than continuing to patch it.** The project's real strengths — a disciplined data/archival layer, prospective evaluation, an honest validation philosophy — are exactly the assets needed to run that trial cheaply. What has gone wrong is narrow and recent: a season of rapid, individually-reasonable stage-race patches, each validated only against the anecdote that motivated it, accumulating into a model that is the largest thing in the codebase and the least evidenced. The discipline that governs the one-day model — ship on theory plus do-no-harm, then *measure prospectively* — broke down for grand tours because the measurement half was never built. Build it, and the architecture question largely answers itself.

---

### Appendix: evidence and reproduction

- League comparison and baselines: `scripts/league_eval.jl` (offline; reads `~/Dropbox/code/velogames/archive` and `data/league_winners.toml`). Run July 2026.
- Rank metrics: `prospective_season_summary(2026)`; PIT: `prospective_pit_values(2026)` → n = 1,012, mean 0.826, KS 0.559.
- Code audits: `bayesian_core.jl`/`strength_pipeline.jl` (knob inventory, non-Bayesian mechanisms), `simulate_stage.jl`/`StageSimConfig` (layer inventory, defects), data/eval layer (duplication, coverage). Findings with file:line references are incorporated in §§3–4; defects in §4.2 were re-verified directly against the source before inclusion.
- Caveats: the hindsight optimum for the Giro omits class constraints (mildly inflated); the odds-implied baseline maximises summed implied win probability, which is the natural naive reading of a winner market but not the strongest possible market-only strategy; four one-day races could not be scored for the model (missing `chosen` flag) and skew selective, so the one-day table slightly understates the model.
