# Velogames.jl improvement roadmap

See `CLAUDE.md` for current architecture, prediction model details, signal inventory, and parameter settings.

## Remediation phases 0–1 executed (July 2026)

Phases 0 and 1 of `docs/remediation-plan.md` (following `docs/architecture-review.md`) shipped on branch `remediation/phase-0-1`. **The mechanism moratorium is in force**: no new signals or simulation layers until the Phase 2 stage-race harness exists; genuine bug fixes only. Decisions D1–D4 were executed as follows:

- **D1 (league standings)**: resolved without a new scraper — the sibling `../vgleague` package already scrapes full league standings; `load_league_standings` (data_assembly.jl) reads its JSON cache, with `data/league_standings.toml` manual paste as fallback. First measurement: **over the 9 races with both archived model teams and standings, the model would place 2nd of 15 cumulatively** (11,198 vs leader 11,616), slightly ahead of the entered teams (11,076; delta −122). Note: "Mud Springs Eternal", read by the review as a strong opponent, is the user's own team. Entered-vs-advised deltas now reported per race by `scripts/league_eval.jl`. Later-season races need `vgleague update dpcc` run in `../vgleague`.
- **D2 (final-KOM fix, review defects 1+2)**: final mountains jersey now ranked by cumulative daily-KOM points (driven by `kom_s`, hilly+mountain); `mountain_top5_counts` deleted. Fixed-seed Giro 2026 diff: movement confined to the KOM component (sum |ΔEVG| 185.3); Ciccone +29.4, Vine +26.9, Scaroni +10.1 up; Caruso/Vendrame/Narváez down. Caveat: Giro/Tour 2026 prediction archives predate the `strength_kom` column, so retrospective reconstructions fall back to `strength_mountain` for the KOM channel.
- **D3 (intermediate sprints)**: the undocumented runtime 0.5× folded into the config vector (`[10, 6, 4, 3, 2, 1] .* 0.5` as literals); bit-identical on fixed seeds.
- **D4 (multidim block-correlation)**: the scalar cluster discount ported per-dimension to `estimate_rider_strength_multidim`, behind `multidim_block_correlation::Bool = true`. Pre-registered checks all passed: (a) SDs widen only for multi-signal riders; (b) archived TdF 2026 reconstruction: Pogačar simulated GC win% 93.1% → **78.3%** (market raw implied 80.0%, normalised 55.3%) — the GC over-determinism defect and the missing discount were indeed the same fact; (c) Giro 2026 top-20 rank ρ 0.094 → 0.119 (improves). **Recorded caveat for the revisit trigger**: Giro full-field EVG↔actual ρ fell 0.577 → 0.303 (wider posteriors let simulation noise compress cheap riders' EVG), and the Giro favourite's win% barely moved (92.2% → 91.5%). **Pre-registered revisit trigger: if Vuelta 2026 top-20 rank ρ degrades vs Giro/Tour 2026 levels, or GC win% moves further from market, flip the flag off and investigate.**

Other Phase 1 fixes: GC-favourite protection no longer silently skipped when `gc_strengths` is empty (review defect 4); simulation layers (attrition, breakaway participation, aleatoric) now draw from independent per-sim RNG sub-streams so toggling one layer leaves the others' streams unchanged — the enabler for Phase 2's clean ablations. Seeded outputs changed once at that commit. Prediction archives now write a mandatory column set plus `schema_version` (review defect 5); readers warn on legacy archives (pre-April-2026 archives cannot be re-created).

Dead-knob prune (WP1.5): the two dead `BayesianConfig` fields the review counted (`form_absence_floor`, `qualitative_absence_floor`) are deleted — the estimation-path knob count drops by 2. The REFACTOR_PLAN audit found Phases 1–4 essentially already shipped (the plan document had not been kept in sync); only its optional 3d (estimator shared-block refactor) remains open, worth scheduling since the estimators keep needing edits. `qualitative_base_variance` stays a hardcoded 2.0 literal in its accessor, deliberately not promoted to a config field while the qualitative signal is production-dead.

Known bugs recorded, not fixed (moratorium): `find_race`'s fuzzy fallback mis-resolves short aliases ("Tour" → "Paris-Tours Elite"); `CLASSICS_RACES_2026`'s gent-wevelgem display name doesn't match the VG/vgleague name ("From Middelkerke" vs "Middelkerke"), so its standings don't match by name.

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

### Stage-race breakaway modelling (prototype, July 2026)

Grand tour breakaway participation was entirely unmodelled: `SCORING_GRAND_TOUR.breakaway_points` (20 pts, "breakaway at 50% distance", `src/scoring.jl` ~line 248) was defined but never read anywhere in `simulate_stage_race` (`src/simulate_stage.jl`) — dead code. `solve_stage`'s `breakaway_dir` kwarg was only consumed by the aggregate GC-position fallback (`src/race_solver.jl`, old `resample_optimise!` branch), never by the per-stage pipeline that every real grand-tour prediction actually uses.

The empirical trigger: real historical VG scores (`getvg_stage_race_totals`) for known breakaway-reliant domestiques/opportunists are far above what the model predicts for 2026 — e.g. Pascal Eenkhoorn scored 295 (2023 Tour) and 290 (2025 Tour) but the model predicted 34.6; Clément Russo scored 241 (2024)/245 (2025) vs a 106.8 prediction. Meanwhile headline GC riders (Pogačar: real 3841/4153 in 2024/2025 vs 3819.4 predicted for 2026) are well-calibrated. The miss concentrates exactly where the scoring ceiling depends on breakaway sector/stage-win points the simulator doesn't generate — cheap (4–6 credit) riders occupying 3+ of 9 squad slots.

**Prototyped fix** (`src/simulate_stage.jl` `_draw_breakaway!`/`_score_breakaway_bonus!`, `StageSimConfig.breakaway_stage_boost`, `scoring.jl` `STAGE_BREAKAWAY_MAX_RATE`): reuses the same archived PCS breakaway-km data and `compute_breakaway_rates` ranking already used for one-day races, but with a stage-specific `max_rate` (0.15/stage vs one-day's 0.35, since a GT offers ~10–13 hilly/mountain stages rather than one race day). On each hilly/mountain stage, riders with recorded breakaway history get an independent Bernoulli draw; on success they get the flat 20-pt bonus plus a `noisy`-strength boost (`breakaway_stage_boost = 2.5`, same units as `stage_strengths`) that lets them compete for stage/points-jersey/KOM placing from within a smaller effective group rather than the full bunch. Deliberately excluded from `cumulative_gc_score` — a domestique's break essentially never moves real GC, and keeping GC untouched means the feature cannot inflate the final-GC/team-classification metrics used for rank-ρ validation. Riders with no recorded breakaway km (`breakaway_rates[i] == 0`, i.e. most sprinters/GC leaders) consume zero RNG draws — an all-zero rate vector reproduces the pre-change simulation bit-for-bit (see `test/test_stage_race.jl` "breakaway event" tests).

**Not yet validated** — this is a design/prototype pass, not a calibrated model. Per the Validation philosophy below, this is an EVG-level (points-level) change, not a strength-level one, so it should be judged on points-level metrics (PIT, team-points-captured, and specifically whether Eenkhoorn/Russo-shaped riders' predicted EVG moves toward, not past, their real historical range) rather than top-20 rank ρ. `STAGE_BREAKAWAY_MAX_RATE` (0.15) and `breakaway_stage_boost` (2.5) are first-pass estimates with no backtest behind them yet; HC/Cat1 climb points are NOT modelled for breakaways (`StageProfile.n_hc_climbs`/`n_cat1_climbs` are always 0 from the current PCS scraper — same limitation already documented for `_score_daily_mountains!`). `render_stagerace.jl` now passes `breakaway_dir` into `solve_stage` so the feature is live next time it runs; recommend a dry run against an archived past grand tour (e.g. re-predict TDF 2025 with these riders' pre-race data) before trusting it for a live 2026 prediction.

### GT VG-history strength signal (Option A prototype, July 2026)

**Problem.** The stage-race strength model is built from role-BLIND general-performance signals (PCS specialty, VG season points, classics race history, betting odds). In a grand tour, VG points are generated ROLE-conditionally: protected leaders convert strength→points at full efficiency, but break-hunters/opportunists score via spiky breakaway/stage-win points largely decoupled from bunch-finish strength. So the model badly under-scores cheap perennial break-hunters while getting leaders right (verified 2026 pre-signal EVG: Pogačar 3776 vs real 3841/4153 — good; Eenkhoorn 33 vs real 290/295, Russo 105 vs real 241/245, Abrahamsen 217 vs real 300/606/460 — huge misses).

**Hypothesis (tested).** A rider's OWN prior GT VG total is a lower-bias proxy for their GT VG points than their general ability is, because a prior GT total is role-conditional *by construction* (a rider who domestiqued/break-hunted last year scored like one).

**Mechanism** (`gt_vg_history` signal; flag `use_gt_vg_history`, default off). New same-tour VG-history signal in the multidim estimator. Data: `assemble_gt_vg_history(vg_slug, year, history_years)` (`src/data_assembly.jl`) re-fetches each prior edition's full-field VG totals via `getvg_stage_race_totals` (the corrupted `vg_results` GT archive was deleted). `_assemble_signals` log1p-z-scores each edition's field (GT totals are heavily right-skewed; log stops the 4000-pt leader dominating σ and compressing the field to z≈0). Each rider's own z-entries update the posterior conjugately in `estimate_rider_strength_multidim`, recency-decayed by `vg_hist_decay_rate`; multiple editions give ~n× precision (sparsity handled by the mechanism, no bolt-on). Base variance `gt_vg_hist_base_variance = 1.5` (unscaled by any precision-group factor).

Three design decisions that make it do-no-harm (all in `src/bayesian_core.jl` / `src/strength_pipeline.jl`):
1. **Routing** `(hilly=1.0, mountain=1.0, kom=0.5)`, ZERO on `:gc`, `:itt`, `:flat`. A GT total is a role/propensity factor, not terrain-specific — but routing it to `:gc` would fake a break-hunter into a GC threat (inflating daily/final-GC scoring), and to `:flat` would inflate a GC leader's bunch-sprint strength (their huge total comes from mountains). GT breakaways are a hilly/mountain phenomenon.
2. **Runs AFTER the market updates.** Placed before them, the extra precision it adds on `:mountain`/`:hilly` *dampens* the later GC-odds/oracle lift and silently pulls leaders DOWN (Pogačar −238 EVG in the first cut — a precision effect, not a mean effect). After the market, a leader's already-lifted posterior mean is compared against the observation and (3) skips it.
3. **UPWARD-ONLY clamp.** A dimension updates only when the observation would RAISE its mean. Prior GT success is evidence of *extra* propensity on top of ability; it must never drag down a rider whose ability estimate already exceeds their historical-VG z. Consequence: the INVERSE case (elite classics rider on locked domestique duty whose LOW GT history *should* pull them down) is deliberately NOT handled — the two-sided version reintroduces leader harm; that correction belongs in an EVG-stage layer (Option B).
4. **Exempt from `market_discount`** — orthogonal to what the market prices for unpriced domestiques, so the double-counting inflation must not gut it.

**Validation** (seeded `MersenneTwister(20260703)` sim, breakaway feature OFF to isolate the strength effect, n_sims=2500; `scratchpad/validate.jl` reproduces). EVG before→after against real Tour totals:

| Rider | cost | EVG off→on | real Tour totals | verdict |
|---|---|---|---|---|
| Eenkhoorn | 4 | 33→72 | 295/290 | toward, ~25% of gap closed |
| Russo | 4 | 105→141 | 241/245 | toward |
| Turgis | 6 | 267→313 | 54/644/407 | toward |
| Abrahamsen | 6 | 217→338 | 300/606/460 | into range |
| Simmons | 6 | 54→90 | 16/380 | toward (mixed record limits it) |
| Pogačar | 34 | 3776→3688 | 2979/3841/4153 | strength IDENTICAL; −2.3% EVG = field crowding |
| Vingegaard | 24 | 2325→2237 | 2946/2703/3200 | strength IDENTICAL; −3.8% = crowding |
| Van Dijke (debutant) | 4 | 162→156 | — | strength IDENTICAL (no GT history) |

Do-no-harm rank ρ (predicted 2026 EVG vs real 2025 totals, signal restricted to ≤2024 to avoid leaking the 2025 target, 96 riders in both): overall 0.691→**0.700** (improves), **top-20 0.469→0.466 (flat — passes the gate)**, top-40 0.610→0.546 (mild degradation in the volatile mid-band — riders whose 2024 was strong but 2025 collapsed to injury get lifted wrongly; inherent to a 1-year-ahead check).

**Verdict.** Option A does no harm (leader strengths byte-identical; top-20 ρ preserved; debutants untouched) and closes a MEANINGFUL FRACTION of the gap — it roughly doubles the flagged break-hunters' EVG and moves each *toward*, never past, their real range. But it does NOT fully close it: a strength nudge can only lift a rider's finish-position ranking so far, and these riders' 200–300-pt hauls come from breakaway/stage-win points the finish-position simulator barely generates for a mid-pack rider. The residual is exactly what the **breakaway prototype** (above) and/or **Option B** (a points-propensity layer applied at the `expected_vg_points` stage, which could also deliver the inverse pull-down that the upward-only strength nudge cannot) should stack on top of. Recommendation: keep Option A on (it is the cheap, do-no-harm half), and pursue Option B for the remaining gap and the role-DECOUPLING (strong-domestique) direction. **Flag now ON by default in `render_stagerace.jl` (July 2026 decision, alongside Option B)**; `gt_vg_hist_base_variance` (1.5) and the routing weights are un-backtested first-pass estimates, monitored prospectively per the revisit trigger below.

### GT VG points-propensity layer (Option B prototype, July 2026)

**Why B exists.** Option A nudges *strength*, so it is structurally (i) upward-only — a strength observation clamped to only ever raise a dimension cannot pull a rider DOWN — and (ii) capped — lifting a rider's finish-position ranking earns bunch-finish points, not the spiky breakaway/stage-win hauls that make a cheap break-hunter's 250-600pt total. B operates at the **points** level (on `expected_vg_points`), so it is naturally **two-sided** (raise break-hunters AND lower locked domestiques) and can close the residual A leaves.

**Signal source — EVG-residual (Decision 1).** For each rider `i`, learn a persistent log-propensity `f_i` from the residual between their REAL prior GT totals and the model's ability-implied prediction (`src/build_model.jl` `gt_propensity_factors`):

- `r_{i,e}` = real VG total in past edition `e` (`getvg_stage_race_totals(e,"velogame")`; the corrupted `vg_results` archive was deleted and 2023–2025 re-archived).
- `p_i` = the model's ability-implied EVG (role-blind when A is off; A-lifted when A is on — see stacking).
- `f_i = s_i · Σ_e w_e·log((r_{i,e}+c)/(p_i+c)) / Σ_e w_e`, recency weight `w_e = decay^years_ago` (decay 0.8), partial-pool shrink `s_i = W_i/(W_i+κ)` with `W_i = Σ_e w_e` and `κ = 2.0` (heavy — this is ~1-3 obs/rider small-data), floor `c = 30` VG points (regularises the log-ratio for near-zero r/p and caps cheap-rider blow-ups). Adjusted EVG = `p_i·exp(f_i)`.

Algebraically this is a **log-space convex combination of the model's ability EVG and the rider's historical realised total**, with the weight on history growing with edition count: `log(EVG_adj) ≈ (1−s_i)·log(p_i) + s_i·(recency-weighted mean log r_i)`. Break-hunters (`r≫p`) get `f>0`; locked domestiques (`r≪p`) `f<0`; leaders (`r≈p`) `f≈0`; riders with no GT history get `f=0` exactly (do-no-harm, inert).

**Temporal-integrity approximation (documented shortcut).** A rigorous `p_{i,e}` would be the model EVG for edition `e` reconstructed from ≤e-1 data (as-of-date startlist, costs, odds, specialty for each past year) — the historical odds especially are almost entirely un-archived, so this is out of scope for the prototype. Instead we use the CURRENT-race ability-implied EVG `p_i` as the baseline for every past edition. Leakage introduced: (1) ability drift — using current ability for a 3-year-old edition mis-attributes genuine improvement/decline to role (mitigated by recency weighting); (2) `p_i` reflects 2026 form correlated with recent results, so the residual is not a clean out-of-sample gap. The signal we actually want is the *persistent multiplicative role factor*, which the current-p approximation captures directly if ability is roughly stable — the honest weakness is riders whose ability moved a lot between editions. The do-no-harm rank check restricts the signal to ≤2024 when scoring against real 2025 to avoid leaking the target.

**Injection point (Decision 2) — evaluated both, recommend (a).** `gt_vg_propensity_mode` in `src/race_solver.jl` `solve_stage`:
- **(a) `:posthoc`** (default): multiply the final `expected_vg_points` mean by `exp(f_i)` after `resample_optimise_stage!`, re-optimise the chosen team on the adjusted points. Per-draw selection frequency stays on the unadjusted sim.
- **(b) `:sim`**: scale every per-draw column of `sim_vg_points` by `exp(f_i)` and re-run the (RNG-free) optimise tail (`_resample_core!`) on the scaled matrix, so mean, downside deviation AND selection frequency all reflect propensity. No re-simulation — the pass-1 draws are reused.

**Key finding: (a) and (b) give an IDENTICAL EVG mean.** A per-rider multiplicative factor scales the mean the same way whether applied outside or inside the draw loop (`mean(exp(f)·X) = exp(f)·mean(X)`), and it scales the SD proportionally too, leaving CV — and therefore the rank-order within every draw — unchanged. (b) differs from (a) *only* in per-draw selection frequency / team diversity, which the validation harness deliberately does not read (the final optimiser is unseeded/degenerate). The only version of (b) that would genuinely widen tails (a stochastic spiky per-draw bonus) re-implements the breakaway feature and reintroduces its calibration burden. So **(a) is recommended**: simplest, cleanly separable, identical on the validated metric; (b) remains wired (same flag, `mode="sim"`) for when a seeded team-selection harness exists to exploit its selection-diversity effect.

**Validation** (same harness as A: seeded `MersenneTwister(20260703)`, breakaway OFF, n_sims=2500; `scratchpad/validate.jl`). EVG through the pipeline: role-blind → A → B-alone → A+B stacked, against real Tour totals.

*1. Flagged break-hunters — B alone ≈ A; A+B stacked closes materially more:*

| Rider | cost | blind→A→B→A+B | real | fB/fAB |
|---|---|---|---|---|
| Eenkhoorn | 4 | 33→72→63→**114** | 295/290 | 0.64/0.46 |
| Russo | 4 | 105→141→141→**172** | 241/245 | 0.29/0.20 |
| Turgis | 6 | 267→313→280→306 | 54/644/407 | 0.05/−0.02 |
| Abrahamsen | 6 | 217→338→302→**386** | 300/606/460 | 0.33/0.13 |
| Simmons | 6 | 54→90→72→**104** | 16/380 | 0.29/0.15 |

*2. Inverse / role-decoupling — B pulls DOWN riders the role-blind model over-rates from ability (A structurally CANNOT do this):*

| Rider | cost | blind→B | fB | real | why |
|---|---|---|---|---|---|
| Philipsen | 12 | 1323→**1081** | −0.20 | 1935/1482/329 | sprinter, 2025 crash-out; recency pulls down |
| Merlier | 12 | 996→**857** | −0.15 | 575 | pure sprinter under-scores GT |
| Bernal | 8 | 483→**362** | −0.29 | 126/292 | ex-GC-winner now scores like a domestique |
| Van Eetvelt | 6 | 251→**135** | −0.62 | 2 (DNF) | over-moved by ONE anomalous edition — the small-data risk |

Globally: 54 riders lifted, 46 lowered, 59 untouched (no GT history). The pull-down direction is B's differentiator, and it fires sensibly on sprinters and diminished GC riders — but a single DNF/crash edition (Van Eetvelt real=2) over-moves a rider; `κ`/`c` contain but do not eliminate this.

*3. Leaders / 4. debutants — do-no-harm, but NOT strictly inert:*

| Rider | cost | blind→B | fB | real |
|---|---|---|---|---|
| Pogačar | 34 | 3776→3744 | −0.01 | 2979/3841/4153 |
| Vingegaard | 24 | 2325→**2617** | +0.12 | 2946/2703/3200 |
| Van Dijke (debutant) | 4 | 162→162 | 0.00 | — |

Unlike A (upward-clamp-after-market ⇒ leaders byte-identical), B moves ANY rider whose ability EVG diverges from their history. Pogačar (model already right) barely moves; Vingegaard moves +12% because the role-blind model *under-rates* him (blind 2325 vs real ~2950) — a correction *toward* real, not harm, but B is not leader-inert by construction. Debutants with no GT history are exactly inert (fB=0).

*4. Do-no-harm rank ρ (predicted 2026 EVG vs real 2025, B signal restricted ≤2024, 96 riders):* overall 0.691→**0.723**, top-20 0.469→**0.477**, top-40 0.610→0.607. B **passes the gate and improves it** — and is notably gentler on the mid-band than A (A degraded top-40 to 0.546; B holds 0.607).

*5. A+B stacked composes without double-counting.* Because B's baseline `p` in the stack is the A-lifted EVG, A raising strength shrinks B's residual factor (Eenkhoorn fB 0.64→fAB 0.46; Abrahamsen 0.33→0.13). A+B gives the largest toward-real move on every flagged break-hunter (Eenkhoorn 114, Abrahamsen 386, Russo 172) yet never overshoots their real range.

**Verdict.** Option B delivers what A cannot: it closes MORE of the break-hunter gap (only when stacked with A; B-alone ≈ A) AND supplies the two-sided pull-down for ability-over-rated riders (sprinters, faded GC leaders), while *improving* rank ρ at every tier — the cleanest do-no-harm result of the three stage-race changes. **Recommend A+B together, injection mode (a) `:posthoc`** — both now ON by default in `render_stagerace.jl` (July 2026 decision), monitored prospectively. Un-calibrated / needs real monitoring: (i) `κ=2.0`/`decay=0.8`/`c=30` are first-pass — a single anomalous edition still over-moves sparse riders (Van Eetvelt); (ii) the current-`p` temporal approximation attributes genuine ability drift to role (Bernal is arguably correctly lowered, but the mechanism can't distinguish "changed role" from "declined"); (iii) B moves leaders it thinks are mis-rated (Vingegaard +12%) — directionally toward real here, but worth watching. **Pre-registered revisit trigger: if the next 2 GTs show B over-moving a rider with a single fluke edition, or top-20 ρ dropping, revisit `κ`/`c`.**

**Files.** `src/build_model.jl` `gt_propensity_factors` (learner); `src/race_solver.jl` `solve_stage` (both injectors, `use_gt_vg_propensity` / `gt_vg_propensity_mode`) + `_prepare_rider_data` (GT-history fetch now triggered by A OR B); `scripts/render_stagerace.jl` + `data/race_config.toml.example` (`gt_vg_propensity`, `gt_vg_propensity_mode`); `test/test_stage_race.jl` (two-sided / shrinkage / inert unit test). Default OFF. `κ=2.0`, `decay=0.8`, `c=30` are un-backtested first-pass estimates.

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

Implemented. `simulate_stage_race` per-stage performance is now `α·σ·rider_noise` (persistent epistemic, correlated across stages) `+ a_stage·stage_noise` (independent aleatoric, a flat per-type scale NOT scaled by σ, drawn `_rand_t(rng, 5)` for fat tails), replacing the old `σ·(α·rider + β·stage)`. The aleatoric scale, breakaway noise, jersey allocation, and intermediate-sprint points live in a new `StageSimConfig` (`race_helpers.jl`, `DEFAULT_STAGE_SIM_CONFIG`), threaded `render_stagerace`→`solve_stage`→`resample_optimise_stage!`→`simulate_stage_race`.

`a_type` was **re-fitted by top-K (K=20) Plackett–Luce ranking-likelihood MLE** on archived GT finishing orders (finishers only; μ reconstructed via `estimate_strengths(:stage)` on archived specialty), superseding the overlap-matched estimates above. The top-K PL ignores the meaningless flat bunch-sprint tail, giving much smaller, K-robust values — clean giro-2026 fit: flat 0.54 / hilly 1.06 / mtn 0.50 / itt 0.49 (ordering hilly>flat≈mtn>itt; itt under-identified). Because `a_type ∝ μ-scale` (an identifiability confound the sweep bounds) and specialty-only μ understates production sprinter sharpening, the **shipped defaults sit at the upper-middle of the fitted range: `aleatoric_noise = (flat=0.8, hilly=1.1, mountain=0.7, itt=0.5)`**. Validation (giro-2026, market-sharpened μ): the dominant sprinter's flat top-10 rate de-saturates from 1.00 (a_type≈0) to 0.82 under the fitted config vs real 0.67; do-no-harm top-20 EVG↔actual ρ unchanged within noise. **Pre-registered revisit trigger: if the next 2 GTs show top sprinters now under-predicting, or top-20 ρ drops materially, revisit `a_type` (esp. flat).** Next: B1 (oneday→flat trim), then A2 (correlated attrition).

#### A2 SHIPPED (July 2026 — attrition / DNF hazard)

Implemented in `simulate_stage_race` via a new `rider_classes` kwarg (gates attrition; empty = off, so tests keep old behaviour) threaded from `resample_optimise_stage!` (reads `df.classraw`). Per not-yet-abandoned rider each stage, DNF hazard = `base_type × class_mult × brutal_day_shock`; abandoned riders are frozen out (`-Inf`) of every per-stage event and all final classifications, but keep points earned before abandoning. A single shared per-stage Gamma(shape 2)/2 shock (mean 1, var 0.5) eliminates sprinters in correlated cohorts. Params live in `StageSimConfig` (`attrition_hazard`, `attrition_class_mult`, `attrition_shock_shape`).

**Empirical hazards** (fitted from archived `pcs_abandons` × VG class labels, 4 GTs): base per-rider-stage by type flat 0.0035 / hilly 0.0075 / mtn 0.0092 / itt 0.0018; class multipliers sprinter 1.29 / climber 1.19 / allrounder 1.53 / unclassed 0.86 (field DNF 14.8%). **Important reset of the plan's premise: the *VG sprinter class* DNFs at only 19% (1.29× field), not the assumed 32% — that figure is elite-only.** Validation: simulated field survival 0.86-0.87 (obs 0.82-0.88), sprinter survival 0.83 (obs mean 0.82), over-dispersion 1.82 (obs 1.66). EVG impact: top riders −5 to −8% (expected haircut < DNF rate, since pre-abandon points stand), survivors redistribute upward, field total ~conserved.

**Residual (logged, not fixed): class-based hazard mis-attritions the tails.** It under-attritions elite sprinters (they DNF ~32%, get the class's 19%) and over-attritions the exceptionally-durable GC leader (Pogačar −8%, though he rarely abandons) — class can't identify exceptional durability/fragility. An "elite-aware" hazard (scale with strength/cost within class) was offered and deliberately not chosen (thin data). This slightly worsens the C2 GC-star under-prediction below.

**Ability-based hazard tested and rejected (July 2026).** The intuitive hypothesis — DNF hazard should fall with climbing quality (weak climbers time-cut on mountains) — is **contradicted by the data**: corr(cost, DNF) = +0.066, corr(overall-quality, DNF) = +0.124, corr(climber, DNF) = +0.056 (giro-2026); quality tertiles run worst 11.5% → best 27.4% DNF. Stronger/marquee riders abandon *more* (strategic abandonment once goals evaporate), not less; climbing ability offers no protection, and the durable exception is simply the rider still winning — which no ability variable can identify ex-ante. Decision: **keep the class-based hazard**; do not re-propose a climbing-quality hazard without new evidence. (Data-consistent alternatives, if revisited: market-favourite GC protection, or a quality-*increasing* hazard paired with favourite protection.)

**GC-favourite protection SHIPPED (July 2026).** The durable-GC over-attrition surfaced visibly on the live TdF GC table: sorted by top-10%, Pogačar sat 5th with top-10 capped at 82.4% (= his climber-class finish rate), below younger low-attrition riders — because a contender's top-10% ≈ finish rate ≈ (1 − class DNF), so the column ranked by attrition class, not GC quality. Fixed two ways: (1) `StageSimConfig.gc_favourite_protection` (default 1.2) multiplies the hazard by `exp(-k·max(0, gc_z−1))` (gc_z = GC-strength z-score), so genuine favourites rarely abandon while the field-wide survival rate is unchanged (only >1 SD riders protected); (2) `format_classification_table` sorts `:gc` by win% first (top-10% is not a GC-quality ordering once attrition is in play). Live result: Pogačar top-10 82.4→98.4 (win% now 96), Vingegaard 82.4→96.6. Side note: this unmasks the model's high GC determinism (Pogačar ~96% win on strength alone) — a separate μ-calibration question, not an attrition issue.

**Protection floor (July 2026):** the first cut protected too hard (Pogačar DNF ~1.6%). Historical incidence says GC favourites crash out meaningfully (Roglič DNF'd 2021/22/24 Tours + 2025 Giro; Pinot 2019; Mas 2025; field ~13%), even if the durable extreme — Pogačar has finished all ~10 GTs he started — justifies a low rate for him. Added `StageSimConfig.gc_protection_floor` (default 0.35): the protection multiplier bottoms out there, so the top favourite keeps ~5–8% irreducible crash risk. Live: Pogačar top-10 98.4→94.2 (~6% DNF), win% 96→92.8.

#### Separate residual issues surfaced (do not conflate with the noise fix)

1. **GC/jersey scoring under-predicts dominant all-rounders.** After stage-finish is corrected, Pogačar's total still trails real by ~400 in the daily-GC/final-GC/points-jersey terms. Independent of the noise model.

   **C2 INVESTIGATED (July 2026) — the daily/final-GC hypothesis does NOT hold; the real omission was daily KOM.** Decomposing Pogačar's simulated points by component: **daily GC 626 (≈ the 630 max — he leads GC nearly every day) and final GC 599 (≈600 — wins ~99.8%) are near-maximal, not under-predicted.** The genuine gap was that the per-stage sim scored *none* of `daily_mountains_class`, `hc_climb_points`, or `cat1_climb_points` — only a crude `mountain_top5_counts` proxy feeding the final KOM. **Fix shipped: daily mountains classification** (`_score_daily_mountains!`) now awards `daily_mountains_class` (up to 33/climbing-stage) ranked by climbing ability + stage luck on mountain/hilly stages — ~100/tour for Pogačar, up to ~252 for a KOM specialist, materially lifting pure climbers/polka-dot contenders who were badly under-scored. **HC/Cat-1 per-climb points remain unscoreable** — the PCS scraper leaves `n_hc_climbs`/`n_cat1_climbs` at 0, so there's no per-climb data (a scraper-side fix would be a prerequisite). Any residual Pogačar gap is now attributable to points-jersey contribution + A2's durable-GC-leader over-attrition, not GC scoring.
2. **Flat-strength leakage.** GC ability leaks into the `:flat` dimension (Pogačar's flat strength 2.43 sits above every second-tier sprinter; his fitted-model flat top-10 rate is 0.49 vs real 0.17). A `SIGNAL_DIMENSION_WEIGHTS` / routing cleanup, on the $\mu$ axis.

   **B1 SHIPPED (July 2026) — `pcs_oneday → :flat` weight 0.2 → 0.0.** Swept the weight on the TdF-2026 field. Two findings: (a) A1's aleatoric noise already de-saturated the *backtest-regime* symptom — Pogačar's PCS-only flat top-10 was 0.13 even at weight 0.2, not 0.49 (the 0.49 was pre-A1). (b) The trim is the right conceptual cleanup regardless: it removes the all-rounder one-day → flat-sprint leak (Pogačar backtest flat 1.02 → 0.75) with **elite-sprinter flat strength unchanged** (Philipsen 2.12→2.15, Kooij 1.52→1.68 — their flat comes from `pcs_sprint`, weight 1.0). It is **inert in production** (Pogačar production flat = 2.46 at both 0.0 and 0.2, since `market_discount` suppresses PCS for priced riders), so it only helps backtests, as the plan anticipated.

   **NEW residual surfaced by the sweep — the real *production* flat leak is `odds_points → :flat` (weight 0.4), not `pcs_oneday`.** Pogačar is listed in the green-jersey (points) betting market (info_share_odds_points ≈ 0.155), and that pricing routes onto `:flat`, giving him a production flat top-10 rate of ≈0.50. B1 does not touch this (market signals bypass `market_discount`). A future cleanup could route `odds_points`/`oracle_points` to `:flat` only for riders *classed* as sprinters (as B2's stage-win channel does via `RACE_HISTORY_CLASS_PROJECTION`), so a GC rider's green-jersey pricing informs points-jersey scoring without inflating his flat-sprint ability. Not in this plan's scope; logged for a future μ-routing pass.
3. **`points_jersey` noise not recalibrated (C1 — BLOCKED on data, July 2026).** Only `stage_finish` was fitted. The points-jersey breakaway shock (`StageSimConfig.breakaway_noise.points_jersey`, hilly 1.5 / mtn 2.5) plus `points_jersey_allocation` / `intermediate_sprint_points` drive green-jersey scoring. The A1b-style ranking-likelihood recalibration is **blocked**: no per-stage points/KOM classification standings are archived (only the `odds_points`/`oracle_points` betting markets, which are predictions not results), so there's no target to fit. Prerequisite: a PCS scraper for daily points/mountains classification standings. Also note post-A1 the points-jersey shock now stacks on top of the new aleatoric `noisy`, so it may be mildly over-dispersed — revisit once classification data exists.

4. **GC contest is over-deterministic — the win% is more certain than the market (diagnosed July 2026; NEXT stage-race item).** Once GC-favourite protection removed the attrition cap, the TdF-2026 board rated **Pogačar 92.8% / Vingegaard 6.6%** to win — well above the model's own market inputs (bookmaker ~55% / oracle 67% for Pogačar; ~15–18% for Vingegaard). The sim *amplifies* the strength gap into near-certainty.

   **Mechanism (verified on the board):** GC is decided by *cumulative* strength over 21 stages. Pogačar `strength_gc` 4.57 vs Vingegaard 3.33 → gap **1.24 units → ~26 accumulated**; the GC-contest noise (difference of the two riders' cumulative noise) has SD ≈ **12**, so the head-to-head is z ≈ 2.2 → ~98.5% (vs the market's ~4:1 ≈ 80%, z ≈ 0.85). **Root cause:** the A1 per-stage aleatoric noise *averages out* over three weeks (grows as √21 while the gap grows as 21), so it barely affects GC order. That leaves the persistent `α·σ·rider` term as essentially the only source of GC-order uncertainty — and σ is *small* for well-characterised favourites (Pog and Ving both 0.45), so two elite peers get a near-deterministic outcome. The model cannot express "any given three weeks, the clear #2 could take it," which is exactly what the market's ~16% encodes. This is not a μ error (the strengths are roughly market-consistent) so much as a *noise* gap: there is no σ-independent, correlated-across-stages GC form/tour shock.

   **Fix direction (own piece, not a knob-turn):** the GC analogue of the A1 insight. A1 gave *stage* outcomes a σ-independent aleatoric scale; the GC contest needs a **persistent, correlated-across-stages "form/tour" random effect** that likewise does *not* scale with σ — a "who is actually best across these three weeks" shock — calibrated so the top-2 win split matches the market (target head-to-head z ≈ 0.85, i.e. Pog ~75–85% / Ving ~12–18%, between the current model and the market). Practical impact on team selection is limited (both are top-EVG picks regardless), but the displayed win% reads over-confident and under-values the second favourite.

5. **No stage-race backtesting path — the GT signal-eval scripts are a temporary workaround (July 2026).** `backtest.jl` and `render_backtesting.jl` cover **one-day classics only**: everything hangs off `BacktestRace` / `build_race_catalogue` (the classics schedule) and `predict_expected_points` (the one-day MC pipeline). There is no stage-race path — no GC/points/KOM target, no multidim-GC isolation backtest — so when the cross-history and classification-history signals needed validating on GTs, that work landed in three standalone scripts instead: `scripts/eval_gt_history.jl`, `scripts/eval_classification_history.jl`, `scripts/ablation_gt_history.jl`. **These are TEMPORARY.** They do backtesting-shaped work (isolation backtest, correlation-with-actuals, signal ablation) and already borrow `backtest.jl`'s `spearman_correlation`/`top_n_overlap`, but they duplicate a shared harness between them and copy `render_stagerace.jl`'s pipeline setup, so they will drift.

   **Proper fix:** fold a **stage-race signal-isolation harness into `backtest.jl`** (its natural home — it already hosts the correlation/overlap primitives and the `RaceData`/prefetch machinery), parameterised by target (`:gc`/`:points`/`:kom`) and the signal toggled, then surface a "stage-race signals" section in `render_backtesting.jl`. The three scripts then collapse into thin callers or are deleted, and future stage-race signals validate through one consistent path rather than a new bespoke script each. Connects to the open stage-race-planning question of whether team-assessor/backtesting should be combined or separate for stage races. **Until this lands, treat the three scripts as provisional (a header note on each points here).**

6. **Mountain/ITT mis-attribution + stale-PCS over-rating (SHIPPED July 2026, multidim path only; validated prospectively).** Three coupled μ-axis fixes to the stage-race model, all confined to `estimate_rider_strength_multidim` / `simulate_stage_race`:
   - **Dimension-aware market discount.** `market_discount` (8×) was applied to every non-market signal on *every* dimension whenever the race had any market, including `:itt` — which has no betting/oracle market — deleting the only ITT signal (PCS-TT) and collapsing all top TT riders to one value. `md` is now per-dimension (`market_dims` mask, keyed to which dimensions a market actually routes to). Effect: Evenepoel (TT world champ) correctly tops ITT.
   - **KOM channel decoupling.** Added a scoring-only `:kom` dimension (in `STRENGTH_DIMENSIONS`, absent from `stage_dimension_weights` so it never enters the finish-position blend). KOM/breakaway market signals (`odds_kom`/`oracle_kom`/`kom_history`) route to `:kom` (was `:mountain` at weight 1.0) and drive `_score_daily_mountains!` only; `odds_gc/oracle_gc → :mountain` raised 0.2→0.5. Effect: polka-dot specialists (Carapaz) no longer inflate their summit-finish placing while keeping high KOM strength.
   - **Recency-weighted PCS specialties.** Career-cumulative specialty totals over-rate veterans vs ascending youngsters. New `getpcs_specialty_by_season` (PCS filterable results pages, dated) + `_apply_pcs_recency!` produce decay-weighted per-season scores in `:<spec>_r`; the multidim z-scoring uses them (no currency multiplier) when present, else falls back to career × currency. All five specialties. Effect: Lipowitz now out-climbs Carapaz on `:mountain`.

   **Validation: prospective only (deliberate).** These are large-effect, mechanistically-clear changes that pass do-no-harm (top-of-field rank unchanged, sprinters still lead `:flat`, info-share sums to 100%, full test suite green) and directional checks. Per the validation philosophy, they ship on theory + do-no-harm and are monitored prospectively — predictions and per-season specialty points (`pcs_specialty_seasons/{slug}/{year}.feather`) are archived for as-of-race-date reconstruction. **They are NOT reachable by the current one-day/scalar backtest** (see item 5), so a numeric backtest was consciously *not* run; it would validate the wrong path. When the item-5 stage-race harness lands, these become its first regression targets.

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
| 13. Per-stage simulation (April 2026) | Per-stage scoring, PCS stage scraping, stage-type strength modifiers, cross-stage correlated simulation | `StageRaceScoringTable`, `simulate_stage_race`, `resample_optimise_stage!`. Validated against TDF 2024/2025 (scoring ρ=0.94–0.96, prediction ρ=0.77 vs aggregate 0.66). Extended to all VG stage races including week-long races (Itzulia, Catalunya, etc.) with optional class constraints. |

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
- `getpcs_race_results` falls back from `/result` to `/gc` URL for stage races where PCS uses a different results page structure

#### Stage-type strength modifiers (deprecated — replaced in Phase 5)

- The original Phase 4 design used `compute_stage_type_modifiers` to apply additive ±0.5σ modifiers on top of a single Bayesian latent strength (since deleted). Phase 5 replaced this with a multi-dimensional posterior over `STRENGTH_DIMENSIONS`; per-stage strengths come from a continuous PCS-ProfileScore-weighted blend across `:flat/:hilly/:mountain/:itt` rather than discrete modifiers.

#### Per-stage simulation

- `simulate_stage_race` in `src/simulation.jl` runs full per-stage simulation: stage finish points, stage/GC assist points, daily GC tracking, cumulative GC standings, and final classification bonuses (GC, points, mountains, team)
- Cross-stage correlated noise via α-blending of persistent rider noise + independent stage noise (`cross_stage_alpha`, default 0.7)
- `resample_optimise_stage!` wraps the simulation in the resampled optimisation framework

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
- Stage-race-specific PIT calibration in prospective evaluation. **Interim (July 2026):** `prospective_pit_values` now *skips* stage races (`haskey(_STAGE_RACE_VG_SLUGS, pcs_slug)`) with an `@info`, rather than silently mis-scoring them. Previously it fell back to one-day Cat 2 scoring (`_find_race_by_slug` returns `nothing` for grand-tour slugs → `cat=2`), producing meaningless PIT numbers. The one-day `simulate_vg_draws` path (`ScoringTable`, single race, scalar strength) cannot consume `SCORING_GRAND_TOUR`; correct follow-up is to route stage races through `simulate_stage_race` (per-stage multi-dim strengths, stage profiles, GC/jersey scoring) for their PIT draws.
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
