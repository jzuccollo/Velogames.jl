#!/usr/bin/env julia
"""
Take the vgleague scrape into the archive.

Usage:
    julia --project scripts/ingest_league.jl [--config=PATH] [--date=YYYY-MM-DD]
                                            [--force] [--dry-run]

Reads every `*.json` in the vgleague data directory (located via the `[league]`
section of `data/race_config.toml`) and writes three things per league-season
under `archive_dir()`:

  * `league/raw/{game_slug}_{year}_{league_id}/{YYYY-MM-DD}.json` — the scrape
    verbatim, dated and content-deduped, so a day on which nothing changed
    costs no file and every file that exists marks a real change;
  * `league/rosters/{game_slug}_{league_id}/{year}.arrow` — the entrant × race
    × rider panel;
  * `league/meta/{game_slug}_{league_id}/{year}.arrow` — the race catalogue.

This is the **only** thing in this package that reads the vgleague repo.
Everything downstream — the report renderer, the assessor, `league_eval.jl`,
`auto_publish.jl` — reads the archive, so the league's data survives the
machine it was scraped on, which the gitignored, backed-up-by-nothing JSON
directory did not.

Idempotent: run it as often as you like. `auto_publish.sh` runs it before every
publish, which is the ETL-then-publish ordering Phase 2 will formalise.

`--force` rebuilds `league/rosters` and `league/meta` from the newest snapshot
even where nothing changed. Run it after changing `league_rosters_frame` or
`league_meta_frame`: a finished season's scrape stops changing, so the ordinary
staleness test never fires again and the season keeps the table the old code
wrote.

`--dry-run` reports what it would write and writes nothing.
"""

using Velogames
using Dates, TOML

const REPO = dirname(@__DIR__)

function main(args)
    config_path = joinpath(REPO, "data", "race_config.toml")
    date = Dates.today()
    force = false
    dry_run = false
    for arg in args
        if startswith(arg, "--config=")
            config_path = expanduser(split(arg, "="; limit = 2)[2])
        elseif startswith(arg, "--date=")
            date = Date(split(arg, "="; limit = 2)[2])
        elseif arg == "--force"
            force = true
        elseif arg == "--dry-run"
            dry_run = true
        else
            error(
                "ingest_league.jl: unrecognised argument $(repr(arg)); known arguments are --config=PATH, --date=YYYY-MM-DD, --force and --dry-run",
            )
        end
    end

    isfile(config_path) || error(
        "No config at $config_path (needs a [league] section — see race_config.toml.example)",
    )
    league = get(TOML.parsefile(config_path), "league", Dict())
    isempty(league) && error("No [league] section in $config_path")

    dry_run && println("dry run: reporting what would be written, writing nothing")
    for r in ingest_league_dir(
        league["vgleague_data_dir"];
        date = date,
        force = force,
        dry_run = dry_run,
    )
        state = if r.snapshot_date === nothing
            r.rebuilt ? "unchanged, derived tables rebuilt from $(r.source_date)" : "unchanged"
        else
            "new snapshot $(r.snapshot_date)"
        end
        println("$(r.game_slug) $(r.year) $(r.league_id): $state, $(r.rows) roster rows")
    end
    return
end

main(ARGS)
