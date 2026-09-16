# Velogames.jl roadmap

Open issues, pre-registered triggers, settled findings and deferred ideas. See
`CLAUDE.md` for current architecture and parameters. Completed work and the
experiments behind it live in git history (this file was pruned in September
2026; `git log -p roadmap.md` has the full record).

## Validation philosophy

Cycling supplies only ~3 grand tours and a few dozen classics a year, and market
signals cover even fewer races, so most changes will never have large-sample
power. Match the rigour of the check to the change's effect size × mechanistic
clarity, never to a race count.

### Triage each change

- **Large, mechanistically understood bias** — e.g. the June 2026 aleatoric-noise
  fix (model sprinter top-10 rate ~0.98 v real ~0.42). The effect dwarfs sampling
  noise. Ship on theory + directional confirmation + do-no-harm, then monitor.
- **Small metric-chasing tuning** — e.g. non-uniform market discount (overall ρ
  0.518 v 0.473, within 1–2 SEs on ~6 races). Needs power. Defer on grounds of
  effect size, revisited when it looks material.

### The toolkit

1. **Directional and magnitude checks** on the races we have. Evaluate at the
   rider-stage level where possible; "6 GTs" undercounts the information (a
   per-stage-type dispersion fit uses ~40 stages and every placement).
2. **Do-no-harm guard rails** — top-~20 rank ρ must not degrade; no absurd
   outputs (a domestique winning bunch sprints); field totals conserved (a bug
   check, not evidence of correctness).
3. **Selection impact, read directionally** — does a team chosen under the change
   beat the current pick on held-out actuals? 5/6 in the right direction is
   meaningful without significance.
4. **Leave-one-out as information, not a veto.**
5. **Estimate ranges, not points** — bound what is identifiable and pick a
   defensible value in range.
6. **Ship, then monitor** against a pre-registered revisit trigger. The
   prospective harness (`src/prospective_eval.jl`) is the long-run validator.

Rank correlation is invariant to monotonic EVG-level changes, so it cannot
confirm calibration fixes: use PIT and team-points-captured for those.

Ship one change at a time, for attribution.

## Pre-registered triggers

| Change | Trigger | Action |
| --- | --- | --- |
| Archive-fed breakaway channel (Sept 2026) | Prospective team-points-captured over the next 20 one-day races does not hold the sign | Back it out. Also probe `prior_strength` 250 and 500: 120 was the largest tested and the curve had not turned |
| One-day market blend (July 2026) | Paired `simulator_market` − `simulator_risk` capture below +0.02 on the 2027 classics (render_backtesting.jl "Market blend — paired comparison" table) | Revert. If the blend still fails to beat odds alone, ask why we simulate marketed classics at all |
| Multidim block correlation (`multidim_block_correlation`) | Vuelta 2026 top-20 ρ degrades v Giro/Tour 2026, or GC win% moves further from the market | Flip the flag off and investigate |
| Stage aleatoric noise (`aleatoric_noise`) | Next 2 GTs show top sprinters under-predicting, or top-20 ρ drops materially | Revisit the per-type scale, flat first |
| GT VG-history signal and propensity layer (`gt_vg_history`, `gt_propensity_factors`) | Next 2 GTs show a rider over-moved by a single fluke edition, or top-20 ρ drops | Revisit `κ` / `c` / `gt_vg_hist_base_variance` |

**Due now: Vuelta 2026 out-of-sample check.** Run `backtest_stage_race` with
`predictors = [:simulator, :simulator_risk, :persistence, :odds]` on Vuelta 2026
and compare team-points-captured. Odds and predictions are archived. The
simulator losing to `:persistence` (the 10-edition sweep had it at 0.563 v 0.451)
should trigger a re-examination of the stage stack; losing to `:odds` alone
raises the same question as the market blend. With n = 1, both are triggers to
look, not pass/fail gates.

## Known issues

### Breakaway channel: shipped directionally, not validated (September 2026)

The one-day breakaway channel runs on per-race archive data (131 editions
backfilled, 726 rider-race observations). Break participation is persistent
(split-half Spearman ρ = 0.453) and pays where the model is weakest:

| Finish | Pack mean VG | Break mean VG | Ratio |
| --- | --- | --- | --- |
| Top 10 | 277.8 | 361.9 | 1.3x |
| 21-50 | 20.7 | 86.0 | 4.2x |
| 51+ finished | 5.3 | 64.9 | 12.2x |
| DNF | 4.5 | 43.2 | 9.6x |

