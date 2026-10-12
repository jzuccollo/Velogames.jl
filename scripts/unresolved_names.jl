#!/usr/bin/env julia
"""
Every printed rider name that no rule or override resolved against its field,
one row per (source, race, year, name), as CSV on stdout.

The Julia twin of `vgleague unresolved-names`, which groups the same rows by
name and sorts out the non-starters; this emits the rows only, so the two
resolvers can be compared row for row. The frames are the ones the
publication and the model resolve: every market book and the `predictions`
and `pcs_specialty` frames against the race's report field, and PCS one-day
results against the season pool where the field is `:pool_pcs_filtered`.
Reads the archive and fetches nothing.

Usage:
    julia --project scripts/unresolved_names.jl [--years=2026] > unresolved.csv
"""

using Velogames, DataFrames

const YEARS = let arg = findfirst(a -> startswith(a, "--years="), ARGS)
    arg === nothing ? nothing : parse.(Int, split(split(ARGS[arg], "=")[2], ","))
end

const FIELD_SOURCES = [
    "odds", "odds_kom", "odds_points", "odds_stagewin",
    "oracle", "oracle_kom", "oracle_points", "predictions", "pcs_specialty",
]
const UNRESOLVED = (:none, :ambiguous, :collides_exact, :override_refused, :override_absent)

function printed_frame(data_type, key, year)
    df = Velogames.load_race_snapshot(data_type, key, year)
    (df === nothing || !(:rider in propertynames(df))) && return nothing
    names = unique(String[String(n) for n in df.rider if !ismissing(n)])
    return DataFrame(rider = names, riderkey = createkey.(names))
end

function report_field(slug, year)
    Velogames.race_format(slug) == :stage ?
    Velogames.load_stage_race_report_data(slug, year) :
    Velogames.load_report_data(slug, year)
end

csvq(s) = occursin(r"[\",\n]", s) ? "\"" * replace(s, "\"" => "\"\"") * "\"" : s

function emit(source, race, year, frame, ref)
    ref = unique(dropmissing(ref[:, [:rider, :riderkey]]), :riderkey)
    results = Velogames.resolve_riders(frame, ref; source, race, year)
    for (name, (method, _, _)) in zip(frame.rider, results)
        method in UNRESOLVED || continue
        println(join([source, race, string(year), csvq(name), string(method)], ","))
    end
end

function main()
    println("source,race,year,rider,method")
    for source in FIELD_SOURCES, race in Velogames.archive_races(source),
        year in Velogames.archive_years(source, race)

        YEARS === nothing || year in YEARS || continue
        frame = printed_frame(source, race, year)
        field = frame === nothing ? nothing : report_field(race, year)
        (frame === nothing || field === nothing) && continue
        emit(source, race, year, frame, field)
    end
    for race in Velogames.archive_races("pcs_results")
        Velogames.race_format(race) == :stage && continue
        for year in Velogames.archive_years("pcs_results", race)
            YEARS === nothing || year in YEARS || continue
            Velogames.race_completeness(race, year).field_basis == :pool_pcs_filtered || continue
            pool = Velogames.load_race_snapshot("vg_riders", Velogames.vg_classics_slug(year), year)
            frame = printed_frame("pcs_results", race, year)
            (pool === nothing || frame === nothing) && continue
            emit("pcs_results", race, year, frame, DataFrame(pool))
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
