"""
What a race's archive actually holds, and what that lets a page claim.

The publication path used to answer "is race X's data complete?" by rendering it
and seeing what came out. Every archival step was a side effect of something
else — `render_reports.jl` archived results while rendering, `_prepare_rider_data`
archives odds while estimating — so completeness was not a question anything
could be asked. Phase 2 makes ingest a phase; this is the question that phase
exists to make answerable.

**Computed, not written.** The design note asked for a marker file per race. A
function that reads the archive is better on all three counts that motivated it:
a half-synced Dropbox file fails the check because the check opens it, where a
marker could sync ahead of its data; there is no second writer to race the first;
and nothing can go stale. What a marker file would add — "we tried and the source
had nothing", as against "we never tried" — is the run log's job, and `_runs/`
answers it directly.
"""

"""
Which archive types a race of each format needs, and what each one buys.

`required` types are the ones without which there is no page: the realised scores
and the prices to put beside them. The rest raise what the page can say —
`vg_startlist` turns a reconstructed field into Velogames' own record of it, and
the PCS types are what put "3rd" and "DNF" next to a rider's name.
"""
const COMPLETENESS_TYPES = Dict(
    :oneday => [
        (type = "vg_results", required = true, buys = "realised Velogames points"),
        (type = "vg_riders", required = true, buys = "rider prices for the season"),
        (type = "vg_startlist", required = false, buys = "the field Velogames listed for this race"),
        (type = "pcs_results", required = false, buys = "finishing positions and the starter filter"),
    ],
    :stage => [
        (type = "vg_stage_totals", required = true, buys = "realised Velogames points across the tour"),
        (type = "vg_stage_riders", required = true, buys = "rider prices and classifications"),
        (type = "vg_stage_results", required = false, buys = "per-stage scores"),
        (type = "pcs_stage_results", required = false, buys = "per-stage finishing positions"),
        (type = "pcs_gc_results", required = false, buys = "the final general classification"),
        (type = "pcs_abandons", required = false, buys = "who left the race and when"),
        (type = "pcs_stage_profiles", required = false, buys = "stage terrain"),
    ],
)

"""
    RaceCompleteness

One race's archive coverage, and the two facts that decide whether a
field-required stat can be trusted.

`field_basis` says where the field of riders came from:

- `:startlist` — the `vg_startlist` Velogames published for this race, which is
  the only source that keeps non-finishers and riders PCS never listed;
- `:vg_rider_list` — a grand tour's rider pool, which *is* its field: `riders.php`
  carries no Start List column for a stage race, and none is needed;
- `:pool_pcs_filtered` — the season pool filtered through the PCS finishers,
  which is every race before August 2026 and drops both of those groups silently;
- `:pool` — the season pool unfiltered, when even PCS results are missing;
- `:none` — no field at all.

`unpriced_scorers` is the one that bites. A rider who scored but appears in
neither the startlist nor the season pool is dropped by `load_report_data`'s
`leftjoin` without a word: the page's points total is short by their score, and
the cheapest-winning-team stat is wrong in the direction that matters, because
it lives on exactly the cheap scorers most likely to be missing. Sergio Serrano
scored at Classique Dunkerque 2026 and is in no surviving pool snapshot.
"""
struct RaceCompleteness
    pcs_slug::String
    year::Int
    format::Symbol
    types::DataFrame
    field_basis::Symbol
    field_riders::Int
    unpriced_scorers::Int
    unpriced_points::Int
    race_points::Int
end

"""Format of a race by slug: `:stage` for anything with a Velogames stage-race game."""
race_format(pcs_slug::AbstractString) =
    haskey(_STAGE_RACE_VG_SLUGS, String(pcs_slug)) ? :stage : :oneday

"""Archive key for a type: VG game slug for the season-scoped types, `pcs_slug` otherwise."""
function _completeness_key(data_type::AbstractString, pcs_slug::AbstractString, year::Int)
    data_type in ("vg_riders", "vg_racelist", "vg_startlist") && return vg_classics_slug(year)
    return String(pcs_slug)
