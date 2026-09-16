# The archive data dictionary

Column-level truth lives in `_manifest.toml` at the root of the archive, which is
written from `ARCHIVE_TYPES` in `src/cache_utils.jl` by
`julia --project scripts/archive_audit.jl --write-manifest`. That const is the
source of truth; the manifest is a derived export for readers that cannot see
Julia code, and `--check` exits non-zero when the two have parted company.

This file carries what the const cannot: the arguments behind the shape of the
table.

## What the archive is

Every file is `<archive_dir>/<data_type>/<key>/<year>.arrow` — Arrow IPC, one
frame per key-year, with `data_type`, `schema_version`, `fetched_at`, `machine`
and `source_url` in the file's schema metadata. `archive_dir()` reads
`VELOGAMES_ARCHIVE`, defaulting to `~/Dropbox/code/velogames/archive`.

`<key>` is a PCS race slug for most types, but not for all, and anything that
assumes the middle segment is a race will mis-read three families:

- `vg_riders`, `vg_racelist` and `vg_startlist` are per-season and keyed by the
  **Velogames game slug** (`sixes-superclasico/2025`, `sixes-classics/2026`).
- The `league/*` types are per league-season and keyed by
  **`{game_slug}_{league_id}`** (`league/rosters/sixes-classics_100737112/2026`).

`league/` is also the one namespace: `league/rosters`, `league/meta` and
`league/winners` are ordinary types one level down, so an audit descends into it
off the type table rather than assuming every top-level directory is a type.
`league/raw` sits beside them holding dated JSON documents rather than frames,
which is why it is in `RAW_ARCHIVE_TREES` instead of `ARCHIVE_TYPES` — that
const means "a frame with these mandatory columns", and `save_race_snapshot`
validates against it.

`_retired/` and `_inputs/` are ordinary directories one level up from the types,
so any census has to exclude them by name too. A race directory does not imply a
data file either: three in the live tree hold nothing, which is why file counts
trail directory counts.

## Two languages write here

Julia owns PCS, Cycling Oracle and the odds paste. Python (vgleague) owns the
Velogames league pages and `vg_startlist` — the field that started one race,
which `riders.php` exposes only while that race is on.
`src/vgleague/archive.py` is the Python half of the boundary and enforces the
same two rules from `_manifest.toml`: an unknown `data_type` and a frame short
of a mandatory column both raise before anything is written, and the same five
provenance keys are stamped into the schema metadata. The manifest means the
second writer needs no copy of the type table.

`riderkey` is the join key across every source and is therefore implemented
twice. `vgleague verify-keys <league>` recomputes it from the rider names in an
archived `vg_riders` pool and compares against the keys Julia wrote — 5,144
names across 2023–26, zero mismatches. A divergence would silently drop a rider
from a join.

`vg_startlist` carries a uniqueness constraint the column guard cannot express:
**one row per `(race_number, riderkey)`**. A re-capture of a race must replace
that race's rows rather than append to them. `load_report_data` joins the frame
and then sums, so a rider listed twice is counted twice in the page's points
total and in the cheapest-team stat — a report with plausible wrong numbers on
it, not an error. Julia dedupes on read as a backstop, keeping the first
occurrence, but the constraint belongs to the writer: dropping the wrong
duplicate keeps the wrong price.

## Provenance is metadata, not columns

The grain of provenance is the file. One file is one fetch, and the question
that motivated recording it — which side of Velogames' 24-hour score revision a
row came from — is a property of the fetch rather than of any row.

Columns would also break things that work. `backtest.jl` joins two archived
frames through `join_pcs_specialty` and `prospective_eval.jl` inner-joins
archived predictions against archived PCS results; with provenance columns both
sides carry `fetched_at` and `makeunique` quietly produces `fetched_at_1`.
`_archive_predictions` intersects `propertynames` against an allowlist, so a
provenance column added by a caller would be dropped without a word. Stamping at
the boundary means neither question arises.

`source_url` is populated at the four sites where the URL is already to hand —
the two Velogames rider pools, the race calendar and the scoring table — and
left empty elsewhere. Threading a kwarg through twenty call sites for a field
nobody reads yet is work for later, if ever.

Read it with `archive_provenance(data_type, pcs_slug, year)`; from Python, it is
`schema.metadata` on the Arrow file.

## Re-fetchable or irreplaceable

`refetchable` in the manifest is the column that says which trees need backing
up. Twenty-two of the twenty-seven types are `false`, and so is `league/raw`,
for four different reasons.

