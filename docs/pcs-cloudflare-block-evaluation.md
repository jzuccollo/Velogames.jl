# Evaluating the PCS Cloudflare block: what to build

**Status:** recommendation, written 9 September 2026 against `docs/pcs-cloudflare-block.md`.
Every measurement below was taken on 9 September 2026 between 08:25 and 08:55 UTC from this
machine, against the live site.

## Recommendation

Do both halves of a two-part fix, in this order. **First, make the archive the primary source
of PCS specialty and race history and make a challenge raise instead of returning missing
data** — this is about half a day in Julia, needs no browser, and on measurement recovers
81% of Coppa Sabatini's field (128/159) and 75% of GP Industria's (123/163) from `pcs_specialty`
files the archive already holds, plus the whole primary race-history signal for both races
from `pcs_results` files already on disk for 2023–2025. **Second, add a `vgleague pcs` command**
that pulls rider profiles through a *headed* Playwright browser and writes `pcs_specialty` and
`pcs_seasons` into the archive under the race slug — another half day, and it is now known to
work rather than hoped to: a headed Chromium clears the challenge in a few seconds and then
served 24 of 25 rider profiles with zero re-challenges at a 0.27s median, which puts a
160-rider field at under three minutes. Two things fall out of the measurements and change the
brief's assumptions: **headless Chromium does not get through** — not even with vgleague's exact
UA, viewport, locale, timezone and `Sec-Ch-Ua` context — so this is not the vgleague pattern
copied across, and **`cf_clearance` replay is dead**, refused with 403 from curl on the same IP
seconds after the cookie was minted, with the exact browser UA and the full cookie jar. Two
`pcs_specialty` archive files are currently poisoned with all-missing ratings by the blocked
runs and should be deleted today.

## 1. Is a browser-based PCS fetch worth building?

Yes, and the volume objection does not survive measurement.

### The block, confirmed

An HTTP client with a real Chrome UA gets, on every deep path:

```
HTTP/2 403
cf-mitigated: challenge
server: cloudflare
<title>Just a moment...</title>      5,769 bytes, 0 of 5 .xvalue elements
```

The homepage answers 200 with its full 76KB. So this is **path-scoped**, not
session-reputation: `warmup`, the thing that solved the Velogames case, is not the lever here.
The response also carries `accept-ch` and `critical-ch` headers demanding a dozen client hints,
which is Cloudflare fingerprinting the client rather than rate-limiting it. That matches four
days' persistence better than a cooling IP does, and it confirms the brief's reading.

### What actually gets through

| Client | Homepage | `/rider/tadej-pogacar` |
| --- | --- | --- |
| curl / `HTTP.jl`, Chrome UA | 200 | **403 `cf-mitigated: challenge`** |
| Headless Chromium, vgleague's exact context | 200 | **403 challenge, unresolved after 24s** |
| Headed Chromium, `--disable-blink-features=AutomationControlled` | 200 | **200, "Tadej Pogačar", 6 `.xvalue`** |

The middle row is the finding that matters, and it is not what the brief assumes. `vgleague`
launches `pw.chromium.launch()` — headless — and that is enough for velogames.com. It is not
enough for PCS. The bundled headless Chromium advertises itself through client hints and
`navigator.webdriver` no matter what `user_agent` is set to, and PCS's configuration reads
that. A PCS fetcher has to run headed, which is an operational constraint on any unattended
scheduling: it needs a logged-in GUI session, not a bare launchd job.

### The volume objection

Measured in one headed session, warmup then 25 rider profiles at 0.4–1.0s jittered pacing:

```
ok=24  challenged=0  other=1  of 25
median page time 0.27s  →  160 riders ≈ 2.6 minutes
```

Zero re-challenges. Once `cf_clearance` is held by a client whose fingerprint Cloudflare
accepts, the profile pages come back as fast as any static page. The brief's worry — "a
Playwright session may still get challenged at that volume" — is answered: at this volume it
is not. That is one session's observation and PCS can change its posture, but it is the right
kind of evidence to act on, and it cost twenty minutes to get rather than half a day of
building.

Worth noting what the current Julia path actually costs, because it is worse than the brief
says. `getpcs_rider_pts` caches under `params = Dict("rider" => ridername)` and
`getpcs_rider_seasons` under `params = Dict("slug" => pcs_slug)` — the **same URL, two cache
keys**, so a one-day render fetches each rider's profile twice, ~320 requests rather than 160.
A stage race adds `getpcs_specialty_by_season`'s five `career-points-<spec>` pages per rider,
another ~800. A browser fetcher that loads each profile once and reads both the five `.xvalue`
elements and the season table off it halves the one-day burst for free.

## 2. Where it lives

