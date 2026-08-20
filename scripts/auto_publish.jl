#!/usr/bin/env julia
"""
Record the league winner for any race the archive can now settle but hasn't.

Usage:
    julia --project scripts/auto_publish.jl [--dry-run] [--min-age-hours=24]

Walks **every** league-season in `archive_dir()/league/raw/`, so the classics
league and each grand tour are covered and a league added later is picked up
without touching this script. Each snapshot directory's own name dates it.
Nothing here reads the vgleague repo — `scripts/ingest_league.jl` does that,
and runs first.

For a `classics` league: every scored race becomes one winner row, its winner
the highest-scoring entrant. For a `grand_tour`: the whole tour becomes one
row, its winner the highest cumulative total.

Prints one `slug year score winner` line per recorded race to stdout (nothing
when there is nothing to do), so a calling script can tell whether to bother
re-rendering. Reasoning goes to stderr.

The gates live in `derive_league_winners`; the one that matters here is that a
classic waits `--min-age-hours` (default 24) past its pick deadline, because
Velogames revises scores after a race and the record is not re-derived once
written.
"""

using Velogames
using DataFrames, Dates

function main(args)
    dry_run = "--dry-run" in args
    min_age_hours = 24.0
    for arg in args
        if startswith(arg, "--min-age-hours=")
            min_age_hours = parse(Float64, split(arg, "="; limit = 2)[2])
        end
    end

    leagues = archived_leagues()
    isempty(leagues) && error(
        "No league snapshots in $(joinpath(archive_dir(), "league", "raw")) — run scripts/ingest_league.jl first.",
    )

    appended = String[]
    for l in leagues
        new = derive_league_winners(
            l.game_slug,
            l.year,
            l.league_id;
            min_age_hours = min_age_hours,
        )
        isempty(new) && continue
        if dry_run
            for r in eachrow(new)
                @info "would record $(r.pcs_slug) $(r.year): $(r.teamname) ($(Int(round(r.score)))) from the $(r.snapshot_date) snapshot"
            end
        else
            append_league_winners(new, l.game_slug, l.year, l.league_id)
        end
        for r in eachrow(new)
            push!(appended, r.pcs_slug)
            println("$(r.pcs_slug) $(r.year) $(Int(round(r.score))) $(r.teamname)")
        end
    end

    isempty(appended) && @info "Nothing to publish"
    return
end

main(ARGS)
