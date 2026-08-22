# Velogames.jl

Fantasy cycling team optimisation for velogames.com. Scrapes rider data from Velogames and ProCyclingStats, estimates rider strength via Bayesian updating, and selects optimal teams using resampled optimisation (JuMP/HiGHS).

## Architecture

- `src/Velogames.jl` - Main module, includes and exports
- `src/get_data.jl` - Data scraping: VG riders, PCS rankings/specialty ratings, Oddschecker odds parsing, Cycling Oracle predictions, VG race results, VG race catalogue and per-race results
- `src/pcs_scraper.jl` - PCS table scraping infrastructure and column aliases
- `src/pcs_extended.jl` - Extended PCS scraping: race history results, startlists across multiple years
- `src/data_assembly.jl` - Shared data assembly: `RaceData` struct, `join_pcs_specialty`, `assemble_pcs_race_history`, `assemble_vg_race_history`, `assemble_season_vg_points` (mean VG points per round across other rounds of a season-long series — see "Season-round VG points" below), `prefetch_vg_racelists` (used by both production and backtesting pipelines). Also report data loading (all **archive-only** since Phase 2 — the live-scrape fallbacks are gone) and post-race archival: `load_report_data`, `load_stage_race_report_data`, `load_stage_race_per_stage_data` (and `fetch_stage_race_per_stage_data`, its fetching twin, called only by the ingest phase), `list_completed_races`, `compute_cumulative_scores`, `compute_stage_type_scores`, `archive_stage_race_results`, `load_stage_profiles`, `load_vg_startlist` (the field that actually started one classic, from the `vg_startlist` archive vgleague writes — see "Phase 1c" below)
- `src/completeness.jl` - `race_completeness` (what the archive holds for one race, computed not written — see "Ingest is a phase" below), `RaceCompleteness`, `has_required_data`, `field_prices_every_scorer`, `unpriced_share`, `field_basis_note`, `COMPLETENESS_TYPES`. Archive-only: it must not fetch, or asking the question would change the answer
- `src/ingest.jl` - `ingest_race` (fetch-and-store for one completed race, reporting the before/after difference in the archive rather than the writers' own account of it), `IngestResult`, `pending_races`
- `src/run_log.jl` - `_runs/{YYYY-MM}/{run_id}-{phase}.json`: `RunRecord`, `record_run`, `new_run_id` (honours `VELOGAMES_RUN_ID`), `read_run_log`. One file per run, because the writers are two processes in two clones with no shared lock
- `src/league_archive.jl` - The league tier of the archive: dated raw snapshots (`league/raw`), the derived entrant × race × rider panel and race catalogue (`league/rosters`, `league/meta`), the winners record (`league/winners`), `ingest_league_dir`/`ingest_league_file`, `load_league_standings`, `load_league_team`, `league_race_slug`, `load_league_winners`, `derive_league_winners`, `remove_league_winner` — see "The league lives in the archive" below
- `src/scoring.jl` - VG scoring tables by category (one-day Cat 1/2/3, stage race aggregate) and expected points functions
- `src/bayesian_core.jl` - `BayesianConfig` (3 precision scale factors — market, history, ability — with fixed within-group ratios) and variance accessors, `BayesianPosterior`/`StrengthEstimate`/`MultiDimPosterior`, `bayesian_update`, `bayesian_update_multidim_dim`, `multidim_prior`, and dimension tables (`STRENGTH_DIMENSIONS`, `SIGNAL_DIMENSION_WEIGHTS`, `RACE_HISTORY_CLASS_PROJECTION`). Block-correlation discount groups signals into the same 3 clusters.
- `src/strength_pipeline.jl` - Bayesian strength estimation (`estimate_strengths`): uninformative prior with PCS as observation, season-adaptive VG variance, class-aware PCS blending for stage races, domestique strength discount. Signal assembly (`RiderSignalData`, `AssembledSignals`, `_assemble_signals`), scalar + multidim estimators, and `predict_expected_points` (MC simulation) for backtesting. PCS form, qualitative and trajectory signals deleted (April 2026 ablation, code removed August 2026).
- `src/simulate_oneday.jl` - One-day Monte Carlo race simulation (`simulate_race`, `position_to_strength`, `position_probabilities`) and expected VG points (`expected_vg_points`, `breakaway_sectors_from_km`). `_score_vg_draw!` is the shared finish+assist+breakaway scoring rule used by both `expected_vg_points` (backtest) and `resample_optimise!` (production).
- `src/simulate_stage.jl` - Per-stage grand tour simulation (`simulate_stage_race`, `StageRaceDiagnostics`, `stage_dimension_weights`) and stage-type strength projection (`compute_stage_strengths`). The final mountains jersey is ranked by cumulative daily-KOM points. Attrition, the breakaway participation draw, and GC-favourite protection were deleted July 2026 (WP2.3: none moved team-points-captured on the backtest harness).
- `src/prior_checks.jl` - Prior predictive checks, sensitivity sweeps, and simulation-based calibration (SBC). Validates model behaviour by simulating from the generative process without historical data.
- `src/prospective_eval.jl` - Prospective evaluation: compares archived pre-race predictions against actual results. Computes Spearman rho, top-N overlap, signal value analysis.
- `src/build_model.jl` - JuMP optimisation models: `_build_team_model` (the shared budget knapsack) with the `build_model_oneday` (6 riders) / `build_model_stage` (9 riders + class constraints) wrappers over it, `resample_optimise!` (resampled optimisation that draws noisy strengths, scores VG points, and optimises per draw), `minimise_cost_stage`. Also hindsight-optimal / cheapest-winning team selection for report retrospectives (`compute_optimal_team`, `compute_cheapest_winning_team`, `compute_optimal_stage_team`, `compute_cheapest_winning_stage_team`). All four are **lexicographic**, via `_lexicographic_team` over `_team_model`'s objective-free feasible set: a single-objective knapsack leaves a tie set the solver resolves arbitrarily, so the displayed team was not reproducible across solvers. Optimal maximises score then minimises cost; cheapest-winning minimises cost then maximises score
- `src/race_solver.jl` - High-level solvers: `solve_oneday` and `solve_stage` (estimate strengths → resampled optimisation pipeline, returns top teams). Fetch-free prediction cores `_oneday_prediction_core`/`_stage_prediction_core` (estimate_strengths → resample_optimise, no I/O or archival) are shared by the production solvers and the backtest champions. Also archives predictions for prospective evaluation, and provides `archive_race_results` for post-race archival.
- `src/cache_utils.jl` - Arrow IPC caching with configurable TTL (default ~/.velogames_cache, 7 days), plus permanent archival storage (`archive_dir()`, ~/Dropbox/code/velogames/archive unless `VELOGAMES_ARCHIVE` says otherwise) for odds/oracle snapshots. `ARCHIVE_TYPES` is the typed boundary every write goes through (see "The archive checks its inputs" below); `audit_archive` / `write_archive_manifest` back `scripts/archive_audit.jl`
- `src/race_helpers.jl` - `RaceInfo` struct (canonical race metadata), `RaceConfig` struct, `setup_race()`, `RenderConfig` / `load_render_config()` (the single typed object every renderer takes — see "Render configuration" below), `all_races()` (the 44 classics + 11 stage races as one catalogue), URL alias lookup, `CLASSICS_RACES_2026` schedule, `SIMILAR_RACES` (derived from `RaceInfo`), year-aware VG slug/URL/game ID functions
- `src/utilities.jl` - Name normalisation (`normalisename`), key creation (`createkey`), sentinel constants (`DNF_POSITION`, `UNRANKED_POSITION`), and report/display utilities (`suppress_output`, `clean_team_names!`, `round_numeric_columns!`)
- `src/backtest.jl` - Backtesting framework: race catalogue, season-level evaluation, calibration diagnostics, VG race history integration, cumulative VG season points, PCS specialty archiving. Stage-race harness: `prefetch_stage_race_data` (as-of-race-day grand tour reconstruction into `StageRaceBacktestData`), `backtest_stage_race` (team-points-captured + rank metrics for `:simulator`/`:persistence`/`:odds` or custom predictors; targets `:vg_total`/`:gc`/`:points`/`:kom`), `champion_evg` (full production stack as a predictor), `crosscheck_option_ab` (Option A/B drift alarm: pass vs a pinned post-WP2.3 baseline ±0.03, historical roadmap values carried as `rec_*`). Both harnesses score team-points-captured through one shared core: `GameFormat` (team size, model function, name, predictor table) + `_score_team_points_captured`, so the two cannot drift apart — a divergence there would be invisible, producing plausible numbers rather than an error. The top-N overlap column is named for the team size (`overlap6` / `overlap9`). One-day harness: `prefetch_oneday_backtest_data` (as-of-race-day classic reconstruction into `OneDayBacktestData`, scoring against TRUE scraped `vg_results` totals incl. assist/breakaway, not the finish-only proxy of `backtest_race`), `backtest_oneday_race`/`backtest_oneday_season` (team-points-captured + rank metrics for `:simulator` (`champion_oneday_evg`, runs `_oneday_prediction_core`)/`:simulator_market` (`champion_oneday_market_evg` — the shipped market-blended rule, marketed editions only)/`:odds`/`:maxcost` or custom `name => f` predictors)
- `src/report_html.jl` - HTML page generation primitives (`html_page`, `html_table`, `html_callout`, `html_heading`, `plotly_html`, `_slugify`, `commafmt`, `write_report`)
- `src/report_charts.jl` - SVG/Plotly chart functions (PIT histograms, scatter plots, rank histograms, line charts, team totals, sim distributions), `compute_pit_values`, `simulate_vg_draws`
- `src/report_formatters.jl` - Signal/classification/podium table formatters (`format_signal_waterfall`, `format_classification_table`, `format_stage_podium_picks`, per-dim helpers), `precision_budget`, `format_near_optimal_section` (team switcher + core/filler + structural forks) and `format_rankings_and_alternatives` (full rankings + best-value/upside/budget picks) — the last two are shared verbatim by both prediction reports
- `scripts/render_predictor.jl` - One-day prediction report: reads `race_config.toml`, runs prediction pipeline, writes `prediction_docs/predictor.html` (`[output] dir` overrides)
- `scripts/render_assessor.jl` - Team assessor report: compares custom team vs optimal, retrospective analysis, writes `prediction_docs/assessor.html` (`[output] dir` overrides)
- `scripts/render_stagerace.jl` - Stage race prediction report: reads `race_config.toml`, runs stage race pipeline, writes `prediction_docs/stagerace.html` (`[output] dir` overrides)
- `scripts/render_backtesting.jl` - Backtesting and calibration report: prior checks, historical backtest, prospective evaluation, writes `prediction_docs/backtesting.html` (`[output] dir` overrides)
- `scripts/render_reports.jl` - Public race reports site: generates per-race HTML retrospectives to `site/docs/`, incremental build (skips existing). **Reads the archive and fetches nothing**; a race the league has settled but whose results are not archived stops the run rather than producing a page-shaped hole
- `scripts/league_eval.jl` - Offline league evaluation: scores archived model teams against realised VG points, the hindsight-optimal team, and max-cost / odds-implied baselines, then reports cumulative league placement and the entered-vs-advised delta from the `[league]` config. Its placement section matches standings race names against `CLASSICS_RACES_2026`, so it is classics-shaped — a grand tour league's per-stage race names will not resolve.
- `scripts/ingest.jl` - **The** fetch-and-store phase. `--race=SLUG --year=N`, `--pending` (every race the league has settled a winner for whose archive is short of a required type), `--status`. Exits non-zero on a race it was asked for and could not complete, so `auto_publish.sh` stops before rendering
- `scripts/archive_audit.jl` - Archive integrity: per-type counts, unknown types, files short of mandatory columns, files with no provenance, stray files. `--write-manifest` / `--write-races` / `--check` keep `_manifest.toml` in step with `ARCHIVE_TYPES` and `_races.toml` with the race catalogue
- `scripts/backfill_archive.jl` - Archive completeness: reports what is missing and fetches back what the sources still serve (`--run`), plus two narrow repairs — `--rekey` for legacy riderkeys and `--repair-predictions` for prediction archives short of `team`/`cost`
- `scripts/baseline_compare.jl` - Naive-persistence yardstick for grand tours: mean VG points across the two prior Tours, fed through `build_model_stage`, set beside the model's archived optimal team
- `scripts/ingest_league.jl` - The one thing in this package that reads the vgleague repo: takes each league snapshot into `league/raw` (dated, content-deduped) and rebuilds `league/rosters` and `league/meta`. Idempotent; `auto_publish.sh` runs it first. `--force` rebuilds the derived tables when only the frame builders changed; `--dry-run` writes nothing
- `scripts/auto_publish.jl` / `scripts/auto_publish.sh` - **The** publishing path, classics and grand tours alike: derive each race's league winner from the archived snapshot contemporaneous with the race, record it in `league/winners`, render and deploy. See "Unattended publishing" below
- `scripts/deploy_site.sh` - Upload `site/docs/` to Netlify from disk. The single deploy step every publish path goes through
- `data/race_config.toml` - Shared per-race configuration (gitignored); `race_config.toml.example` is the committed template. Sections: `[race]`, `[output]`, `[data_sources]`, `[optimisation]`, `[team_assessor]`, `[league]`, `[entered_team]`

## Key functions

### Render configuration (src/race_helpers.jl)

- `load_render_config(path=data/race_config.toml; fresh=false) -> RenderConfig` - The one place TOML key names appear. Parses the file, builds the `RaceConfig` via `setup_race`, **parses the odds paste files into DataFrames**, and validates. Every renderer takes the resulting object and nothing else.
- `RenderConfig` wraps `race::RaceConfig` plus every render-time knob: output dir, the three oracle URLs, four parsed odds frames, `season_round_slugs`, the optimisation settings, `vg_race_number`, `my_team`, `breakaway_dir`, `fresh`. Odds are stored **parsed rather than as filenames**, which is what stops a renderer silently skipping a market it never read.
- Why one object: `RaceConfig` already derived `team_size` correctly from race format while a parallel untyped TOML `Dict` supplied everything else by hand, and the two drifted — `render_assessor`'s fresh-solve path was passing a strict subset of the kwargs `render_stagerace` passed, so its "fresh" prediction silently differed. Consolidating fixed that by construction.
- `all_races() -> Vector` of `(slug, name, type)` across the 44 classics and 11 stage races. Used by the web frontend's race picker; its absence is why `league_eval.jl` once reached into `Velogames._find_race_by_slug`.
- An unrecognised race name **throws** (listing near-matches) rather than warning and fabricating a URL.

### The league lives in the archive (Phase 1b, August 2026)

The league used to live in `~/code/vgleague-deploy/data/*.json`: gitignored,
machine-local, overwritten on every scrape, backed up by nothing — while
`league_winners.toml` sat in the archive as a five-field summary of it,
existing only because the source of truth was unreliable. Four trees replace
that, all under `archive_dir()`:

- **`league/raw/{game_slug}_{year}_{league_id}/{YYYY-MM-DD}.json`** — the
  scrape verbatim, dated and deduped on content hash, never overwritten.
- **`league/rosters/{game_slug}_{league_id}/{year}.arrow`** — the entrant ×
  race × rider panel, rebuilt from the newest snapshot on every ingest.
- **`league/meta/...`** — that league's race catalogue, with the league-level
  fields repeated down the rows so a Python reader needs no second lookup.
- **`league/winners/...`** — one row per race, replacing `league_winners.toml`.

Five things that decide the design:

- **Dated because names mutate at source.** The 2026 Paris-Roubaix winner is
  "Martin is typing..." in the oldest surviving snapshot, "Megaton-Structo
  NimaRent" in the record written the week of the race, and "Lowering The Toon"
  today. Only a dated snapshot can answer "who won" honestly, which is why
  `derive_league_winners` reads **the earliest raw snapshot that satisfies the
  publishing gate**, not the newest, and why a recorded winner is never
  re-derived.
- **The 29 pre-archive winners were carried across, not recomputed.** No
  snapshot on disk predates April, so four of them (two renames, two grand tour
  totals a few points out) are reproducible from nothing else. They are seeded
  rows, marked by an empty `snapshot_date`; `league_winners.toml` moved to
  `_retired/`.
- **`scripts/ingest_league.jl` is the only thing that reads the vgleague repo.**
  Everything else — the renderers, the assessor, `league_eval.jl`,
  `auto_publish.jl` — reads the archive. `auto_publish.sh` runs the ingest
  first, which is the ETL-then-publish ordering Phase 2 will formalise.
- **Standings are aggregated from the roster panel**, not parsed separately, so
  the scores that decide the league come from the same rows the rider stats do.
- **`league/rosters` and `league/meta` go through the WP5 guard**, keyed by
  `{game_slug}_{league_id}` rather than a `pcs_slug`. `league/raw` holds
  documents rather than tables, so it is in `RAW_ARCHIVE_TREES` instead of
  `ARCHIVE_TYPES` — `ARCHIVE_TYPES` means "a frame with these mandatory
  columns", and the audit descends one level into `league/` off the type table
  rather than assuming every top-level directory is a type.

`[team_assessor] use_league_team = true` makes `_resolve_my_team` fill `my_team`
from `league/rosters` via `load_league_team` instead of the hand-typed list.
Exposed as a checkbox in `scripts/serve.jl`'s Team assessor fieldset.

- **Velogames publishes rosters only after the entry deadline**, so before the
  race the pull legitimately returns nothing. It warns and falls back to the
  typed `my_team` rather than silently handing the assessor an empty team. It
  also returns nothing until the ingest has run since the deadline passed.
- League race names are matched to `pcs_slug` through `CLASSICS_RACES_2026`,
  which carries the VG display names — all 43 scraped 2026 names resolve, so no
  fuzzy fallback is needed.
- Grand tour rosters are locked for the tour and recorded against every stage,
  so `pcs_slug` is ignored there and the latest stage's roster is returned. This
  means the `[league]` `game_slug`, not the race, decides which GT is read.

### Python writes the startlist (Phase 1c, August 2026)

`riders.php` shows a `Start List` column **only for the race in progress**, so
who was in the game on a given Sunday is capturable only while that Sunday is
happening. vgleague is the thing already on that page every hour, so it writes
it: `vg_startlist`, keyed by VG game slug, one row per starter per race,
accumulating down the season. It is the first archive type written from Python.

- **Python writes through the same guard, from `_manifest.toml`.**
  `src/vgleague/archive.py` refuses an unknown `data_type` and a frame short of
  a mandatory column, and stamps the same five provenance keys into Arrow schema
  metadata. Reading the manifest rather than hard-coding a copy is what the
  manifest is for: a type added on the Julia side is known there on the next
  write.
- **`riderkey` is duplicated across the two languages and checked, not
  trusted.** `vgleague verify-keys <league>` recomputes it from the names in an
  archived `vg_riders` pool and compares against the keys Julia wrote — 5,144
  names across 2023–26, zero mismatches. A divergence here would drop a rider
  from a join rather than raise anything.
- **The page's own hashtag decides which race a startlist belongs to.**
  `riders.php` keeps showing the last race's start list after that race is
  scored, so trusting the league's idea of the live race would file the previous
  race's field under the next race's number. The tag is matched to the catalogue
  on letters and digits alone and by containment either way ("#CyclassicsHamburg"
  against "ADAC Cyclassics Hamburg"); a tag matching nothing, or more than one
  race, archives nothing rather than guessing.
- **A late capture is not a superset of the results.** Velogames revises the
  Start List column: the copy taken three days after Cyclassics Hamburg 2026 had
  lost two riders who scored, one an 8-credit rider on 228 points. So
  `load_report_data` takes the field as the startlist **plus anyone in
  `vg_results` it lacks**, priced from the season pool. Dropping a scorer would
  understate every total on the page and break the cheapest-team stat, which
  lives on exactly those riders.
- Where a race has no archived startlist — every race before August 2026 — the
  field is still the season pool filtered through PCS finishers, which drops
  non-finishers and anyone PCS never listed.

### Velogames is behind Cloudflare; Julia cannot fetch it (22 August 2026)

Every `velogames.com` page — `riders.php`, `races.php`, `ridescore.php`, the
homepage — returns **403 with `cf-mitigated: challenge`** to this package's HTTP
client and to curl with a full browser header set. ProCyclingStats is unaffected
and answers normally.

- **A Playwright browser *context* passes; a bare `browser.new_page()` does
  not.** vgleague's `_new_browser_context` builds one with a realistic UA and
  header set, which is why its scrape never stopped. This is the trap: a
  Playwright test that 403s has probably skipped the context, not hit a block.
- **So `vgleague ingest` is the only route to Velogames data**, and the decided
  "Python owns every Velogames page" split is now enforced by the site rather
  than chosen. `getvg_riders`, `getvg_race_list`, `getvg_race_results`,
  `getvg_stage_*` all fail from here. **Never diagnose one of those as a code bug
  without checking for a 403 first.**
- The `getvg_riders` smoke test in `test_utilities.jl` fails for this reason and
  will until either the block lifts or the test moves off the live page.
- `docs/two-package-reconciliation.md` records the falsified "Playwright looks
  unnecessary" finding and what replaced it. Phase 4's "drop Playwright" is dead.

### Ingest is a phase (Phase 2, August 2026)

Nothing scrapes during a render. `_ensure_results_archived` and the
`archive_stage_race_results` call inside `stage_race_report_html` are gone, as is
the grand-tour probe that fetched a tour's totals and its final stage live to
decide whether the race had finished. The chain is:

```text
ingest-vg (vgleague, Python)   vg_results, vg_stage_totals/results/riders
  → ingest-league   scripts/ingest_league.jl
  → derive-winners  scripts/auto_publish.jl
  → ingest-race     scripts/ingest.jl --pending      (PCS; VG only if absent)
  → render          scripts/render_reports.jl        (archive-only)
  → deploy          scripts/deploy_site.sh
```

`ingest-vg` runs in the vgleague launchd job, before the hook fires. `ingest.jl
--pending` runs **before** `auto_publish.sh` deletes a race's existing HTML, so a
failure leaves the winner recorded and the old page on disk for the retry.

- **Completeness is computed, not written.** `race_completeness(pcs_slug, year)`
  reads the archive: which types are present, row counts, `fetched_at`,
  `field_basis` and `unpriced_scorers`. The design note asked for a marker file;
  a function is better because a half-synced Dropbox file fails the check by
  being opened, there is no second writer, and nothing goes stale. It is
  **archive-only on purpose** — `load_vg_classics_riders` and `load_vg_startlist`
  scrape and archive on a miss, so using them would make the question change the
  answer and make `ingest_race`'s before/after reading meaningless.
- **`field_basis` is what the page says about its field.** `:startlist` (VG's own
  list), `:vg_rider_list` (a grand tour, whose pool *is* its field),
  `:pool_pcs_filtered` (every race before August 2026 — drops abandoners and
  anyone PCS never listed), `:pool` (no PCS results either). On `:pool` the
  starter count and the average-value line are **withheld**, because "43 riders
  scored out of 1,248 starters" is not true.
- **`unpriced_scorers` is annotated, not withheld.** A rider in `vg_results` that
  neither the startlist nor the pool can price is dropped by
  `load_report_data`'s `leftjoin`. One live case in 132 races (Sergio Serrano,
  Classique Dunkerque 2026, 60 pts, 1.5%), so a withholding threshold would be a
  rule nothing crosses.
