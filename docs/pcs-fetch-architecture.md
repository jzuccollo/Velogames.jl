# Fetching from behind Cloudflare: Python as transport

**Status:** built and in use, 12 September 2026. Supersedes Stage 2 of
`docs/pcs-cloudflare-block-evaluation.md`, which proposed porting the PCS
scrapers to Python. It resolves the problem set out in
`docs/pcs-cloudflare-block.md`.

## The problem, restated

Both procyclingstats.com and velogames.com check the TLS and HTTP/2 fingerprint
of the client. `HTTP.jl` cannot pass that check and exposes no control over its
handshake, so no combination of user agent, headers, pacing or cookie replay
gets Julia a page. Measured 9 September 2026 against `/rider/tadej-pogacar`:

| Client | Homepage | Deep path |
| --- | --- | --- |
| curl / `HTTP.jl`, Chrome UA | 200 | 403, `cf-mitigated: challenge` |
| Headless Chromium, vgleague's context | 200 | 403, unresolved after 24s |
| Headed Chromium, automation flag off | 200 | 200 |

Of Julia's 13 fetch sites, 12 were on a blocked host. The one exception is the
Cycling Oracle.

## The seam was in the wrong place

Before this change the rule was "Julia fetches unless the host blocks it". That
line moves whenever Cloudflare changes posture — it moved for Velogames last
year and PCS this month, and each move cost a port. It had also produced three
archive types with two writers each, one of which could no longer run.

The block is a transport problem: Cloudflare objects to how the request is
made, not to what we do with the page. So the fix belongs at the transport, and
the boundary that does not move is **Python fetches, Julia parses**.

The alternative — porting the PCS scrapers into `vgleague` — was rejected on the
strength of one argument. Most of the archive types at stake are
`refetchable = false`, so a bad write is permanent; in September a *single*
writer archived 163 and 159 rows of all-null specialty ratings that can never be
regenerated. A second writer for a non-refetchable type is the highest-stakes
duplication available, and `write_snapshot`'s old advantage over
`save_race_snapshot` had already been closed by porting the hollow-column guard.

## What was built

**`vgleague fetch`** (`src/vgleague/fetch.py`, ~150 lines). Takes a file of
URLs, drives one headed browser over them, writes each page to
`<out>/<sha256(url)>.html` with a `manifest.json` of per-URL outcomes. It knows
nothing about what any page means. It reuses `_goto`, `looks_blocked` and
`BLOCK_BACKOFF` unchanged; `warmup` was generalised from `LeagueConfig` to a
base URL, since PCS has no league.

The browser context deliberately does *not* override the user agent or the
`Sec-Ch-Ua` hints, unlike every other context in that package. A headed browser
is worth having because its fingerprint is real, and a Windows platform hint
from a browser running on macOS is the sort of contradiction the check looks
for.

**`scrape_get`** (`src/utilities.jl`) resolves in four steps:

1. a page `prefetch!` already fetched, consumed on the way out;
2. a page held from an earlier `reuse` fetch in this process;
3. `HTTP.get`;
4. `vgleague fetch`, when 3 comes back blocked.

Step 3 stays ahead of step 4 because it costs one request to find out, and it
keeps unblocked hosts on the fast path with no host list to maintain. It costs
that request once per host per process: a refusal goes into `_BLOCKED_HOSTS` and
later URLs on the same host skip straight to step 4, throttle included. Per host
rather than per URL, because the fingerprint check is indifferent to the path;
per process rather than persisted, because a site's posture is exactly the thing
that changes, and a stored list would keep us on the slow path long after PCS
relented.

**`prefetch!`** (`src/utilities.jl`) fetches a whole list in one browser
session. This is the difference between three minutes and eight for a 160-rider
field: a launch costs seconds, a page about a quarter of one. `_prefetch_pages`
in `get_data.jl` filters the list against `cached_fetch` and `_PAGE_CACHE`
first, so a re-render costs no browser time and a seasons batch is free after a
specialty batch has been over the same profiles.

Two page stores, answering different questions. `_PAGE_CACHE` is opt-in and
exists so two parsers can share one profile page. `_PREFETCHED` holds pages
fetched moments ago on behalf of a specific batch, is served to every caller
regardless of `reuse`, and is popped on read — so a zero-TTL caller (race
results, which go from empty to partial to final on race day) still gets a live
page on its second request.

## Rendered DOM parity

Playwright returns the post-JavaScript DOM where `HTTP.jl` returned the raw
response, so every parser was checked against real pages before the rewire:

| Check | Result |
| --- | --- |
| `.xvalue` specialty elements | 6, and 1:5 still map to oneday/GC/TT/sprint/climber |
| Profile season table | second table, 10–13 season rows, parses |
| `div.resTab` active-tab scoping | 1 tab, 1 active, correct finishing order |
| Startlist `rider/<slug>` hrefs | 165 riders |
| `h1` not-found guard | not tripped |

Two incidental findings, both acted on. PCS has added a sixth specialty,
**Hills**, appended after Climber — see below. And `div.svg_shield` breakaway
markers are now present where the raw response had none, with the distance in
the element's `title` ("204 kilometre in a group in front of the peloton"), so
both `in_breakaway` and `breakaway_km` became readable after years of being
hardcoded `false`/`missing`. `_row_breakaway` parses them, and `pcs_results`
being `refetchable = true` meant the history could be recovered rather than
merely accumulated: `scripts/backfill_breakaways.jl` re-fetched 131 archived
editions in one browser session, 131/131, yielding 726 rider-race observations.
The model consequences are in `roadmap.md` under "Known issues".

## Hills

