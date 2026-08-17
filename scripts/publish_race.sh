#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <pcs_slug> <year> <winner_name> <winner_score>"
    echo ""
    echo "Example: $0 gent-wevelgem 2026 \"Team Name\" 1234"
    echo ""
    echo "Appends the winner to data/league_winners.toml and regenerates"
    echo "reports, then stops so you can review the page locally. Prompts"
    echo "before deploying the site and recording the winner in git."
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

# League standings live in the sibling vgleague package (../vgleague), not here
# (see docs/remediation-plan.md D1 — we read its JSON cache rather than
# scraping standings ourselves). Remind to refresh it so scripts/league_eval.jl's
# cumulative-placement section stays current.
echo ""
echo "Reminder: run 'vgleague update <league>' in ../vgleague to refresh league"
echo "standings for $PCS_SLUG $YEAR, then re-run scripts/league_eval.jl."

# Generate HTML reports directly (no Quarto needed)
echo "Generating reports..."
julia --project="$REPO_ROOT" "$REPO_ROOT/scripts/render_reports.jl"

REPORT_FILE="site/docs/reports/${PCS_SLUG}-${YEAR}.html"

# Stop for local review before publishing. The rendered site is deployed to
# Netlify straight from disk; only the winner entry appended above is committed
# — league_winners.toml is the input the reports are built from, and its
# contents (winning team name and score) are already public in those pages.
echo ""
echo "Review the report locally before publishing:"
echo "  open \"$REPO_ROOT/$REPORT_FILE\""
echo ""
read -r -p "Deploy the site and record the winner in git now? [y/N] " reply
if [[ "$reply" =~ ^[Yy]$ ]]; then
    "$REPO_ROOT/scripts/deploy_site.sh"
    cd "$REPO_ROOT"
    git add data/league_winners.toml
    git commit -m "Add $PCS_SLUG $YEAR race winner ($WINNER_NAME, $WINNER_SCORE)"
    git push
    echo "Deployed and pushed."
else
    echo "Not deployed. When ready, run:"
    echo "  \"$REPO_ROOT/scripts/deploy_site.sh\""
    echo "  git -C \"$REPO_ROOT\" add data/league_winners.toml && git -C \"$REPO_ROOT\" commit -m \"Add $PCS_SLUG $YEAR race winner ($WINNER_NAME, $WINNER_SCORE)\" && git -C \"$REPO_ROOT\" push"
fi