- **`archive_race_results` skips what is already archived** unless
  `force_refresh`. It used to re-fetch and overwrite every call, which in a
  Dropbox archive with no locking means a rate-limited PCS page replaces a good
  snapshot with a worse one.
- **Velogames revises results months after the race**, not the ~24 hours assumed
  elsewhere: Flèche Wallonne (April) was still changing in August. The skip-if-
  present guard means a revision is never picked up on its own.
- **`_races.toml`** maps a Velogames race name to a PCS slug, exported from
  `CLASSICS_RACES_2026` by `archive_audit.jl --write-races`. Python needs it to
  key a `vg_results` file at all. `race_squash` is duplicated across the two
  languages and checked by `vgleague verify-races`.
- **`vgleague verify-results`** diffs Python's fetch against the archived files.
  A mismatch that **conserves the race total** is a Velogames revision; one that
  does not is a parser fault. That test is what tells them apart.
- **Still archiving during a render, on purpose**: `_prepare_rider_data`'s odds,
  oracle and PCS specialty capture. Those are human inputs that exist only at
  that moment, and the prediction renderers are the lab, which Phase 4 separates.

### Unattended publishing (August 2026)

One-day races publish themselves, with nobody at the keyboard and nothing
written to git. The winner name and score a human used to type are already in
the league snapshot — just `argmax(score)` over that race's entrants — so
`scripts/ingest_league.jl` takes the scrape into the archive,
`scripts/auto_publish.jl` derives every winner the archive can now settle and
records it in `league/winners`, and the wrapper renders and deploys. Triggered
by `POST_UPDATE_HOOK` in the `vgleague` deploy clone's `.env`, which both of
that repo's launchd jobs run after fresh data lands.

