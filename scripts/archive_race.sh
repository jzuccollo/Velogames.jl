#!/usr/bin/env bash
set -euo pipefail

# Archive PCS and VG results for all current-season races that have
# predictions but are missing results.  Mirrors the assessor's logic:
# auto-detects VG race numbers via match_vg_race_number.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YEAR="${1:-$(date +%Y)}"

julia --project="$REPO_ROOT" -e "
using Velogames
using Dates

year = $YEAR
archive_dir = DEFAULT_ARCHIVE_DIR
pred_dir = joinpath(archive_dir, \"predictions\")
if !isdir(pred_dir)
    @info \"No predictions archive at \$pred_dir\"
    exit(0)
end

# Find races with predictions
race_slugs = String[]
for d in readdir(pred_dir; join=true)
    isdir(d) || continue
    isfile(joinpath(d, \"\$year.feather\")) || continue
    push!(race_slugs, basename(d))
end

isempty(race_slugs) && (@info \"No \$year predictions found\"; exit(0))

# Fetch VG racelist once for auto-detection
cache = CacheConfig(joinpath(homedir(), \".velogames_cache\"), 6)
vg_racelist = try
    getvgracelist(year; cache_config=cache)
catch e
    @warn \"Failed to fetch VG racelist: \$e\"
    nothing
end

for slug in sort(race_slugs)
    has_pcs = load_race_snapshot(\"pcs_results\", slug, year; archive_dir) !== nothing
    has_vg  = load_race_snapshot(\"vg_results\",  slug, year; archive_dir) !== nothing
    if has_pcs && has_vg
        @info \"Already archived: \$slug\"
        continue
    end

    # Auto-detect VG race number
    vg_num = 0
    if vg_racelist !== nothing
        ri = findfirst(r -> r.pcs_slug == slug, CLASSICS_RACES_2026)
        name = ri !== nothing ? CLASSICS_RACES_2026[ri].name : slug
        detected = match_vg_race_number(name, vg_racelist)
        if detected !== nothing
            vg_num = detected
        end
    end

    @info \"Archiving \$slug (vg_race_number=\$vg_num)...\"
    try
        archive_race_results(slug, year; vg_race_number=vg_num, cache_config=cache)
    catch e
        @warn \"Failed to archive \$slug: \$e\"
    end
end
@info \"Done.\"
"
