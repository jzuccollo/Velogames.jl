# Reconciling Velogames.jl and vgleague

Working design note, August 2026. Written after an attempt to answer a league
question ("was 42 credits the cheapest team to beat us all this season?") ran
across the seam between the two packages and found it in the wrong place.

The first two thirds are the durable statement: what is actually there, what the
outputs are for, and which moves are worth making. "The plan of work" at the end
is the worklist that follows from it, sequenced and costed, and it is the part to
read if you are picking the next job up. See `CLAUDE.md` for current architecture
and `roadmap.md` for model work.

## Status

### Decided

- **Modelling and lab outputs stay in Julia; league reporting and its
  calculations go to Python.** Split by audience (lab vs publication), not by
  implementation lineage.
- **Scraping splits by source**: Python owns every Velogames page, Julia owns
  PCS, Cycling Oracle and the odds paste. A property of the websites, so it
  survives changes in what gets built.
- **The archive is the interface.** No RPC, no callable Julia modelling
  service, no `juliacall`. Reading PCS-derived tables is not scraping PCS.
- **One public site**, merged at the URL level (vgleague builds into
  `site/docs/league/`), not one codebase.
- **Dropbox stays** as the archive root, with single-writer discipline and
  idempotent-by-content writes.
- **League snapshots deduped by content hash** — one file per genuine state
  change, not one per scrape.
- **Not doing**: merging the codebases, unifying the scrapers into one
  language, rewriting the model in Python, building a pipeline framework.
- **Archive files move to `.arrow`**, not a `.feather` extension carrying Arrow
  IPC content. Clearer, and the rename forces the hand-rolled path builders
  through `archive_path` (see WP1a) — which is worth doing on its own.
- **Team names are recorded as at the time of the race.** Dated raw snapshots
  are therefore the source of truth, and re-deriving a winner must read the
  snapshot contemporaneous with the race, never the latest one.
- **Dropbox is written from one place at a time**, by one person. Conflict
  handling can stay a convention rather than machinery.
- **The whole programme lands as one merge.** Work sits on the
  `two-package-reconciliation` branch until it is finished, rather than merging
  phase by phase. See "Operating constraints while the branch is unmerged".
- **The vgleague hook gets paused** for the archive-mutating work rather than
  the migration being reshaped to keep unattended publishing alive through it.
  A short pause is acceptable; the site keeps serving every report it already
  has throughout, and only a new race would be delayed.

### Tested (August 2026)

- **Arrow IPC migration works.** Arrow.jl writes; Julia round-trips the
  151-row × 21-col Hamburg prediction archive with `isequal == true`; pyarrow
  25.0.1 reads the result through both `pa.ipc.open_file` and
  `feather.read_table` with warnings-as-errors and no deprecation; `Int64`,
  `Bool`, `String` and `Float64` all survive. **Still required**: the current
  archive is Feather V1 (Feather.jl v0.5.10, end-of-life) and pyarrow warns
  that V1 support "will be removed in a future version", so the migration plus
  a one-off rewrite of the archive stays on the critical path. A later census
  read all 556 V1 files without a single failure, and every column came back a
  plain `Vector` of `Int64`, `Float64`, `Bool` or `String` — no
  `CategoricalArray`, which is the type-fidelity trap in the round-trip.
- **Playwright looks unnecessary.** Ten cold sequential `teamroster.php`
  fetches — plain curl, browser UA, no warmup, no cookies, no referer, 1.5 s
  apart — returned 10/10 usable responses (`http=200`, 14+ `<h4>` blocks).
  Caveat: a full update is 364 requests, so this is strong but not conclusive.
- **`Start List` is classics-only.** The classics `riders.php` carries
  `Rider | Team | Start List | Class | Points | Cost` with `#CyclassicsHamburg`
  as the live value. The Tour, Giro and Femmes pages carry
  `Rider | Team | Class | Cost | Selected | Points` — **no `Start List`**, and
  none needed: a grand tour's rider list *is* the field. Python's per-race
  persistence must branch on format (classics filter by hash, GT take all).
  Both formats do expose `Class`, which the 9-rider constraints need.

### Undecided — needs a call

- **Whether the race reports ever port to Python** — deliberately deferred
  until the two halves have coexisted for a season.
- **Whether Julia's VG fetchers keep their scrape fallback permanently** or
  become archive-only once Python's coverage is complete.
- **Where entrant pages sit** in the URL structure and navigation.
- **Whether to consolidate the odds/oracle market families** — `odds`,
  `odds_kom`, `odds_points`, `odds_stagewin`, `oracle`, `oracle_kom`,
  `oracle_points` could be two types with a `market` column. Recommendation is
  no: a schema change through the estimation path for no functional gain.
  Document instead.

## Established facts

### The vgleague archive is complete

Every entrant's roster, with per-rider cost and per-rider score, exists for
every race of 2026:

- **Classics** (`sixes-classics_2026_100737112.json`): 26 scored races × 14
  entrants, all with `riders`, `rider_costs`, `rider_scores`.
- **Tour** (`velogame_2026_192866016.json`): 17 entrants × 22 rows (21 stages +
  End-of-Tour), per-rider scores at **stage** granularity.
- Giro and Femmes snapshots are the same shape.

**`meta.captured_pick_races` is not a coverage field.** It flags races where
pre-deadline picks were captured live, and is read only by `check.py` for
dedup. Reading it as "the races we have rosters for" (as this note's author
first did) understates coverage by 24 races. Roster coverage is total.

So there is a full **ownership × price × points panel** for the whole season,
per entrant, per rider, per race, and per stage for grand tours. Anything
phrased as "we can't backfill that" is almost certainly wrong.

### What each package is and does

| | Velogames.jl (Julia, ~25k lines) | vgleague (Python, ~5.6k lines) |
| --- | --- | --- |
| Ingest | PCS + VG race facts → Dropbox feather archive | VG league facts → local JSON |
| Analysis | Bayesian model, backtest, calibration | — |
| Private output | predictor / stagerace / assessor / backtesting | — |
| Public output | race reports, rider dossiers, index | standings + bump chart, per-race selection matrix |
| Deploy | Netlify, `site/docs/` | Netlify, `site/` |

Coupling today is one-way, vgleague → Velogames.jl:

- vgleague's `POST_UPDATE_HOOK` fires `scripts/auto_publish.sh`.
- `load_league_standings`, `load_league_team` and `auto_publish.jl` read
  `~/code/vgleague-deploy/data/*.json` directly.
- Nothing in vgleague reads the feather archive.

The two published sites do not link to each other.

## The seam is cut by lineage, not by audience

The split today is "the Julia thing" and "the Python thing". The split that
matters is:

- **The lab** — the model, backtests, calibration, `league_eval`, the roadmap.
  Instruments, read by one person, entirely inside Velogames.jl.
- **The publication** — race retrospectives, rider dossiers, standings,
  selection matrix, league stats. Read by ~14 people, on a phone, via a
  WhatsApp link. **Split down the middle across both repos.**

That is the whole of the confusion. `scripts/render_reports.jl` (2,495 lines,
publication) sits beside `scripts/render_backtesting.jl` (2,260 lines, lab) as
though they were the same kind of artefact. They share only a language.

The audience question settles the site question: **there should be one public
site.** Three URLs for one league's Saturday is worse for the reader, and none
of the reasons for the split are reader-facing.

## The missing entity is the entrant

The pages are organised by concern rather than by entity. By entity:

| Entity | Page | Status |
| --- | --- | --- |
| Race | what happened + how we played it + what the model said | exists; the league half is one sentence |
| Rider | season arc, price vs points, who owned them | exists (`riders.html`) |
| **Entrant** | **season arc, picks, regret, head-to-heads, contrarian index** | **does not exist** |
| Season | standings, bump chart, records | exists, on the other site |

Every league stat is a cell in that grid: one-swap is race × entrant, the
contrarian index is entrant × season, the ownership curse is rider × season.
The selection matrix is race × entrant × rider, which is why it is the densest
and least readable page — a raw fact table where the others are narratives.

The entrant page is the gap, it is the page people will actually click
(it is about them), and it is the one **neither package can build alone**: it
needs vgleague's rosters and Velogames.jl's price/points/optimal-team
machinery in one process.

## The data layer is the real problem

Three stores, one of them load-bearing and not durable:

1. `~/Dropbox/code/velogames/archive/` — race facts, feather, backed up.
2. `~/code/vgleague-deploy/data/*.json` — league facts, gitignored
   (`.gitignore:144`), machine-local, **backed up by nothing**.
3. `archive/league_winners.toml` — a five-field summary of (2), living in (1).

**(3) is a symptom of (2).** It exists because the source of truth lives
somewhere unreliable, and re-deriving it reproduces only 25 of 29 entries.
Move the snapshots into the archive and it can be deleted outright: winners get
derived at render time, `auto_publish`'s append-only-record handling goes away,
and the "correct a published winner" procedure in `CLAUDE.md` goes with it.