PCS began publishing a sixth specialty rating in September 2026. It is wired in
rather than merely captured, because `:hilly` had no direct signal at all — it
was synthesised from `pcs_oneday` at 0.5 and `pcs_climber` at 0.5, a proxy that
existed only because nothing better did. Three riders show what the proxy could
not see:

| Rider | Oneday | Climber | Hills |
| --- | --- | --- | --- |
| Pogačar | 9983 | 11052 | 4654 |
| Van der Poel | 8836 | 1220 | 4714 |
| Van Aert | 8637 | 2360 | 5496 |

On oneday and climber Pogačar dwarfs both, so the synthesised `:hilly` ranks him
far above them. On the rating that is actually about hilly racing he is third.
Capturing that and not using it would mean running the proxy against a better
signal sitting unread in the archive.

`pcs_hills` routes `hilly = 1.0`, with a 0.1 trickle to `mountain` and `kom`
(PCS Hills counts cat-2/cat-3 finishes, which is where hilly breakaways take KOM
points). The oneday and climber routes stay at 0.5 rather than being trimmed to
make room: every race before September 2026 has no Hills rating and never will,
so trimming would leave the whole history with a weaker `:hilly` than it has
today — and the overlap between three correlated ability signals is already
discounted by `within_cluster_correlation = 0.5`.

The trap, and the reason this needed a presence flag rather than a column. For a
frame with no `:hills` column, `pcs_z` yields `zeros(n_riders)`, and a z-score of
zero is a perfectly good observation of "exactly average" — routing it into
`:hilly` would sharpen every rider's hilly posterior toward the prior in every
historical race. So `RiderSignalData` carries `has_pcs_hills` beside
`pcs_hills_z`, gated per rider on the column existing *and* the value not being
`missing`, and the signal is only pushed onto the update list when it is true.
`join_pcs_specialty` deliberately leaves `:hills` out of the coalesce-to-zero
loop for the same reason.

`pcs_specialty` goes to schema version 2 with `hills` **not** mandatory, since
the 30 v1 files cannot gain it — a re-fetch would record today's cumulative value
under a past race's key, which is the exact leak `refetchable = false` exists to
prevent. `SCHEMA_VERSION_COMPATIBLE` records that v1 still reads correctly, so
the version-drift warning stays quiet for a bump that only adds an optional
column. Re-export `_manifest.toml` (`archive_audit.jl --write-manifest`) after
any such change or Python starts validating against a stale contract.

Evaluation can only ever be prospective here. There is no historical Hills data
to backtest against, and waiting would not have changed that — it would only have
meant running the proxy for longer.

One parse difference did surface. The Velogames riders page carries its
startlist filter widget as a table row — every team name concatenated, no rider,
an unparseable cost. `getvg_riders` now drops rows with an empty `riderkey`, as
vgleague's own parser already did.

## What this restored

A GP Québec 2026 render, before and after:

| | Before | After |
| --- | --- | --- |
| `pcs_specialty` | 142/151, live tier 0 | **145/151**, live tier 9 |
| `pcs_seasons` | 148/151, live tier 0 | **148/151**, live tier 2 |
| Blocked requests | 11 | **0** |
| Own-race archive written | nothing | 9 specialty, 2 seasons rows |

The archive-first tiers were already carrying most of the field; what the
transport adds is the remainder, which is exactly the part that was decaying.
Cross-race coverage only ever reaches riders seen in an earlier archived field,
so without a working live tier a new race's cheap end goes permanently
uncovered. `vg_racelist`, `vg_scoring` and `vg_riders` also come back, having
been reachable only through manually seeded cache files.

## What the transport exposed

Two latent bugs surfaced the moment reconstruction was forbidden from fetching,
and both had been hidden by the live tier quietly supplying what the archive
lacked — while leaking today's data into reconstructions of past races.

`prefetch_race_data` read only the own-race `pcs_specialty` file and sent
everything else to `getpcs_rider_pts_batch`, which raises past
`PCS_BLOCK_RAISE_THRESHOLD`. A handful of uncovered riders killed the whole
edition: the first sweep skipped 130 of 131. It now uses `_load_pcs_specialty`,
so the backtest gets the same three-tier resolution production does — the
production/backtest divergence `GameFormat` exists to prevent.

`_pcs_results_archive_first` raised when a prior edition was neither archived nor
fetchable, and a backtest asks for three or four per race. It now returns an
empty frame *only when the transport is disabled*. During a live render a block
still propagates, because a challenge quietly becoming "no history" is the exact
failure `ScrapeBlockedError` was created to stop.

## What was deliberately not done

**The Julia VG writers were left in place.** The plan called for deleting the
`vg_results`, `vg_stage_totals` and `vg_stage_results` writers as duplicates of
vgleague's. That premise died with the fix: they were dead only because Julia
could not fetch, and they now work. All five are archive-on-miss backfill, gated
on `load_race_snapshot(...) === nothing`, and validated against the same
`ARCHIVE_TYPES` manifest Python validates against — so they never overwrite and
cannot drift on schema. Deleting them would remove working backfill for any race
`vgleague ingest` has not covered.

**`HTTP.jl` stays.** It is step 3 of `scrape_get` and the fast path for every
host that is not behind a challenge.

**The five `career-points-<spec>` pages per rider** that feed
`pcs_specialty_seasons` are still unprefetched — ~800 page loads, read only by
the stage-race path, and the next grand tour is months away. Add a
`_prefetch_pages` call in `_apply_pcs_recency!` when one is.

## Operational note

Headed means a GUI session. Any job that may reach the live tier cannot be a
bare launchd job. `VGLEAGUE_BIN` overrides where the CLI is found; otherwise it
is taken from `PATH`.
