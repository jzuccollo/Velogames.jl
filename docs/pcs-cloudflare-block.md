# PCS is now blocking Velogames.jl's scraper

**Status:** open, needs a fix design. Written 9 September 2026 for evaluation.

## Summary

ProCyclingStats (PCS) has started serving a Cloudflare JS challenge to every request `Velogames.jl` sends it, across the whole domain — rider profiles, race results, and startlists alike. This isn't a rate-limit that eases off: it has now held for four days across two separate predictor runs. The knock-on effect is that PCS specialty (one-day/GC/TT/sprint/climber ratings) and PCS race-history signals — two of the model's core inputs — have been silently zero for both runs, degrading every prediction to VG-season-points-only. Velogames itself has blocked this package's HTTP client outright for longer, and the project already has a working fix for that (a separate Python + Playwright tool, `vgleague`). PCS now needs the same kind of fix, or a reason to believe it doesn't.

## Evidence

**5 Sept 2026 — GP Industria & Artigianato.** `render_predictor.jl` completed cleanly but logged `pcs_specialty = 0/163`, `race_history = 0/163`. Investigated afterwards (see project memory `gp-industria-pcs-specialty-scraper-broken`): a direct re-fetch of a PCS rider profile returned a Cloudflare "Sorry, you have been blocked" page (HTTP 403, 5.5KB body, 0 of the expected 5 `.xvalue` specialty-score elements). Initially misdiagnosed as a markup regression, because `getpcs_rider_pts` (see below) silently converts *any* response with fewer than 5 `.xvalue` elements into a clean "rider has no specialty data" row — a block and a genuine 404 look identical downstream.

**8 Sept 2026 — mitigation attempt.** Suspecting the block was triggered by traffic pattern (163 sequential requests in ~13 minutes, every one self-identifying via `User-Agent: Mozilla/5.0 (compatible; VelogamesBot/1.0)`), shipped three fixes:
- Replaced the bot-labelled UA with a real Chrome desktop UA everywhere (`SCRAPE_USER_AGENT` in `src/utilities.jl`, used at all 12 `HTTP.get` call sites across `src/get_data.jl`, `src/pcs_extended.jl`, `src/pcs_scraper.jl`).
- Added a 0.5–1.5s jittered `sleep` before each live PCS rider-profile fetch (`fetch_rider_pts` closure, `src/get_data.jl`).
- Gave PCS specialty fetches their own 7-day cache TTL instead of reusing the race-data TTL (`src/race_solver.jl`, around the `getpcs_rider_pts_batch` call), so a full-field burst happens roughly weekly rather than on every render.

Re-testing a single rider profile immediately after shipping these still returned a block — but now a *milder* Cloudflare tier: `HTTP 403`, title `"Just a moment..."`, header `Cf-Mitigated: challenge` — a JS challenge rather than a hard WAF block. Consistent across three requests, 2s apart, with the new UA. **A JS challenge cannot be passed by any HTTP-client-side change** (UA, headers, pacing, retries) — it requires executing JavaScript, which `HTTP.jl` cannot do.

**9 Sept 2026 — Coppa Sabatini, four days later.** Ran the full predictor again with the mitigations in place. Same result: `pcs_specialty = 0/159`, `race_history = 0/159`. Every PCS response — rider profiles, `/race/.../result`, `/race/.../startlist/startlist-quality` — carried `Cf-Mitigated: challenge`. The block also now covers at least one Velogames endpoint outside the one already cache-seeded around (`ridescore.php`, same header signature), non-fatal here but a sign the surface is broadening. Four days' persistence across this many endpoints rules out "still-cooling IP from the original burst" — this reads as a sustained posture change on PCS's side, not transient rate-limiting.

## Current architecture (what's actually being fetched, and how)

- `src/pcs_scraper.jl` — `scrape_html_tables(pageurl)`: raw `HTTP.get` + Gumbo HTML parse. Used by the VG rider-pool fetch (`gettable` in `get_data.jl`).
- `src/get_data.jl:247` — `getpcs_rider_pts(ridername; ...)`: fetches `https://www.procyclingstats.com/rider/<slug>`, parses 5 `.xvalue` elements (specialty scores). Falls back to an all-`missing` row on 400/403/404 *or* on any unexpected element count — this is the code path that swallowed both the original block and the current JS challenge into innocuous-looking missing data.
- `src/get_data.jl:1080` — `getpcs_rider_pts_batch`: loops `getpcs_rider_pts` over every rider in the pool, one request each, no batching endpoint on PCS's side.
- `src/pcs_extended.jl` — `getpcs_race_results`, `getpcs_race_startlist`, `getpcs_rider_seasons`, `getpcs_race_history`, plus grand-tour stage variants. Same `HTTP.get` + parse pattern, same UA now, same vulnerability to a domain-wide challenge.
- `src/cache_utils.jl` — `CacheConfig{cache_dir, max_age_hours}`, on-disk Arrow + JSON, keyed by `sha256(url * params)`. This is what let a manually browser-scraped VG rider pool be seeded into the cache and read back by `cached_fetch` without a live fetch (the standing workaround for the *Velogames* block, used on both GP Industria and Coppa Sabatini this month) — but it only helps for the one URL seeded; every other PCS/VG call still fetches live.
- All of the above is Julia's `HTTP.jl`, no JS execution capability, no cookie-jar warm-up beyond what `HTTP.jl`'s default `CookieRequest` layer does automatically.