**Open question before doing that:** re-deriving from a live snapshot lets team
renames rewrite history (Paris-Roubaix is already recorded under a name its
winner no longer uses). If the name-at-the-time matters, snapshots must be
dated and immutable rather than overwritten in place. A deliberate choice, not
a bug to reflex-fix.

**Duplicated ingest.** Both packages independently scrape `races.php` for the
race catalogue. Velogames.jl then carries `CLASSICS_RACES_2026` and
`normalise_race_name` largely to reconcile its race names with vgleague's names
for the same endpoint. That reconciliation is integration tax paid for having
two scrapers of one source.

## The layer boundary already exists, and it is the archive

A tempting move is to turn Velogames.jl into a callable modelling service that
vgleague invokes — a clean ETL / estimation / reporting split with an RPC
interface in the middle. **It would have no caller.**

**The publication layer never touches the model.** `scripts/render_reports.jl`
(2,495 lines, every race report and rider dossier) contains zero calls to
`estimate_strengths`, `solve_oneday`, `solve_stage`, `resample_optimise!` or
the prediction archives. Its whole dependency on the package is:

1. archive readers — `load_race_snapshot`, `load_report_data`,
   `load_stage_race_report_data`, `list_completed_races`, `load_league_winners`;
2. four knapsacks over *realised* scores — `compute_optimal_team`,
   `compute_cheapest_winning_team` and their stage-race twins;
3. five HTML primitives from `report_html.jl` (227 lines) — `html_page`,
   `html_heading`, `html_table`, `plotly_html`, `commafmt` — one chart function
   (`line_chart`), and 14 direct `PlotlyBase` constructions.

It uses **none** of `report_formatters.jl` (925 lines — prediction reports
only) and seven of the eight functions in `report_charts.jl` go unused. That is
not an accident of implementation: retrospectives are about what happened, the
model is about what might. The league stats are the same — cheapest-team is a
MILP over realised scores, ownership and one-swap are arithmetic over rosters.
The only model-flavoured thing a race page could want is "what the model
advised", and that is a read of a `predictions` feather file.

**The archive is the interface.** `{data_type}/{pcs_slug}/{year}.feather`,
language-neutral, on disk, already versioned (`schema_version` on predictions).
Estimation writes; reporting reads; neither calls the other. For a
cron-driven batch workload that beats an RPC boundary: `using Velogames` alone
costs **5.9 s** before any JIT (which is why `serve.jl` exists to amortise it),
so per-call invocation from Python would be painful and a daemon means running
a Julia process for a site that changes twice a week. Files are also
inspectable and survive both processes.

What is missing is not the boundary but the discipline around it: a documented
schema per `data_type`, a named writer, and a rule that reporting reads only
archive files. If a Python caller ever does appear, the mechanism should be a
batch CLI over those files — not `juliacall`, not a service.

### Where the internal layering actually leaks

Worth fixing on its own merits (testability, not interop). The split is roughly
right already — `get_data.jl`/`pcs_scraper.jl`/`pcs_extended.jl` are ETL,
`bayesian_core.jl`/`strength_pipeline.jl`/`simulate_*.jl` are estimation,
`report_*.jl` are presentation. The leaks are specific:

- **`data_assembly.jl` (1,287 lines) is three modules in one file**: signal
  assembly for the estimator, report-data loading for the publication, and
  league-standings loading for both. Split this first — it is where the league
  work is about to land.
- **`race_helpers.jl` holds `RenderConfig`**, a renderer's config object in a
  core module the estimator also imports.
- **`build_model.jl` mixes** the production optimiser (`resample_optimise!`,
  estimation-adjacent) with the retrospective knapsacks (publication-only).
- **`render_reports.jl` triggers ETL**: `_ensure_results_archived` calls
  `archive_race_results`, so rendering a report can scrape PCS and VG.
- **`load_report_data` scrapes rider costs**: it calls
  `getvg_riders(vg_classics_url(year))` for the cost column, so the reporting
  path is *not* archive-fed. Cached, but a network call in principle. Archive
  the VG rider list as its own `data_type` per race and year and this becomes a
  pure join of archived facts — which also means a report re-rendered in 2029
  uses 2026 prices rather than whatever the page serves then.

The last two are what constrain any future port: Python has neither scraper.

Splitting these makes the reporting layer testable against fixture feather
files with no model in the loop, and the estimator testable with no archive.
It is mostly moving functions between files.

## Could reporting move wholesale to Python?

Technically yes, and the surface is thinner than it looks — see the dependency
list above. Nothing on the publication path needs Julia in principle:
`pyarrow` reads feather, a 6-of-150 binary knapsack is twenty lines of PuLP or
OR-tools, and vgleague already hand-rolls HTML strings and renders Plotly, so
the idiom is identical to what `render_reports.jl` does.

Three things to weigh before treating that as a plan:

- **Scope is ~2,500 lines with no reader-facing benefit.** The reader sees the
  same pages. It buys single-language ownership of the publication layer, not
  a better site.
- **The ETL trigger must be decoupled first.** `_ensure_results_archived`
  means rendering can scrape; Python has no PCS/VG results scraper. Archival
  has to become an explicit pipeline step ahead of rendering.
- **Knapsack ties are a live bug, not just a port risk** — see below.

The solver itself is not an obstacle. A PuLP/CBC port of both knapsacks is ~25
lines and runs the Hamburg field in **0.5 s including interpreter startup**,
against 5.9 s just to `using Velogames`. It reproduced the hindsight-optimal
team exactly and the cheapest-beating **cost** exactly. Most league stats need
no solver at all: head-to-heads, contrarian index, ownership curse and the
one-swap regret table are arithmetic over rosters (one-swap is a 6 × 150 scan).
Only the perfect team and the cheapest-beating team are MILPs.

### Bug found: both retrospective teams are under-determined

`compute_cheapest_winning_team` minimises cost subject to
`score >= target + 1` **and nothing else**, so every min-cost team clearing the
target is optimal and the solver returns whichever it finds first. Verified on
Hamburg 2026: HiGHS returns Behrens (4 cr, 135 pts) for a 1,332 total, CBC
returns Toneatti (4 cr, 76 pts) for 1,273. Both cost 42; both are correct.
**The published report has been showing an arbitrary member of a tie set.**

Solving it lexicographically — minimise cost, then maximise score among
min-cost solutions — gives 1,332, which is what Julia happened to show. Right
by luck, not construction.

Fix in `compute_cheapest_winning_team` and
`compute_cheapest_winning_stage_team`: solve for min cost, then re-solve with
cost pinned and score maximised. Worth doing now, independent of any port —
it makes the displayed team reproducible across solvers, which is precisely the
property a port would need. The headline *number* is unaffected: minimum cost
is unique even when the team is not, so the season table stands.

**And the same defect sits in the other pair, which the fix missed.**
`compute_optimal_team` and `compute_optimal_stage_team` maximise score subject
to budget and nothing further, so the hindsight-optimal team — the "perfect
team" headline on every race report — is likewise whichever member of its tie
set the solver reached first. The commit that shipped the cheapest-team
tie-break is titled as though it covered this; it did not. Same two-solve fix,
inverted: maximise score, then minimise cost among max-score teams. See Phase
0.2.

**The incremental path avoids the choice.** The growth area — entrant pages,
league stats, head-to-heads — is Python-shaped already (rosters, ownership,
standings) and needs no Julia at all. Build those in vgleague, publish them
into the same site as the Julia-rendered race reports, and let the two halves
coexist for a season. That delivers value at every step and answers the port
question with evidence rather than prediction: if the Julia half turns out to
be a burden, port it then; if it just sits there working, leave it.

## ETL: the pipeline and the storage contract

Settled: modelling and lab outputs stay in Julia, league reporting and its
calculations go to Python. ETL is the part that does not divide along that
line — Julia scrapes PCS and the Velogames public pages, Python scrapes the
league pages — so it needs its own answer.

### The Playwright requirement is probably not real

`scraper.py` justifies Playwright on the grounds that "some WAFs serve an empty
/ challenge response to clients that hit deep URLs without a prior natural
pageview". Tested August 2026 and not reproduced: a **cold** `teamroster.php`
fetch (plain curl, browser UA, no warmup, no referer, no cookies) returns 200
with the full roster — 14 `<h4>` blocks, rider names present.
`leaguescores.php` likewise returns all 14 teams and their `tid` links.

More telling, both captured failures in `vgleague/data/` are origin errors, not
challenges: `title: Whoops! There was an error.`, `status: 500`,
`cf-cache-status: DYNAMIC`. **Playwright cannot fix a 500; a retry can.** The
only recorded evidence for the browser requirement does not support it.

