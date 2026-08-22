"""
Fetch-and-store as a phase of its own.

Until Phase 2 nothing's job was ingest. `render_reports.jl` archived results
while rendering, via `_ensure_results_archived`; `stage_race_report_html`
archived a whole grand tour while drawing its first chart. That worked, and the
design note is careful to say so — it was the unattended-ingest guarantee, not
merely untidy — but it made two questions unanswerable. "Is this race's data
complete?" could only be answered by rendering it, and a failed fetch was
indistinguishable from a race that had not happened, because both produced no
page.

`ingest_race` is the same work with the side effect turned into the point. It
reads the archive before and after, and reports the difference.

**The report is read off the archive, not off the writers.** The two archivers
underneath warn-and-continue at roughly a dozen points each, so their own account
of what they did would be a summary of their intentions. Comparing
`race_completeness` before and against after says what actually landed, which is
the only claim the caller can act on.
"""

"""
    IngestResult

What one race's ingest changed. `gained` are the archive types that were absent
before and present after; `still_missing` are the required types absent after,
which is what makes `ok` false.
"""
struct IngestResult
    pcs_slug::String
    year::Int
    format::Symbol
    gained::Vector{String}
    still_missing::Vector{String}
    before::RaceCompleteness
    after::RaceCompleteness
end

ok(r::IngestResult) = isempty(r.still_missing)

function Base.show(io::IO, r::IngestResult)
    state = if !isempty(r.still_missing)
        "MISSING $(join(r.still_missing, ", "))"
    elseif isempty(r.gained)
        "already complete"
    else
        "gained $(join(r.gained, ", "))"
    end
    print(io, "$(r.pcs_slug) $(r.year): $state")
end

"""
    ingest_race(pcs_slug, year; cache_config, n_stages) -> IngestResult

Fetch and archive everything the publication path needs for one completed race.
Idempotent — every underlying write is guarded on the snapshot being absent — so
a re-run costs the fetches for whatever is still missing and nothing else.
"""
function ingest_race(
    pcs_slug::AbstractString,
    year::Integer;
    cache_config::CacheConfig = DEFAULT_CACHE,
    n_stages::Union{Int,Nothing} = nothing,
    archive_dir::String = archive_dir(),
)
    slug = String(pcs_slug)
    yr = Int(year)
    format = race_format(slug)
    before = race_completeness(slug, yr; archive_dir = archive_dir)

    if format == :stage
        archive_stage_race_results(
            slug,
            yr;
            n_stages = something(n_stages, grand_tour_stages(slug)),
            cache_config = cache_config,
        )
    else
        _ingest_oneday(slug, yr; cache_config = cache_config, archive_dir = archive_dir)
    end

    after = race_completeness(slug, yr; archive_dir = archive_dir)
    present(c) = Set(r.data_type for r in eachrow(c.types) if r.present)
    gained = sort!(collect(setdiff(present(after), present(before))))
    still_missing =
        sort!([r.data_type for r in eachrow(after.types) if r.required && !r.present])

    return IngestResult(slug, yr, format, gained, still_missing, before, after)
end

"""
The one-day arm: the season pool and race list first, then this race's results.

The pool and the race list are season-scoped and shared by every classic, so they
are fetched here rather than by whoever happens to load a report first — which is
what `load_vg_classics_riders` used to be, and is the last of the design note's
"five problems" on this path.
"""
function _ingest_oneday(
    slug::String,
    yr::Int;
    cache_config::CacheConfig,
    archive_dir::String,
)
    # Both archive on the way past when absent, and return the archived copy
    # when present. Velogames retires a season's pages, so a year whose pool was
    # never captured cannot be reported on at all.
    load_vg_classics_riders(yr; cache_config = cache_config, archive_dir = archive_dir)
    racelist = getvg_race_list(yr; cache_config = cache_config, archive_dir = archive_dir)

    number = _vg_race_number(slug, racelist)
    if number === nothing
        @warn "No Velogames race number for $slug $yr — its results cannot be fetched. Check the race's name against races.php."
    end
    archive_race_results(
        slug,
        yr;
        vg_race_number = something(number, 0),
        cache_config = cache_config,
    )
    return nothing
end

"""This race's `st` parameter on `ridescore.php`, matched by normalised name."""
function _vg_race_number(slug::String, racelist::DataFrame)
    nrow(racelist) == 0 && return nothing
    ri = find_race(slug)
    name = ri !== nothing ? ri.name : replace(slug, "-" => " ")
    return match_vg_race_number(name, racelist)
end

"""
    pending_races(years; league_winners, archive_dir) -> Vector{Tuple{String,Int}}

Races the league has settled a winner for whose archive is short of a required
type — the work list the publish path needs done before it renders.

Keyed off the winners record rather than off a calendar: a race nobody in the
league entered is not one the site publishes, and a race the league has scored is
one whose results Velogames has certainly published.
"""
function pending_races(
    years::Vector{Int};
    archive_dir::String = archive_dir(),
)
    out = Tuple{String,Int}[]
    for w in load_league_winners(; archive_dir = archive_dir)
        slug = String(w.pcs_slug)
        yr = Int(w.year)
        yr in years || continue
        (slug, yr) in out && continue
        c = race_completeness(slug, yr; archive_dir = archive_dir)
        has_required_data(c) || push!(out, (slug, yr))
    end
    return sort!(out)
end