- **It waits 24h after the pick deadline** (`--min-age-hours`), and the
  *snapshot* it derives from has to clear the same window — an early capture
  must not freeze a pre-revision score just because a later run is the one
  deriving. Velogames revises scores after a race and a recorded winner is never
  re-derived, so a wrong one is unpicked with `--redrive=<pcs_slug>`. A race the
  gate can never settle — the season's last, after which content dedupe writes
  no further snapshot — is reported by name with the threshold that would
  settle it. The `local_update.sh`
  backstop, not the probe, is what fires a deferred publish: `local_check.sh`
  exits at "nothing due, no new code" *before* it reaches the hook, so on a
  quiet day the hook never runs from the hourly job at all.
- **A race already rendered without a winner gets its HTML deleted** before the
  build. `render_reports.jl` skips existing files, so appending alone would
  leave the winner-less page up for ever.
- **Grand tours are one entry for the whole tour**, not one per stage, and
  wait until *every* race in the **newest** snapshot's catalogue is scored
  (End-of-Tour included) — until then the cumulative totals are a partial sum
  and the leader is not the winner. Newest, and settled for `min_age_hours`
  first: a GT catalogue grows at the finish, so testing a snapshot against its
  own catalogue settles the tour on a partial total, and gating on "newest"
  alone still leaves the window open to a run that lands inside it. See "Silent
  failures closed (WP6)" below for what that was worth on the 2026 Giro. GT
  catalogues carry `deadline: null`, so that structural test replaces the age
  gate rather than adding to it. `GT_PCS_SLUG` maps the
  Velogames game slug to a PCS one (the Vuelta's is `spain`, mapped since
  the 20 August fix that let its league winner be recorded); an unmapped game
  warns and is skipped rather than guessed at.