Not grounds to rip it out on one request — a 14 × 26 sweep is a different
traffic pattern, and WAF behaviour changes — but worth a proper test, because
if it holds then the ETL language split is incidental rather than forced.

### What exists

Julia, ~20 fetchers (`get_data.jl`, `pcs_scraper.jl`, `pcs_extended.jl`): PCS
rankings / specialty / results / startlists / race history / rider seasons /
stage profiles, VG `riders.php` + `races.php` + `ridescore.php`, Cycling
Oracle — all plain HTTP — plus bookmaker odds as a **human paste**.

Python, `scraper.py` (834 lines): `races.php`, `leaguescores.php`,
`teamroster.php`, `riders.php`.

**Both scrape `races.php`; both scrape `riders.php`.** Julia then carries
`CLASSICS_RACES_2026` and `normalise_race_name` largely to reconcile its names
against vgleague's names for the same endpoint.

Storage is three unlike things: the Julia cache (parsed frames, URL-hash keyed,
7-day TTL, `~/.velogames_cache`, 18,983 files / 84 MB, disposable); the Julia
archive (25 semantic types, `{type}/{slug}/{year}.feather`, Dropbox, 556 files
/ 18 MB, backed up); and vgleague's one nested JSON per league-season in a
gitignored repo directory with **no backup at all**.

### Five problems

1. **There is no ETL phase.** Archiving is a side effect of whatever ran:
   `_prepare_rider_data` archives odds while *estimating*, `render_reports.jl`
   archives results while *rendering*, `load_report_data` scrapes costs while
   *loading a report*. Nothing's job is fetch-and-store, so "is race X's data
   complete?" cannot be answered without running a renderer.
2. **The irreplaceable half has the weakest storage.** PCS and VG race results
   are re-fetchable for years; a league's rosters exist only while the league
   does. That is the dataset with no backup, overwritten in place each scrape.
3. **No provenance.** `vg_results` is `[rider, team, score, riderkey]` — no
   `fetched_at`, no `source_url`, no `schema_version` (only `predictions` has
   one). VG also revises scores for ~24 h after a race and nothing records
   which side of the revision a row came from.
4. **The type namespace has already drifted**: `prediction` (1 orphan file)
   beside `predictions` (28); `stage_profiles` (5) beside `pcs_stage_profiles`
   (12); `pcs_breakaways` with 0 files. Nobody wrote those on purpose.
5. **Paths are hardcoded or cross-repo.** `DEFAULT_ARCHIVE_DIR` is a `const`;
   vgleague's location is a TOML key pointing into a sibling clone.

### Design: the archive is the data plane, ingest is a phase

**Two tiers, made explicit.** *Cache* — ephemeral, URL-keyed, TTL'd,
machine-local, disposable, unchanged, and deleting it must never lose anything;
each language may keep its own. *Archive* — permanent, semantically keyed,
backed up, the contract, rooted at `$VELOGAMES_ARCHIVE` (defaulting to today's
path) and read by both packages, replacing both the Julia `const` and
vgleague's `vgleague_data_dir` reach-in.

```text
$VELOGAMES_ARCHIVE/
  race/{data_type}/{pcs_slug}/{year}.arrow
  league/raw/{game_slug}_{year}_{league_id}/{YYYY-MM-DD}.json   # dated, append-only
  league/rosters/{game_slug}_{league_id}/{year}.arrow            # entrant × race × rider × cost × score
  league/meta/{game_slug}_{league_id}/{year}.arrow               # catalogue, deadlines, categories
  _manifest.toml                                                 # machine-readable dictionary
  _runs/{YYYY-MM}.arrow                                          # one row per pipeline run
```

- **Dated, never-overwritten raw league JSON** is the fix for the team-rename
  problem, not an extra tier for its own sake: names mutate at source, so the
  only honest record is what the site said on a given date. It also retires
  `league_winners.toml` — winners become derivable *and* reproducible, from the
  snapshot taken the week of the race.
- **Normalised league tables in feather, not JSON.** `load_league_standings_json`
  exists only because the storage is nested. Costs vgleague a `pyarrow`
  dependency it needs anyway once it reads the race archive.
- **A run log** makes "why didn't Hamburg publish?" answerable without reading
  launchd logs.
- **Format: Arrow IPC, not Feather V1.** The archive is currently Feather V1
  (Feather.jl v0.5.10, end-of-life). pyarrow 25.0.1 reads it but warns that
  V1 support "will be removed in a future version". Since the entire design
  rests on Python reading this archive, migrating Julia to Arrow.jl and
  rewriting the existing files is a Phase 1 item, not a tidy-up.

**Provenance** — `fetched_at`, `source_url`, `machine`, `schema_version`,
written by the archive helper rather than by callers, and written as **Arrow
schema metadata rather than as columns**: the grain of a fetch is the file, and
two archived frames already get joined in the estimation and evaluation paths,
where a `fetched_at` on both sides lands as `fetched_at_1`. See WP5 for the full
argument. No backfill: new writes carry it, the dictionary records which types
were retrofitted when.

**Ingest as a real phase** — two idempotent commands whose only job is
fetch-and-store (`velogames ingest --race … --year …`,
`vgleague ingest --league …`), with archival stripped out of estimation,
rendering and report loading. This requires archiving the VG rider list as its
own type, which is what makes `load_report_data` archive-only — the gate on
Python owning reporting, so it is on the critical path.

### One owner per source: Python takes all of Velogames

The stable boundary is the **source site**, not the consuming feature.

| Scrapes | Owner | Why |
| --- | --- | --- |
| All VG pages — `riders.php`, `races.php`, `ridescore.php`, `leaguescores.php`, `teamroster.php` | **Python** | One site, one session story, one set of table parsers; kills the double-scrape of `races.php` and `riders.php` |
| PCS, Cycling Oracle, odds paste | **Julia** | Nothing else touches them; ~1,500 lines of working, site-coupled parsing with no reason to move |

**Reading PCS data is not scraping PCS.** The rider dossiers need
`pcs_results`, `pcs_gc_results` and `pcs_abandons` — but only to render finish
labels ("3rd", "DNF", "GC 5th"), which VG cannot supply (`vg_results` is
`[rider, team, score, riderkey]`, no position, and VG score bundles finish +
assist + breakaway so position cannot be inferred). Those three are feather
files in the archive; Python reads them with pyarrow. So publishing
PCS-derived facts from Python requires **none** of the PCS scraping to move.
This is the payoff of the archive-as-data-plane: the language that renders a
fact need not be the language that fetched it.

**What Python actually has to build** is small, because vgleague already
scrapes two of the three pages:

- `riders.php` — already scraped by `scrape_current_startlist`, which already
  extracts costs, classes *and* the Start List column (verified August 2026:
  headers are `Rider | Team | Start List | Class | Points | Cost`, with
  `#CyclassicsHamburg` as the live value; 1,177 season rows, 154 Hamburg
  starters). The work is **persisting it per race**, not new scraping — and it
  is what makes starters knowable from VG alone, since the page only ever shows
  the current race.
- `races.php` — already scraped, with deadlines and categories.
- `ridescore.php?ga={game_id}&st={race_number}` — the one genuinely new
  fetcher. vgleague already holds `game_id` and race numbers, and it is a plain
  table of the kind it parses four times already.

One new fetcher plus one persistence change buys Python complete independence
for every league stat, full-field ones included — the 42-vs-60 failure above
disappears at source, because the field arrives from the same scrape as the
rosters.

**Wrinkle: the backtester.** Julia consumes `vg_results`, `getvg_race_list` and
`getvg_race_points` across historical years Python has not ingested and may
never. So Julia's VG fetchers become **archive-first with a scrape fallback** —
read the archive, scrape only when the year or race is absent. New races arrive
via Python's ingest; old ones stay reachable. The cost is VG parsing existing
in both languages permanently; it already does, and it changes about once a
year. The alternative — backfilling every historical VG season in Python purely
to serve the lab — is work in service of nothing anyone reads.

**Orchestration: formalise the chain that exists.** vgleague's launchd jobs
already hold the lock, the gating and the probe; `POST_UPDATE_HOOK` already
reaches across. Keep it, but give it phase boundaries —
`ingest-league → ingest-race → derive → render → deploy` — each independently
runnable, idempotent, and logging to `_runs/`. `auto_publish.jl` loses its
winner derivation and becomes render+deploy.

**Documentation** — `docs/data-dictionary.md`: one row per `data_type` with
grain, columns, writer, readers, cadence, schema version, and **whether it is
re-fetchable or irreplaceable**. That last column is the one that matters: it
is what says league rosters need backup and `pcs_seasons` does not. Plus
`_manifest.toml` in the archive so the write helper can validate type name and
columns — the minimum that stops `prediction`/`predictions` recurring. No
schema registry, no migration framework.

### The cross-package dependency, and its silent failure mode