**Extend `vgleague`, as a `pcs` command group that does not touch `LeagueConfig`.**

The pieces worth sharing are the block-handling and the archive writer, and both are already
correct in `vgleague`:

- `looks_blocked(html, meta)` (`src/vgleague/scraper.py:49`) checks exactly the header PCS is
  sending — `meta["headers"]["cf-mitigated"]` — plus status in `(403, 429)` and body markers.
  It needs no change to recognise a PCS challenge.
- `BlockedError` (`scraper.py:83`) exists because a challenge page parses as valid HTML with
  none of the expected elements, so an undifferentiated failure reads as a site redesign. Its
  docstring names the trap; `getpcs_rider_pts`'s `_missing_rider_df()` fallback walked straight
  into it, and that is why GP Industria was first diagnosed as a markup regression.
- `_goto` (`scraper.py:128`) captures status and headers, treats a "successful" navigation onto
  a challenge page as a failure, and backs off on `BLOCK_BACKOFF = (20, 45, 90)` before raising.
- `write_snapshot` (`archive.py:137`) validates against `_manifest.toml` exported from Julia's
  `ARCHIVE_TYPES`, refuses unknown types and missing mandatory columns, refuses **hollow**
  columns (present but empty in every row), tightens nullability so Julia reads a plain `T`
  rather than `Union{Missing,T}`, and writes atomically. Reproducing that in a standalone tool
  is how the `prediction`/`predictions` directory drift happened, and it would be the second
  time.
- `rider_key` (`archive.py:343`) is already the character-for-character twin of `createkey`,
  and `vgleague verify-keys` checks it.

The objection in the brief — that `LeagueConfig.base_url` and every scrape function are
Velogames-shaped — dissolves once you notice that a PCS module simply does not take a
`LeagueConfig`. It takes a race slug and a year. One small generalisation is needed:
`warmup(page, config)` reads `config.base_url` and nothing else, so it should take a base URL
string. Add a headed sibling to `_new_browser_context` (`cli.py:71`) and the shared machinery
is complete.

A standalone tool would duplicate `looks_blocked`, `BlockedError`, `_goto`, `write_snapshot`,
the manifest guard and `rider_key`, and would then need its own answer when the manifest gains
a type. There is no benefit on the other side of that ledger.

One design note that removes a whole class of drift: **do not port `PCS_SLUG_OVERRIDES` to
Python.** Julia already solves slug resolution by scraping the PCS startlist page for
`rider/<slug>` hrefs (`_extract_rider_slugs`, `pcs_extended.jl:176`). A Python fetcher does the
same in one page load and gets the site's own slugs, so nothing has to be kept in step by hand.

## 3. Ingest shape

**Per race, browser-driven, run as a pre-race phase — and read by the renderer from the
archive, not fetched by it.**

The brief floats a periodic full-field pull instead. It should not be one, and the reason is in
`ARCHIVE_TYPES` itself: `pcs_specialty` is `refetchable = false`, noted as *"PCS specialty
ratings as of race day. Live ratings drift, so re-fetching would leak the future into a
backtest."* The per-race key is not an accident of storage, it is the temporal-integrity
guarantee — `{pcs_slug}/{year}.arrow` means "what PCS said on the day of that race". A
season-scoped pool file would throw that away for no gain, since at 2.6 minutes a full field
there is nothing to amortise.

Concretely, three phases, and the pipeline already has the first and third:

```
vgleague ingest-all            (exists)  Velogames results → archive
vgleague pcs <slug> <year>     (new)     PCS startlist → slugs → 160 profiles
                                         → pcs_specialty, pcs_seasons → archive
julia render_predictor.jl      (changed) reads both from the archive
```

The renderer change is what makes this fit the archive-only rule, and it is the part that keeps
working when PCS next changes its mind. `_prepare_rider_data` (`race_solver.jl:489`) should
resolve specialty in three steps and fetch last:

1. the race's own archived `pcs_specialty` for `(pcs_slug, year)`;
2. for riders still uncovered, the union across every other archived key, newest file first —
   `archive_races("pcs_specialty")` already enumerates them;
3. for whoever is left, the live fetch.

Step 2 is what makes this durable, and it is worth stating what it buys on its own, with no
browser at all. The archive holds 30 clean `pcs_specialty` files covering 1,070 distinct
riderkeys. Against the two failed races:

| Race | Field | Covered by other archived races | |
| --- | --- | --- | --- |
| Coppa Sabatini 2026 | 159 | 128 | **81%** |
| GP Industria 2026 | 163 | 123 | **75%** |

