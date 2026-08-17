#!/usr/bin/env julia
"""
Record league winners for races the vgleague scrape has scored but the
archive's `league_winners.toml` hasn't caught up with yet.

Usage:
    julia --project scripts/auto_publish.jl [--dry-run] [--min-age-hours=24] [--config=PATH]

Walks **every** snapshot in the vgleague data directory (located via the
`[league]` section of `data/race_config.toml`), so both the classics league and
each grand tour are covered, and a league added later is picked up without
touching this script. Each snapshot's own `meta.year` dates it.

For a `classics` snapshot: every scored race becomes one `[[winners]]` entry,
its winner the highest-scoring entrant. For a `grand_tour`: the whole tour
becomes one entry, its winner the highest cumulative total.

Prints one `slug year score winner` line per appended race to stdout (nothing
when there is nothing to do), so a calling script can tell whether to bother
re-rendering. Reasoning goes to stderr.

Gates, all deliberate:
  * classics wait `--min-age-hours` (default 24) past the pick deadline.
    Velogames revises scores after a race, so a winner published the same
    evening can be wrong, and the record is append-only: a bad entry has to be
    unpicked by hand (and that race's rendered HTML deleted so it rebuilds).
  * a grand tour waits until **every** race in its catalogue is scored,
    End-of-Tour included — until then the cumulative totals are a partial sum
    and the leader is not the winner. Grand tour catalogues carry no deadlines
    (`deadline: null`), so this structural test replaces the age gate rather
    than adding to it.
  * a race whose top score is 0 is skipped: `ridescore.php` serves the full
    roster at zero for a race that hasn't been scored yet.
"""

using Velogames
using DataFrames, Dates, JSON3, TOML

const REPO = dirname(@__DIR__)

# Velogames games have their own slugs, unrelated to PCS's. Only the games that
# actually exist are listed: an unmapped one warns and is skipped rather than
# being guessed at, so the Vuelta (whose slug nobody here has seen yet) will
# announce itself in the log instead of publishing under a wrong race.
const GT_PCS_SLUG = Dict(
    "velogame" => "tour-de-france",
    "italy" => "giro-d-italia",
    "velogame-femmes" => "tour-de-france-femmes",
)

"""Winner row of a standings frame, ties broken by name so a re-run agrees with itself."""
top_entrant(df, score_col) = sort(df, [order(score_col, rev = true), :teamname])[1, :]

"""Record one winner (or say what it would record) and log it for the caller."""
function record!(appended, slug, year, name, score; dry_run)
    if dry_run
        @info "would append $slug $year: $name ($score)"
    else
        append_league_winner(slug, year, name, score)
    end
    push!(appended, slug)
    println("$slug $year $score $name")
end

function publish_classics!(appended, standings, meta, year, recorded, min_age_hours, dry_run)
    # Deadlines date each race: the catalogue is the only thing in the snapshot
    # that knows when a classic was ridden (team rows carry no timestamp).
    deadlines = Dict{Int,DateTime}(
        parse(Int, String(k)) => DateTime(String(v["deadline"]), "yyyy-mm-dd HH:MM:SS")
        for (k, v) in pairs(meta.race_catalogue) if
        get(v, "deadline", nothing) !== nothing
    )

    for g in sort(collect(groupby(standings, :race_name)); by = g -> g.race_number[1])
        race_name = String(g.race_name[1])
        race_number = g.race_number[1]

        slug = league_race_slug(race_name)
        if isempty(slug)
            @info "skip $race_name: not a known classic (missing from CLASSICS_RACES_2026?)"
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

        top = top_entrant(DataFrame(g), :score)
        if top.score <= 0
            @info "skip $slug: nobody has scored yet"
            continue
        end
        record!(appended, slug, year, String(top.teamname), Int(round(top.score)); dry_run)
    end
end

function publish_grand_tour!(appended, standings, meta, year, recorded, dry_run)
    game_slug = String(meta.game_slug)
    slug = get(GT_PCS_SLUG, game_slug, "")
    if isempty(slug)
        @info "skip $game_slug $year: no PCS slug mapped for that Velogames game (add it to GT_PCS_SLUG)"
        return
    end
    (slug, year) in recorded && return

    catalogue = Set(parse(Int, String(k)) for k in keys(meta.race_catalogue))
    unscored = setdiff(catalogue, Set(Int.(standings.race_number)))
    if !isempty(unscored)
        @info "skip $slug: $(length(unscored)) of $(length(catalogue)) races unscored, so the tour isn't over"
        return
    end

    # scored_total in the snapshot equals the sum of the per-race scores exactly,
    # so summing what the shared loader returns avoids a second way of reading
    # the same file.
    totals = combine(groupby(standings, [:username, :teamname]), :score => sum => :total)
    top = top_entrant(totals, :total)
    if top.total <= 0
        @info "skip $slug: nobody has scored yet"
        return
    end
    record!(appended, slug, year, String(top.teamname), Int(round(top.total)); dry_run)
end

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

    data_dir = expanduser(league["vgleague_data_dir"])
    isdir(data_dir) || error("No vgleague data directory at $data_dir (has the scrape run?)")
    snapshots = sort(filter(p -> endswith(p, ".json"), readdir(data_dir; join = true)))
    isempty(snapshots) && error("No vgleague snapshots in $data_dir (has the scrape run?)")

    recorded = Set((w.pcs_slug, w.year) for w in load_league_winners())
    appended = String[]

    for path in snapshots
        meta = JSON3.read(read(path, String)).meta
        series = String(get(meta, :series_type, ""))
        year = Int(meta.year)
        standings = load_league_standings(path)
        if isempty(standings)
            @info "skip $(basename(path)): no scraped races"
            continue
        end

        if series == "classics"
            publish_classics!(
                appended,
                standings,
                meta,
                year,
                recorded,
                min_age_hours,
                dry_run,
            )
        elseif series == "grand_tour"
            publish_grand_tour!(appended, standings, meta, year, recorded, dry_run)
        else
            @info "skip $(basename(path)): unknown series_type $(repr(series))"
        end
    end

    isempty(appended) && @info "Nothing to publish"
    return
end

main(ARGS)