- **It walks every league-season in the archive**, not the one named in
  `[league]` — that section supplies `vgleague_data_dir` for the ingest, and
  each snapshot directory's own name dates it. A league added later needs no
  code change on either side.
- **Nothing writes to git.** The only git operation is the `--ff-only` pull
  that fetches the code about to run. That is what the winners record moving to
  the archive bought: no commit, no push, no dirty-tree guard, and no way for a
  git failure to keep a report offline or wedge the next run.

### Silent failures closed (WP6, August 2026)

A review of Phases 1b/1c found ten defects and one next door in the cache. All
of them failed silently — a wrong winner, a doubled rider, a report that never
appears — which is what the archive's position makes expensive: it crosses
processes, languages and years, sits in Dropbox with no locking, and is written
by a launchd job with nobody watching.

- **A grand tour could be settled on a partial total.** The completeness gate
  compared each snapshot's own `race_catalogue` against its own scored set and
  returned on the first match. GT catalogues *grow* — End-of-Tour is added at
  the finish, 21 entries to 22 on the 2026 Giro — so a snapshot taken in that
  window lists every race it knows about as scored and passes a self-referential
  test. Measured: End-of-Tour is 20.1% of the Giro winner's total (1,680 of
  8,359) and 18.5% of the Tour's; the Giro was decided by **33 points**, and
  excluding it reorders second through fifth. Two changes, and the second is not
  optional: gate on the **newest** snapshot's catalogue (not the union — a
  cancelled stage dropped from the list would otherwise be required for ever),
  and require that newest snapshot to have been stable for `min_age_hours`.
  Without the second, a publish landing inside the window sees the partial
  catalogue *as* the newest one, which turns a reliable bug into an intermittent
  one. Wall-clock age always grows, so unlike the classics gate this cannot
  deadlock.
- **A classic the gate cannot settle now says so.** `save_league_snapshot`
  dedupes on content, so a snapshot exists only where something changed. After
  the season's final race nothing changes again, no snapshot dated a full
  settling window past its deadline is ever written, and the race could never
  publish — silently, for ever. The gate is unchanged and still publishes
  nothing it should not; what is new is a pass over the newest snapshot that
  reports each unsettled race once, with the remedy. It computes the threshold
  rather than naming one, because the obvious guess is wrong: a snapshot dated
  the race day is *negative* hours from an 11:00 deadline, so `--min-age-hours=0`
  does not rescue it.
- **`--redrive=<pcs_slug>` is the escape hatch.** A recorded winner is never
  re-derived, which is right, and meant a wrong one was wrong for ever — the
  documented repair was hand-editing an Arrow file, which no text editor does.
  `remove_league_winner` drops the row and the same run derives it again.
  **Seeded rows are refused**: the 29 carried across when the league moved into
  the archive have an empty `snapshot_date` because nothing on disk can
  reproduce them.
- **Archive writes are atomic.** `atomic_write(f, path)` writes a dot-prefixed
  temporary file in the target directory and renames it into place; every typed
  write goes through `save_race_snapshot`, so one change covers ~30 call sites,
  plus `save_league_snapshot` and `write_archive_manifest`. Dot-prefixed because
  that is what `audit_archive` and `archive_years` skip, so neither a write in
  flight nor one orphaned by a kill is a stray file; in the target directory
  because that is what keeps the rename inside one filesystem. It does **not**
  make `append_league_winners` safe: that is read-modify-write, so two
  concurrent runs lose one winner silently. `.velogames-publish.lock` serialises
  that, and it is per-clone.
- **The publish lock can no longer wedge publishing.** The `EXIT` trap does not
  survive SIGKILL or a power cut, and the script exits 0 on contention — so an
  abandoned lock disabled publishing for ever while launchd recorded success.
  A lock over an hour old is now broken, loudly, and the `mkdir` retried because
  two runs can reach the break together.
- **`--dry-run` is read-only end to end.** The ingest ran before the dry-run
  exit, so a dry run wrote to the append-only raw tier. It now takes the flag
  itself: the content-dedupe decision and the frame building stay on one path
  and only the three writes fork, so the reported answer cannot drift from the
  real one.
- **Arguments are parsed, not forwarded.** `auto_publish.sh` forwarded `"$@"` to
  `auto_publish.jl`, so `--config=` was accepted there, ignored, and never
  reached `ingest_league.jl`, which is the only thing that reads it. Both now
  reject anything they do not know. No bash arrays in that script: launchd
  resolves `/bin/bash`, which is 3.2, where expanding an empty array under
  `set -u` is an unbound-variable error.
- **One winner per race, across leagues.** `derive_league_winners`' contract is
  one league-season, so two leagues on the same game and year would each record
  every race, and `render_reports.jl` keys on `(pcs_slug, year)` and silently
  keeps whichever came last. The guard is global, in `auto_publish.jl`'s loop,
  and `load_league_winners` warns when the archive holds two — logged, because
  the alphabetically-first league would otherwise claim every shared race and
  the second league's real winner would vanish permanently.
- **`ingest_league.jl --force`** rebuilds `league/rosters` and `league/meta`.
  They are a function of the newest snapshot *and* of the frame builders, and
  only the snapshot half was checked, so changing a builder left a finished
  season's table stale for ever — present, readable, and no longer what the code
  says it is.
- **`vg_startlist` is deduped on read**, and the constraint is written into
  `ARCHIVE_TYPES` and `docs/data-dictionary.md` for the Python writer: one row
  per `(race_number, riderkey)`. Duplicates multiply through
  `load_report_data`'s `leftjoin` into the page's points total and the
  cheapest-team stat. First occurrence wins, deliberately — the startlist arm is
  first in the `vcat`, so the price Velogames showed for that race beats the
  season pool's.
- **The cache wrote its metadata before its data.** `is_cache_valid` turns on
  the metadata alone and `cached_fetch` reads metadata-without-data as the
  deliberate "empty result" marker, so the window between the two writes served
  an empty DataFrame nothing had fetched. Reordered to data-then-metadata, which
  leaves the deliberate marker byte-identical (an empty fetch writes no data
  file, so there is no window). A corrupt data file is also distinguished from
  an empty one now, instead of being served as empty for the rest of the TTL.

### The archive is Arrow IPC (August 2026)

Archive and cache files are Arrow IPC with an `.arrow` extension, converted from
Feather V1 by `scripts/migrate_archive_arrow.jl` (518 files, value-level verified,
303,743 rows unchanged). Feather.jl v0.5.10 was end-of-life and pyarrow warns that
V1 support will be removed, which mattered because Python is due to read this
archive.

- **`copycols = true` on every load is load-bearing.** It materialises the mmapped
  columns, so `sort!` and element assignment work on a loaded frame and no file is
  left mmapped while another call overwrites the same path. The
  `rematch_riderkeys!` workaround in `utilities.jl` existed only to dodge that and
  is gone.
- **Hard cutover, no dual read.** A slug present as both `.feather` and `.arrow`
  would be listed twice by `list_completed_races`, silently duplicating a race in
  every season table built from it.
- **One dataset, one type.** `stage_profiles` was `pcs_stage_profiles` at an older
  schema, written by a second hand-built frame builder; both write paths now go
  through `stage_profiles_frame` and only `pcs_stage_profiles` exists. The pre-race
  write is kept, which means the post-race archiver's `=== nothing` guard skips and
  a mis-scraped pre-race profile is never corrected. Acceptable — profiles are
  near-static facts, though the Tour and Giro show PCS revising distance and
  ProfileScore between the pre-race and post-race scrapes.

### Velogames retires its pages — we keep them (WP1d, August 2026)