## Precedent: how the project already solved this for Velogames

Velogames has blocked `HTTP.jl` outright for longer than PCS has (documented in project memory since earlier this year). The fix was a separate Python package, `vgleague` (`~/code/vgleague`), using Playwright to drive a real browser. Relevant pieces, in `src/vgleague/scraper.py`:

- `looks_blocked(html, meta)` — checks `meta["headers"]["cf-mitigated"]`, status in `(403, 429)`, or known block-page markers in the HTML. This is exactly the signal PCS is now sending; `Velogames.jl`'s Julia side has no equivalent check anywhere.
- `BlockedError(ScrapeError)` — its own exception type, deliberately, with a docstring explaining why: a challenge page parses as valid HTML with none of the expected elements, so an undifferentiated failure reads as "site redesigned its markup" and sends whoever's debugging into the parser instead of at the real cause. (`getpcs_rider_pts`'s missing-value fallback is the Julia-side version of the exact trap this class exists to avoid.)
- `_goto(page, url, ...)` — navigates with retry-on-timeout, captures response status/headers, and treats a "successful" navigation that lands on a challenge page as a `BlockedError` after retries with backoff, rather than as success.
- `warmup(page, config)` — visits the site's homepage and dismisses the cookie-consent popup *before* any deep link, on the theory (borne out) that some WAFs challenge a session's first request if it goes straight to a deep URL with no prior "natural" pageview.
- Scraped rows are written into `Velogames.jl`'s own archive format via `write_snapshot(rows, data_type, slug, year, source_url=...)` — same Arrow files, same `ARCHIVE_TYPES`, so the Julia side reads it exactly like anything else in the archive (`load_vg_startlist`, etc.), no schema divergence.
- `vgleague` is currently Velogames-only: `LeagueConfig.base_url` and every scrape function are built around `velogames.com` URLs (`riders.php`, `ridescore.php`, `leaguescores.php`, `teamroster.php`). There is no PCS-scraping code in it today.

## Constraints (from project conventions)

- **Keep it simple. No defensive coding, no boilerplate** — this is a small personal package; whatever fix is chosen should not turn into a general-purpose scraping framework.
- **Julia stays the modelling core.** Nothing here should move estimation, optimisation, or rendering out of Julia — only the fetch layer for blocked sources is in question, matching how VG's fetch was already carved out.
- **The archive is the integration boundary.** Any fix should land data in `Velogames.jl`'s existing archive format (Arrow, `ARCHIVE_TYPES`) rather than inventing a second channel, exactly as `vgleague` already does for VG data.
- **Render is archive-only; nothing fetches during a render.** If PCS ends up needing browser-based ingestion, it should follow the same shape as VG: a separate ingest step that populates the archive, with `render_predictor.jl` reading from it — not a live browser call from inside the renderer.
- A predictor run currently still *completes* with PCS signal at zero (it degrades gracefully to VG-only, per `gt-stagehunter-underrating`/`gp-industria-pcs-specialty-scraper-broken` project memory) — so this is a signal-quality problem, not an availability outage. There's no emergency deadline, but two live races have now gone out on a materially weaker model.

## Open questions for evaluation

1. **Is a browser-based PCS fetch worth building at all**, given the burst size (up to ~160 rider-profile requests per race) and PCS's apparent willingness to escalate? A Playwright session that looks like a real browser may still get challenged at that volume — worth assessing before committing to the approach, rather than discovering it after building it.
2. **If yes, where does it live?** Extend `vgleague` with a parallel PCS-scraping module (shares its Playwright setup, `looks_blocked`/`BlockedError` pattern, and archive-writing plumbing, but its `LeagueConfig`/`base_url` model is Velogames-specific and would need generalising or duplicating), or a small standalone Python + Playwright tool dedicated to PCS, or something else?
3. **What's the ingest shape?** PCS specialty/history data is season-cumulative and slow-moving (unlike VG's per-race startlist) — does this look like a periodic full-field pull (e.g. weekly, matching the 7-day TTL already added Julia-side) that populates the archive ahead of races, rather than a per-race live fetch at all?
4. **Is there a lower-effort middle ground** before committing to full browser automation — e.g. capturing a browser-solved Cloudflare cookie (`cf_clearance`) and replaying it from `HTTP.jl` for a session? Worth naming as an option and its known fragility (tied to IP/fingerprint, short-lived) rather than dismissing it unassessed.
5. **Is it worth fixing at all right now**, versus leaning further into the signals that still work (VG season points, VG history, qualitative override for hilly/selective races per `gt-stagehunter-underrating`) until PCS's posture is better understood? The model has run and produced usable — if weaker — predictions on VG-only signal for two races running.

## What "fixed" looks like

A predictor run's data-quality summary shows non-zero `pcs_specialty` and `race_history` coverage again, sourced either from a live or recently-archived fetch, without `render_predictor.jl` itself performing any live network calls (per the archive-only rendering rule) — and the approach should not need re-solving every time PCS adjusts its Cloudflare rules.