Specialty scores are season-cumulative and move slowly, so a rating from Bretagne Classic
eleven days earlier — or from Paris-Roubaix in April — is a close read on race day, and the
model z-scores and `log1p`-transforms it before use. The 20% left over are mostly Continental
riders who never start a WorldTour classic, which is to say the cheap end of the field.

Race history needs the same treatment and gets more from it. `getpcs_race_history` →
`getpcs_race_results` (`pcs_extended.jl:43`) fetches live every time and never consults the
archive, even though `pcs_results` is `refetchable = true` and the archive already holds
**coppa-sabatini 2023, 2024, 2025** and three or four years each of most similar-race slugs.
Reading `pcs_results/{slug}/{year}.arrow` before reaching for the network would have restored
the primary race-history signal for both failed races with no scraping whatsoever.

Order the work so step 3 is the one that can fail. A browser pull that covered 155 of 159
riders leaves four live fetches, they get challenged, and nothing breaks.

## 4. The `cf_clearance` replay option

**Against, and this is now settled empirically rather than argued.**

The test: a headed Chromium cleared the challenge and minted a `cf_clearance`; within seconds,
from the same IP, curl requested a different rider profile carrying that cookie, the exact
`navigator.userAgent` the browser reported, matching `Sec-Ch-Ua` client hints, and
`Accept-Language`. Both variants:

```
replay [cf_clearance only]: HTTP 403  5,940 bytes  title="Just a moment..."
replay [full jar]:          HTTP 403  5,940 bytes  title="Just a moment..."
```

Cloudflare is validating the TLS and HTTP/2 fingerprint, not merely cookie plus IP plus UA.
curl's fingerprint is not Chrome's, and `HTTP.jl`'s is further away still — and unlike curl,
which at least has `curl-impersonate` as an escape hatch, `HTTP.jl` exposes no control over its
TLS handshake at all. There is no version of this that works from Julia.

Which is the right outcome for the project anyway. Cookie replay would have meant a manual
browser step before every render, a cookie with a short life and no way to tell a stale one
from a blocked one, and a `HTTP.jl` path that fails in exactly the same silent way it does
today. It was the option worth thirty minutes to falsify, and it took twenty.

## 5. Is it worth fixing now?

Yes — but the ranking matters, and the browser is not the top of it.

**The silent-failure fix is not optional and is not really about PCS.** `getpcs_rider_pts`
turns a 403, a challenge page, a genuine 404 and a PCS redesign into the same all-`missing`
row. That is what let two live races go out on a VG-points-only model with a clean-looking log.
It has already cost something worse than a weak prediction: `getpcs_rider_pts_batch` returns a
full frame of missing rows rather than an empty one, so `_try_archive` wrote it, and Julia's
`missing_mandatory_columns` guard is presence-only — the columns were there, holding nothing.
Two `pcs_specialty` files are now poisoned with 163 and 159 rows of all-null ratings:

```
gp-industria-e-artigianato-di-larciano/2026.arrow  163 rows, 0 non-null  fetched 2026-09-05
coppa-sabatini/2026.arrow                          159 rows, 0 non-null  fetched 2026-09-09
```

`refetchable = false` means those cannot be regenerated. They read as coverage and carry
nothing — which is exactly the failure `hollow_columns` in `archive.py:107` was written to
stop, with a docstring noting that the Julia half is the lax one. The block found the gap. Both
files should be deleted today and the hollow-column check ported to `save_race_snapshot`.
`pcs_seasons` escaped only by luck: its batch returns an empty frame on total failure, and
`nrow(seasons_df) > 0` gated the write.

**The archive-first change is high value for low effort and is the durable half.** 75–81%
coverage recovered, full primary race history recovered, no new tooling, no new language, no
new failure mode. It also satisfies the brief's own standard for "fixed" — *"the approach
should not need re-solving every time PCS adjusts its Cloudflare rules"* — in a way the browser
never can. The browser is the part that will need re-solving.

**The browser is worth it too, at half a day, now that it is known to work.** Without it the
archive slowly staleness-decays: coverage of a new race's field comes only from riders who
appeared in an earlier archived field, and by March 2027 that is a season-old rating. The
counter-argument from `CLAUDE.md` — *"keep it simple, no defensive coding, this is a small
personal package"* — is a real constraint and it is met: roughly 150 lines of Python in
`vgleague`, no new dependency, no new archive type, no new integration boundary, reusing four
functions that already exist and are already tested against a live WAF. This is not a scraping
framework.

**What is not worth doing now.** The five `career-points-<spec>` pages per rider that feed
`pcs_specialty_seasons` are ~800 page loads and are read only by the stage-race path
(`apply_recency = false` for one-day, `race_solver.jl:820`). At 13 minutes a grand tour that is
affordable, but there are three grand tours a year and the next is months away. Add it when
one is. Same for `pcs_stage_profiles` and `pcs_stage_results`.

