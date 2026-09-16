#!/usr/bin/env julia
"""
Print a digest of every race's report field, as JSON, for `vgleague verify-field`.

The field frame — who could have been picked for one race, at what price — is
built twice, once in each language, because publication is in Python and the
model is here. The failure mode is silent: a field short of a few riders yields a
plausible team and a wrong number, never an error. At Cyclassics Hamburg 2026 the
league-picked pool answers 60 credits against the real field's 42.

So it gets the treatment `riderkey` and race-name squashing already have: two
implementations, checked against each other over every race the archive holds.
This is the Julia half — it emits, it does not compare. `vgleague verify-field`
recomputes each row in Python and reports the differences.

The digest is per race rather than per rider: the field is a set, so its size,
the sum of what it costs, the sum of what it scored and a hash of its keys pin it
exactly. A digest that matched while the frames differed would need two
compensating errors inside one race.

Reads the archive and fetches nothing.

Usage:
    julia --project scripts/field_digest.jl [--years=2025,2026]
"""

using Velogames, DataFrames, JSON3, SHA

const YEARS = let arg = findfirst(a -> startswith(a, "--years="), ARGS)
    arg === nothing ? nothing : parse.(Int, split(split(ARGS[arg], "=")[2], ","))
end

"""A hash of the field's rider keys, order-independent, so a reordering is not a difference."""
keyhash(keys) = bytes2hex(sha256(join(sort(collect(String.(keys))), "\n")))[1:16]

"""League winners by `(pcs_slug, year)` — the target the cheapest-beating team must clear."""
const WINNERS = Dict(
    (w.pcs_slug, w.year) => w.score for w in load_league_winners()
)

"""
The two hindsight teams, as the digest sees them: keys, cost and score.

Emitted alongside the field because they are what the field is *for*. The
comparison depends on the lexicographic tie-break: a single-objective knapsack
leaves a tie set the solver resolves arbitrarily, and two arbitrary choices can
differ through nobody's fault.
"""
function team_facts(df, fmt::Symbol, target)
    optimal =
        fmt == :stage ? compute_optimal_stage_team(df) : compute_optimal_team(df)
    cheapest =
        target === nothing ? nothing :
        fmt == :stage ? compute_cheapest_winning_stage_team(df, target) :
        compute_cheapest_winning_team(df, target)
    pack(t) =
        t === nothing ? (keyhash = "", cost = 0, score = 0) :
        (keyhash = keyhash(t.riderkey), cost = sum(t.cost), score = sum(t.score))
    return (optimal = pack(optimal), cheapest = pack(cheapest))
end

function digest_race(pcs_slug::String, year::Int, fmt::Symbol)
    df =
        fmt == :stage ? load_stage_race_report_data(pcs_slug, year) :
        load_report_data(pcs_slug, year)
    c = race_completeness(pcs_slug, year)
    # The invariant `verify-field` asserts on both sides: every realised point
    # the race scored is carried by some rider in the field, except the points of
    # riders nothing can price. It is emitted, not assumed: `unpriced_scorers`
    # once said zero for 76 races that between them dropped 12,844 realised
    # points on a `riderkey` mismatch.
    missing_points = c.race_points - (df === nothing ? 0 : sum(df.score))
    target = get(WINNERS, (pcs_slug, year), nothing)
    teams =
        df === nothing ? (optimal = (keyhash = "", cost = 0, score = 0),
                          cheapest = (keyhash = "", cost = 0, score = 0)) :
        team_facts(df, fmt, target)
    return (
        pcs_slug = pcs_slug,
        year = year,
        format = String(fmt),
        riders = df === nothing ? 0 : nrow(df),
        keyhash = df === nothing ? "" : keyhash(df.riderkey),
        cost = df === nothing ? 0 : sum(df.cost),
        score = df === nothing ? 0 : sum(df.score),
        field_basis = String(c.field_basis),
        unpriced_scorers = c.unpriced_scorers,
        unpriced_points = c.unpriced_points,
        race_points = c.race_points,
        missing_points = missing_points,
        winner_score = target === nothing ? 0 : target,
        optimal = teams.optimal,
        cheapest = teams.cheapest,
        has_required_data = has_required_data(c),
    )
end

function main()
    rows = []
    seen = Set{Tuple{String,Int}}()
    # The format is the race's, not the archive tree's. Itzulia and Romandie are
    # stage races that also carry a `vg_results` file, so keying off the tree
    # would read them through the one-day loader and compare a week's stage
    # totals against a single race's field.
    for data_type in ("vg_results", "vg_stage_totals")
        for pcs_slug in archive_races(data_type)
            for year in archive_years(data_type, pcs_slug)
                YEARS === nothing || year in YEARS || continue
                (pcs_slug, year) in seen && continue
                push!(seen, (pcs_slug, year))
                push!(rows, digest_race(pcs_slug, year, Velogames.race_format(pcs_slug)))
            end
        end
    end
    sort!(rows, by = r -> (r.pcs_slug, r.year))
    JSON3.write(stdout, rows)
    println()
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
