#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <pcs_slug> <year> <winner_name> <winner_score>"
    echo ""
    echo "Example: $0 gent-wevelgem 2026 \"Team Name\" 1234"
    echo ""
    echo "Appends the winner to data/league_winners.toml and regenerates"
    echo "reports, then stops so you can review the page locally. Prompts"
    echo "before committing site/docs/ and pushing."
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

# Generate HTML reports directly (no Quarto needed)
echo "Generating reports..."
julia --project="$REPO_ROOT" "$REPO_ROOT/scripts/render_reports.jl"

REPORT_FILE="site/docs/reports/${PCS_SLUG}-${YEAR}.html"

# Stop for local review before publishing. league_winners.toml is gitignored,
# so only the rendered site is committed.
echo ""
echo "Review the report locally before publishing:"
echo "  open \"$REPO_ROOT/$REPORT_FILE\""
echo ""
read -r -p "Commit site/docs/ and push now? [y/N] " reply
if [[ "$reply" =~ ^[Yy]$ ]]; then
    cd "$REPO_ROOT"
    git add site/docs/
    git commit -m "Add $PCS_SLUG $YEAR race report ($WINNER_NAME, $WINNER_SCORE)"
    git push
    echo "Pushed."
else
    echo "Not pushed. When ready, run:"
    echo "  git -C \"$REPO_ROOT\" add site/docs/ && git -C \"$REPO_ROOT\" commit -m \"Add $PCS_SLUG $YEAR race report ($WINNER_NAME, $WINNER_SCORE)\" && git -C \"$REPO_ROOT\" push"
fi
