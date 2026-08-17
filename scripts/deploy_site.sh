#!/usr/bin/env bash
# Deploy site/docs/ to Netlify.
#
# The race reports site used to publish by committing its generated HTML and
# letting a GitHub Pages action fire on push. That put git on the critical path
# of every race: a failed push meant the report never went live, and the next
# unattended run's --ff-only pull refused. Now the rendered site is build
# output — gitignored, deployed straight from disk — and git carries only code
# and the winners record.
#
# NETLIFY_AUTH_TOKEN / NETLIFY_SITE_ID come from a gitignored .env at the repo
# root (see .env.example). Same arrangement as the vgleague deploy clone.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

if [ -z "${NETLIFY_AUTH_TOKEN:-}" ] || [ -z "${NETLIFY_SITE_ID:-}" ]; then
    echo "NETLIFY_AUTH_TOKEN / NETLIFY_SITE_ID not set (expected in $REPO_ROOT/.env); aborting." >&2
    exit 1
fi

# site/docs/ is no longer tracked, so a clone that has never rendered has an
# empty one — and deploying that would replace the live site with nothing.
# Cheap guard against a genuine failure mode, not a hypothetical: pulling the
# commit that untracked these files deletes them from every existing clone.
if [ ! -f site/docs/index.html ]; then
    echo "site/docs/index.html is missing — run scripts/render_reports.jl before deploying." >&2
    exit 1
fi

echo "--- deploying site/docs to Netlify ---"
npx --yes netlify-cli deploy --prod --dir=site/docs
