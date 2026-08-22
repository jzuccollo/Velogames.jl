# Cutting over to the single site

**Done, 22 August 2026.** Both repos are pushed to `main`; the deploy clones
fast-forward on their next tick. What follows is what was done and what is left,
kept because the "what to watch" section is still live and step 4 has not been
taken yet.

Read `docs/two-package-reconciliation.md` for why any of it is shaped this way.

## What changes at the moment of the push

| Before | After |
| --- | --- |
| Two Netlify sites, two builds, two navs | One site, one build, one nav |
| `vgleague build` → league pages only | `vgleague build` → league pages, race reports, dossier |
| Hook fires *after* the vgleague build and deploy | Hook fires *before* them |
| `auto_publish.sh` ingests, renders and deploys | `auto_publish.sh` ingests; that is all |
| Race reports rendered by `render_reports.jl` | Rendered by `vgleague`, verified against Julia |

The surviving site is **`dpcc-vgleague`** (`50f04887-…`). The retired one is
**`velogames-race-reports`** (`2de3e2e6-…`).

## Before pushing

Run the three cross-language checks from a vgleague clone. They take about four
minutes between them and they are the only thing standing between the port and a
silently wrong page.

```bash
cd ~/code/vgleague
vgleague verify-field      # 146 races: field, completeness, both hindsight teams
vgleague verify-report     # 144 reports: every table, every headline fact
vgleague verify-dossier    # 22,628 rides: riders.json and stages.json
```

All three must report zero differences. They shell out to `scripts/field_digest.jl`
and `scripts/report_dump.jl` in `$VELOGAMES_JL` (default `~/code/velogames`), so
that clone needs the branch checked out too.

Then build the whole site once and look at it:

```bash
vgleague build --output-dir /tmp/vgsite
python3 -m http.server -d /tmp/vgsite 8000
```

The build reports its own broken internal links and should say
`Every internal link resolves.`

## What remains

**Step 4 below — the redirects on the retired site — has NOT been done.** It is
deliberately last: until the surviving site has actually deployed with the
reports on it, the redirects would point at pages that are not there. Do it once
`https://dpcc-vgleague.netlify.app/races.html` serves the index.

## The push, in order (done, except step 4)

1. ~~**Push Velogames.jl.**~~ Done — `c5e36d3..adaedcd`. The ETL is what the vgleague job calls, so it has to be
   in place before the job that calls it changes.
   ```bash
   cd ~/code/velogames && git push origin phases-2-4-publication:main
   ```
   The deploy clone picks it up on the next tick's `git pull`. At this point the
   hook still runs at its old position (after the build) because the vgleague
   side has not changed yet — so for one tick, `auto_publish.sh` does the ETL and
   nothing renders the reports. The league site is unaffected; the race-reports
   site simply goes stale, which it already is.

2. ~~**Push vgleague.**~~ Done — through `7e4f81c`. The two new dependencies
   (`jinja2`, `highspy`) were also **pre-installed by hand** into the deploy
   clone's venv, so a failure in `sync_venv_if_deps_changed` cannot abort the
   scrape on the first tick.
   ```bash
   cd ~/code/vgleague && git push origin phases-2-4-publication:main
   ```
   The deploy clone pulls, `sync_venv_if_deps_changed` installs `jinja2` and
   `highspy` (both new), and the next build produces the whole site.

   **Watch that venv sync.** It is gated on `pyproject.toml` changing across the
   pull, which it does here. If it fails the script aborts rather than scraping
   against a stale environment — which is right, but it means a failure stops the
   scrape, so check the log rather than assuming.

3. **Check the surviving site** (pending the first tick) has `races.html`, `riders.html` and
   `reports/*.html` on it, and that the nav appears on the league pages.

4. **Only then, redirect the retired site.** — **still to do** Until step 3 the redirects would
   point at pages that are not there.
   ```bash
   cd ~/code/vgleague
   NETLIFY_AUTH_TOKEN=… NETLIFY_SITE_ID=2de3e2e6-0806-4aea-bf47-1fac5040b43c \
     npx --yes netlify-cli deploy --prod --dir=scripts/retired-site
   ```
   See `scripts/retired-site/README.md`. The two site ids are easy to confuse and
   the cost of confusing them is replacing the live site with three redirect
   rules.

## What to watch afterwards

- **The first tick.** The hook now runs before the build, so a hook failure shows
  up as a site one tick behind rather than as a missing deploy. Read the launchd
  log rather than inferring from the site.
- **The lock.** A check run is now nearer ten minutes than four (pacing between
  leagues, the hook, 144 reports). `local_update.sh` waits fifteen minutes for
  `.vgleague.lock` rather than five; if runs get longer still, that number has
  to follow or the twice-daily backstop starts skipping itself.
- **Build time.** The full build is around two minutes — every page every time,
  no incremental skipping. That is deliberate: the incremental version needed the
  publisher to delete a race's HTML by hand so a page rendered before its winner
  was known did not keep its winner-less copy for ever. If two minutes an hour
  becomes a problem, cache by archive mtime rather than by file existence.
- **The 76 pages with recovered riders.** The starter-filter fix means those
  races now carry riders they were missing, and their optimal and
  cheapest-beating teams change accordingly. That lands with this push, since the
  Python build renders everything fresh. Nothing to do; just do not be surprised
  by a diff on a 2023 race.
- **`site/docs/` in the Velogames.jl clones** is now dead weight. Nothing deploys
  it. `render_reports.jl` still writes there if run.

## What was deliberately not done

- **`render_reports.jl` is kept**, out of the publish path but not deleted. It is
  the reference implementation the three checks diff against, and deleting it
  would leave the published pages with nothing to be checked against. Delete it
  once the Python site has run a season.
- **The standings, matrix and squads page *bodies* are still Python strings.**
  Their chrome now comes from the same Jinja base as everything else, so there is
  one nav and one stylesheet; the bodies can follow whenever somebody is in
  there anyway. Converting them now would be about two thousand lines of churn
  with nothing to show a reader.
- **`auto_publish.sh` keeps its name**, which no longer describes what it does.
  The deploy machine's `POST_UPDATE_HOOK` points at that path, and a rename that
  missed it would stop the hook silently.