Today vgleague depends on nothing from Julia. **Once reporting moves to Python
it will, and the failure mode is a wrong answer rather than an error.**

The league snapshot holds costs and scores only for riders somebody *picked*.
There is no full-field data in it at all — top-level keys are just `meta` and
`teams`; no rider table, no costs table. Hamburg 2026: the field was 154
starters, the league collectively picked **34** of them, 22% coverage.

Running the cheapest-team calculation on the pool Python would have if
`vg_results` were missing:

| Pool | Riders | Cheapest team beating 1,260 |
| --- | --- | --- |
| Full field (`vg_results`) | 154 | **42 credits** |
| League-picked only | 34 | **60 credits** |

No exception, no empty result — a plausible six-rider team (Magnier, Pithie,
Hobbs, Artz, Stockwell, Giddings) and a number **43% too high**.

**Sequencing trap.** `_ensure_results_archived` currently *masks* this: render
triggers ingest, so the data is always present by the time the stat runs.
Removing that layering violation without first adding a precondition check
introduces the bug. The cleanup and the guard must land together.

**Response — classify stats by data requirement and make the tiers
structural.** Roster-only (publish unconditionally): standings, spread,
head-to-heads, ownership, contrarian index, consensus team, best/worst pick
among picks, costliest zero among picks. Field-required (hard precondition):
optimal team, cheapest-beating team, unowned top scorers, best available
one-swap, best value in field, points left on the table.

- **An explicit completeness marker per race** — which types are present, row
  counts, `fetched_at` — checked before any field-required stat. On failure the
  page renders roster-only sections plus a visible "awaiting full results"
  note, and re-renders when ingest catches up.
- **Make the wrong pool unreachable.** Python stat functions take the field
  frame as a required argument sourced only from the archive, with no fallback
  to a roster-derived rider list. The 60-credit answer should not be
  expressible.

This also covers Dropbox partial sync: a half-synced archive fails the same
check and holds the section back instead of publishing a confident wrong
number.

### Unattended operation is the governing constraint

The publish path must work with nobody at the keyboard for weeks. It already
does, and **the mechanism is the layering violation this note proposes to
remove**, so the replacement has to land in the same change.

`render_reports.jl` reads no config at all — no `race_config.toml`, no
`RenderConfig`. `auto_publish.jl` reads one key (`[league] vgleague_data_dir`).
The cron already runs Julia, and `_ensure_results_archived` scrapes PCS and VG
results on that path; `auto_publish.sh` says so in comments. **Running the
predictor has never been a precondition for a race report.** The two were
coupled by habit, not by code.

So `_ensure_results_archived` is load-bearing for unattended operation, not
merely untidy. Delete it without a replacement and the holiday case breaks.
The replacement is the same work, promoted to a phase:

```text
ingest-vg (Python) → ingest-pcs (Julia) → render → deploy
```

All four unattended, on the existing vgleague hook. Julia still runs on the
cron — invoked as `velogames ingest`, not smuggled in via a renderer. As an
explicit phase it either ran or it did not, and `_runs/` records which; as a
side effect it works only while the call order happens to hold.

**Degradation if `ingest-pcs` fails while away**: rider dossiers lose finish /
DNF labels, stage-race reports lose GC and abandon sections, GTs lose stage
profiles. **Every league stat is unaffected** — they are VG-only. The tiering
therefore degrades in the right direction: the WhatsApp-facing content
publishes, PCS detail appears on the next successful ingest and re-render.
Today's behaviour is harsher — a failed `archive_race_results` warns, then
`load_report_data` returns nothing and the race gets **no page at all**.

**Worse than that, and worth naming as a defect rather than a degradation.**
The failure is swallowed at three levels: `archive_race_results` warns per
source and returns nothing, `_ensure_results_archived` warns and returns, and
`main()` skips the page and exits 0. Meanwhile `auto_publish.sh` has already
`rm -f`'d that race's existing HTML — correct on its own terms, since the
incremental build only regenerates what is absent — and `deploy_site.sh` checks
only that `index.html` exists. So a transient Velogames or PCS outage during the
unattended publish **deletes a good report and deploys the site without it,
while the script prints "published"**. The winner has been appended by then, so
the next tick treats the race as done and nothing re-renders it. Phase 0.3 makes
that exit non-zero; the archived winner then survives for the retry.

**What genuinely needs a human**: the odds paste and the Oracle URL. Away from
the keyboard there is no `odds` archive and no prediction for that race, which
costs a gap in the prospective-evaluation record and a missing row in
`league_eval`. It costs the league nothing — race reports do not read
prediction archives. A holiday loses the lab a data point and the site nothing.

### Multi-machine storage

Dropbox is fine for distribution, risky for concurrent writes, and the archive
has the risky shape — `{type}/{slug}/{year}.feather` is overwritten in place,
so two machines re-archiving one race yield a silent conflicted copy.

- **Idempotent-by-content writes**: hash the frame, compare with disk, skip if
  identical. Nearly every re-archive is a no-op, so nearly every conflict
  disappears. Same mechanism as the league-snapshot dedup below.
- **Single-writer discipline**: one designated ingest machine (the one with the
  launchd jobs); others read. Already true in practice — make it explicit.
- **A `machine` provenance field**, so a conflicted copy can be attributed
  rather than guessed at.

**League snapshot dedup**: write `{YYYY-MM-DD}.json` only when its content hash
differs from the newest existing snapshot; a same-day re-scrape overwrites the
same filename. One file per genuine state change — roughly 40 a year rather
than 700, and every one marks a real change.

### ETL: what not to do

**Do not unify the scrapers into one language.** They are the most site-coupled,
least reusable code in either package, they both work, and rewriting either buys
risk and nothing else. Share the storage schema, not the scraping code.

**Do not move the cache into the archive.** Different lifecycles; conflating
them puts 84 MB of hashed junk in Dropbox.

**Do not build a pipeline framework.** Five shell phases and a lock is the right
size for something that publishes twice a week.

## The plan of work

Supersedes the lists this note carried while it was being drafted. Phase 0 is
standalone fixes that block nothing and are worth having whatever else happens.
Phase 1a is written to task level because its dependencies are known; the later
phases are outlines with entry conditions, because 1a and 2 are what settle their
detail.

All of it lands on the `two-package-reconciliation` branch, unmerged until the
programme finishes — read "Operating constraints while the branch is unmerged"
before starting anything from WP2 onwards, because that is where the work stops
being confined to the repo. **Next job: WP5.**

WP1d (capturing the VG pages that retire) was inserted ahead of WP5 in August 2026 —
see "WP1d" below. It had to precede WP5 so the manifest is written once, over the
final type inventory including `vg_riders` and `vg_racelist`.

| Phase | Work | State |
| --- | --- | --- |
| 0 | Two solver tie-breaks, a publish-path guard, one re-render | code shipped; re-render deferred to WP1b |
| 1a | Archive hygiene: Arrow, retirements, the write-time guard | WP1a, WP2, WP3, WP1b shipped; next WP5, then WP4 |
| 1b | League data into the archive; retire `league_winners.toml` | after WP5 |
| 1c | Python persists `riders.php` per race | after WP5 |
| 2 | Ingest as a phase, with completeness markers | after 1b and 1c |
| 3 | League recap and entrant pages in Python, one site | after 2 |
| 4 | Optional: lab/publication split, report port, drop Playwright | evidence-led |

### Operating constraints while the branch is unmerged

Git isolates the code. It does not isolate the two things this programme
actually mutates: the **Dropbox archive** and the **live site**. Meanwhile
`~/code/velogames-deploy` keeps running `main` from the vgleague
`POST_UPDATE_HOOK` on every race, so `main`'s code and the branch's data
assumptions can part company without a single merge conflict to warn anybody.

That splits the remaining work in two:

- **Safe unmerged, indefinitely**: Phase 0 and WP1a. Pure code, touching no
  file outside the repo.
- **Mutates state `main` still reads**: WP2 (moving `pcs_form`, `qualitative`
  and `pcs_breakaways` out of the archive), WP3 (retiring the narrow
  `stage_profiles` files), WP1b (rewriting every archive file to Arrow) and
  Phase 1b (moving the league snapshots in).

**WP1b is the forcing point**, since it is a hard cutover by design: the moment
the migration script runs, `main`'s Feather reads fail and the next race breaks
the unattended publish. The chosen answer is to pause the vgleague launchd jobs
for the duration rather than merge early or build a dual-read path the note has
already argued against.

The sequence that keeps the site honest through it:

1. Put a maintenance banner up **before** touching the archive — one deploy of
   the existing `site/docs/` with nothing re-rendered.
2. Pause the vgleague jobs. Run WP2, WP3, WP1b.
3. `render_reports.jl --force`, drop the banner, deploy. That is Phase 0.4,
   folded in at the end, and it doubles as WP1b's verification: a forced
   re-render exercises every archive read path in the reporting layer against
   the converted files.
