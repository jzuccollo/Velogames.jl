# Fetching from behind Cloudflare: Python as transport

Built and in use since 12 September 2026.

## The problem

Both procyclingstats.com and velogames.com check the TLS and HTTP/2 fingerprint
of the client. `HTTP.jl` cannot pass that check and exposes no control over its
handshake, so no combination of user agent, headers, pacing or cookie replay
gets Julia a page. Measured 9 September 2026 against `/rider/tadej-pogacar`:

| Client | Homepage | Deep path |
| --- | --- | --- |
| curl / `HTTP.jl`, Chrome UA | 200 | 403, `cf-mitigated: challenge` |
| Headless Chromium, vgleague's context | 200 | 403, unresolved after 24s |
| Headed Chromium, automation flag off | 200 | 200 |

Replaying a browser-minted `cf_clearance` cookie from curl, with the browser's
exact UA and client hints, was also refused.

## The boundary: Python fetches, Julia parses

The block is about how the request is made, so the fix sits at the transport.
Porting the PCS scrapers into `vgleague` was rejected: most archive types at
stake are `refetchable = false`, so a bad write is permanent, and a second
writer for a non-refetchable type is the riskiest duplication available. Julia
keeps every parser and every archive writer.

## What was built

**`vgleague fetch`** (`src/vgleague/fetch.py`). Takes a file of URLs, drives one
headed browser over them, writes each page to `<out>/<sha256(url)>.html` with a
`manifest.json` of per-URL outcomes. It knows nothing about what any page means.
The browser context does not override the user agent or `Sec-Ch-Ua` hints: a
headed browser is worth having because its fingerprint is real, and a Windows
platform hint from a browser running on macOS is the kind of contradiction the
check looks for.

**`scrape_get`** (`src/utilities.jl`) resolves in four steps:

1. a page `prefetch!` already fetched, consumed on the way out;
2. a page held from an earlier `reuse` fetch in this process;
3. `HTTP.get`;
4. `vgleague fetch`, when 3 comes back blocked.

Step 3 stays ahead of step 4 because it keeps unblocked hosts (the Cycling
Oracle) on the fast path with no host list to maintain. A refusal goes into
`_BLOCKED_HOSTS` and later URLs on that host skip to step 4. Per host, because
the fingerprint check ignores the path; per process, because a stored list
would keep us on the slow path long after a site relented.

**`prefetch!`** fetches a whole list in one browser session: a launch costs
seconds, a page about a quarter of one, so a 160-rider field takes three minutes
instead of eight. `_prefetch_pages` in `get_data.jl` filters the list against
`cached_fetch` and `_PAGE_CACHE` first, so a re-render costs no browser time.

Two page stores answer different questions. `_PAGE_CACHE` is opt-in and lets two
parsers share one profile page. `_PREFETCHED` holds pages fetched moments ago
for a specific batch, is served to every caller regardless of `reuse`, and is
popped on read, so a zero-TTL caller (race results on race day) still gets a
live page on its second request.

## Rendered DOM

Playwright returns the post-JavaScript DOM where `HTTP.jl` returned the raw
response. Every parser was checked against real pages: `.xvalue` specialty
elements, the profile season table, `div.resultCont` active-tab scoping (`div.resTab` before Oct 2026), startlist
`rider/<slug>` hrefs and the `h1` not-found guard all parse.

The rendered DOM also carries `div.svg_shield` breakaway markers, with the
distance in the element's `title` ("204 kilometre in a group in front of the
peloton"). `_row_breakaway` parses them into `in_breakaway` and `breakaway_km`,
and a one-off backfill recovered them for 131 archived editions.

The Velogames riders page renders its startlist filter widget as a table row
with no rider, so `getvg_riders` drops rows with an empty `riderkey`.

## PCS Hills

PCS added a sixth specialty, Hills, in September 2026, appended after Climber.
Before it, `:hilly` had no direct signal and was synthesised from `pcs_oneday`
and `pcs_climber` at 0.5 each. The proxy misreads riders:

| Rider | Oneday | Climber | Hills |
| --- | --- | --- | --- |
| Pogačar | 9983 | 11052 | 4654 |
| Van der Poel | 8836 | 1220 | 4714 |
| Van Aert | 8637 | 2360 | 5496 |

`pcs_hills` routes `hilly = 1.0`, with 0.1 to `mountain` and `kom` (Hills counts
cat-2/cat-3 finishes, where hilly breakaways take KOM points). The oneday and
climber routes stay at 0.5: races before September 2026 have no Hills rating and
never will, so trimming them would weaken `:hilly` across the whole history.
`within_cluster_correlation` already discounts the overlap.

For a frame with no `:hills` column, `pcs_z` yields zeros, and a z-score of zero
reads as "exactly average". Routing that into `:hilly` would sharpen every
historical rider's posterior toward the prior. So `RiderSignalData` carries
`has_pcs_hills` beside `pcs_hills_z`, true only when the column exists and the
value is not `missing`, and `join_pcs_specialty` leaves `:hills` out of its
coalesce-to-zero loop.

`pcs_specialty` is schema version 2 with `hills` optional, since the v1 files
cannot gain it: a re-fetch would record today's value under a past race's key.
`SCHEMA_VERSION_COMPATIBLE` keeps the version-drift warning quiet. Re-export
`_manifest.toml` (`archive_audit.jl --write-manifest`) after any such change or
Python validates against a stale contract.

Evaluation can only be prospective: there is no historical Hills data.

## Reconstruction never fetches

`with_browser_transport(false)` wraps both backtest entry points. A backtest that
reaches the network rebuilds a past race from today's pages. So
`prefetch_race_data` uses the same three-tier `_load_pcs_specialty` as
production, and `_pcs_results_archive_first` returns an empty frame for a missing
prior edition only when the transport is disabled. During a live render a block
still raises `ScrapeBlockedError`, so a challenge never quietly becomes "no
history".

## Not done

- **Julia's VG writers stay.** The `vg_results`, `vg_stage_totals` and
  `vg_stage_results` writers are archive-on-miss backfill, gated on
  `load_race_snapshot(...) === nothing` and validated against the same manifest
  as Python, so they never overwrite and cannot drift on schema.
- **The five specialty-breakdown pages per rider** feeding
  `pcs_specialty_seasons` are not prefetched: ~800 page loads, read only by the
  stage-race path. Add a `_prefetch_pages` call in `_apply_pcs_recency!` before
  the next grand tour.

## Operations

Headed means a GUI session: any job that may reach the live tier cannot be a
bare launchd job. `VGLEAGUE_BIN` overrides where the CLI is found; otherwise it
is taken from `PATH`.
