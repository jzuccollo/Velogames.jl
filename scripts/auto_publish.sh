#!/usr/bin/env bash
# Publish the report for any league race that has been scored in the vgleague
# scrape but has no winner recorded in the archive yet.
#
# This is the whole publishing path for one-day races: scripts/ingest_league.jl
# takes the scrape into the archive, scripts/auto_publish.jl derives the winner
# from the snapshot contemporaneous with the race and records it, and this
# renders and deploys. Safe to run on every tick — it exits without touching
# anything when there is nothing new.
#
# Intended to run from the vgleague update job's POST_UPDATE_HOOK against a
# dedicated deploy clone (not a dev working directory), so it only ever
# publishes committed, pushed code. Pass --dry-run to see what it would do.
set -uo pipefail

# The body lives in a function, and `exit` shares the last line with the call,
# for the reason vgleague's local_check.sh does the same: this script pulls
# halfway through, and bash reads a script lazily by byte offset. A pull that
# rewrites this file underneath the running shell would otherwise resume at an
# offset that means nothing in the new text and execute whatever it lands on.
# Nearly demonstrated for real by the commit that moved deployment to Netlify,
# which rewrote the whole second half of this file.
main() {
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    cd "$REPO_ROOT" || exit 1

    DRY_RUN=
    for arg in "$@"; do
        [ "$arg" = "--dry-run" ] && DRY_RUN=1
    done

    # One publish at a time: a render takes minutes and the hook can fire from
    # either vgleague job. mkdir is atomic; macOS ships no flock.
    LOCK_DIR="$REPO_ROOT/.velogames-publish.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') velogames publish: another run holds the lock; exiting ==="
        exit 0
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

    echo "=== $(date '+%Y-%m-%d %H:%M:%S') velogames auto-publish starting in $REPO_ROOT ==="

    # The only git operation left: fetch the code to run. Nothing is written
    # back — the winners record lives in the archive and the site deploys from
    # disk — so a git failure can no longer keep a report offline or wedge the
    # next run.
    if [ -z "$DRY_RUN" ]; then
        echo "--- git pull ---"
        if ! git pull --ff-only origin main; then
            echo "git pull failed (clone diverged from origin/main?); aborting." >&2
            exit 1
        fi
    fi

    # ETL first, then publish. The ingest is the only step that reads the
    # vgleague repo; everything after it reads the archive.
    echo "--- ingesting league snapshots ---"
    if ! julia --project="$REPO_ROOT" "$REPO_ROOT/scripts/ingest_league.jl"; then
        echo "ingest_league.jl failed; aborting before anything is published." >&2
        exit 1
    fi

    echo "--- checking for unpublished races ---"
    NEW="$(julia --project="$REPO_ROOT" "$REPO_ROOT/scripts/auto_publish.jl" "$@")"
    status=$?
    if [ $status -ne 0 ]; then
        echo "auto_publish.jl failed (exit $status); aborting." >&2
        exit $status
    fi

    if [ -z "$NEW" ]; then
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') nothing to publish ==="
        exit 0
    fi

    echo "$NEW"

    if [ -n "$DRY_RUN" ]; then
        echo "=== dry run: nothing written ==="
        exit 0
    fi

    # The incremental build skips any report whose HTML already exists, so a race
    # rendered before its winner was known would keep its winner-less page for ever.
    # Delete exactly the pages just given a winner and let the build put them back.
    while read -r slug yr _; do
        [ -z "$slug" ] && continue
        rm -f "site/docs/reports/$slug-$yr.html"
    done <<< "$NEW"

    # render_reports.jl archives the PCS/VG results for the winners just appended,
    # then renders only the reports that don't exist yet.
    echo "--- rendering reports ---"
    if ! julia --project="$REPO_ROOT" "$REPO_ROOT/scripts/render_reports.jl"; then
        echo "render_reports.jl failed; the archive keeps the new winners so a re-run retries the render." >&2
        exit 1
    fi

    SLUGS="$(echo "$NEW" | awk '{print $1}' | paste -sd' ' -)"

    if ! "$REPO_ROOT/scripts/deploy_site.sh"; then
        echo "deploy failed; the new winners are already recorded, so a re-run retries the render and deploy." >&2
        exit 1
    fi

    echo "=== $(date '+%Y-%m-%d %H:%M:%S') published $SLUGS ==="
}

main "$@"; exit $?
