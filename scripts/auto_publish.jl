#!/usr/bin/env julia
"""
Record the league winner for any race the archive can now settle but hasn't.

Usage:
    julia --project scripts/auto_publish.jl [--dry-run] [--min-age-hours=24]
                                            [--redrive=PCS_SLUG]

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

The gates live in `derive_league_winners`. A classic waits `--min-age-hours`
(default 24) past its pick deadline, because Velogames revises scores after a
race and the record is not re-derived once written.

`--redrive=PCS_SLUG` drops that race's recorded winner and lets the same run
derive it again — the escape hatch for one that went in wrong, since a recorded
winner is otherwise permanent. Seeded rows are refused; see
`remove_league_winner`.
"""

using Velogames
using DataFrames, Dates

function main(args)
    dry_run = false
    min_age_hours = 24.0
    redrive = ""
    for arg in args
        if arg == "--dry-run"
            dry_run = true
        elseif startswith(arg, "--min-age-hours=")
            min_age_hours = parse(Float64, split(arg, "="; limit = 2)[2])
        elseif startswith(arg, "--redrive=")
            redrive = String(split(arg, "="; limit = 2)[2])
        else
            error(
                "auto_publish.jl: unrecognised argument $(repr(arg)); known arguments are --dry-run, --min-age-hours=N and --redrive=PCS_SLUG",
            )
        end
    end

    leagues = archived_leagues()
    isempty(leagues) && error(
        "No league snapshots in $(joinpath(archive_dir(), "league", "raw")) — run scripts/ingest_league.jl first.",
    )

    if !isempty(redrive)
        gone = 0
        for l in leagues
            n = if dry_run
                nrow(
                    filter(
                        r -> String(r.pcs_slug) == redrive,
                        Velogames.league_winners_frame(l.game_slug, l.year, l.league_id),
                    ),
                )
            else
                remove_league_winner(redrive, l.game_slug, l.year, l.league_id)
            end
            n > 0 &&
                @info "redrive: dropped $n recorded winner(s) for $redrive from $(l.game_slug) $(l.year)/$(l.league_id)"
            gone += n
        end
        gone == 0 && @info "redrive: nothing recorded for $redrive; deriving as usual"
    end

    # `derive_league_winners` only sees its own league-season's record, so two
    # archived leagues on the same game and year would each record every race.
    # This is the global guard.
    published = Set((w.pcs_slug, w.year) for w in load_league_winners())
    appended = String[]
    for l in leagues
        derived = derive_league_winners(
            l.game_slug,
            l.year,
            l.league_id;
            min_age_hours = min_age_hours,
        )
        isempty(derived) && continue

        new = filter(r -> !((String(r.pcs_slug), Int(r.year)) in published), derived)
        for r in eachrow(derived)
            (String(r.pcs_slug), Int(r.year)) in published &&
                @info "skip $(r.pcs_slug) $(r.year) for $(l.game_slug)/$(l.league_id): another league-season has already recorded it, and the site can only show one winner per race"
        end
        isempty(new) && continue

        if dry_run
            for r in eachrow(new)
                @info "would record $(r.pcs_slug) $(r.year): $(r.teamname) ($(Int(round(r.score)))) from the $(r.snapshot_date) snapshot"
            end
        else
            append_league_winners(new, l.game_slug, l.year, l.league_id)
        end
        # Outside the dry-run branch: auto_publish.sh keys `[ -z "$NEW" ]` off
        # this stdout.
        for r in eachrow(new)
            push!(published, (String(r.pcs_slug), Int(r.year)))
            push!(appended, r.pcs_slug)
            println("$(r.pcs_slug) $(r.year) $(Int(round(r.score))) $(r.teamname)")
        end
    end

    isempty(appended) && @info "Nothing to publish"
    return
end

"""Wrap `main` so the derivation appears in `_runs/` as its own phase."""
function logged(args)
    dry_run = "--dry-run" in args
    # A dry run derives nothing, so it logs nothing.
    dry_run && return main(args)
    return record_run("derive-winners") do
        main(args)
        return ("ok", "derivation complete")
    end
end

logged(ARGS)