**The source closes.** Bookmaker markets (`odds`, `odds_points`, `odds_kom`,
`odds_stagewin`) are pasted by hand from Oddschecker the evening before a race
and are gone once it starts. Cycling Oracle posts (`oracle`, `oracle_points`,
`oracle_kom`) are edited and eventually disappear. These are archived through
`_try_archive`, which turns an error into a warning, so an over-strict mandatory
list here would silently drop a sheet nobody can re-paste. That is why the
mandatory lists were derived by census rather than by judgement.

**The source retires the page.** Velogames takes a season's pages down:
`sixes-classics/2025/riders.php` and `races.php` for 2024 and 2025 all 404 as of
August 2026. `vg_riders` is the only surviving record of rider costs for a past
season — `vg_results` carries no cost column — and without it the 2025
back-catalogue cannot be re-rendered. Everything under `vg_` is treated the same
way for that reason.

**Re-fetching would leak the future.** `pcs_specialty`,
`pcs_specialty_seasons` and `pcs_seasons` are snapshots of live PCS ratings as
of race day. Fetching them again returns today's values, which would let a
backtest see results the model could not have seen.

**The league exists only while it does.** `league/raw` holds the only copy of
every entrant's roster, cost and score for every race, and Velogames publishes no
history of it. It is dated and never overwritten because names mutate at source:
the 2026 Paris-Roubaix winner is called three different things across the three
copies of the league that survive, so only a dated snapshot can say who won.
`league/rosters`, `league/meta` and `league/winners` are derived from it, but
`league/winners` is derived **once** — the recorded winner of a race is a fact
about that Sunday and is never recomputed, and the 29 rows that predate the
archive came across from `league_winners.toml` rather than being re-derived,
because no snapshot on disk predates April 2026.

The five `true` types are settled facts on PCS — finishing orders, GC standings,
abandons, stage profiles — which that site keeps indefinitely.

## Why the market families stay as seven types

`odds`, `odds_points`, `odds_kom` and `odds_stagewin` share a schema, as do
`oracle`, `oracle_points` and `oracle_kom`. One type with a `market` column
would be tidier on disk. It is not worth it: the estimation path reads each
market separately, so consolidating means a schema change threaded through
`_prepare_rider_data`, the signal assembly and every archived file, for no
functional gain.

## Retired types

`RETIRED_ARCHIVE_TYPES` in `cache_utils.jl` records the retired trees and where
they went; the manifest exports them. One of them, `stage_profiles`, was
`pcs_stage_profiles` under a second name with a drifted schema. The type table
cannot stop that: adding a type requires a deliberate edit, which is the moment
to ask whether it is one we already have.

## Legacy files the guard cannot fix

`save_race_snapshot` refuses an unknown type or a frame missing a mandatory
column, so no new file can drift. Files written before that guard existed are
another matter, and `scripts/archive_audit.jl` is what reports them.

Eight 2026 prediction archives are short of columns the schema now requires: six
lack `chosen`, `selection_frequency` and `expected_vg_points`, and Kuurne-Brussel-
Kuurne and Trofeo Laigueglia lack `selection_frequency` alone. Omloop het
Nieuwsblad also lacked `team` and `cost`; those are facts, so
`backfill_archive.jl --repair-predictions` restored them by joining the season's
rider pool, matching all 175 riders.

The three model columns stay missing, in those six files and for good. They are
model outputs and the model has changed since — the April 2026 ablation dropped
signals, the July market blend changed the pick — so recomputing them today
produces a different prediction from the one that was made, in a file labelled
"what we predicted". Filling them with `missing` to satisfy the guard would be
worse: the audit would read the file as complete while it carried nothing.

The 521 files with no provenance are simply older than the stamp. Re-writing
them to add it would put today's date on a fetch from 2023.

## What is provably gone

An August 2026 sweep (`scripts/backfill_archive.jl`,
`scripts/backfill_vg_pages.jl`) closed every gap any source still serves,
including the 2023 and 2024 Velogames pools and calendars from the Internet
Archive. What no source has any more:

- **Odds, oracle and `pcs_specialty` before 2026.** The market closed, the blog
  post is edited, and the rating is live — re-fetching the last would leak the
  future into a backtest.
- **Sergio Serrano's cost** (Classique Dunkerque 2026). He scored 60 points for
  a wildcard squad that appears nowhere in the rider pool, the live 2026 page
  still omits him, and the Internet Archive has no snapshot of that page at all.
  One rider-row of 1,294.