4. Unpause.

**The banner belongs in Netlify, not in the templates.** Snippet injection
(Site configuration → Build & deploy → Post processing) adds raw HTML to every
page at deploy time with no repo change and no re-render, and comes back off
the same way — worth confirming in the dashboard that it still applies to
`--dir` deploys from the CLI. A banner in `html_page` would instead need a
forced re-render of all 72 pages to appear, which is the one thing that cannot
be done mid-migration. Netlify's other lever, a `_redirects` 503, takes the
site down rather than annotating it, and is the wrong tool.

Cheapest option of all: run the migration in a gap in the race calendar, and
the question does not arise.

### Phase 0 — standalone fixes

**0.1 Cheapest-beating team tie-break — shipped, August 2026.**
`_cheapest_winning_core` in `build_model.jl` solves min-cost, then max-score among
min-cost teams, shared by `compute_cheapest_winning_team` (6 riders, no classes) and
`minimise_cost_stage` (9 riders, classes) exactly as `_build_team_model` is shared.
`totalcost` is a live constraint in both — it was an ignored parameter on
`minimise_cost_stage`, and the one-day version had no budget cap at all, so either
could return a team that was never fieldable. **20 of the 26 completed 2026 classics
had a tie set the old code resolved arbitrarily**, some of them wide: Copenhagen
Sprint's 28-credit teams span 1,217–1,421 points and Eschborn-Frankfurt's
34-credit teams span 1,266–1,444. Minimum *cost* is unaffected in every case, so the
season table stands; the displayed *team* changes.

**0.2 Hindsight-optimal team tie-break — shipped, August 2026.**
`compute_optimal_team` and `compute_optimal_stage_team` now maximise score, then
minimise cost among max-score teams. The two-solve shape was extracted rather than
copied: `_lexicographic_team` in `build_model.jl` takes a feasible-set closure and two
(sense, column) pairs, and `_cheapest_winning_core` was rewritten onto it, so the two
retrospective pairs are one implementation differing only in the order of the
objectives. `_build_team_model` split into `_team_model` (constraints, no objective)
plus the solve, which is what let the cheapest-team core stop carrying its own copy of
the constraint set.

**Impact is small, unlike 0.1**: 2 of 26 completed 2026 classics change their
displayed optimal team (Strade Bianche and Nokere Koerse, both reaching the same
score for 98 credits rather than 100), and none of the three grand tours does. Score
ties are rarer than cost ties because the objective is a wide-range integer. The
backtest's `opt_team_pts` uses the same knapsack but sums only points, so no
backtest metric moves.

Tests: `test_optimisation.jl` gains a "Retrospective team tie-breaks" set with a
deliberate tie in each of the four functions, asserting the pinned member is the one
returned — the guard 0.1 never got, now covering both halves.

**0.3 The publish path must fail loudly — outstanding.** Three swallowed failures
compound into a wrong site. `archive_race_results` warns per source and returns
nothing; `_ensure_results_archived` warns and returns; `load_report_data` then
returns `nothing`, `main()` skips the page and exits 0 — after `auto_publish.sh` has
already `rm -f`'d the previous HTML so the incremental build would regenerate it, and
`deploy_site.sh` checks only that `index.html` exists. **A transient VG or PCS outage
therefore deletes a good report and deploys the site without it, while the script
prints "published".** The winner is already appended by then, so the next tick skips
the race and nothing re-renders it.

**Shipped, August 2026.** The fix is a count, not machinery, and it checks the end
state rather than tracking attempts: after both render loops, `main()` asserts that
every recorded league winner in the requested years has a `reports/{slug}-{year}.html`
on disk, prints the ones that do not, and exits 1. Checking the file catches all three
failure paths at once, the `list_completed_races` one included — a race that never
reached the loop cannot be tracked by a loop. `auto_publish.sh` already aborts on a
render failure, so that is enough to hold the deploy and leave the appended winner for
a retry. Verified both ways against the live archive: all 29 recorded winners pass,
and removing one page fails with exit 1. This makes the failure loud; it does not make
`_ensure_results_archived` unnecessary, which is Phase 2's job.

**0.4 Re-render and deploy — outstanding.** 0.1 changed the displayed cheapest team
on 20 of 26 races and 0.2 changes the displayed optimal team on 2 more, so the
per-race `rm` list this note used to carry is no longer the cheap option:
`julia --project scripts/render_reports.jl --force && ./scripts/deploy_site.sh`,
once, from the clone that holds the rendered site. By hand — publishing is a
deliberate act. Note that `site/docs/` is build output and a dev clone's copy is
typically empty, so this belongs in `~/code/velogames-deploy` after it has pulled the
0.1–0.3 commits.

**Deferred to the WP1b landing**, deliberately. The displayed numbers are already
right — minimum cost is unique even when the team achieving it is not, and the same
holds for maximum score — so what is stale is which member of a tie set each page
shows. Nothing accumulates while it waits, and the re-render is worth more attached
to the archive migration, where it doubles as verification.

**The "orphan archive types" item was wrong and is dropped.** Investigated before
deleting anything, and none of the three was an orphan:

- `prediction/strade-bianche/2026.feather` (the one singular-key file) is **richer
  than the plural**: 38 columns including `team`, `cost`, `chosen`,
  `selection_frequency` and `expected_vg_points`, against 13. That plural file is one
  of the known-deficient legacy archives, and this file is what repairs it. Deleting
  it, as this plan originally said to, would have destroyed the only complete
  prediction record for that race.
- `stage_profiles` and `pcs_stage_profiles` are both live — and, on a later look,
  **the same data at two schema versions** (WP3). One supersedes the other.
- `pcs_breakaways` is the live default `breakaway_dir` in `race_helpers.jl`, simply
  never populated with tabular data.

### Phase 1a — archive hygiene (Julia, five evenings)

**Sequence: WP1a → WP2 → WP3 → WP1b → WP5 → WP4.** Three corrections to the
`WP1 → WP2 → WP3 → WP5 → WP4` this note carried:

- **WP1 splits in two.** Routing the hand-rolled paths through `archive_path` is a
  refactor that touches no archive files; the format cutover rewrites the durable
  record. Only the refactor has to precede WP2 and WP3.
- **WP2 and WP3 move ahead of the rewrite.** They take 39 files out of the set that
  must be converted, verified and re-verified, and they settle whether dead data gets
  the new format (it does not — retired trees stay Feather V1, which is all a
  historical record has to be). The dependency argument for putting the cleanups
  first applies to the migration script exactly as it does to the manifest.
- **"WP5's guard before the largest rewrite" cannot hold for WP1.** The guard would
  reject the very files WP1b must convert: the `prediction` singular type and the
  nine deficient `predictions` archives. The rule that resolves it is worth stating
  once and keeping: **`save_race_snapshot` is the pipeline boundary; one-off
  maintenance scripts write with `Arrow.write` directly.** That keeps a
  `validate=false` escape hatch out of the guard, and makes WP1b and WP4 bypass it by
  construction. WP4 is then validated by the audit script after writing rather than
  by the guard during it.

#### WP1a — consolidate the path builders

`archive_path` is called only from inside `cache_utils.jl`. Every other archive path
in the codebase is built by hand — six in `prospective_eval.jl`, a year-listing regex
in `data_assembly.jl`, and full reimplementations in `league_eval.jl` and
`baseline_compare.jl`, the last two hardcoding the Dropbox root and calling
`Feather.read` themselves. That is why a one-character extension change touches nine
places instead of one, and it is the same drift class that produced
`prediction`/`predictions`.

- Replace the `DEFAULT_ARCHIVE_DIR` const with
  `archive_dir() = get(ENV, "VELOGAMES_ARCHIVE", <today's path>)`. **A function, not
  `const X = get(ENV, ...)`** — a const is evaluated at precompile time and baked
  into the image, so the environment variable would silently stop working. The
  `= DEFAULT_ARCHIVE_DIR` default kwargs across `cache_utils.jl`,
  `data_assembly.jl`, `backtest.jl`, `prospective_eval.jl` and `race_helpers.jl`
  become `= archive_dir()`, evaluated per call.
- Add the three functions that leave no reason to reach past the API:
  `archive_races(data_type)`, `archive_years(data_type, pcs_slug)` and
  `has_race_snapshot(data_type, pcs_slug, year)`. Filters must be strict: the live
  tree carries `.DS_Store` files, `league_winners.toml` at the root and four
  `.mhtml` inputs.
- Rewrite the four bypassing files through them. `list_completed_races`' regex goes
  away; `league_eval.jl`'s `loadf` has identical semantics to `load_race_snapshot`
  and can be deleted outright; both scripts drop `using Feather`.

