#!/usr/bin/env bash
# Bring the archive up to date for every league race the vgleague scrape has
# scored: the snapshots, the derived winners, and the ProCyclingStats results.
#
# **This no longer renders or deploys anything.** Since Phase 3b the whole site —
# race reports, rider dossier, league pages — is built by `vgleague build` and
# deployed once, from the job that calls this. So what is left here is the ETL,
# and the ordering that matters is that it runs *before* that build:
#
#   ingest-league  scripts/ingest_league.jl   the vgleague scrape into the archive
#   derive         scripts/auto_publish.jl    each race's winner, from the
#                                             snapshot contemporaneous with it
#   ingest-race    scripts/ingest.jl          that race's results into the archive
#
# `ingest-vg` — the Velogames half — is not here either. It runs on the vgleague
# side, as `vgleague ingest-all` in the job that fires this hook, because since
# August 2026 velogames.com answers 403 to anything that is not a browser and
# Python is the half that drives one.
#
# Three things went with the render step, and none of them is missed. The
# publish lock is still taken, because `append_league_winners` is
# read-modify-write and two runs would lose a winner silently — but it no longer
# has to hold for the minutes a render took. The dance where a race's HTML was
# deleted so the incremental build would replace a winner-less page is gone: the
# Python build renders every page every time, from an archive that is a pure
# function of what has been ingested. And a failure here no longer takes the
# site offline; the build simply runs against the archive as it stood.
#
# Safe to run on every tick.
#
# Intended to run from the vgleague update job's POST_UPDATE_HOOK against a
# dedicated deploy clone (not a dev working directory), so it only ever runs
# committed, pushed code.
#
# The name is historical — it published, once. It is kept because the deploy
# machine's POST_UPDATE_HOOK points at this path, and a rename that missed that
# would stop the hook silently.
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

    # One run at a time. `append_league_winners` is read-modify-write, so two
    # concurrent runs lose a winner silently — and the hook can fire from either
    # vgleague job. mkdir is atomic; macOS ships no flock.
    #
    # The EXIT trap does not survive SIGKILL, a reboot or a power cut, and this
    # script exits 0 on contention — so a lock left behind by any of those would
    # disable the ingest for ever while launchd went on recording success.
    # Anything an hour old is taken over, loudly.
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

    # One id across every phase, so the three Julia processes and this shell read
    # back from `_runs/` as one run rather than as four to be correlated on their
    # timestamps.
    VELOGAMES_RUN_ID="$(date -u '+%Y%m%dT%H%M%S')-$$"
    export VELOGAMES_RUN_ID

    echo "=== $(date '+%Y-%m-%d %H:%M:%S') velogames auto-publish starting in $REPO_ROOT (run $VELOGAMES_RUN_ID) ==="

    # The only git operation: fetch the code to run. Nothing is written back —
    # the winners record lives in the archive — so a git failure cannot wedge
    # the next run.
    if [ -z "$DRY_RUN" ]; then
        echo "--- git pull ---"
        if ! git pull --ff-only origin main; then
            echo "git pull failed (clone diverged from origin/main?); aborting." >&2
            exit 1
        fi
    fi

    # The only step that reads the vgleague repo; everything after it reads the
    # archive. It ran before the dry-run exit below until August 2026, which made
    # --dry-run write to the append-only raw tier, so it now takes the flag
    # itself.
    echo "--- ingesting league snapshots ---"
    if ! jl ingest_league.jl ${DRY_RUN:+--dry-run} ${CONFIG_ARG:+"$CONFIG_ARG"}; then
        echo "ingest_league.jl failed; aborting before anything is derived from it." >&2
        exit 1
    fi

    echo "--- deriving league winners ---"
    NEW="$(jl auto_publish.jl ${DRY_RUN:+--dry-run} ${MIN_AGE_ARG:+"$MIN_AGE_ARG"} ${REDRIVE_ARG:+"$REDRIVE_ARG"})"
    status=$?
    if [ $status -ne 0 ]; then
        echo "auto_publish.jl failed (exit $status); aborting." >&2
        exit $status
    fi

    if [ -n "$NEW" ]; then
        echo "$NEW"
    else
        echo "--- no new league winners ---"
    fi

    if [ -n "$DRY_RUN" ]; then
        echo "=== dry run: nothing written ==="
        exit 0
    fi

    # Fetch-and-store, as a phase. Runs whether or not a winner was newly
    # derived: `--pending` is every race that *has* a recorded winner and no
    # archived results, so a race whose fetch failed on an earlier tick is
    # retried here rather than waiting for another winner to appear.
    #
    # A failure is reported and the run exits non-zero, but nothing downstream
    # is blocked by it — the build that follows renders every race the archive
    # can serve and leaves out the one it cannot.
    echo "--- ingesting race results ---"
    if ! jl ingest.jl --pending; then
        echo "ingest.jl could not complete a race the league has settled; the archive keeps the winners, so the next run retries." >&2
        echo "If a Velogames result is what is missing, run 'vgleague ingest-all' in the vgleague clone: velogames.com answers 403 to anything that is not a browser." >&2
        exit 1
    fi

    echo "=== $(date '+%Y-%m-%d %H:%M:%S') archive up to date ==="
}

main "$@"; exit $?
