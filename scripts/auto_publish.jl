#!/usr/bin/env julia
"""
Record league winners for races the vgleague scrape has scored but the
archive's `league_winners.toml` hasn't caught up with yet.

Usage:
    julia --project scripts/auto_publish.jl [--dry-run] [--min-age-hours=24] [--config=PATH]

Reads the `[league]` section of `data/race_config.toml` (the same block
`scripts/league_eval.jl` uses) to find the vgleague JSON snapshot, then for
every scored classic in it: maps the league's race name to a PCS slug, takes
the highest-scoring entrant as that race's winner, and appends a `[[winners]]`
entry.

Prints one `slug year score winner` line per appended race to stdout (nothing
when there is nothing to do), so a calling script can tell whether to bother
re-rendering. Reasoning goes to stderr.

Gates, all deliberate:
  * `--min-age-hours` (default 24) — Velogames revises scores after a race, so
    a winner published the same evening can be wrong. Waiting a day costs
    nothing, and the record is append-only: a bad entry has to be unpicked by
    hand (and that race's rendered HTML deleted so it rebuilds).
  * grand tours are skipped — they get one entry for the whole tour via
    `publish_stage_race.sh`, not one per stage.
  * a race whose top score is 0 is skipped: `ridescore.php` serves the full
    roster at zero for a race that hasn't been scored yet.
"""

using Velogames
using DataFrames, Dates, JSON3, TOML

const REPO = dirname(@__DIR__)

function main(args)
    dry_run = "--dry-run" in args
    min_age_hours = 24.0
    config_path = joinpath(REPO, "data", "race_config.toml")
    for arg in args
        if startswith(arg, "--min-age-hours=")
            min_age_hours = parse(Float64, split(arg, "="; limit = 2)[2])
        elseif startswith(arg, "--config=")
            config_path = expanduser(split(arg, "="; limit = 2)[2])
        end
    end

    isfile(config_path) ||
        error("No config at $config_path (needs a [league] section — see race_config.toml.example)")
    league = get(TOML.parsefile(config_path), "league", Dict())
    isempty(league) && error("No [league] section in $config_path")

    year = Int(league["year"])
    json_path = joinpath(
        expanduser(league["vgleague_data_dir"]),
        "$(league["game_slug"])_$(year)_$(league["league_id"]).json",
    )
    isfile(json_path) || error("No vgleague snapshot at $json_path (has the scrape run?)")

    meta = JSON3.read(read(json_path, String)).meta
    series = String(get(meta, :series_type, ""))
    series == "classics" ||
        error("$(league["game_slug"]) is a $series league; stage races publish via publish_stage_race.sh")

    standings = load_league_standings(json_path)
    if isempty(standings)
        @info "No scraped races in $json_path"
        return
    end

    recorded = Set((w.pcs_slug, w.year) for w in load_league_winners())

    # Deadlines date each race: the catalogue is the only thing in the snapshot
    # that knows when a classic was ridden (team rows carry no timestamp).
    deadlines = Dict{Int,DateTime}(
        parse(Int, String(k)) => DateTime(String(v["deadline"]), "yyyy-mm-dd HH:MM:SS")
        for (k, v) in pairs(meta.race_catalogue) if haskey(v, "deadline")
    )

    appended = String[]
    for g in sort(collect(groupby(standings, :race_name)); by = g -> g.race_number[1])
        race_name = String(g.race_name[1])
        race_number = g.race_number[1]

        slug = league_race_slug(race_name)
        if isempty(slug)
            @info "skip $race_name: not a known classic (grand tour stage, or missing from CLASSICS_RACES_2026)"
            continue
        end
        (slug, year) in recorded && continue

        deadline = get(deadlines, race_number, nothing)
        if deadline === nothing
            @info "skip $slug: no deadline in the race catalogue, so its age can't be checked"
            continue
        end
        age_hours = (now() - deadline) / Hour(1)
        if age_hours < min_age_hours
            @info "skip $slug: scored $(round(age_hours; digits = 1))h ago, holding until $(min_age_hours)h"
            continue
        end

        # Ties broken by name so a re-run can't pick a different winner.
        top = sort(DataFrame(g), [order(:score, rev = true), :teamname])[1, :]
        if top.score <= 0
            @info "skip $slug: nobody has scored yet"
            continue
        end

        score = Int(round(top.score))
        if dry_run
            @info "would append $slug $year: $(top.teamname) ($score)"
        else
            append_league_winner(slug, year, String(top.teamname), score)
        end
        push!(appended, slug)
        println("$slug $year $score $(top.teamname)")
    end

    isempty(appended) && @info "Nothing to publish"
    return
end

main(ARGS)
