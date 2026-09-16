#!/usr/bin/env bash
# Bring the archive up to date for every league race the vgleague scrape has
# scored: the snapshots, the derived winners, and the ProCyclingStats results.
#
# It renders and deploys nothing: `vgleague build` builds and deploys the whole
# site from the job that calls this, and this ETL has to run before that build:
#
#   ingest-league  scripts/ingest_league.jl   the vgleague scrape into the archive
#   derive         scripts/auto_publish.jl    each race's winner, from the
#                                             snapshot contemporaneous with it
#   ingest-race    scripts/ingest.jl          that race's results into the archive
#
# `ingest-vg`, the Velogames half, runs on the vgleague side as `vgleague
# ingest-all` in the job that fires this hook.
#
# A failure here leaves the site up: the build runs against the archive as it
# stood.
#
# Safe to run on every tick.
#
# Intended to run from the vgleague update job's POST_UPDATE_HOOK against a
# dedicated deploy clone (not a dev working directory), so it only ever runs
# committed, pushed code.
#
# The name is historical. It is kept because the deploy machine's
# POST_UPDATE_HOOK points at this path, and a rename that missed that would stop
# the hook silently.
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
main() {
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    cd "$REPO_ROOT" || exit 1

    # Parsed, not forwarded: `--config=` belongs to ingest_league.jl alone, and
    # auto_publish.jl would otherwise accept and ignore it.
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

    # The caller logs a failure here as one line and carries on, so a hook that
    # fails every run looks like a hook that works. A notification lands on the
    # screen instead.
    on_exit() {
        status=$?
        rmdir "$LOCK_DIR" 2>/dev/null
        [ $status -eq 0 ] && return
        osascript -e "display notification \"auto_publish.sh exited $status — see ~/Library/Logs/vgleague-update.log or vgleague-check.log\" with title \"Velogames ETL failed\"" 2>/dev/null
    }

    # The pull brings a new Project.toml but never a Manifest.toml, which is
    # gitignored. A dependency added upstream is then missing from this clone's
    # manifest and every script dies at `using Velogames`. A pull that changes
    # Project.toml leaves it newer than the manifest, so the mtimes say when to
    # resolve.
    sync_manifest_if_project_changed() {
        [ "$REPO_ROOT/Project.toml" -nt "$REPO_ROOT/Manifest.toml" ] || return 0
        echo "--- Project.toml newer than Manifest.toml: resolving ---"
        if ! julia --project="$REPO_ROOT" -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()'; then
            echo "manifest sync failed; aborting rather than running against a stale environment." >&2
            exit 1
        fi
        touch "$REPO_ROOT/Manifest.toml"
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
    trap on_exit EXIT

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
        sync_manifest_if_project_changed
    fi

    # The only step that reads the vgleague repo; everything after it reads the
    # archive. It runs before the dry-run exit below, so it takes --dry-run
    # itself to keep a dry run out of the append-only raw tier.
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