**Risk**: `league_eval.jl` and `baseline_compare.jl` are lab scripts with no test
coverage. Run both end to end and diff stdout before and after. `baseline_compare`
also fetches from Velogames, so pin a warm cache.

**WP1a shipped, August 2026.** `DEFAULT_ARCHIVE_DIR` is now `archive_dir()`, read
per call from `VELOGAMES_ARCHIVE`; `ARCHIVE_EXT` holds the extension so WP1b changes
it in one place; `archive_races`, `archive_years` and `has_race_snapshot` join
`archive_path` as the enumeration API. All four bypassing sites go through it —
`prospective_eval.jl`'s three scan loops, `list_completed_races`' year regex, and
both lab scripts, which drop `using Feather` and their hardcoded Dropbox roots.
`league_eval.jl`'s `loadf` was deleted outright, its semantics being
`load_race_snapshot`'s.

Verification: `league_eval.jl` prints byte-identical stdout across the change (109
lines, all 29 races). `baseline_compare.jl` **fails at HEAD for an unrelated reason**
— `prior_edition_scores` fetches the 2024 Tour `ridescore.php`, which Velogames now
404s, so the two-prior-Tours baseline cannot be built at all and no warm cache saves
it. It fails at the identical line before and after; its archive read was verified
directly instead (`load_race_snapshot` and `Feather.read` return `isequal` frames for
the 183-row 2026 Tour prediction). Worth knowing before WP4 leans on that script.

#### WP2 — retire the dead types

`pcs_form` (27 files) and `qualitative` (7) back signals deleted in the April 2026
ablation and removed from the code in August; zero code references remain. Move both
to `_retired/` rather than deleting — they are the only surviving record of what
those signals contained, and `roadmap.md` cites their evidence. Left in Feather V1
deliberately.

- `pcs_breakaways` holds four `.mhtml` files and no tabular data. It is a raw input
  masquerading as a data type, and at the top level it forces WP5's manifest to carry
  an entry for something holding no Arrow files: move it to `_inputs/` and repoint
  the one default in `race_helpers.jl`.
- **Strade Bianche is a superset swap, not a repair.** Verified at value level: the
  singular and plural files have identical riderkey sets and no differing values
  across all 13 shared columns, so the 38-column file simply replaces the 13-column
  one and `prediction/` retires. That drops a type before the manifest is written and
  leaves WP4 as the Omloop join alone.
- Record all three in a `RETIRED_ARCHIVE_TYPES` table with a one-line reason each, so
  the manifest documents them. Grep `roadmap.md` for paths pointing at the old
  locations.

**Effort: minutes.**

#### WP3 — consolidate `stage_profiles` into `pcs_stage_profiles`

Not two datasets: the same 21 stages at two schema versions. `stage_profiles` has 8
columns, `pcs_stage_profiles` has those 8 plus `gradient_final_km` and
`n_intermediate_sprints`. Two code paths write them — `race_solver.jl` the narrow one
before the race, `data_assembly.jl` the wide one after it — and
`render_assessor.jl` reads the narrow one, filling the two absent columns with `0.0`
and `0`.

The finding that makes this safe: **neither extra column is read by any model or
simulation code.** Every reference is I/O plumbing. So repointing the assessor
changes no output, and the note's "care needed" is a documentation risk rather than a
numerical one.

- Extract the duplicated frame builder — the two constructions differ only by those
  two columns — into one `stage_profiles_frame(::Vector{StageProfile})` beside
  `StageProfile`, and standardise on `pcs_stage_profiles`.
- **Keep the pre-race write.** It is the only profile write that happens before the
  race, and the assessor's archive-fed run needs it. One consequence to record: the
  post-race archiver's `=== nothing` guard then skips, so a mis-scraped pre-race
  profile is no longer corrected afterwards. Acceptable — profiles are static facts.
- `render_assessor.jl` reads `load_stage_profiles` and its hand-built `StageProfile`
  with placeholders goes.
- Five narrow files, all 2026. Giro, Tour and Femmes have a wide sibling: diff the 8
  shared columns, then retire. Itzulia and Romandie have none: re-derive with
  `getpcs_stage_profiles`, assert the 8 shared columns match, write wide.
- `stage_profiles` must **not** appear in WP5's type table, so that a future write of
  the narrow type errors.
- Test: `stage_profiles_frame` → `save_race_snapshot` → `load_stage_profiles`
  round-trips equal on all ten `StageProfile` fields.

**Effort: half an evening.**

#### WP1b — Feather V1 → Arrow IPC, extension `.arrow`

**Hard cutover. No dual read, anywhere.** Reasons in order of weight:

1. Dual read is a correctness bug in `list_completed_races`, which pushes one row per
   matching file: a slug present as both `.feather` and `.arrow` gets listed twice,
   silently duplicating a race in every season table built from it. And
   `archive_path` would have to answer "which extension?", turning the one function
   WP5 needs to be dumb into a resolver with precedence rules.
2. There is no window to bridge. One repo, one machine, ~500 small files, seconds of
   conversion.
3. The insurance for a durable-record rewrite is a pre-flight copy plus value-level
   verification, not a compatibility path that lives for ever and hides
   half-migrated state.

The one concession this note previously suggested — the year regex accepting both
"during transition" — is exactly where the first bug bites. Dropped.

Code: add `Arrow` (2.8.1 is already in the depot, so it installs offline) with a
`[compat]` entry; `archive_path` gains `.arrow`; `save_race_snapshot` becomes
`Arrow.write(path, df; metadata = ...)`; `load_race_snapshot` becomes
`DataFrame(Arrow.Table(path); copycols = true)`. **`copycols = true` is
load-bearing**: it materialises the mmapped columns, so `sort!` and element
assignment work on loaded frames and a file is not left mmapped while another call
overwrites the same path. Once a test pins that, the workaround in `utilities.jl`
goes — its comment names this as the reason it exists. The cache layer converts too,
since dropping Feather removes `Feather.write`, and needs no migration: wipe
`~/.velogames_cache` and it re-fetches. Keep the empty-frame skip in `save_to_cache`
— its real job is the "not published yet" marker that `EMPTY_CACHE_MAX_AGE_HOURS`
depends on — but rewrite the comment, which blames Feather.

`scripts/migrate_archive_arrow.jl`, one-shot, deleted with the Feather dependency:

1. Copy the archive to a sibling directory outside the archive root, so the audit
   never sees it. 18 MB, free insurance; take it.
2. Enumerate `*.feather` excluding `_retired/` and `_inputs/`, counting dynamically
   rather than asserting a number — the count has grown twice while this note was
   being written.
3. Per file: read V1, `Arrow.write`, re-read, and assert row count, column names in
   order, per-column `eltype` **and full value equality**. At this size value
   equality is free and much stronger than a types-only check. Delete the V1 file
   only when all four pass; on mismatch keep both, record it, continue, and exit
   non-zero at the end.
4. Final pass: `.arrow` count matches, zero `.feather` outside `_retired/`, summed
   row count unchanged, per-type before-and-after table printed.
5. Wipe the cache, restart `serve.jl` (long-lived, holds both stale code and the
   memory cache), and keep the pre-flight copy for a season.

Also to change: four documentation mentions of the extension in `CLAUDE.md`,
`README.md` and `roadmap.md`, and `CLAUDE.md`'s "correct a published winner" recipe.

Tests: mixed-type and `missing`-bearing frames survive the round-trip;
`loaded.riderkey isa Vector{String}` and `sort!` and element assignment do not throw;
load, overwrite the same path, load again (pins the mmap hazard); a planted
`.feather` returns `nothing`; `archive_years` and `archive_races` against a tree
salted with `.DS_Store`, a stray `.txt` and a `_retired/` sibling.

**Effort: an evening. Risk: low** — all 556 V1 files read cleanly during the schema
census, and every column came back a plain `Vector` of `Int64`, `Float64`, `Bool` or
`String`, with no `CategoricalArray`, which is the type-fidelity trap in a V1 →
Arrow round-trip. Do it while that is still true: Feather.jl v0.5.10 is
end-of-life and a Julia upgrade is what ends it. The window between the code flip and
the script finishing is the one to be careful about — the library cannot read the
archive during it, and `auto_publish.sh` firing from the vgleague hook can write a
stray file in either format. Land both in one sitting, mid-week, on the machine that
owns the cron, and never from two machines.

**No external dependents**: nothing outside this repo reads the archive yet, because
the Python reporting does not exist. This is the cheapest moment the migration will
ever have.

**WP2, WP3 and WP1b shipped, August 2026**, in one sitting with the vgleague
launchd jobs paused, in the 11-day gap between Hamburg and Bretagne Classic. No
Netlify banner was needed: with no race due, nothing on the live site went stale.

