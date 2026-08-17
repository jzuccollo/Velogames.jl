#!/usr/bin/env bash
set -euo pipefail

# The one manual publishing path left. One-day races publish themselves through
# auto_publish.sh, which derives the winner from the league scrape; grand tours
# do not, because the scraped totals and the recorded ones disagree by a handful
# of points (Giro 8351 vs 8359, Tour 11884 vs 11880) for reasons nobody has run
# down. Three races a year, and a wrong number would be published as fact.

usage() {
    echo "Usage: $0 <pcs_slug> <year> <winner_name> <winner_score>"
    echo ""
    echo "Example: $0 tour-de-france 2026 \"Team Name\" 12345"
    echo ""
    echo "Records the winner in the archive, regenerates reports and deploys."
    exit 1
}

[[ $# -ne 4 ]] && usage

PCS_SLUG="$1"
YEAR="$2"
WINNER_NAME="$3"
WINNER_SCORE="$4"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# render_reports.jl calls archive_stage_race_results itself, so there is no
# separate archiving step here.
julia --project="$REPO_ROOT" -e "
using Velogames
append_league_winner(\"$PCS_SLUG\", $YEAR, \"$WINNER_NAME\", $WINNER_SCORE)
println(\"Recorded $WINNER_NAME ($WINNER_SCORE) for $PCS_SLUG $YEAR\")
"

echo "Generating reports..."
julia --project="$REPO_ROOT" "$REPO_ROOT/scripts/render_reports.jl"

"$REPO_ROOT/scripts/deploy_site.sh"

echo "Done."
