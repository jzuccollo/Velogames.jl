#!/usr/bin/env julia
"""
Fetch and archive everything the publication path needs for a completed race.

Usage:
    julia --project scripts/ingest.jl --race=PCS_SLUG --year=YYYY
    julia --project scripts/ingest.jl --pending [--years=2025,2026]
    julia --project scripts/ingest.jl --status --race=PCS_SLUG --year=YYYY

This is the ETL phase that used to be a side effect of rendering. Until Phase 2
`render_reports.jl` called `_ensure_results_archived`, so a report could scrape
PCS and Velogames, and a failed fetch and a race that had not happened produced
the same thing: no page. As a phase it either ran or it did not, and `_runs/`
records which.

`--pending` is what the publish path calls: every race the league has recorded a
winner for whose archive is short of a required type. Nothing to do is the normal
answer and exits 0.

**Exits non-zero when a race it was asked for is still short afterwards.** That
is the whole difference from the old arrangement — `auto_publish.sh` stops before
rendering rather than deploying a site with a race-shaped hole in it, and the
recorded winner stays in the archive for the retry.

`--status` fetches nothing and prints what the archive already holds.
"""

using Velogames
using DataFrames, Dates

function usage()
    println(strip("""
    Usage:
      julia --project scripts/ingest.jl --race=PCS_SLUG --year=YYYY
      julia --project scripts/ingest.jl --pending [--years=2025,2026]
      julia --project scripts/ingest.jl --status --race=PCS_SLUG --year=YYYY

    Known arguments: --race=, --year=, --years=, --pending, --status, --fresh
    """))
end

function print_status(c::RaceCompleteness)
    println("$(c.pcs_slug) $(c.year) ($(c.format))")
    for r in eachrow(c.types)
        mark = r.present ? "yes" : (r.required ? "MISSING" : "no")
        count = r.present ? " ($(r.rows) rows$(isempty(r.fetched_at) ? "" : ", $(r.fetched_at)"))" : ""
        println("  $(rpad(r.data_type, 20)) $(rpad(mark, 8))$count   — $(r.buys)")
    end
    println("  field: $(c.field_riders) riders, basis $(c.field_basis)")
    if c.unpriced_scorers > 0
        println(
            "  WARNING: $(c.unpriced_scorers) scorer(s) worth $(c.unpriced_points) points ($(round(100 * unpriced_share(c), digits = 1))% of the race) are in no price list",
        )
    end
end

function main(args)
    race = ""
    year = 0
    years = [2023, 2024, 2025, 2026]
    pending = false
    status = false
    fresh = false
    for arg in args
        if startswith(arg, "--race=")
            race = String(split(arg, "="; limit = 2)[2])
        elseif startswith(arg, "--year=")
            year = parse(Int, split(arg, "="; limit = 2)[2])
        elseif startswith(arg, "--years=")
            years = parse.(Int, split(split(arg, "="; limit = 2)[2], ","))
        elseif arg == "--pending"
            pending = true
        elseif arg == "--status"
            status = true
        elseif arg == "--fresh"
            fresh = true
        elseif arg in ("-h", "--help")
            usage()
            return 0
        else
            println(stderr, "ingest.jl: unrecognised argument $(repr(arg))")
            usage()
            return 2
        end
    end

    # A stale cache entry is the one thing that can make an ingest look like it
    # ran and change nothing, so the phase gets its own short TTL rather than the
    # week-long reporting default.
    cache = CacheConfig(DEFAULT_CACHE_DIR, fresh ? 0 : 6)

    if status
        (isempty(race) || year == 0) && (println(stderr, "--status needs --race= and --year="); return 2)
        print_status(race_completeness(race, year))
        return 0
    end

    targets = if pending
        !isempty(race) && println(stderr, "ingest.jl: --pending ignores --race=")
        pending_races(years)
    elseif !isempty(race) && year > 0
        [(race, year)]
    else
        println(stderr, "ingest.jl: give either --race= with --year=, or --pending")
        usage()
        return 2
    end

    if isempty(targets)
        println("Nothing to ingest.")
        return 0
    end

    run_id = new_run_id()
    results = IngestResult[]
    record_run(
        "ingest-race";
        run_id = run_id,
        items = ["$slug-$yr" for (slug, yr) in targets],
    ) do
        for (slug, yr) in targets
            println("--- $slug $yr ---")
            r = ingest_race(slug, yr; cache_config = cache)
            push!(results, r)
            println("  ", r)
        end
        failed = [r for r in results if !Velogames.ok(r)]
        detail = "$(length(results)) race(s); $(length(failed)) short of a required type"
        return (isempty(failed) ? "ok" : "partial", detail)
    end

    failed = [r for r in results if !Velogames.ok(r)]
    if !isempty(failed)
        println(stderr, "\nERROR: $(length(failed)) race(s) still missing required archive data:")
        for r in failed
            println(stderr, "  $(r.pcs_slug) $(r.year): $(join(r.still_missing, ", "))")
        end
        println(
            stderr,
            "Holding the publish — these races would render as a page-shaped hole. Re-run once the sources have them.",
        )
        return 1
    end

    gained = sum(length(r.gained) for r in results; init = 0)
    println("\nIngested $(length(results)) race(s); $gained archive file(s) gained.")
    return 0
end

exit(main(ARGS))