P(scoring at all) is 89.5 per cent for a break rider against 28.6 per cent for
the pack. Use `pcs_results` as the denominator: `vg_results` holds only riders
who scored, and joining on it alone conditions away most of the effect.

Backtest, 108 editions, paired against breakaway-off: Δ capture +0.0168 (SE
0.0111, 48/41/19) at `prior_strength = 120`. Not significant, but every one of
six specs beat baseline and the effect is monotone in shrinkage. `km_weighted`
rates double-count distance, since the sector count already carries it. The
comparison is on v off; the change actually made (leaderboard → archive) cannot
be backtested because the old source cannot be reconstructed as-of. Mean sectors
is 1.3, not the old hardcoded 2.0, which had inflated the channel by ~54 per
cent.

### VG points distributions underestimate scoring riders

The largest calibration problem. Mean PIT for scoring riders is ~0.83 (target
0.5) across the 2026 prospective races; bottom and middle tiers ~0.9, top 25 per
cent ~0.7. Higher posterior uncertainty correlates with worse PIT, so the
failure is asymmetric: unknown riders in stochastic races have right-skewed
outcomes that symmetric noise cannot capture. The rank ordering is decent; the
failure is in converting strength to VG points.

Race selectivity clusters, by big-miss rate: selective (Strade, Dwars, E3: 0–10
per cent), standard (Brugge, MSR, Omloop: ~20 per cent), stochastic (Kuurne,
Nokere, Gent-Wevelgem, Trofeo: 30–60 per cent). The league gap has the same
shape: within 3–10 per cent of the winning human in selective races, 30–60 per
cent below in stochastic ones.

### Early-race GC is static, so sprinters never score daily-GC points

`simulate_stage_race` adds `gc_strengths[i]` to `cumulative_gc_score` on every
stage from stage 1, so the simulated GC table is the static GC-strength order
from day one. In reality a sprinter who wins stage 1 leads GC on bonus seconds
until the race separates on time. On the 2026 Femmes field, 663 of 1,989 daily-GC
EVG fell in stages 1–3 (before the ITT) and all went to GC riders; Wiebes got 2
per cent of her EVG from daily GC, Vos 0. Men's grand tours are affected the
same way. The fix needs bonus seconds (10/6/4 on stage and intermediate sprints)
and early GC ordered by time-then-placing. Validate on the stage harness first.

### GC contest is over-deterministic

The TdF 2026 board rated Pogačar ~93 per cent to win against a market ~55 per
cent. GC is decided by cumulative strength over 21 stages; per-stage aleatoric
noise averages out (grows as √21 while the gap grows as 21), leaving the
persistent `α·σ·rider` term as the only GC-order uncertainty, and σ is small for
well-characterised favourites. The fix direction is a persistent, σ-independent
"form across these three weeks" shock calibrated so the top-2 split matches the
market (head-to-head z ≈ 0.85). The GC-favourite protection layer that amplified
this was deleted in July 2026, so re-measure before building anything. Impact on
team selection is limited; the displayed win% reads over-confident.

### PCS recency scores treat a missed season as a zero

`_apply_pcs_recency!` (`race_solver.jl`) builds `<spec>_r` as `sum(w .* pts)` over
seasons present, so a season not raced counts as weakness. The fallback
`currency_factors` path uses a weighted average, which is absence-neutral. Example
(2026 Femmes ITT): Bäckstedt 947 outranks Reusser 572 (missed 2024 through
illness, career 3,208). Switching to the weighted average is cheap and clearly
right. Aggravating: `pcs_season_decay = 0.7` is global across specialties, which
over-discounts stable TT ability, and `:itt` has a single signal (`pcs_tt`) with
no market input.

### `stage_dimension_weights` ramp is calibrated on men's stage lengths

The flat→hilly ramp runs over ProfileScore 40–90 and ignores PCS's `stage_type`
above PS 40. Women's stages are shorter at comparable vertical, so PS runs higher:
no stage of the 2026 Femmes route was treated as a pure sprint (flattest
`flat = 0.54`), starving sprinters. Candidate fixes: normalise by distance or
vertical metres per km, or floor the flat weight when PCS says `:flat`.

