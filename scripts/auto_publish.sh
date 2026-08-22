#!/usr/bin/env bash
# Publish the report for any league race that has been scored in the vgleague
# scrape but has no winner recorded in the archive yet.
#
# This is the whole publishing path for one-day races, and since Phase 2 it is
# explicitly phased. Each step either ran or it did not, each records a row in
# the archive's `_runs/` log, and each gates the next:
#
#   ingest-league  scripts/ingest_league.jl   the vgleague scrape into the archive
#   derive         scripts/auto_publish.jl    the winner, from the snapshot
#                                             contemporaneous with the race
#   ingest-race    scripts/ingest.jl          that race's results into the archive
#   render         scripts/render_reports.jl  reads the archive; fetches nothing
#   deploy         scripts/deploy_site.sh
#
# `ingest-vg` — the Velogames half — is not here. It runs on the vgleague side,
# as `vgleague ingest-all` in the job that fires this hook, because since August
# 2026 velogames.com answers 403 to anything that is not a browser and Python is
# the half that drives one.
#
# Safe to run on every tick — it exits without touching anything when there is
# nothing new.
#
# Intended to run from the vgleague update job's POST_UPDATE_HOOK against a
# dedicated deploy clone (not a dev working directory), so it only ever
# publishes committed, pushed code.
#
# Usage: auto_publish.sh [--dry-run] [--config=PATH] [--min-age-hours=N]
#                        [--redrive=PCS_SLUG]
# --dry-run is read-only end to end: it skips the pull and tells the ingest to
# write nothing.
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

    # Parsed rather than forwarded. `--config=` belongs to ingest_league.jl and
    # nothing else; forwarding "$@" to auto_publish.jl meant it was accepted
    # there, ignored, and never reached the step that reads it.
    DRY_RUN=
    CONFIG_ARG=
    MIN_AGE_ARG=
    REDRIVE_ARG=
    for arg in "$@"; do
        case "$arg" in
            --dry-run)         DRY_RUN=1 ;;
            --config=*)        CONFIG_ARG="$arg" ;;
            --min-age-hours=*) MIN_AGE_ARG="$arg" ;;
            --redrive=*)       REDRIVE_ARG="$arg" ;;
            *)
                echo "auto_publish.sh: unrecognised argument $arg (known: --dry-run, --config=PATH, --min-age-hours=N, --redrive=PCS_SLUG)" >&2
                exit 2
                ;;
        esac
    done

    # No bash arrays anywhere in here: launchd's PATH finds /bin/bash, which is
    # 3.2, where expanding an empty array under `set -u` is an unbound-variable
    # error. `${VAR:+"$VAR"}` expands to one properly-quoted word or to nothing.
    jl() {
        script="$1"
        shift
        julia --project="$REPO_ROOT" "$REPO_ROOT/scripts/$script" "$@"
    }

    # One publish at a time: a render takes minutes and the hook can fire from
    # either vgleague job. mkdir is atomic; macOS ships no flock.
    #
    # The EXIT trap does not survive SIGKILL, a reboot or a power cut, and this
    # script exits 0 on contention — so a lock left behind by any of those would
    # disable publishing for ever while launchd went on recording success. A
    # render takes minutes, so anything an hour old is taken over, loudly.
    LOCK_DIR="$REPO_ROOT/.velogames-publish.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
            echo "=== $(date '+%Y-%m-%d %H:%M:%S') velogames publish: BREAKING STALE LOCK held since $(date -r "$LOCK_DIR" '+%Y-%m-%d %H:%M:%S') — a previous run died without releasing it ===" >&2
            rmdir "$LOCK_DIR" 2>/dev/null
        fi
        # Retried rather than assumed: two runs can reach the break together and
        # only one of them can win the mkdir.
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            echo "=== $(date '+%Y-%m-%d %H:%M:%S') velogames publish: another run holds the lock; exiting ==="
            exit 0
        fi
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

    # One id across every phase of this publish, so the five steps — three Julia
    # processes, this shell and the deploy — read back from `_runs/` as one run
    # rather than as five that have to be correlated on their timestamps.
    VELOGAMES_RUN_ID="$(date -u '+%Y%m%dT%H%M%S')-$$"
    export VELOGAMES_RUN_ID

    echo "=== $(date '+%Y-%m-%d %H:%M:%S') velogames auto-publish starting in $REPO_ROOT (run $VELOGAMES_RUN_ID) ==="

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
    # vgleague repo; everything after it reads the archive. It ran before the
    # dry-run exit below until August 2026, which made --dry-run write to the
    # append-only raw tier — so it now takes the flag itself.
    echo "--- ingesting league snapshots ---"
    if ! jl ingest_league.jl ${DRY_RUN:+--dry-run} ${CONFIG_ARG:+"$CONFIG_ARG"}; then
        echo "ingest_league.jl failed; aborting before anything is published." >&2
        exit 1
    fi

    echo "--- deriving league winners ---"
    NEW="$(jl auto_publish.jl ${DRY_RUN:+--dry-run} ${MIN_AGE_ARG:+"$MIN_AGE_ARG"} ${REDRIVE_ARG:+"$REDRIVE_ARG"})"
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

    # Fetch-and-store, as a phase. Rendering does not scrape any more, so a race
    # whose results are not in the archive by this point produces no page — and
    # the deletion below has already removed the page it had. Failing here leaves
    # the winner recorded and the old HTML intact for the retry, which is the
    # whole reason this runs before the deletion rather than after it.
    echo "--- ingesting race results ---"
    if ! jl ingest.jl --pending; then
        echo "ingest.jl could not complete a race the league has settled; nothing rendered or deployed." >&2
        echo "If a Velogames result is what is missing, run 'vgleague ingest-all' in the vgleague clone: velogames.com answers 403 to anything that is not a browser." >&2
        exit 1
    fi

    # The incremental build skips any report whose HTML already exists, so a race
    # rendered before its winner was known would keep its winner-less page for ever.
    # Delete exactly the pages just given a winner and let the build put them back.
    while read -r slug yr _; do
        [ -z "$slug" ] && continue
        rm -f "site/docs/reports/$slug-$yr.html"
    done <<< "$NEW"

    # Reads the archive and nothing else. It re-renders only the reports that do
    # not exist, which after the deletion above is exactly the races just given a
    # winner.
    echo "--- rendering reports ---"
    if ! jl render_reports.jl; then
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
