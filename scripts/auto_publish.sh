#!/usr/bin/env bash
# Publish the report for any league race that has been scored in the vgleague
# scrape but has no entry in data/league_winners.toml yet.
#
# Unattended equivalent of publish_race.sh: scripts/auto_publish.jl derives the
# winner from the league snapshot instead of asking you to type it, and this
# renders, commits and pushes without prompting. Safe to run on every tick —
# it exits without touching git when there is nothing new.
#
# Intended to run from the vgleague update job's POST_UPDATE_HOOK against a
# dedicated deploy clone (not a dev working directory), so it only ever
# publishes committed, pushed code. Pass --dry-run to see what it would do.
set -uo pipefail

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

if [ -z "$DRY_RUN" ]; then
    echo "--- git pull ---"
    if ! git pull --ff-only origin main; then
        echo "git pull failed (clone diverged from origin/main?); aborting." >&2
        exit 1
    fi

    # Refuse to run on a tree with edits to the paths we commit blind: this is
    # meant to be a deploy clone, and sweeping up someone's half-finished work
    # into an unattended push is the one failure with no easy undo.
    if [ -n "$(git status --porcelain -- data/league_winners.toml site/docs/)" ]; then
        echo "data/league_winners.toml or site/docs/ has uncommitted changes; aborting." >&2
        exit 1
    fi
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
    echo "render_reports.jl failed; league_winners.toml keeps the new entries so a re-run retries the render." >&2
    exit 1
fi

SLUGS="$(echo "$NEW" | awk '{print $1}' | paste -sd' ' -)"
echo "--- committing ---"
git add data/league_winners.toml site/docs/
# league_winners.toml has changed by this point, so there is always something to
# commit — a failure here is a real one (hook, identity, index lock), not an
# empty diff, and leaves the appended entries in place for the next run.
if ! git commit -m "Add race reports: $SLUGS"; then
    echo "git commit failed; new winners are still in data/league_winners.toml." >&2
    exit 1
fi
if ! git push; then
    echo "git push failed; the commit is local, so push it by hand (a later run's --ff-only pull will refuse once origin moves on)." >&2
    exit 1
fi

echo "=== $(date '+%Y-%m-%d %H:%M:%S') published $SLUGS ==="