Velogames takes a season's pages down. `sixes-classics/2025/riders.php` and its
`sixes-superclasico` alias 404, and `races.php` 404s for both 2024 and 2025. Two
archive types now hold them, both read archive-first and written on any live
scrape: **`vg_riders`** (the classics rider pool: name, team, cost, points) and
**`vg_racelist`** (race number, deadline, name, category), keyed by *VG game
slug* and year rather than a `pcs_slug`. `scripts/backfill_vg_pages.jl` captures
them, pinning Internet Archive snapshot timestamps for retired seasons.

- **Grand tours were never exposed.** `vg_stage_riders` has archived their pools
  since 2023 and `load_stage_race_report_data` already read it first. The one-day
  `load_report_data` scraped unconditionally; that asymmetry between twins is
  what cost the 2025 back-catalogue.
- **No other source has the pool.** `vg_results` carries no cost; the published
  reports show a display slice (71% of 2025 rider-rows); the vgleague snapshots
  record only what entrants picked (62%, and they start at 2026).
- **Costs are constant within a season** — verified across all 40 races of 2025 —
  so an archived pool stays correct for reporting, which reads rider, team and
  cost. The prediction path deliberately still scrapes: it needs live `points`.
- **The test that matters** is that `render_reports.jl --years=2025,2026 --force`
  completes without any retired VG page. It does, from a cold cache.
- **2023 and 2024 followed in August 2026**, from the Internet Archive: those
  seasons serve nothing at all now — `riders.php`, `races.php` and
  `ridescore.php` all 404 — so the pinned Wayback snapshots in
  `backfill_vg_pages.jl` are the only copy. 1,248 and 1,362 riders. Pool coverage
  of archived results is 100% for 2023, 2024 and 2025.
- Known gap: Sergio Serrano scored in Classique Dunkerque 2026 but appears in no
  pool snapshot, so that report omits him. Pre-existing — the previously-published
  page omits him too, the live page still omits him, and the Internet Archive has
  no snapshot of the 2026 pool. `backfill_vg_pages.jl` names uncovered riders
  rather than printing a bare percentage, because the left join drops them
  silently.

### The archive checks its inputs (WP5, August 2026)

`save_race_snapshot` used to accept any string as a type and any frame as
content: it `mkpath`ed and wrote. Five drift modes came out of that, four of
them observed. `ARCHIVE_TYPES` in `cache_utils.jl` closes them at the boundary —
one const holding, per type, `version`, `mandatory` columns, `refetchable` and a
note. See `docs/data-dictionary.md` for the arguments the const cannot carry.

- **An unknown type errors before `mkpath`.** The empty directory is the thing
  being prevented: `prediction/` sitting beside `predictions/` is what made a
  typo look like a data type for four months.
- **The mandatory lists were derived by census**, not by judgement — the
  intersection of column sets across all 522 live files, cross-checked against
  what each writer provably emits. A list stricter than the writers emit would
  *lose* data rather than protect it: odds and oracle are archived through
  `_try_archive`, which turns the error into a warning, so an over-strict entry
  would silently drop a hand-pasted odds sheet nobody can re-paste. Two census
  facts to respect: `vg_results` carries `year` on only some files, and
  `vg_stage_riders` carries `class`, `classraw` and `selected` on only some.
- **Provenance is Arrow schema metadata, not columns.** The grain is the file —
  one file is one fetch, and the motivating question is which side of Velogames'
  24-hour score revision a row came from. Columns would collide on the joins in
  `backtest.jl` and `prospective_eval.jl` (both sides carrying `fetched_at`,
  `makeunique` producing `fetched_at_1`) and would be dropped silently by
  `_archive_predictions`' allowlist. `schema_version` moved out of the
  predictions frame for the same reason; nothing read the column.
- **The audit reports what the guard cannot see.** The guard stops new drift;
  `scripts/archive_audit.jl` finds the old kind. On the live archive it reports
  the 8 deficient 2026 prediction files and 522 files with no provenance, both
  expected and neither fixable.
- **`_manifest.toml` is written by a command, not on every save.** Rewriting a
  file in the archive root hundreds of times a run is how Dropbox produces a
  conflicted copy, and `serve.jl` and launchd would tear it concurrently. It is
  a derived export of the const, so `--check` is a string comparison.
- This is a genuine boundary — it crosses processes, languages and years — which
  is why it gets checks the rest of the package does not.

### Wiping the cache is not free (August 2026)

`~/.velogames_cache` is **not** purely a re-fetchable convenience. Velogames retires
a season's rider page: `sixes-classics/2025/riders.php` and its
`sixes-superclasico` alias both 404 as of August 2026, and `vg_results` carries no
`cost` column, so **rider costs for a past season exist nowhere else** once the
cache is cleared. `load_report_data` needs them, so the 2025 back-catalogue can no
longer be re-rendered; its 43 pages are preserved only as already-published HTML.

Consequences to respect:

- Never wipe the cache without checking what in it is still fetchable upstream.
- The rebuild was restored by WP1d above, which archives the pool: a
  `--force` run over both years now completes from a cold cache. Before WP1d it
  failed on the first 2025 race.

### Site deployment (August 2026)

`site/docs/` is **build output, not source**: gitignored, rendered by
`render_reports.jl`, uploaded by `scripts/deploy_site.sh` (`netlify deploy
--prod --dir=site/docs`, credentials from a gitignored `.env`). It was tracked
until the move off GitHub Pages, which could only publish what was in the repo —
so every race cost a push of megabytes of generated HTML, and the unattended
publish could not run without git succeeding.

`league_winners.toml` followed it out of the repo and has since been absorbed
into `league/winners` — see "The league lives in the archive" above.

- Keeping it in git was never what made the site rebuildable, whatever the old
  README said: `list_completed_races` scans `archive_dir()/vg_results/`,
  so a clone without the Dropbox archive renders nothing at all.
- `deploy_site.sh` refuses to deploy when `site/docs/index.html` is missing.
  Pulling the commit that untracked these files **deletes them from every
  existing clone**, so a deploy from a clone that hasn't re-rendered would have
  replaced the live site with an empty one.

### Solvers (src/race_solver.jl)

- `solve_oneday(rc::RenderConfig)` / `solve_stage(rc::RenderConfig, stages, stage_scoring)` - **What the renderers call.** Forwarding methods that unpack every knob from one config object; the kwarg forms below stay for the backtest harness, which legitimately varies knobs one at a time.
- `solve_oneday(config; ..., market_blend_weight=1.0)` - Resampled optimisation pipeline for one-day classics. Returns `(predicted, chosenteam, top_teams)`. `market_blend_weight < 1` blends the bookmaker market into the final team pick (see "Market blend" below); `race_config.toml` supplies 0.5.
- `solve_stage(config; ..., season_round_slugs=String[])` - Resampled optimisation pipeline for stage races (class constraints). Returns `(predicted, chosenteam, top_teams)`. `season_round_slugs` supplies the VG slugs of the other rounds of a season-long series (see "Season-round VG points" below); `race_config.toml`'s `[data_sources]` provides it.
- `archive_race_results(pcs_slug, year; vg_race_number)` - Fetch and archive PCS results and VG results for a completed race. Idempotent.

### Optimisation models (src/build_model.jl)

- `resample_optimise!(df, scoring, build_model_fn; team_size, n_resamples=500, max_per_team, n_alternatives=20, market_probs, market_blend_weight=1.0)` - Draw noisy strengths from posterior, score VG points, tally per-draw selection frequency, then optimise on risk-adjusted expected points. Returns `(df, top_teams)` where df gains `:selection_frequency` and `:expected_vg_points`, and `top_teams` is a `Vector{DataFrame}` of the `n_alternatives` best distinct teams ranked best-first (k-best enumeration via iterated no-good cuts; `top_teams[1]` is the optimal team). Both report types use this near-optimal set for the team switcher, filler pool, and structural-fork analysis.
- `market_win_probs(odds_df, riderkeys)` / `blend_market_points(pts, market_probs, w)` - Implied win probability (`1/max(odds, 1.01)`, 0 for unpriced riders; empty when there is no market) and the unit-normalised blend `w·unitnorm(pts) + (1−w)·unitnorm(probs)`. Both arms MUST be unit-normalised — a knapsack is invariant to scaling one column but not to mixing two on different scales. `DEFAULT_MARKET_BLEND_WEIGHT` (0.5) is the single source for the shipped weight — the config default and the harness's `simulator_market` arm both read it, so they cannot drift apart.
- `build_model_oneday(df, n, points_col, cost_col; max_per_team, exclude, force_in, force_out)` - Maximise points, one-day (6 riders, cost <= 100, optional per-team cap). `exclude` adds no-good cuts (k-best); `force_in`/`force_out` pin riders (structural forks).
- `build_model_stage(...)` - Same, stage race (9 riders + VG class minimums). Both are thin wrappers over `_build_team_model(...; classes)` — the class constraint is the *only* structural difference between the two games' knapsacks. Keep them as separate named functions: they are passed around as `build_model_fn` values and carry the right team size.
- `compute_filler_pool(top_teams)` / `compute_structural_forks(predicted, build_model_fn; team_size, max_per_team, points_col=:expected_vg_points, n_forks=5)` - Decompose the k-best set into locked core + interchangeable filler pool, and rank the highest-EVG either/or roster decisions (drop-a-rider deltas + the both-GC-leaders-vs-one structural fork, the latter only when `:strength_gc` is present). Returns `best_obj` alongside, so the report can print each delta as a share of the team total. Rendered by `format_near_optimal_section` (report_formatters.jl) from **both** renderers. `points_col` must be the column the team was actually picked on — `:market_blend_points` on the one-day path when the blend is live — or the forks describe a different roster from the one displayed.
- `minimise_cost_stage(df, target_score, n, cost_col)` - Minimise cost for target score