WP2 moved `pcs_form` (27), `qualitative` (7), `prediction` (1) and — after WP3 —
`stage_profiles` (5) into `_retired/`, and `pcs_breakaways` into `_inputs/`, all
left in Feather V1. WP3 replaced two hand-built frame builders with
`stage_profiles_frame`. WP1b converted the remaining **518 files**, verifying row
count, column names in order, per-column eltype and full value equality per file:
all 518 passed, 303,743 rows unchanged, no strays.

Three things this note had wrong:

- **The Strade Bianche swap is a repair, not a cosmetic superset swap.** The
  *plural* file was the 13-column one and was missing five of the seven mandatory
  prediction columns — one of the nine deficient archives, not a separate problem.
  Deficient archives are now 8, and `league_eval.jl` scores Strade instead of
  reporting "legacy preds (no cost)", growing its one-day sample from 17 races to
  18 and mean capture from 0.49 to 0.50.
- **The narrow and wide stage profiles are not identical.** Femmes matches; the
  Tour differs on 8 stages and the Giro on 4, across `distance_km`,
  `profile_score`, `vertical_meters` and `n_hc_climbs` — PCS revising the record
  between the pre-race and post-race scrapes, including two Tour stages whose
  distance moved by 31 km and 44 km. Of those columns only `profile_score` reaches
  the model, on two hilly stages, so repointing the assessor shifts two stages'
  dimension weights by a few percent rather than changing nothing. Itzulia and
  Romandie re-derived with all 8 shared columns matching exactly.
- **"Wipe `~/.velogames_cache` and it re-fetches" is false, and it cost the 2025
  back-catalogue.** Velogames retires a season's rider page — `sixes-classics/2025`
  and `sixes-superclasico/2025` both 404 — and `vg_results` has no `cost` column,
  so `load_report_data` cannot rebuild a 2025 report once the cached rider list is
  gone. The 43 published 2025 pages were recovered from the live site and are now
  the only copy; `riders.json` and `stages.json` had their 2025 halves merged back
  the same way. **2026 is on the same clock.** Archiving VG rider costs per race is
  the durable fix — WP1c's remit, and now the reason to do it rather than a nicety.

#### WP1d — capture the Velogames pages that retire

**Shipped August 2026**, inserted after WP1b when the cache wipe revealed that
Velogames does not keep its own back-catalogue: `sixes-classics/2025/riders.php`
and the `sixes-superclasico` alias both 404, as does `races.php` for 2024 and
2025.

Two new archive types, `vg_riders` and `vg_racelist`, keyed by **VG game slug**
and year rather than a `pcs_slug` — the classics pool is one page per season, not
one per race. Both are read archive-first and written on any live scrape;
`scripts/backfill_vg_pages.jl` does the backfill with Internet Archive snapshot
timestamps pinned for retired seasons.

Verification: the 2025 pool covers **2,016 of 2,016** rider-rows across all 40
archived 2025 classics, and re-rendered 2025 pages have rider tables identical to
the ones published before any of this work. `render_reports.jl --years=2025,2026
--force` now completes from a cold cache with no retired page fetched — that
offline rebuild is the standing test of whether "we keep them ourselves" holds,
and is worth re-running whenever a VG surface is added.

Two things worth carrying into WP5:

- **`milan-san-remo` and `milano-sanremo` are the same race under two slugs.**
  `vg_results/milan-san-remo/2025` and `vg_results/milano-sanremo/2025` hold
  byte-identical data. The index links a `milan-san-remo-2025` page the renderer
  never generates, so a clean rebuild in a fresh clone would leave a broken link.
  This is drift mode 5 ("same dataset, two names") occurring in *race slugs*, not
  type names — the guard as designed would not have caught it.
- **A season's pool sheds riders.** Sergio Serrano scored in Classique Dunkerque
  2026 but is in no snapshot of the pool, live or archived. One row in 1,294, and
  pre-existing, but it means a single end-of-season capture is not provably
  complete for a live season.

#### WP5 — close the drift class at the boundary

Every archive problem in this note is one of five drift modes, all of which happened
because **`save_race_snapshot` accepts any string as a type and any frame as
content**. It `mkpath`s and writes.

| Drift mode | Observed as | Guard |
| --- | --- | --- |
| Typo'd or parallel type name | `prediction` vs `predictions` | Unknown `data_type` **errors**, and creates no directory |
| Missing mandatory columns | 9 of 28 deficient prediction archives | Per-type mandatory columns checked on write |
| Unversioned writes | 24 of 25 types carry no version | Stamped on write, warned on read |
| Hand-rolled paths diverging | 4 files bypassing `archive_path`, 9 extension literals | Make the API sufficient (WP1a) |
| Same dataset, two names | `stage_profiles` vs `pcs_stage_profiles` | **Not fully preventable** — a design error, not a typo. But adding a type now requires a deliberate table edit, which is the moment to ask "is this the one we already have?" |

The pattern to generalise already exists; it is applied to one type of 20 and lives
in the caller rather than at the boundary. `race_solver.jl` holds
`PREDICTION_MANDATORY_COLUMNS` and `PREDICTION_ARCHIVE_SCHEMA_VERSION`, with
`_missing_prediction_columns` shared between a write-time error and a read-time
warning. Move that shape into `cache_utils.jl`, keyed by `data_type`.

**One const, `ARCHIVE_TYPES`**, each entry carrying version, mandatory columns,
whether the type is re-fetchable, and a one-line note. The work is writing it
honestly, and the method matters: **derive the mandatory lists by census** — the
intersection of column sets across every live file of a type, cross-checked against
what the writer provably emits — rather than by judgement. A list stricter than the
writers emit turns an irreplaceable snapshot into a lost one: odds and oracle are
archived through `_try_archive`, which swallows the error into a warning, so an
over-strict entry would silently drop a human-pasted odds sheet that cannot be
re-fetched. Two census facts to respect: `vg_results` carries `year` on only some
files, and `vg_stage_riders` carries `class`, `classraw` and `selected` on only some,
so none of those can be mandatory.

The flip side of `_try_archive` is a feature: an unknown type is a warning rather
than a crash, and no directory is created either way, so the drift is still
prevented.

**Provenance goes in Arrow schema metadata, not in columns.** This revises the
provenance line in the ETL design above. `fetched_at`, `source_url`, `machine`,
`schema_version` and `data_type` are written by the archive helper as file metadata
(`Arrow.write(path, df; metadata = ...)`, read back with `Arrow.getmetadata`, and in
Python via `schema.metadata`). Four reasons, the first decisive:

1. **The grain is the file.** One file is one fetch, and the motivating case — which
   side of Velogames' 24-hour score revision a row came from — is a property of the
   fetch.
2. **Column collisions are already real.** `backtest.jl` joins two archived frames
   through `join_pcs_specialty`, and `prospective_eval.jl` inner-joins archived
   predictions against archived PCS results. With provenance columns both sides carry
   `fetched_at`, and `makeunique` quietly produces `fetched_at_1`.
3. **The allowlist interaction disappears.** `_archive_predictions` intersects
   `propertynames` against an allowlist, so provenance columns added by a caller
   would be dropped silently. Stamping at the boundary as metadata means the question
   never arises — likewise for `load_stage_profiles`, which tolerates extra columns
   only by luck of implementation.
4. `schema_version` is currently a column that **nothing reads** — only the write and
   three test assertions reference it.

`source_url` is populated at the four sites where the URL is already a local and left
empty elsewhere, with the dictionary saying so. Plumbing a kwarg through 20 call
sites for a field nobody reads yet is work for later, if ever.

**`_manifest.toml` is written by a command, not as a side effect of every save.**
Three reasons: rewriting a file in the archive root hundreds of times per run is how
Dropbox produces a conflicted copy, which would be a drift artefact created by the
drift-prevention machinery; `serve.jl` and launchd can tear it concurrently; and it
cannot drift within a run, being a derived export of a Julia const. So
`write_archive_manifest()` in `cache_utils.jl`, invoked by
`scripts/archive_audit.jl --write-manifest`, with `--check` comparing disk against
the const and exiting non-zero. One source of truth, one derived artefact — two
hand-maintained lists would be a drift bug about drift bugs.

**`scripts/archive_audit.jl`** is also WP1b's verification tool and WP4's acceptance
test. It walks the archive and reports unknown top-level types, per-file missing
mandatory columns, files lacking provenance, stray extensions and per-type counts. It
is what tells the truth about *legacy* files without the write guard having to.

**`docs/data-dictionary.md` carries only what the const cannot**: why the odds and
oracle market families stay as seven types rather than one with a `market` column (a
schema change through the estimation path for no functional gain — documented, not
consolidated), the retirement history, and the re-fetchable-or-irreplaceable
argument, which is the column that says league rosters need backup and `pcs_seasons`
does not. It points at `_manifest.toml` for column-level truth. Generating the
markdown from the const, or hand-maintaining a table beside it, is the same drift bug
again.