end

"""
    race_completeness(pcs_slug, year; archive_dir) -> RaceCompleteness

Read the archive and report what it holds for one race.

**Archive-only, on purpose.** The obvious implementation reaches for
`load_vg_classics_riders` and `load_vg_startlist`, and both of those scrape and
archive on a miss — so the function whose job is to report what the archive holds
would quietly change the answer by asking the question, and an ingest phase that
bracketed its work with a before-and-after reading would find the "before" had
already done half the work. Every read here goes through `load_race_snapshot`.
"""
function race_completeness(
    pcs_slug::AbstractString,
    year::Integer;
    archive_dir::String = archive_dir(),
)
    slug = String(pcs_slug)
    yr = Int(year)
    format = race_format(slug)

    rows = NamedTuple{
        (:data_type, :required, :present, :rows, :fetched_at, :buys),
        Tuple{String,Bool,Bool,Int,String,String},
    }[]
    for spec in COMPLETENESS_TYPES[format]
        key = _completeness_key(spec.type, slug, yr)
        df = load_race_snapshot(spec.type, key, yr; archive_dir = archive_dir)
        prov = archive_provenance(spec.type, key, yr; archive_dir = archive_dir)
        push!(
            rows,
            (
                data_type = spec.type,
                required = spec.required,
                present = df !== nothing,
                rows = df === nothing ? 0 : nrow(df),
                fetched_at = prov === nothing ? "" : get(prov, "fetched_at", ""),
                buys = spec.buys,
            ),
        )
    end
    types = DataFrame(rows)

    basis, n_field, unpriced, unpriced_pts, race_pts = if format == :stage
        _stage_field_facts(slug, yr; archive_dir = archive_dir)
    else
        _oneday_field_facts(slug, yr; archive_dir = archive_dir)
    end

    return RaceCompleteness(
        slug,
        yr,
        format,
        types,
        basis,
        n_field,
        unpriced,
        unpriced_pts,
        race_pts,
    )
end

function _oneday_field_facts(slug::String, yr::Int; archive_dir::String)
    results = load_race_snapshot("vg_results", slug, yr; archive_dir = archive_dir)
    results === nothing && return (:none, 0, 0, 0, 0)
    race_pts = sum(results.score)

    vg_slug = vg_classics_slug(yr)
    pool = load_race_snapshot("vg_riders", vg_slug, yr; archive_dir = archive_dir)
    pool === nothing && return (:none, 0, nrow(results), race_pts, race_pts)
    startlist = _archived_startlist(slug, yr, vg_slug; archive_dir = archive_dir)
    pcs = load_race_snapshot("pcs_results", slug, yr; archive_dir = archive_dir)

    basis = if startlist !== nothing
        :startlist
    elseif pcs !== nothing && :riderkey in propertynames(pcs)
        :pool_pcs_filtered
    else
        :pool
    end

    # Exactly the set `load_report_data` can price: the startlist arm plus
    # whatever the season pool can supply for scorers the startlist lacks.
    priced = Set{String}(pool.riderkey)
    startlist !== nothing && union!(priced, Set{String}(startlist.riderkey))
    unpriced_rows = filter(r -> !(r.riderkey in priced), results)

    # The field `load_report_data` actually builds: the startlist plus the
    # scorers it lacks that the pool can price, or the pool through the PCS
    # starter filter when there is no startlist.
    n_field = if startlist !== nothing
        listed = Set{String}(startlist.riderkey)
        listed_count = length(listed)
        listed_count + count(k -> !(k in listed) && k in priced, unique(results.riderkey))
    elseif basis == :pool_pcs_filtered
        starters = Set{String}(pcs.riderkey)
        count(k -> k in starters, unique(pool.riderkey))
    else
        length(Set{String}(pool.riderkey))
    end

    return (
        basis,
        n_field,
        nrow(unpriced_rows),
        nrow(unpriced_rows) == 0 ? 0 : sum(unpriced_rows.score),
        race_pts,
    )
end

