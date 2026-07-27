# Remediation plan: executing the July 2026 architecture review

*Companion to `docs/architecture-review.md`. This document turns the review's recommendations into work packages with acceptance criteria, and provides the orchestration guide and copy-paste prompts needed to run them with Claude Code agents. Nothing here has been started.*

---

## Preconditions (do these by hand before any session)

1. Commit `docs/architecture-review.md`, `scripts/league_eval.jl`, and this file. [DONE]
2. Merge or park the `stage-race-scoring-improvements` branch (it is clean and its features are referenced by the review) [DONE]. Remediation work branches from an up-to-date `main`, one branch per phase: `remediation/phase-0-1`, `remediation/phase-2`.
3. Decide the items in the decisions table below, or accept the recommended defaults (the orchestrator prompts instruct agents to use the defaults without asking).

## Decisions required (defaults pre-agreed so the orchestrator is never blocked)

| # | Decision | Recommended default (used unless you say otherwise) |
| --- | --- | --- |
| D1 | Source for league standings | Manual: paste each race's full standings into `data/league_standings.toml` (schema in WP0.1). If you supply the VG league URL in `race_config.toml`, WP0.1 also builds a scraper — **this is the only thing an agent should ask you for, once, at the start of Phase 0**. [See the ../vgleague package, which does exactly this sort of thing in Python. Ideally we wouldn't duplicate it] |
| D2 | Final-KOM fix design | Rank the final mountains jersey by **accumulated daily-KOM points** (already driven by `kom_s`, already hilly+mountain), replacing the `mountain_top5_counts` proxy. Fixes review bugs 1 and 2 in one move, by construction. |
| D3 | Intermediate-sprint 0.5× | Fold the halving into the config vector (`intermediate_sprint_points = [10,6,4,3,2,1,0.5]`) and delete the multiplier. Behaviour-preserving; documented. |
| D4 | Block-correlation in multidim | Port the scalar discount per-dimension, behind `multidim_block_correlation::Bool = true` in `BayesianConfig`. Pre-registered revisit trigger: if Vuelta 2026 top-20 rank ρ degrades vs Giro/Tour 2026 levels, or GC win% moves *further* from market, flip default off and investigate. |
| D5 | Phase 2 gate (sign off this wording) | "The simulator stack is retained as the GT points engine only if it beats the direct-EVG challenger on **team-points-captured** (9-rider optimiser on each model's EVG, scored on actual VG totals) across ≥4 archived GTs (Giro/Tour/Vuelta 2023–2025 as data allows, plus Giro 2026) by more than the bootstrap 90% CI. Otherwise the challenger becomes the EVG stage; simulator layers that do not move team-points-captured on the harness are deleted." |

---

## Phase 0 — measurement (parallel-safe with Phase 1; disjoint files)

### WP0.1 League standings capture

- **Files:** `data/league_standings.toml` (new, gitignored) + `.example`, `scripts/publish_race.sh`, `src/data_assembly.jl` (loader), `scripts/league_eval.jl` (cumulative-placement table), optionally `src/get_data.jl` (scraper, only if league URL supplied per D1).
- **Spec:** per race, record every entrant's name and score. Extend `league_eval.jl` to compute the model team's cumulative placement ("would it be leading the league?") and the per-race placement distribution.
- **Accept:** with standings for ≥1 race present, `league_eval.jl` prints a cumulative-placement section; publish script prompts for (or scrapes) standings.

### WP0.2 Entered-team recording

- **Files:** `data/race_config.toml.example` (new `[entered_team]` riders list), `src/race_solver.jl` or `scripts/publish_race.sh` (archive it under a new `entered_team` data type), `scripts/league_eval.jl` (report entered-vs-advised delta).
- **Accept:** for a race with an entered team recorded, `league_eval.jl` reports model score, entered score, and the override delta.

### WP0.3 Prediction-archive schema hardening

- **Files:** `src/race_solver.jl` (`_archive_predictions`), `src/prospective_eval.jl`, `test/test_archival.jl`.
- **Spec:** always write `riderkey, rider, team, cost, chosen, selection_frequency, expected_vg_points` plus a `schema_version` column; error loudly if any is absent at archive time; keep readers tolerant of legacy archives (they must warn, not crash). Document that pre-April-2026 archives are unfixable.
- **Accept:** new unit test asserting the mandatory column set on a synthetic archive round-trip; suite green.