### Data scraping (src/get_data.jl)

- `get_cycling_oracle(prediction_url)` - Scrape Cycling Oracle blog predictions, returns DataFrame(rider, win_prob, riderkey)
- `getvg_race_list(year)` - Scrape VG races.php for one-day classics, returns DataFrame(race_number, deadline, name, category, namekey)
- `getvg_race_results(year, race_number)` - Fetch VG race results via year-aware ridescore URL
- `match_vg_race_number(race_name, vg_racelist)` - Match a race name to VG race number using normalised string comparison
- `normalise_race_name(name)` - Normalise race names for cross-source matching (strips accents, hyphens, punctuation)

### Simulation (src/bayesian_core.jl, strength_pipeline.jl, simulate_oneday.jl, simulate_stage.jl)

- `estimate_strengths(rider_df; ...)` / `estimate_strengths(data::RaceData; ...)` - Bayesian strength estimation pipeline. Returns DataFrame with `strength`, `uncertainty`, signal flags, signal shifts, and domestique penalty. Used by production solvers.
- `predict_expected_points(df, scoring; ...)` - Backtest entry point: calls `estimate_strengths` then runs MC simulation to compute `expected_vg_points`. Used by backtesting.
- `estimate_rider_strength(...)` - Bayesian posterior from uninformative prior (mean=0, variance=100), updated with PCS specialty (gated on `has_pcs`), VG season points, PCS race history with variance penalties, odds and oracle. VG race history is applied by the multi-dim (stage-race) estimator only. Variances accessed via functions: `pcs_variance(config)`, `odds_variance(config)`, etc. When odds are present for a race, non-market signal variances are inflated by `market_discount` (default 8.0) at the race level to prevent double-counting information already reflected in odds. Block-correlation discount groups signals into market/history/ability clusters with within-cluster ρ=0.5 and between-cluster ρ=0.15.
- `simulate_race(strengths, uncertainties; n_sims)` - Monte Carlo position simulation (used by backtesting)
- `estimate_rider_strength_multidim(signals; ...)` - Multi-dimensional Bayesian strength estimation for stage races. Routes each signal to dimensions in `STRENGTH_DIMENSIONS` according to `SIGNAL_DIMENSION_WEIGHTS`. Returns `MultiDimStrengthEstimate` with per-dim mean/variance/shift vectors. The scalar block-correlation discount is applied per dimension (gated by `multidim_block_correlation`, default true; `skip_block_correlation` escape hatch for per-signal SBC).
- `compute_stage_strengths(rider_df)` - Project per-dim strength columns onto per-stage-type strength vectors used by `simulate_stage_race`.
- `simulate_stage_race(stages, stage_strengths, uncertainties, teams, scoring; ...)` - Always returns `(vg_points, diagnostics)`. Per-event scoring delegated to `_score_*` helpers; noise scales live in `StageSimConfig`.

### Prior predictive checks (src/prior_checks.jl)

- `prior_predictive_check(config; n_races, n_riders)` - Simulate races from generative process, compute diagnostics (favourite win rate, top-N overlap, rank correlation, posterior SDs)
- `check_stylised_facts(config; facts)` - Run prior predictive check against domain knowledge targets, returns pass/fail DataFrame
- `sensitivity_sweep(param, values; config)` - Sweep a BayesianConfig parameter and report diagnostics
- `simulation_based_calibration(config; n_sims)` - SBC: check posterior CDF rank uniformity to validate inference pipeline

### Prospective evaluation (src/prospective_eval.jl)

- `evaluate_prospective(pcs_slug, year)` - Compare archived predictions vs PCS results for one race
- `prospective_season_summary(year)` - Aggregate prospective metrics across all archived races for a year
- `prospective_pit_values(year)` - Compute PIT values for all riders across archived races (requires predictions + VG results)
- `prospective_pit_summary(pit_df)` - Summary statistics for aggregate PIT: mean, variance, KS statistic
- `signal_value_analysis(year)` - Per-signal shift magnitudes across archived predictions

### Archival storage (src/cache_utils.jl)

- `save_race_snapshot(df, data_type, pcs_slug, year)` - Permanently archive a DataFrame (e.g. odds, oracle) to the path `archive_path` computes
- `load_race_snapshot(data_type, pcs_slug, year)` - Load archived data; returns `nothing` if not found
- `archive_path(data_type, pcs_slug, year)` - Compute the archive file path. The one place the layout and the `.arrow` extension (`ARCHIVE_EXT`) are written down
- `archive_races(data_type)` / `archive_years(data_type, pcs_slug)` / `has_race_snapshot(data_type, pcs_slug, year)` - Enumerate the archive without building paths by hand. Directories only, and a strict `NNNN.arrow` match, because the live tree carries `.DS_Store`, `_manifest.toml` and four `.mhtml` inputs. Added by WP1a so nothing outside `cache_utils.jl` knows the layout — `prospective_eval.jl`, `list_completed_races`, `league_eval.jl` and `baseline_compare.jl` each reimplemented it, which is why a one-character extension change touched nine places
- `archive_dir()` - Archive root: `VELOGAMES_ARCHIVE`, else `~/Dropbox/code/velogames/archive`. A function, not a const — a const is evaluated at precompile time and baked into the image, so the environment variable would silently stop working
- `ARCHIVE_TYPES` - The 27 live data types, each with `version`, `mandatory` columns, `refetchable` and a one-line note. `RAW_ARCHIVE_TREES` holds the trees of documents rather than tables (`league/raw`), which the same manifest exports but the column guard cannot describe. `save_race_snapshot` reads it: an unknown type errors before `mkpath` and a frame missing a mandatory column errors instead of writing. `missing_mandatory_columns(data_type, df)` is the shared check, used by the write-time error and `prospective_eval.jl`'s read-time warning
- `atomic_write(f, path)` - Write via a dot-prefixed temporary file in the target directory, then `mv(...; force = true)`. Used by `save_race_snapshot`, `save_league_snapshot` and `write_archive_manifest`. The archive has many readers and no locking, so an interrupted write must not be observable — see "Silent failures closed" above
- `archive_provenance(...)` - `data_type`, `schema_version`, `fetched_at`, `machine`, `source_url`, stamped into Arrow schema metadata on write. Metadata rather than columns: the grain is the file, and columns would collide on the joins in `backtest.jl` and `prospective_eval.jl`. `nothing` for the pre-WP5 files, which is every file written before August 2026
- `write_archive_manifest()` / `archive_manifest_matches()` / `audit_archive()` - `_manifest.toml` is a derived export of `ARCHIVE_TYPES` for readers that cannot see Julia, written by a command rather than on every save (a file rewritten hundreds of times a run in a Dropbox folder is how you get a conflicted copy). `audit_archive` walks the tree for what the guard cannot see: unknown types, missing columns, absent provenance, stray files
- `RETIRED_ARCHIVE_TYPES` - The trees that are no longer data types, with where they went and why: `pcs_form`, `qualitative` and `prediction` under `_retired/`, and `pcs_breakaways` (four `.mhtml` pages, no tabular data) under `_inputs/`. Documentation, not machinery. Converted to Arrow in August 2026 along with everything else, and the **Feather dependency is gone**: 40 retired files were the only thing keeping an end-of-life package in the manifest. The pre-flight copy is the untouched Feather V1 original

### Backtesting (src/backtest.jl)

- `build_race_catalogue(years)` - Generate `BacktestRace` entries (with dates) from the classics race schedule
- `prefetch_all_races(races)` - Bulk pre-fetch data (PCS results, rider info, race history, VG race history, cumulative VG season points, archived odds/oracle/PCS specialty)
- `backtest_season(races; race_data, signals, ...)` - Evaluate predictions across all races
- `summarise_backtest(results)` - Convert results to summary DataFrame with aggregates
- `BacktestResult` includes: rank metrics (Spearman ρ, top-N overlap), VG team metrics (actual scoring tables), and calibration diagnostics (z-scores, coverage rates)