On the validation question the roadmap would otherwise raise: this needs none. It is not a
model change. Restoring a signal that ran at full coverage for 30 races this season and then
went to zero has an obvious sign and an obvious size, and the do-no-harm check is that a
re-render of Coppa Sabatini with archive-sourced specialty reproduces roughly the pre-block
shape rather than the VG-only one.

## Implementation sketch

### Stage 1 — Julia, archive-first and fail loudly (about half a day)

**`src/cache_utils.jl`**
- Port `hollow_columns` from `archive.py:107` into `missing_mandatory_columns`, or beside it:
  a mandatory column present in every row and empty in all of them is a refusal, not a write.
  Zero stays a value.

**`src/get_data.jl`, `src/pcs_extended.jl`, `src/pcs_scraper.jl`**
- Add `looks_blocked(response)` in `utilities.jl` — `cf-mitigated` header present, or status in
  `(403, 429)`, or `"Just a moment..."` / `"Sorry, you have been blocked"` in the body — and a
  `PCSBlockedError` alongside it, for the reason `BlockedError`'s docstring gives.
- In `getpcs_rider_pts`'s `fetch_rider_pts`, split the `403` out of the
  `(400, 403, 404) → _missing_rider_df()` branch: 400 and 404 stay missing data, 403 raises.
- `getpcs_rider_pts_batch` counts blocks separately from misses and raises once the block count
  passes a handful, rather than returning 160 rows of nothing.
- Same check at the other 12 `HTTP.get` sites; one shared helper, one line each.

**`src/race_solver.jl`**
- New `_load_pcs_specialty(pcs_slug, year, riderkeys; cache_config, force_refresh)`, ~40 lines:
  own archived file → union across `archive_races("pcs_specialty")` newest-first → live fetch
  for the remainder. Log the split three ways so the data-quality summary says where coverage
  came from.
- Call it from `_prepare_rider_data` in place of the bare `getpcs_rider_pts_batch`.
- Extend the `@info "Data quality summary"` line with the provenance counts.

**`src/data_assembly.jl`**
- `assemble_pcs_race_history` reads `load_race_snapshot("pcs_results", slug, y)` for each prior
  year and each similar-race slug before calling `getpcs_race_results`.

**Housekeeping**
- `rm ~/Dropbox/code/velogames/archive/pcs_specialty/{gp-industria-e-artigianato-di-larciano,coppa-sabatini}/2026.arrow`

**Tests** — one that a hollow frame is refused; one that the specialty loader prefers the own-race
file, then the union, then the network; one that a 403 raises rather than yielding a missing row.

### Stage 2 — `vgleague pcs` (about half a day)

**`src/vgleague/scraper.py`**
- `warmup(page, base_url)` instead of `warmup(page, config)`; update the two call sites.

**`src/vgleague/cli.py`**
- `_new_browser_context(browser, headed=False)`, and a `pw.chromium.launch(headless=False,
  args=["--disable-blink-features=AutomationControlled"])` path for PCS. Note in the docstring
  why: headless is challenged, and this was measured.

**`src/vgleague/pcs.py`** (new, ~150 lines)
- `scrape_startlist_slugs(page, race_slug, year) -> dict[riderkey, pcs_slug]` — one load of
  `/race/{slug}/{year}/startlist/startlist-quality`, collect `href^="rider/"`, mirroring
  `_extract_rider_slugs` and its call site at `pcs_extended.jl:252`.
- `scrape_rider_profile(page, pcs_slug) -> (specialty_row, season_rows)` — one load, five
  `.xvalue` elements for specialty, the second table for seasons. One page, both signals.
- `pull_race(page, race_slug, year)` — warmup, slugs, loop with jittered 0.4–1.0s pacing,
  `looks_blocked` on every navigation via `_goto`, then two `write_snapshot` calls:
  `pcs_specialty` (`riderkey, rider, oneday, gc, tt, sprint, climber`) and `pcs_seasons`
  (`riderkey, year, pcs_points, pcs_rank`). Both column sets come straight from `ARCHIVE_TYPES`,
  and `write_snapshot`'s manifest guard enforces them.

**CLI** — `@main.command("pcs")` taking `race_slug` and `year`. Run it by hand before a race for
now; wire it into the pre-race job once it has a few races behind it.

**Documentation** — a line in `CLAUDE.md`'s architecture facts beside the Velogames one:
*PCS blocks Julia — deep paths return a `cf-mitigated: challenge` to any HTTP client, and
headless browsers with it. Only `vgleague pcs` (headed Playwright) can fetch. Renders read
`pcs_specialty` and `pcs_seasons` from the archive.*