**On the house style.** `CLAUDE.md` says no defensive coding, trust the caller,
minimal error handling. This does not contradict it: the archive is a genuine
boundary — it crosses processes, languages and years — and CLAUDE.md permits catching
"at boundaries where you can do something useful". Nor is it hypothetical: four
distinct instances are documented above. The whole of it is one dictionary and two
`setdiff`s, replacing three named things in two files; resist a schema framework.

**Accepted cost**: adding a new data type means editing the table. That is the
feature, but it is friction when experimenting. Do not build an opt-out until it
actually bites.

Tests: an unknown type throws **and** creates no directory (the second assertion is
the property actually being bought); table-driven — for every entry, build a frame
from its mandatory list, drop one column, expect a throw, which also pins that every
entry is satisfiable; the narrow `stage_profiles` errors; provenance round-trips;
the manifest matches the const; the audit finds one planted defect of each kind.

**Risk**: `prospective_eval.jl` archives `pcs_results` from inside a *read* path, so
an over-strict entry aborts an eval run. The census plus the fixed six columns of
`getpcs_race_results`' empty-frame constructor make that safe today; the audit is how
you find out if it stops being.

**Effort: two evenings** — most of it in the census, which means opening every type
and deciding what its mandatory columns actually are. That is the work, not the check.

#### WP4 — prediction archive repair

With Strade Bianche handled in WP2, the repairable remainder is one race.
`omloop-het-nieuwsblad/2026` is missing `team`, `cost`, `chosen`,
`selection_frequency` and `expected_vg_points`; the first two are facts, joinable by
`riderkey` from the VG classics rider list, which carries season-wide costs, so a
February race's prices are still on the page. Run `rematch_riderkeys!` first, and
leave unmatched riders `missing`.

Write it with `Arrow.write` and the provenance helper, **not** through
`save_race_snapshot`: the frame will have four of the seven mandatory columns, and
this is the maintenance-script rule from WP1b applied consistently. Materialising the
three model columns as all-`missing` so the guard passes would be worse — the file
would look complete to the audit while carrying nothing, which is the same category
of dishonesty as re-running the model.

**Seven races stay deficient, and that is the right answer.** Those columns are model
outputs and the model has changed since: the April 2026 ablation removed signals and
the July market blend changed the pick, so re-running today produces a different
prediction from the one actually made. Writing it into an archive labelled "what we
predicted" would fabricate history. The cost is bounded and known —
`prospective_eval` warns and degrades those races' metrics, which it already does —
and the audit makes the deficiency visible for ever, which is the correct end state.

Acceptance: the audit is clean except for exactly the documented list — five races
missing the three model columns, plus Kuurne and Trofeo Laigueglia missing
`selection_frequency`.

**Effort: an evening, most of it on the Omloop join.**

### Phase 1b — league data into the archive

Dated, content-hash-deduped raw JSON under `league/raw/`, with derived Arrow tables
under `league/rosters/` and `league/meta/`; `league_winners.toml` retires, because
winners become derivable *and* reproducible from the snapshot taken the week of the
race. **This is a seven-file, ~50-reference migration, not a config change** —
`data_assembly.jl` (19 refs), `cache_utils.jl` (8), `league_eval.jl` (7),
`render_reports.jl` (6), `auto_publish.jl` (4), `Velogames.jl` (4),
`race_helpers.jl` (2). Three changes inside it are behaviour rather than paths:

- `load_league_standings` and `load_league_team` re-point from the sibling vgleague
  clone to the archive.
- `league_eval.jl` reads the JSON directly today and breaks; it needs the same
  re-point.
- **`auto_publish.jl`'s winner derivation must read the snapshot contemporaneous with
  the race**, not the newest one. That falls straight out of the name-at-the-time
  decision and is the whole reason dated snapshots exist; deriving from the latest
  would reintroduce the rename bug the decision was taken to fix.

*Entry condition*: WP5, so the first league types arrive through the guard.

### Phase 1c — Python persists `riders.php` per race

Costs, class and `Start List` archived as their own data type, which makes
`load_report_data` a pure join of archived facts instead of a report loader that
scrapes the current classics page for prices. One change that fixes the ETL leak,
removes the PCS starter-filter dependency, and gives the league recaps their full
field — so a report re-rendered in 2029 uses 2026 prices rather than whatever the
page serves then.

*Entry condition*: after WP5, so the first Python-written type arrives through the
guard rather than around it. This is the gate on Python owning reporting at all.

### Phase 2 — ingest as a phase, safely

- **Completeness markers** and the roster-only / field-required stat split.
- **`velogames ingest` / `vgleague ingest`** commands; strip the archival side
  effects, `_ensure_results_archived` included. **Must land together with the
  completeness markers** — that function is the unattended-ingest guarantee, and
  Phase 0.3 only makes its failure loud, not unnecessary.
- **Phase the orchestration** (`ingest-vg → ingest-pcs → render → deploy`) on the
  existing vgleague hook; add the run log.

### Phase 3 — the new publication

- **League recap and entrant pages in Python**, reading the archive. Jinja2 plus
  plotly and pyarrow, static output, PuLP or HiGHS for the two knapsacks.
- **vgleague builds into `site/docs/league/`**; one deploy, one domain, one nav.
- Julia keeps the race reports and rider dossiers for now.

### Phase 4 — optional, evidence-led, only if the coexistence proves awkward

- **Split lab from publication inside Velogames.jl** — by then a directory move and
  nothing more, since Phase 2 removed the archival side effects that were the actual
  coupling. Worth it only if the two kinds of `render_*.jl` sitting together still
  causes confusion.
- Port the race reports to Python.
- Drop Playwright — only after the sweep test.

### What not to do

**Do not build a callable Julia modelling service.** No caller exists; the
publication layer provably does not need the model.

**Do not rewrite the model in Python, or the bump chart and matrix in Julia.** Weeks
of work, nothing for the reader. Two packages sharing one durable archive and
publishing one site is a perfectly good architecture — the pain is from the *archive*
being split and the *site* being split.

**Do not big-bang the reporting port.** If it happens, it happens incrementally
behind a single site, with the tie-breaking fixes landed on both sides first.

## Definition of done

The programme is finished when all five hold:

1. **Nothing scrapes during a render**, and a renderer that cannot find its data
   says so loudly — holding a section back, or failing the publish outright rather
   than deploying a page-shaped hole.
2. **Both languages read one archive**, at `$VELOGAMES_ARCHIVE`, in Arrow, with
   provenance, and neither reaches into the other's repo.
3. **A wrong `data_type` or a missing mandatory column fails at write.**
4. **One site, one deploy**, carrying race reports, rider dossiers, entrant pages and
   standings under one nav.
5. **A fortnight away breaks nothing** — the cron ingests, renders and deploys
   without a human, and the only thing lost is the odds paste, which the league never
   sees.

## Reference: the stats this unlocks

Verified against Hamburg 2026 (14 entrants) while writing this note.

Race × league, computable from rosters + `load_report_data`:

- **Cheapest team to beat us all** — the min-cost team of actual starters that
  beats the league winner. Hamburg: 42 credits (Pithie 14, Uhlig 6, Hobbs 8,
  Artz 6, Behrens 4, Van Belle 4) for 1,332 pts vs the winning 1,260.
  Season range 24 (Classique Dunkerque) to 92 (Ronde van Vlaanderen), median
  47, so Hamburg is joint 11th of 26 — dead average.
- **Ownership vs delivery** — Hamburg: Milan (26 cr) and Kooij (22 cr) each
  owned by 7 of 14, both scored zero.
- **Unowned top scorers** — Teunissen 420 pts, owned by nobody.
- **One-swap** — best single legal substitution per entrant. Hamburg: every
  entrant's best swap was the same rider (Teunissen); Mud Springs Eternal would
  have won with it.
- **Best/worst pick** — Artz 6 cr → 204 pts (34 pts/credit); Evenepoel 28 cr → 0.
- **Consensus team** — the six most-owned riders. Hamburg: 1,056 pts and 104
  credits, i.e. the crowd's team was unaffordable.

Season-long, needing the entrant entity:

- head-to-head round robin; contrarian index (mean ownership of picks vs
  score); cumulative regret; most expensive zero of the season; the ownership
  curse (do 50%+-owned riders underperform their price?); best value XI.

**Caveat on the headline stat.** Cheapest-team-to-beat-us-all is defined
relative to the winner's score, so it measures how well the winner played more
than how strange the race was: across the 26 races it correlates ρ = 0.87 with
the winner's share of the hindsight-optimal team and ρ = 0.82 with their raw
score, but only ρ = 0.17 with the number of riders who scored and ρ = 0.02 with
how concentrated the points were. It is a fine league stat and a poor
unpredictability metric; the model's own team-points-captured and rank ρ are
the metrics for that. Worth stating on the page rather than letting it be read
as a race-difficulty measure.