## Prediction model

### Signal inventory

The strength model combines multiple signals grouped into three precision families. Effective variances are computed from base values, fixed within-group ratios, and tuneable scale factors. Accessor functions (e.g. `pcs_variance(config)`) compute the effective variance from the config.

**Active signals (after April 2026 ablation):**

| Signal | Source | Group | Base variance | Notes |
| ------ | ------ | ----- | ------------- | ----- |
| PCS seasons | `getpcs_rider_pts_batch()` | Ability | 7.9 | Z-scored across field. Best discriminator across all tiers (ρ=0.16–0.34). For stage races, each PCS specialty source (sprint/oneday/climber/tt/gc) is z-scored separately and routed to dimensions via `SIGNAL_DIMENSION_WEIGHTS`. |
| VG season points | `getvg_riders()`, or `assemble_season_vg_points()` when this game's own `points` is all zeros | Ability | 1.4×scale | Season-adaptive: `effective = vg_var * (1 + penalty * (1 - frac_nonzero))`. Strong for top-tier discrimination (ρ=0.287) |
| PCS race history | `getpcs_race_history()` | History | 3.0+decay/yr | Recency-weighted. Strong for bottom/middle tiers (ρ=0.23–0.25), weak for top (ρ=0.004) |
| Similar-race history | `getpcs_race_history()` | History | +penalty | Same as race history but with variance penalty. Races from `SIMILAR_RACES` terrain mapping |
| Betting odds | `parse_oddschecker_odds()` | Market | 0.3 | Strongest top-tier signal (ρ=0.464 for top 25%). Applied uniformly when odds are present |
| Odds floor | Derived (absence signal) | Market | var × 2.0 | When odds data exists but rider absent, floor observation from residual probability mass |
| Cycling Oracle | `get_cycling_oracle()` | Market | `_odds_to_oracle_ratio`/scale | Broader coverage than bookmaker odds. Removal deferred: degrades middle-tier discrimination when combined with other changes. |

**Removed by the April 2026 ablation and deleted from the codebase in August 2026**: PCS form score, qualitative intelligence, trajectory. VG race history was dropped from the scalar one-day estimator only — the multi-dim stage-race estimator still consumes it, which is why `RiderSignalData` keeps `vg_race_history`.

### Season-round VG points (stage races, July 2026)

Single-race VG games — the Femmes/GT format, and each round of the Velogames
Womens Cycling Championship — open with `points` at zero for the whole field,
which z-scores to a constant and switches the VG-season signal off. When
`[data_sources] season_round_slugs` is set and the column is all zeros,
`_prepare_rider_data` substitutes each rider's **mean points per scored round**
across those other rounds (`assemble_season_vg_points`).

Three things that matter:

- **Mean, not sum.** Rounds-ridden is negatively rank-correlated with strength
  (ρ = −0.28 vs the market on the 2026 Femmes field), so a total scores volume.
- **Rounds with no scores yet are skipped.** `ridescore.php` serves the full
  roster at zero for an unridden round; counting it would deflate exactly the
  riders entered in the most upcoming rounds.
- **Uncovered riders get the covered-field mean, and `:vg_points_observed`
  records who was actually observed.** The mean-fill makes absence neutral
  (z = 0) instead of reading as weakness; the flag stops `frac_nonzero` seeing a
  fully-substituted column as full season coverage and cancelling the
  `vg_season_penalty` variance widening. The substitution runs *after* every row
  filter, so the fill value is the mean of the frame that is actually z-scored.

Odds are converted to strength via log-odds relative to a uniform baseline. When odds are present for a race, non-market signal variances are inflated by `market_discount` (default 8.0) to prevent double-counting. Riders absent from the market receive a floor observation.

### Bayesian updating

Normal-normal conjugate model (`estimate_rider_strength()`). Each signal updates the posterior mean and variance. Missing data leaves the prior unchanged. Output: posterior mean (strength) and variance (uncertainty).

### Monte Carlo simulation

`simulate_race()` adds Student's t noise (df=5) scaled by posterior uncertainty to each rider's strength, then ranks to get finishing positions. Gaussian noise also supported via `simulation_df=nothing`.

### One-day vs stage race differences

| Aspect | One-day | Stage race |
| ------ | ------- | ---------- |
| PCS blending | Single specialty (e.g. one-day points) | Per-source z-scoring routed to dimensions via `SIGNAL_DIMENSION_WEIGHTS` (multi-dim posterior) |
| Scoring table | Cat 1/2/3 (finish + assist + breakaway) | `SCORING_GRAND_TOUR` (per-stage scoring) or `SCORING_STAGE` (aggregate fallback) |
| Simulation | Single race simulation | Per-stage simulation with cross-stage correlated noise (α=0.7) and stage-type strength modifiers |
| Breakaway points | Heuristic estimate | Not modelled (~6 pts/stage gap from sprint/climb/breakaway bonuses) |
| Team size | 6 riders | 9 riders |
| Constraints | Cost only | Cost + classification (grand tours) or cost only (week-long races without VG class data) |
| Market blend | `market_blend_weight` (0.5) mixes the market into the final pick | Not blended — only 2 marketed GT editions, nowhere near enough evidence |
| Near-optimal set | Same section, `build_model_oneday`, no GC-leader fork | Team switcher, core/filler split, structural forks incl. the GC-leader fork |

### Market blend (one-day only, July 2026)

When a one-day race has bookmaker odds and `market_blend_weight < 1`, the final
team optimisation maximises `w·unitnorm(risk-adjusted EVG) + (1−w)·unitnorm(implied win prob)`
instead of risk-adjusted EVG alone, and `predicted` gains a `:market_blend_points`
column. Applied in `_resample_core!`, *after* the risk adjustment, so `w = 1`
is bit-identical to the unblended path. Marketless races are unaffected at any `w`.

Evidence: +0.079 team-points-captured over the unblended simulator on the 12
marketed 2026 classics (0.572 → 0.651), CI [+0.028, +0.136], 7 wins / 0 losses.
It does **not** clearly beat odds alone (+0.024, CI includes zero) — that weaker
claim is what justifies simulating marketed classics at all, and it is not
established.

**Pre-registered revert trigger: back the blend out if `simulator_market` −
`simulator_risk` falls below +0.02 on the 2027 classics.** Against
`simulator_risk`, not `simulator`: the blend is applied on top of the
risk-adjusted column, so differencing against the unadjusted arm bundles the
risk adjustment into the measured effect. The quoted +0.079 is the
`simulator` difference (what the experiment reported); the harness now renders
both, paired on the editions where each arm produced a row — arms cover
different edition sets, so subtracting the summary means is not a valid
comparison. See `roadmap.md` "SHIPPED: one-day market blend".

### Parameter settings

| Parameter | Value | Rationale |
| --------- | ----- | --------- |
| `market_precision_scale` | 4.0 | Odds are the best single predictor for top-quartile riders |
| `history_precision_scale` | 2.0 | Controls PCS race history only (form and VG history removed by ablation) |
| `ability_precision_scale` | 1.0 | PCS seasons and VG season points are broad career/season aggregates |
| `within_cluster_correlation` | 0.5 | Prevents false certainty from correlated history observations |
| `between_cluster_correlation` | 0.15 | Modest discount across 2–3 active clusters |
| `hist_decay_rate` | 3.2 | Aggressive: 3-year-old result has variance 11.1 vs 1.5 for current year |
| `market_discount` | 8.0 (uniform) | Applied uniformly when odds are present |
| `max_per_team` | 2 | A **diversification preference, not a Velogames rule** — so it does not derive from race format. Both formats race under the same cap, and the backtest harness defaults to the same 2 so its metric matches production |

### Data sources

- **Velogames** (velogames.com) — rider rosters, costs, season points, classifications, ownership %, historical race results, per-stage results
- **ProCyclingStats** (procyclingstats.com) — specialty ratings, rankings, race results, startlist quality, form scores, stage profiles (ProfileScore, vertical metres, gradient)
- **Bookmaker odds** — betting odds pasted from Oddschecker or any bookmaker winner market into `oddschecker_paste.txt`
- **Cycling Oracle** (cyclingoracle.com) — race predictions with win probabilities (optional)

## Key patterns