### `odds_points → :flat` leaks GC riders into bunch sprints

A GC rider priced in the green-jersey market gets flat strength from it
(`odds_points` routes `flat = 0.4`); Pogačar's production flat top-10 rate is
~0.50 against a real ~0.17. Route `odds_points` / `oracle_points` to `:flat` only
for riders classed as sprinters.

### Stage-race channels that cannot be scored or calibrated

- **HC/Cat-1 per-climb points**: `n_hc_climbs` / `n_cat1_climbs` are always 0
  from the PCS scraper, so neither `_score_daily_mountains!` nor anything else
  scores them.
- **Points-jersey noise** (`StageSimConfig.breakaway_noise.points_jersey`) is
  hand-set. Recalibration needs archived per-stage points/mountains
  classification standings, which nothing scrapes.
- **Sprinter DNFs** (~32 per cent for 2nd–4th-tier GT sprinters) are unmodelled
  since the attrition layer was deleted for not moving team-points-captured.
- **Stage-race PIT**: `prospective_pit_values` skips stage races; the right fix
  routes them through `simulate_stage_race` for their draws.
- GT prediction archives before July 2026 lack `strength_kom`, so reconstructions
  fall back to `strength_mountain` for the KOM channel.

### Derived league winners disagree with the hand-typed record in 4 of 29

Grand tour totals differ by a handful of points (Giro 8,351 recorded v 8,359
derived; Tour 11,884 v 11,880). The derived figure matches the snapshot's own
`scored_total`, so the disagreement is with whatever the hand-typed numbers were
read off, probably a standings page mid-rescore. Check against the live page
during the next grand tour.

Team names are mutable and the scrape returns the current one (Paris-Roubaix:
"Megaton-Structo NimaRent" recorded, "Lowering The Toon" derived). Harmless when
publishing within a day of the race; it only bites on backfill, where the
existing `(pcs_slug, year)` check already prefers the record.

### Other

- The `crosscheck_option_ab` baseline (`base_*`) predates the August 2026
  stage-assist archive patch; expect its drift alarm to trip once and re-base it.
- The estimators (`estimate_rider_strength`, `estimate_rider_strength_multidim`)
  duplicate their signal-update blocks and keep needing paired edits. A shared
  block refactor is worth scheduling.
- The retired `velogames-race-reports` Netlify site still needs its redirects
  deployed (`vgleague/scripts/retired-site/README.md`; the two site ids are easy
  to confuse). `scripts/render_reports.jl` is kept only as the reference the
  `vgleague verify-*` checks diff against; delete it once the Python site has run
  a season.

## Settled findings

Do not re-run these without new evidence.

- **The strength→points transform is saturated.** A fitted direct-EVG challenger
  (deleted August 2026) tied the full simulator on both harnesses: stage
  (10 editions, Δ −0.040, 90% CI [−0.093, +0.025]) and one-day (39 held-out 2025
  classics, 0.515 v 0.520). Both sit at an information ceiling set by ability +
  market. Remaining levers are team construction under uncertainty and new
  information.
- **Stage-sim layers that did not earn their keep** (10-edition Δ capture with the
  layer off; seed band ±0.0126): attrition −0.0001, stage breakaway draw +0.005,
  GC-favourite protection −0.010 (one edition). All deleted. The propensity layer
  scored −0.039 and was kept.
- **Market discount is flat across a 64× range.** Sweeping a separate discount for
  unpriced riders (1–64) on the 12 marketed 2026 classics moved capture ±0.004
  except at 1.0 (−0.037), and weakening it degraded top-20 ρ monotonically. The
  mid-field PIT failure is not caused by the blanket haircut. The oracle floor has
  never been active in production (`floor_signals = Set([:odds])`).
- **Simulator + challenger ensemble is null** (59 editions, −0.004, CI [−0.026,
  +0.019]): they make the same errors. Simulator + odds is the real
  decorrelation, hence the shipped market blend (+0.079, CI [+0.028, +0.136], 7/0/5
  on 12 editions). Blending clearly beats the simulator; it does not clearly beat
  odds alone (+0.024, CI [−0.015, +0.069]).
