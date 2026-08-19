# The archive data dictionary

Column-level truth lives in `_manifest.toml` at the root of the archive, which is
written from `ARCHIVE_TYPES` in `src/cache_utils.jl` by
`julia --project scripts/archive_audit.jl --write-manifest`. That const is the
source of truth; the manifest is a derived export for readers that cannot see
Julia code, and `--check` exits non-zero when the two have parted company.

This file carries what the const cannot: the arguments behind the shape of the
table, and the history of what used to be in it.

## What the archive is

Every file is `<archive_dir>/<data_type>/<race>/<year>.arrow` — Arrow IPC, one
frame per race-year, with `data_type`, `schema_version`, `fetched_at`, `machine`
and `source_url` in the file's schema metadata. `archive_dir()` reads
`VELOGAMES_ARCHIVE`, defaulting to `~/Dropbox/code/velogames/archive`.

Two types break the race-slug convention: `vg_riders` and `vg_racelist` are
per-season, not per-race, and their middle path segment is the **Velogames game
slug** (`sixes-superclasico/2025`, `sixes-classics/2026`). Anything that treats
the middle segment as a PCS race slug will mis-read them.

`_retired/` and `_inputs/` are ordinary directories one level up from the types,
so any census has to exclude them by name rather than assume every top-level
directory is a data type. A race directory does not imply a data file either:
three in the live tree hold nothing, which is why file counts trail directory
counts.

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
up. Eighteen of the twenty-three types are `false`, for three different reasons.

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

The five `true` types are settled facts on PCS — finishing orders, GC standings,
abandons, stage profiles — which that site keeps indefinitely.

## Why the market families stay as seven types

`odds`, `odds_points`, `odds_kom` and `odds_stagewin` share a schema, as do
`oracle`, `oracle_points` and `oracle_kom`. One type with a `market` column
would be tidier on disk. It is not worth it: the estimation path reads each
market separately, so consolidating means a schema change threaded through
`_prepare_rider_data`, the signal assembly and every archived file, for no
functional gain. Documented here rather than acted on.

## What used to be here

`RETIRED_ARCHIVE_TYPES` in `cache_utils.jl` records four trees and where they
went; the manifest exports them. Two were signals the April 2026 ablation
dropped (`pcs_form`, `qualitative`), one was a typo that lived long enough to
accumulate a file (`prediction`, singular), and one was never tabular at all
(`pcs_breakaways`, four `.mhtml` pages). The first three are Arrow like
everything else. They were held back as Feather V1 on the argument that a
historical record does not need the current format; that lost to the observation
that those 40 files were the only reason an end-of-life dependency was still in
the manifest. The pre-flight copy taken before the WP1b conversion remains
Feather V1, and is the untouched original if a question ever arises.

A fifth, `stage_profiles`, was the same dataset as `pcs_stage_profiles` at an
older schema, written by a second hand-built frame builder that dropped two
columns. Both write paths now go through `stage_profiles_frame`. This is the one
drift mode the type table cannot prevent: a second name for an existing dataset
is a design error rather than a typo. What the table buys is that adding a type
requires a deliberate edit, which is the moment to ask whether it is the one we
already have.

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

## What was recovered, and what is provably gone

A sweep in August 2026 (`scripts/backfill_archive.jl`,
`scripts/backfill_vg_pages.jl`) closed every gap that any source still serves:

- **`pcs_results` for 2023–2025**: 104 races archived, having been entirely
  absent. Final results do not change, so a fetch now is the same fact.
- **The 2023 and 2024 Velogames rider pools and calendars**: recovered from the
  Internet Archive with pinned snapshot timestamps, since Velogames serves
  nothing at all for those seasons — `riders.php`, `races.php` and
  `ridescore.php` all 404. 1,248 and 1,362 riders respectively.
- **`vg_scoring` for the 2025 grand tours**: the Tour's and Vuelta's pages were
  still live, the Giro's came from the Internet Archive.
- **Nine legacy `riderkey`s** in 2023/2024 `vg_results`, made by an older
  `createkey` that kept apostrophes, so O'Brien, O'Connor and D'Heygere fell out
  of every join. Pool coverage for 2023, 2024 and 2025 is now 100%.

What no source has any more:

- **Odds, oracle and `pcs_specialty` before 2026.** The market closed, the blog
  post is edited, and the rating is live — re-fetching the last would leak the
  future into a backtest.
- **Sergio Serrano's cost** (Classique Dunkerque 2026). He scored 60 points for
  a wildcard squad that appears nowhere in the rider pool, the live 2026 page
  still omits him, and the Internet Archive has no snapshot of that page at all.
  One rider-row of 1,294.