- Per-race config in `data/race_config.toml` (gitignored, shared by all three renderers); `race_config.toml.example` is the committed template. It is read **only** through `load_render_config` — no renderer parses TOML itself, and no solver call site hand-assembles kwargs
- Analysis reports are standalone Julia scripts (`scripts/render_*.jl`) that generate HTML directly — no Quarto/pandoc dependency. Each exposes `render_<name>(rc::RenderConfig) -> output_path` guarded by `abspath(PROGRAM_FILE) == @__FILE__`, so `scripts/serve.jl` can `include` them once and call them per request. A renderer given the wrong race format throws
- Public race reports site (`site/docs/`) generated by `scripts/render_reports.jl` with incremental build (skips existing HTML files), gitignored, deployed to Netlify by `scripts/deploy_site.sh`. Covers **2023–2026** since the August 2026 sweep recovered the 2023/24 rider pools; the year list in `main()` matters only for `--force`, since the index is read off the reports directory
- All data functions use `cached_fetch()` with `CacheConfig` and `force_refresh` parameter
- Rider matching across sources uses `riderkey` (from `createkey()` name normalisation)
- Web scraping: `gettable()` -> `process_rider_table()` via HTTP/Gumbo/Cascadia; `scrape_html_tables()` parses `<table>` elements directly
- Optimisation: JuMP + HiGHS, binary variables for rider selection
- One-day and stage-race paths are deliberately shared where the difference is incidental (`_build_team_model`, `_score_team_points_captured`, `format_rankings_and_alternatives`, `format_near_optimal_section`) and deliberately separate where it is real (`_oneday_prediction_core` vs `_stage_prediction_core` — one simulates a single race, the other 21 correlated stages). When touching one twin, check whether the other is meant to follow
- PCS URLs: `https://www.procyclingstats.com/race/{slug}/{year}`
- VG URLs: `https://www.velogames.com/{race-slug}/{year}/riders.php`
- One-day classics races share one VG URL per year: `sixes-classics/{year}/riders.php` (2026+) or `sixes-superclasico/{year}/riders.php` (≤2025), with startlist hash filtering
- Archival storage: `_prepare_rider_data` automatically archives odds/oracle/PCS specialty data on successful fetch (the one archival side effect Phase 2 deliberately kept — see "Ingest is a phase"); solvers archive predictions after `estimate_strengths`; `archive_race_results` archives post-race PCS and VG results, **skipping whatever is already archived** unless `force_refresh`; `prefetch_race_data` loads archived data for backtesting. The publication path archives nothing: `scripts/ingest.jl` does it as its own phase
- Archival paths: `{archive_dir()}/{data_type}/{key}/{year}.arrow` (`archive_dir()` = ~/Dropbox/code/velogames/archive, overridable with `VELOGAMES_ARCHIVE`) — the 27 data types and their mandatory columns are `ARCHIVE_TYPES`, exported to `_manifest.toml`. `key` is a `pcs_slug` for race types, a **VG game slug** for `vg_riders`, `vg_racelist` and `vg_startlist`, and `{game_slug}_{league_id}` for the `league/*` types. Prediction archives always write `riderkey, rider, team, cost, chosen, selection_frequency, expected_vg_points`; readers warn on legacy pre-April-2026 archives, which cannot be re-created
- VG race URLs: `ridescore.php?ga={game_id}&st={race_number}` where game_id is from `vg_classics_game_id(year)`, `st` is race number 1-44 from races.php
- Backtesting temporal integrity: `estimate_strengths`/`predict_expected_points` accept `race_year`/`race_date` for correct recency weighting; cumulative VG season points prevent end-of-year leakage; archived PCS specialty scores prevent current-day leakage
- Production pipeline: `estimate_strengths` → `resample_optimise!` (avoids Jensen's inequality bias from scoring floor at position 31+). Backtesting pipeline: `predict_expected_points` (MC simulation) for rank-based metrics.

## Commands

- Set up for a race: `cp data/race_config.toml.example data/race_config.toml` then edit
- Run predictor: `julia --project scripts/render_predictor.jl`
- Run team assessor: `julia --project scripts/render_assessor.jl`
- Run stage race predictor: `julia --project scripts/render_stagerace.jl`
- Run backtesting: `julia --project scripts/render_backtesting.jl`
- Local web frontend: `julia --project scripts/serve.jl [--port 8080]`, then open `http://localhost:8080`. Serves a format-adaptive config form, writes `data/race_config.toml`, runs the chosen renderer in-process and serves the report. Long-lived, so it pays the package load and JIT once — but nothing caches the resampled optimisation, so each render is a full solve. Every control carries hover help. Served reports get a back-to-form / re-run bar injected on the way out (never written to the report file, so published reports are unaffected). **`TOML.print` strips comments**: the first save copies the hand-written file to `data/race_config.toml.backup`. A `/render` POST rewrites the config only when it carries the form's hidden `form=1` marker — the bar's Re-run button omits it and so re-runs the config as it stands, rather than reading its absent fields as cleared ones.
- Generate race reports: `julia --project scripts/render_reports.jl` (add `--force` to regenerate all)
- Ingest one race's results: `julia --project scripts/ingest.jl --race=<pcs_slug> --year=<yyyy>`; every race the league has settled but not archived: `--pending`; what the archive already holds: `--status --race=... --year=...` (fetches nothing)
- Ingest Velogames results (the only client that can reach them): `vgleague ingest <league>` or `ingest-all`, from the vgleague clone
- Check the two languages agree: `vgleague verify-keys <league>` (riderkeys), `vgleague verify-races` (race name squashing), `vgleague verify-results <league>` (archived results vs the live pages)
- Publish every race the league has scored: `./scripts/auto_publish.sh` (add `--dry-run` to see what it would do — read-only end to end, so it skips the pull and tells the ingest to write nothing). Normally runs itself from the vgleague hook; see "Unattended publishing" above. There is no manual publishing script — this is the only path
- Take the league scrape into the archive on its own: `julia --project scripts/ingest_league.jl` (`--force` to rebuild `league/rosters`/`league/meta` after changing their frame builders, `--dry-run` to write nothing). Idempotent, and `auto_publish.sh` runs it first
- Correct a published winner: `./scripts/auto_publish.sh --redrive=<pcs_slug>`. Drops the recorded row, derives it again and re-renders in one run — a recorded winner is never re-derived otherwise, and the build skips existing HTML. Seeded rows (empty `snapshot_date`) are refused: no snapshot on disk can re-derive them, so removing one destroys the only record
- Deploy the site without publishing a race (template or style change): `julia --project scripts/render_reports.jl --force && ./scripts/deploy_site.sh`
- Evaluate the league: `julia --project scripts/league_eval.jl` (reads the `[league]` section; point `vgleague_data_dir` at the deploy clone `~/code/vgleague-deploy/data`, which is what the launchd job writes — `~/code/vgleague` is a dev clone and goes stale)
- Audit the archive: `julia --project scripts/archive_audit.jl` (per-type counts plus unknown types, files short of mandatory columns, files with no provenance, stray files). `--write-manifest` rewrites `_manifest.toml` from `ARCHIVE_TYPES`; `--check` exits non-zero when the two disagree
- Run tests: `julia --project -e "using Pkg; Pkg.test()"`

## Conventions

- Julia naming: snake_case for functions, PascalCase for types
- New data functions must support CacheConfig parameter
- Prefer extending existing files over creating new ones
- Scoring categories: Cat 1 = monuments + worlds + Amstel Gold, Cat 2 = WT classics, Cat 3 = semi-classics
- British English spelling throughout (optimise, normalise, colour)

## Keep it simple

This is a small, personal package. Avoid overengineering:

- **No defensive coding** — don't guard against impossible states, add excessive input validation, or handle hypothetical edge cases. Trust the caller.
- **Delete, don't deprecate** — when removing or renaming something, just do it. No deprecation warnings, shims, or backward-compatibility aliases.
- **No unnecessary flexibility** — don't add parameters, config options, or abstractions "for future use". Add them when actually needed.
- **Minimal error handling** — let Julia's built-in errors propagate naturally. Only catch errors at boundaries where you can do something useful.
- **No boilerplate** — skip docstrings for obvious functions, skip type annotations where Julia infers fine, skip comments that restate the code.

## Validating model changes

Match validation rigour to **effect size × mechanistic clarity, not to a sample/race count** — cycling gives ~3 grand tours a year, so a "wait for N races" gate freezes all progress. Ship large, well-understood changes on theory + directional + do-no-harm checks (top-~20 rank ρ must not degrade; no absurd outputs), then monitor prospectively with a pre-registered revisit trigger. Defer only genuinely small metric-chases, until the effect looks material. Rank ρ is invariant to EVG-level changes, so judge those on points-level metrics (PIT, team-points-captured). See `roadmap.md` "Validation philosophy".

## Roadmap

See `roadmap.md` for known issues, planned improvements, ablation findings, and evidence base.