- **Sprinter over-prediction was on the noise axis, not the strength axis.**
  Softening the PCS `log1p` transform, and a per-rider market discount, did not
  move second-tier sprinters. Ability-margin-dependent noise was rejected: it
  re-saturates the sprint top-10. Uniform per-stage-type aleatoric noise
  (`aleatoric_noise`, fitted by top-20 Plackett–Luce on archived GT finishing
  orders; ordering hilly > flat ≈ mountain > itt) is the fix.
- **DNF hazard does not fall with ability.** Stronger riders abandon more (giro
  2026: quality tertiles 11.5 → 27.4 per cent DNF). Do not re-propose a
  climbing-quality hazard.
- **Propensity layer: `:posthoc` and `:sim` modes give identical EVG means.** A
  per-rider multiplicative factor scales mean and SD alike, so the modes differ
  only in selection frequency.
- **VG uses one assist schedule per game**: 8/4/2 for grand tours, 6/4/2 for
  shorter stage races.
- **`max_per_team` is a diversification preference**, not a game rule; the
  harness defaults to production's 2.
- **VG race history is live in the stage-race estimator only.** The April 2026
  ablation removed it from the one-day path; a test pins both halves.
- **Ownership-adjusted optimisation does not apply.** VG is cumulative points
  across ~40 races, so other players' picks do not affect your score (Haugh &
  Singal 2021 gains are for single-contest GPPs).

## Deferred ideas

1. **Risk-aware / upside team construction.** If EVG is at ceiling, the edge is in
   the team given the EVG. The simulator's unique output is the per-draw
   distribution; an upside-tilted objective may beat EVG-max in stochastic races.
   Gate on the harness and on the cumulative-season objective.
2. **Correlated position simulation.** `simulate_race` has no shared race-day or
   team-block factor, so its team-score distributions are too narrow (two teams
   both at the 0th/1st percentile of their own sims).
3. **Drop the oracle signal.** May 2026 analysis: listed oracle riders show
   middle-tier ρ ≈ 0.004. Re-evaluate after 20+ races with odds.
4. **Position-dependent market discount** (full discount only for the top PCS
   quartile). Improved every tier (ρ 0.518 v 0.473) on 6 races, but with
   circular tier assignment and mixed per-race signs. Defer until n ≥ 20 races
   with odds.
5. **Profile-aware PCS specialty for one-day races.** One-day races use only
   `:oneday`; a per-race blend (with Hills now available) would give the prior
   terrain awareness. Risk of double-counting `SIMILAR_RACES`. Ablate on 3–4
   puncheur races.
6. **Data-driven `SIMILAR_RACES`.** Matrix-factorise a rider × race × year tensor
   of PCS points (residualised on rider-year, recency-weighted) and use factor
   cosine similarity as continuous history weights. Sparsity is the main risk.
   Validate manual v top-k v continuous.
7. **Conditional calibration.** PIT by predicted strength, cost band and odds
   coverage, in the prospective section of `render_backtesting.jl`.
8. **Stage-race model follow-ups.** Empirical calibration of
   `SIGNAL_DIMENSION_WEIGHTS`, `RACE_HISTORY_CLASS_PROJECTION` and the
   `StageSimConfig` tables against per-stage VG points; a hierarchical prior over
   dimensions for sparse-data riders; project race history through each past
   race's stage-type mix; per-stage-type stage-winner markets; multidim prior
   checks and SBC.
9. **New information.** Echelon/weather risk, live odds movement, a rebuilt
   qualitative signal. Most added signals have not moved the numbers; gate hard.

## References

- Hubáček et al. (2024, arXiv:2410.21484): ML sports prediction reaches bookmaker
  accuracy at best. Franck et al. (2010), Constantinou & Fenton (2013): betting
  markets are the best probabilistic forecasts.
- Kholkine et al. (2021, *Frontiers in Sports and Active Living*): for classics
  top-10, PCS career/season points matter everywhere; best prior result in the
  race dominates Flanders and Roubaix; related-race results drive LBL; 6-week
  form gets minimal weight.
- Rize, Saldanha & Moskovitch (2025, VeloRost): modelling leader and helper
  roles separately, and clustering races by terrain before rating, both help.
- Haugh & Singal (2021, *Management Science*): ownership-adjusted DFS
  optimisation, strong for single-contest GPPs only.
- Baronchelli et al. (2025, arXiv:2505.02170): recency-weighted Bayesian models
  are strong FPL baselines; roughly two-thirds model, one-third realised points.
