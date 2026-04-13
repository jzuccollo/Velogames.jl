#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <pcs_slug> <year> <winner_name> <winner_score>"
    echo ""
    echo "Example: $0 tour-de-france 2026 \"Team Name\" 12345"
    echo ""
    echo "Appends the winner to data/league_winners.toml, archives stage race"
    echo "data, regenerates reports, commits, and pushes."
    exit 1
}

[[ $# -ne 4 ]] && usage

PCS_SLUG="$1"
YEAR="$2"
WINNER_NAME="$3"
WINNER_SCORE="$4"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOML_FILE="$REPO_ROOT/data/league_winners.toml"

# Append winner entry
cat >> "$TOML_FILE" <<EOF

[[winners]]
pcs_slug = "$PCS_SLUG"
year = $YEAR
name = "$WINNER_NAME"
score = $WINNER_SCORE
EOF

echo "Added $WINNER_NAME ($WINNER_SCORE) for $PCS_SLUG $YEAR"

# Archive stage race data before VG URLs expire
echo "Archiving stage race data..."
julia --project="$REPO_ROOT" -e "
using Velogames
archive_stage_race_results(\"$PCS_SLUG\", $YEAR)
"

# Generate HTML reports
echo "Generating reports..."
julia --project="$REPO_ROOT" "$REPO_ROOT/scripts/render_reports.jl"

# Commit and push
echo "Committing..."
cd "$REPO_ROOT"
git add data/league_winners.toml site/docs/
git commit -m "Add $PCS_SLUG $YEAR stage race report ($WINNER_NAME, $WINNER_SCORE)"
git push

echo "Done."