function _stage_field_facts(slug::String, yr::Int; archive_dir::String)
    totals = load_race_snapshot("vg_stage_totals", slug, yr; archive_dir = archive_dir)
    totals === nothing && return (:none, 0, 0, 0, 0)
    race_pts = sum(totals.score)

    riders = load_race_snapshot("vg_stage_riders", slug, yr; archive_dir = archive_dir)
    riders === nothing && return (:none, 0, nrow(totals), race_pts, race_pts)

    # A grand tour's rider list *is* its field — `riders.php` carries no Start
    # List column for a stage race, and none is needed.
    priced = Set{String}(riders.riderkey)
    unpriced_rows = filter(r -> !(r.riderkey in priced), totals)
    return (
        :vg_rider_list,
        nrow(riders),
        nrow(unpriced_rows),
        nrow(unpriced_rows) == 0 ? 0 : sum(unpriced_rows.score),
        race_pts,
    )
end

"""
This race's rows of the season's `vg_startlist`, read from the archive alone.

`load_vg_startlist` does the same job but reaches `getvg_race_list`, which
scrapes and archives `races.php` on a miss. Here the racelist is read straight
from `vg_racelist`; a season with no archived racelist simply has no startlist to
report, which is the honest answer for a completeness check.
"""
function _archived_startlist(
    slug::String,
    yr::Int,
    vg_slug::String;
    archive_dir::String,
)
    season = load_race_snapshot("vg_startlist", vg_slug, yr; archive_dir = archive_dir)
    season === nothing && return nothing
    racelist = load_race_snapshot("vg_racelist", vg_slug, yr; archive_dir = archive_dir)
    racelist === nothing && return nothing

    ri = find_race(slug)
    name = ri !== nothing ? ri.name : replace(slug, "-" => " ")
    number = match_vg_race_number(name, racelist)
    number === nothing && return nothing

    race = filter(:race_number => ==(number), season)
    return isempty(race) ? nothing : race
end

"""Every required type is present with rows in it."""
has_required_data(c::RaceCompleteness) =
    all(r -> !r.required || (r.present && r.rows > 0), eachrow(c.types))

"""The share of the race's realised points carried by riders nothing can price."""
unpriced_share(c::RaceCompleteness) =
    c.race_points == 0 ? 0.0 : c.unpriced_points / c.race_points

"""
Whether the hindsight knapsacks can see every rider who scored. False when a
scorer cannot be priced at any cost: the optimal and cheapest-winning teams are
then optimising over a field missing exactly the riders they would most want, and
both answers are bounds rather than answers.

Deliberately not called "complete" — a race can pass this and still have a field
reconstructed from the season pool, which is what `field_basis` reports and what
`field_basis_note` puts on the page.
"""
field_prices_every_scorer(c::RaceCompleteness) =
    has_required_data(c) && c.unpriced_scorers == 0

"""
    field_basis_note(c) -> String

One sentence for the page saying where its field came from, or `""` when the
field is Velogames' own record and nothing is missing from it.
"""
function field_basis_note(c::RaceCompleteness)
    parts = String[]
    if c.field_basis == :pool_pcs_filtered
        push!(
            parts,
            "Velogames published no start list for this race, so the field is the season's rider pool filtered through the ProCyclingStats finishers — riders who abandoned, and anyone PCS never listed, are absent.",
        )
    elseif c.field_basis == :pool
        push!(
            parts,
            "Neither a Velogames start list nor PCS results survive for this race, so the field is the whole season's rider pool.",
        )
    end
    if c.unpriced_scorers > 0
        pct = round(100 * unpriced_share(c), digits = 1)
        push!(
            parts,
            c.unpriced_scorers == 1 ?
            "One rider who scored ($(commafmt(c.unpriced_points)) points, $(pct)% of the race) appears in no surviving price list, so the teams below could not have picked them." :
            "$(c.unpriced_scorers) riders who scored ($(commafmt(c.unpriced_points)) points, $(pct)% of the race) appear in no surviving price list, so the teams below could not have picked them.",
        )
    end
    return join(parts, " ")
end
