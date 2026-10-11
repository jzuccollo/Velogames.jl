#!/usr/bin/env julia
"""
Print every archived odds book's rider keys after `rematch_riderkeys!`, as JSON,
for `vgleague verify-odds-keys`.

The odds type is stored as pasted, with `riderkey = createkey(rider)`, and both
languages match it to a race's field at read time: here with `resolve_rider`
(through `rematch_riderkeys!`), in vgleague with its port in `matching.py`. The
golden corpus (`test/fixtures/rider_matching.json`) holds the two resolvers to
the same answers on every measured name; this holds them to the same answers on
the books as archived, against the race's report field
(`load_report_data` or `load_stage_race_report_data`, the frame `verify-field`
already holds equal across the two languages). The failure mode is silent: a
bookmaker's name priced onto the wrong rider, or none.

This is the Julia half; it emits and does not compare. Reads the archive and
fetches nothing.

Usage:
    julia --project scripts/odds_keys_digest.jl [--years=2026]
"""

using Velogames, DataFrames, JSON3

const YEARS = let arg = findfirst(a -> startswith(a, "--years="), ARGS)
    arg === nothing ? nothing : parse.(Int, split(split(ARGS[arg], "=")[2], ","))
end

function digest_book(pcs_slug::String, year::Int)
    odds = Velogames.load_race_snapshot("odds", pcs_slug, year)
    fmt = Velogames.race_format(pcs_slug)
    field =
        fmt == :stage ? Velogames.load_stage_race_report_data(pcs_slug, year) :
        Velogames.load_report_data(pcs_slug, year)
    if odds === nothing || field === nothing
        return (pcs_slug = pcs_slug, year = year, field = field !== nothing, rows = [])
    end
    raw = copy(odds.riderkey)
    matched = Velogames.rematch_riderkeys!(copy(odds), field)
    rows = [
        (rider = String(r), raw = String(k0), matched = String(k1)) for
        (r, k0, k1) in zip(odds.rider, raw, matched.riderkey)
    ]
    return (pcs_slug = pcs_slug, year = year, field = true, rows = rows)
end

function main()
    out = []
    for pcs_slug in Velogames.archive_races("odds")
        for year in Velogames.archive_years("odds", pcs_slug)
            YEARS === nothing || year in YEARS || continue
            push!(out, digest_book(pcs_slug, year))
        end
    end
    sort!(out, by = r -> (r.pcs_slug, r.year))
    JSON3.write(stdout, out)
    println()
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
