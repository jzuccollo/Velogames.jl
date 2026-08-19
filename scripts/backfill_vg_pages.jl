#!/usr/bin/env julia
# ---------------------------------------------------------------------------
# backfill_vg_pages.jl — capture the Velogames pages that retire (WP1d)
#
# Velogames takes a season's pages down. `sixes-classics/2025/riders.php`, its
# `sixes-superclasico` alias, and `races.php` for both 2024 and 2025 all 404 as
# of August 2026, and nothing else has what they held:
#
#   - `vg_results` carries no cost column;
#   - the published race reports show a display slice (71% of 2025 rider-rows);
#   - the vgleague snapshots record what entrants picked, never the unpicked
#     field (62%, and they start at 2026 anyway).
#
# Grand tours were never exposed — `vg_stage_riders` has archived their pools
# since 2023 and `load_stage_race_report_data` reads it first. This is the
# one-day path catching up.
#
# Live seasons come from Velogames. Retired ones come from the Internet Archive,
# whose snapshots are pinned by timestamp below so a re-run fetches the same
# bytes. Verified at capture: the 2025 pool covers 2,016 of 2,016 rider-rows
# across all 40 archived 2025 classics.
#
# Idempotent: skips anything already archived unless --force.
#
# Run:  julia --project scripts/backfill_vg_pages.jl [--force] [--dry-run]
# ---------------------------------------------------------------------------

using Velogames
using DataFrames
using Printf

const FORCE = "--force" in ARGS
const DRY_RUN = "--dry-run" in ARGS

wayback(ts, url) = "https://web.archive.org/web/$(ts)id_/$url"

# (data_type, vg_slug, year, source url). A Wayback URL means Velogames no
# longer serves the page; the bare URL means it is still live.
const SOURCES = [
    (
        "vg_riders",
        "sixes-superclasico",
        2025,
        wayback(20251216115244, "https://www.velogames.com/sixes-superclasico/2025/riders.php"),
    ),
    (
        "vg_racelist",
        "sixes-superclasico",
        2025,
        wayback(20251216182151, "https://www.velogames.com/sixes-superclasico/2025/races.php"),
    ),
    ("vg_riders", "sixes-classics", 2026, "https://www.velogames.com/sixes-classics/2026/riders.php"),
    ("vg_racelist", "sixes-classics", 2026, "https://www.velogames.com/sixes-classics/2026/races.php"),
]

"""
Parse a rider pool the same way `getvg_riders` does, from an arbitrary URL —
the Wayback copy is the same HTML at a different address.
"""
function fetch_riders(url::String)
    df = Velogames.gettable(url)
    hasproperty(df, :class) && rename!(df, :class => :classraw)
    hasproperty(df, :classraw) &&
        (df.class = lowercase.(replace.(df.classraw, " " => "")))
    hasproperty(df, :team) && (df.team = Velogames.unpipe.(df.team))
    df.value = df.points ./ df.cost
    return df
end

function main()
    @printf("%-13s %-22s %-6s %s\n", "TYPE", "SLUG", "YEAR", "RESULT")
    failures = 0
    for (data_type, slug, year, url) in SOURCES
        if !FORCE && has_race_snapshot(data_type, slug, year)
            @printf("%-13s %-22s %-6d already archived, skipped\n", data_type, slug, year)
            continue
        end
        if DRY_RUN
            @printf("%-13s %-22s %-6d would fetch %s\n", data_type, slug, year, url)
            continue
        end
        try
            df =
                data_type == "vg_riders" ? fetch_riders(url) :
                Velogames.parse_vg_racelist(url)
            if nrow(df) == 0
                @printf("%-13s %-22s %-6d EMPTY — not archived\n", data_type, slug, year)
                failures += 1
                continue
            end
            save_race_snapshot(df, data_type, slug, year)
            @printf("%-13s %-22s %-6d archived %d rows × %d cols\n",
                    data_type, slug, year, nrow(df), ncol(df))
        catch e
            @printf("%-13s %-22s %-6d FAILED: %s\n", data_type, slug, year, sprint(showerror, e))
            failures += 1
        end
    end

    DRY_RUN && return 0

    # Coverage check: every rider in every archived one-day result for a season
    # must have a cost in that season's pool, or a report cannot be rebuilt.
    println()
    println("Coverage of archived vg_results by the archived pool:")
    worst = 0.0
    for year in (2025, 2026)
        pool = load_vg_classics_riders(year)
        have = Set(pool.riderkey)
        tot = cov = 0
        uncovered = Tuple{String,String}[]
        for slug in archive_races("vg_results")
            (year in archive_years("vg_results", slug)) || continue
            haskey(Velogames._STAGE_RACE_VG_SLUGS, slug) && continue
            res = load_race_snapshot("vg_results", slug, year)
            tot += nrow(res)
            for r in eachrow(res)
                r.riderkey in have ? (cov += 1) : push!(uncovered, (slug, r.rider))
            end
        end
        pct = tot == 0 ? 100.0 : 100cov / tot
        worst = max(worst, 100.0 - pct)
        @printf("  %d: %d/%d rider-rows (%.1f%%), pool %d riders\n",
                year, cov, tot, pct, nrow(pool))
        # Name the uncovered riders rather than reporting a bare percentage: a
        # rider who scored but is absent from the pool is silently dropped from
        # that race's report by the left join, so the gap is invisible downstream.
        for (slug, rider) in uncovered
            println("      uncovered: ", rider, " (", slug, ")")
        end
    end

    if failures > 0
        println("\n$failures fetch failure(s) — rerun, or pin a new Internet Archive snapshot.")
        return 1
    end
    if worst > 0.0
        @printf("\nArchived, with a shortfall of %.1fpp — see the uncovered riders above.\n", worst)
        return 0
    end
    println("\nEvery archived one-day result has a cost. The seasons are self-contained.")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