## Phase 1 — freeze and consolidate

Mechanism moratorium is in force throughout: no new signals, no new simulation layers. **WP1.1–1.4 all touch `src/simulate_stage.jl` and must run sequentially, in this order, in one agent context.** WP1.5 and WP1.6 touch different files and may run after or alongside (separate agent, separate files only).

### WP1.1 Final-KOM fix (review bugs 1 + 2) — per D2

- **Files:** `src/simulate_stage.jl` (`:677–:681`, `:749–:759`), `test/test_stage_race.jl`.
- **Spec:** track cumulative daily-KOM points per rider per sim; rank the final mountains bonus by that total; delete `mountain_top5_counts`. Abandoned riders stay frozen out.
- **Accept:** new test — a high-`kom_s`, mid-pack-finishing specialist beats a GC leader to the final jersey; existing suite green; fixed-seed before/after EVG diff on the archived Giro 2026 field generated and summarised in the commit message (expected: KOM specialists up, GC leaders down slightly on the KOM component only).

### WP1.2 Intermediate-sprint multiplier — per D3

- **Files:** `src/simulate_stage.jl:216`, `src/race_helpers.jl` (config default + docstring), `test/test_stage_race.jl` (new pin test).
- **Accept:** bit-identical simulation output on a fixed seed before/after (pure refactor — verify, don't assume).

### WP1.3 GC-protection ordering bug

- **Files:** `src/simulate_stage.jl:443–:462`, `test/test_stage_race.jl`.
- **Spec:** populate the empty-`gc_strengths` fallback *before* the protection block.
- **Accept:** unit test: attrition on + empty `gc_strengths` → favourites still protected; suite green.

### WP1.4 RNG layer-stability (enabler for Phase 2 ablations)

- **Files:** `src/simulate_stage.jl`, `src/simulate_oneday.jl` (`_rand_gamma`), tests.
- **Spec:** restructure draws so toggling any one layer (attrition, breakaway, aleatoric) leaves every other layer's random stream unchanged — e.g. pre-draw each layer's noise from independently seeded sub-RNGs per sim, or draw layer noise unconditionally and discard when off. Document the draw order in the docstring.
- **Accept:** new tests — (a) attrition on vs off leaves breakaway participation draws identical on a fixed seed; (b) existing bit-identity guarantees still hold; suite green. This WP may change seeded outputs once (note in commit).

### WP1.5 Dead-knob and scaffolding prune

- **Files:** `src/bayesian_core.jl` (delete `form_absence_floor`, `qualitative_absence_floor`; promote the hardcoded `qualitative_base_variance = 2.0` literal into the config or delete its path), `src/backtest.jl:1004–end` (dead tuning code, per `REFACTOR_PLAN.md` 1a), `src/prospective_eval.jl:350` + `scripts/render_backtesting.jl:684` (no-op trajectory filters, 1b), stale docstrings/labels (1e), `src/Velogames.jl` export trims (REFACTOR_PLAN Phase 4 second bullet). First **verify which REFACTOR_PLAN items are already done** (some Phase 2/3 items shipped in June) and update its checkboxes.
- **Accept:** suite green; `grep` finds no references to deleted symbols; `REFACTOR_PLAN.md` checkboxes updated; CLAUDE.md function lists updated.

### WP1.6 Block-correlation discount in the multidim path — per D4 (statistical change; strongest model)

- **Files:** `src/strength_pipeline.jl` (`estimate_rider_strength_multidim`), `src/bayesian_core.jl` (flag), `test/test_stage_race.jl`.
- **Spec:** apply the scalar path's cluster-discount logic per dimension (cluster membership as in the scalar path; market/history/ability). Same `skip_block_correlation` escape hatch for per-signal SBC.
- **Accept (all three, pre-registered):** (a) posterior SDs widen for multi-signal riders, unchanged for single-signal riders; (b) on the archived TdF 2026 field, the GC favourite's simulated win% moves *toward* the market (from ~93% toward ~55–80%), and (c) top-20 rank ρ on the Giro 2026 do-no-harm check does not degrade by more than 0.02. If (b) or (c) fails, ship flag-off and record findings in `roadmap.md`.

### WP1.7 Documentation closeout

- Update `roadmap.md` (mark fixed issues, record the moratorium and D-decisions), `CLAUDE.md` where function lists changed. Small; fold into the final commit of the phase.

## Phase 2 — stage-race harness, then champion vs challenger

Strictly after Phase 1 (WP1.4 is a hard dependency for clean ablations). Target: decision made before the Vuelta 2026 team deadline (~late August).

### WP2.1 Stage-race backtest harness

- **Files:** `src/backtest.jl` (extend), `scripts/render_backtesting.jl` (new section), delete `scripts/eval_gt_history.jl`, `scripts/eval_classification_history.jl`, `scripts/ablation_gt_history.jl` once absorbed.
- **Spec:** `backtest_stage_race(pcs_slug, year; signals, target)` reconstructing as-of-race predictions from archived data (per-season specialty, archived odds/oracle where present, prior-edition VG totals), scoring against archived actuals. Targets: `:vg_total` (primary), `:gc`, `:points`, `:kom`. Metrics: **team-points-captured** (run `build_model_stage` on the predicted EVG, score on actuals — primary), rank ρ by tier, top-9/top-20 overlap. Include the naive-persistence and odds-implied baselines from `scripts/baseline_compare.jl` and `scripts/league_eval.jl` as standing comparators in the output table.
- **Accept:** runs offline on ≥4 archived GTs; reproduces (approximately) the Option A/B do-no-harm numbers recorded in `roadmap.md` as a cross-check; the three TEMPORARY scripts are deleted; a regression test pins the harness on one small fixture.

### WP2.2 Direct-EVG challenger

- **Files:** new `src/direct_evg.jl` (~200 lines), tests.
- **Spec:** per rider, EVG = exp of a shrunken convex blend in log space of (i) market-implied points (map GC/points/KOM odds rank to expected VG total via a monotone curve fitted on 2023–2025 market-rank→VG-total pairs; riders unpriced → component absent), (ii) ability-implied points (the existing multidim strength → a simple monotone strength-rank→points curve, *not* the full simulator), (iii) own prior GT VG totals (the existing `gt_propensity_factors` machinery, recency-decayed). Weights shrink toward available components per rider (a debutant with no market uses ability only). ≤8 free parameters total; fit on 2023–2024, validate on 2025, never touch 2026 during fitting.
- **Accept:** fitted parameters and validation table committed; challenger EVG produced for every archived GT the harness covers.

### WP2.3 Champion–challenger evaluation and decision

- **Spec:** run the D5 gate on the harness. Produce a one-page decision memo appended to `roadmap.md`: per-GT team-points-captured for simulator stack vs challenger vs naive baselines, bootstrap CIs, and the resulting decision. Then act on it: either (a) simulator retained, memo records the evidence that now justifies it, or (b) challenger wired into `solve_stage` as the EVG source (simulator retained only for per-draw variance if `resample_optimise_stage!` measurably needs it — test that too) and non-earning layers deleted.
- **Accept:** decision memo committed; whichever engine loses on a layer/feature basis is deleted, not flagged off.

### WP2.4 Vuelta 2026 prospective dry-run

- Re-predict the Vuelta with the winning configuration before the deadline; archive predictions; pre-register the prospective checks (top-20 ρ, PIT via the stage simulator path if retained).

## Explicitly out of scope (do not let agents drift into these)

Hierarchical priors, latent-factor race similarity, ML augmentation, ownership adjustment, PPL rewrites, one-day multidim migration, new signals of any kind. Phase 3 of the review (per-rider market discount, oracle floor) waits for ~20 banked odds races in autumn and is not part of this plan.

---

## Orchestration guide

### Which model orchestrates

**Orchestrator: Fable 5** (`claude-fable-5`). The expensive judgement in this plan is not code volume but knowing when a statistical acceptance criterion has genuinely passed, when a fixed-seed diff is "expected movement" versus a regression, and when to stop. That is orchestrator-side work. Opus 4.8 is an acceptable fallback; do not orchestrate with Sonnet or Haiku.

**Subagents:** default to **Sonnet 5** for mechanical, tightly-specified WPs (0.1, 0.2, 0.3, 1.2, 1.3, 1.5, 1.7) — the specs above are deliberately written so Sonnet can execute them. Use the session model (Fable/Opus) for the judgement-heavy WPs (1.1, 1.4, 1.6, 2.1, 2.2, 2.3). Haiku for nothing here.

### Token discipline (the point is NOT to fan out)

- **No workflow mega-fanouts.** This is dependency-ordered surgery, mostly on `simulate_stage.jl`. Maximum 3 concurrent agents, and only across the disjoint-file workstreams (Phase 0 WPs vs WP1.5 vs the WP1.1–1.4 chain). Everything touching the same file runs sequentially in one agent context so it keeps its own edits in view.
- **Verification is compute, not tokens.** Every WP's acceptance runs as Julia: `Pkg.test()`, fixed-seed diff scripts, the harness itself. Agents write the check once and run it; they do not re-read large files to "confirm" edits.
- **One commit per WP**, message stating the acceptance evidence. A WP that fails acceptance twice stops and reports rather than thrashing.
- **One `/code-review` per phase branch** before merge, not per WP.
- Rough expectation: Phase 0+1 is one focused session; Phase 2 is two (harness+challenger, then evaluation+decision). If a session approaches budget, finish the current WP cleanly and stop — the plan is resumable by construction.

### How to launch

Start a fresh Claude Code session in the repo on the phase branch, model Fable 5, and paste the relevant prompt below.

---

## Appendix: orchestrator prompts (copy-paste)

### Prompt A — Phase 0 + Phase 1

```
Read docs/architecture-review.md and docs/remediation-plan.md in full, then execute
Phase 0 and Phase 1 of the remediation plan. You are authorised to use subagents,
within the plan's orchestration guide: max 3 concurrent, Sonnet 5 for the WPs the
plan marks as mechanical, session model for WP1.1, WP1.4 and WP1.6, and everything
touching src/simulate_stage.jl (WP1.1→1.2→1.3→1.4) sequential in a single agent
context in that order.

Ground rules:
- Work on branch remediation/phase-0-1 off main. One commit per WP; the commit
  message must state the acceptance evidence (test names, fixed-seed diff summary).
- Use the plan's D1–D4 defaults without asking. The single permitted question is
  D1 (the VG league URL) once, at the start; if unanswered, proceed with the
  manual-paste workflow.
- Acceptance criteria are binding. Run Pkg.test() plus each WP's specific checks
  before committing. A WP failing acceptance twice: stop that WP, record what
  happened, continue with independent WPs, and flag it in the final report.
- WP1.6 ships flag-off if its pre-registered checks (b) or (c) fail — record the
  numbers in roadmap.md either way.
- The mechanism moratorium is in force: fix and delete only; add no new signals,
  layers, or knobs beyond what the WP specs name.
- Finish with: /code-review on the branch, fix what it confirms, then a summary
  table (WP, status, acceptance evidence, files touched) and stop. Do not merge;
  leave the branch for human review.
```

### Prompt B — Phase 2 (run only after the Phase 0+1 branch is merged)

```
Read docs/architecture-review.md and docs/remediation-plan.md in full, then execute
Continue Phase 2 of the remediation plan on branch remediation/phase-0-1. You are
authorised to use subagents per the plan's orchestration guide (max 3 concurrent;
WP2.1 and WP2.2 may run in parallel — disjoint files — then WP2.3 strictly after
both).

Ground rules:
- The D5 gate wording in the plan is pre-registered and binding. Fit the challenger
  only on 2023–2024, validate on 2025; 2026 data is evaluation-only.
- WP2.1 must reproduce roadmap.md's recorded Option A/B do-no-harm numbers within
  tolerance as its own cross-check before being trusted for the gate.
- The gate's outcome is executed, not just reported: the losing engine/layers are
  deleted per the plan. If the result is within the bootstrap CI (no winner), the
  challenger does NOT replace the simulator, but layers that individually fail to
  move team-points-captured on the harness are still deleted; record the tie in
  the decision memo.
- One commit per WP with acceptance evidence; Pkg.test() green throughout;
  /code-review before finishing; do not merge.
- Deliverable: the WP2.3 decision memo appended to roadmap.md, plus a final
  summary table, then stop. If the Vuelta deadline is within 3 weeks of
  completion, also run WP2.4 and archive the prediction.
```
