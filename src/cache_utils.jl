"""
Cache configuration and utilities for Velogames data retrieval.

Two layers:
- **In-memory**: session-scoped `Dict` keyed by cache key. Avoids redundant disk
  reads when the same URL is requested multiple times (e.g. the same rider across
  88 backtest races). Cleared on Julia restart or via `clear_memory_cache!()`.
- **On-disk**: Arrow IPC files with JSON metadata and TTL-based expiry.
"""

"""
Cache configuration structure
"""
struct CacheConfig
    cache_dir::String
    max_age_hours::Int
end

# Default on-disk cache directory. Scripts reuse this and vary only the TTL.
const DEFAULT_CACHE_DIR = joinpath(homedir(), ".velogames_cache")

# Default cache configuration
const DEFAULT_CACHE = CacheConfig(
    DEFAULT_CACHE_DIR,
    168,  # 7 days default cache lifetime
)

# Session-scoped in-memory cache (avoids redundant disk reads within a session)
const _MEMORY_CACHE = Dict{String,DataFrame}()

# An empty fetch means "not published yet", not "this page is empty", so it is
# held only briefly regardless of the configured TTL.
const EMPTY_CACHE_MAX_AGE_HOURS = 1

"""
    clear_memory_cache!() -> Nothing

Clear the in-memory cache. The on-disk cache is unaffected.
"""
function clear_memory_cache!()
    n = length(_MEMORY_CACHE)
    empty!(_MEMORY_CACHE)
    @info "Cleared in-memory cache ($n entries)"
    return nothing
end

"""
Generate a cache key from URL and parameters
"""
function cache_key(url::String, params::Dict = Dict())::String
    content = url * string(params)
    return bytes2hex(sha256(content))[1:16]  # Use first 16 chars of hash
end

"""
Cache metadata structure
"""
struct CacheMetadata
    url::String
    timestamp::DateTime
    version::String
    params::Dict
end

"""
Get cache file paths for data and metadata
"""
function cache_paths(key::String, cache_dir::String)
    mkpath(cache_dir)  # Ensure cache directory exists
    data_file = joinpath(cache_dir, key * ".feather")
    meta_file = joinpath(cache_dir, key * ".json")
    return data_file, meta_file
end

"""
Check if cache is valid - works for both .feather and .json files
"""
function is_cache_valid(key::String, max_age_hours::Int, cache_dir::String)::Bool
    data_file_feather, meta_file = cache_paths(key, cache_dir)
    data_file_json = replace(data_file_feather, ".feather" => ".json")

    if (!isfile(data_file_feather) && !isfile(data_file_json)) || !isfile(meta_file)
        return false
    end

    try
        meta_content = read(meta_file, String)
        meta = JSON3.read(meta_content, CacheMetadata)
        age_hours = Dates.value(now() - meta.timestamp) / (1000 * 60 * 60)
        return age_hours < max_age_hours
    catch e
        @warn "Failed to read cache metadata $meta_file, treating as invalid" exception = e
        return false
    end
end

"""
Save DataFrame data to cache with metadata
"""
function save_to_cache(
    data::DataFrame,
    key::String,
    url::String,
    cache_dir::String,
    params::Dict = Dict(),
)
    data_file, meta_file = cache_paths(key, cache_dir)

    # Data first, metadata last. `is_cache_valid` turns on the metadata alone,
    # and `cached_fetch` reads metadata-without-data as a cached empty result —
    # so writing the metadata first opens a window in which a crash, or a reader
    # in another process, is served an empty DataFrame nothing ever fetched.
    # This ordering makes the interrupted state "not yet valid", so a reader
    # refetches instead.
    #
    # An empty result still writes metadata only. That absence is the "not
    # published yet" marker `EMPTY_CACHE_MAX_AGE_HOURS` keys off, so the entry
    # expires in hours rather than sitting out the full TTL — and with no data
    # to write there is no window here to open.
    if nrow(data) > 0
        Arrow.write(data_file, data)
    end
    write(meta_file, JSON3.write(CacheMetadata(url, now(), "1.0", params)))
end

"""
Load data from cache - handles both DataFrame and JSON data
"""
function load_from_cache(key::String, cache_dir::String)::Union{DataFrame,Nothing}
    data_file, meta_file = cache_paths(key, cache_dir)

    if isfile(data_file)
        try
            return DataFrame(Arrow.Table(data_file); copycols = true)
        catch e
            @warn "Failed to read cached data $data_file" exception = e
            return nothing
        end
    end

    return nothing
end

"""
Generic cached data fetcher.

Lookup order: in-memory Dict → on-disk Arrow → network fetch.
Results are promoted into the in-memory cache on first access so that
subsequent requests for the same URL are instant.
"""
function cached_fetch(
    fetch_func::Function,
    url::String,
    params::Dict = Dict();
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
    verbose::Bool = true,
)
    key = cache_key(url, params)

    # 1. Check in-memory cache (instant)
    if !force_refresh && haskey(_MEMORY_CACHE, key)
        return _MEMORY_CACHE[key]
    end

    # 2. Check on-disk cache. An empty entry means the page had nothing on it
    # yet (results fetched before the race finished), so it expires quickly
    # rather than at the full TTL — otherwise the race results stay invisible
    # for a week after they appear.
    data_file, _ = cache_paths(key, cache_config.cache_dir)
    max_age =
        isfile(data_file) ? cache_config.max_age_hours :
        min(cache_config.max_age_hours, EMPTY_CACHE_MAX_AGE_HOURS)
    if !force_refresh && is_cache_valid(key, max_age, cache_config.cache_dir)
        cached_data = load_from_cache(key, cache_config.cache_dir)
        if cached_data !== nothing
            verbose && @info "Loading from cache: $url"
            _MEMORY_CACHE[key] = cached_data
            return cached_data
        end
        if !isfile(data_file)
            # Metadata with no data file at all is the deliberate empty marker.
            verbose && @info "Loading cached empty result: $url"
            return DataFrame()
        end
        # A data file that exists and will not read is a corrupt entry, not an
        # empty one — `load_from_cache` returns `nothing` for both. Treating it
        # as empty would serve a blank frame for the rest of the TTL, so fall
        # through and fetch it again.
        @warn "Corrupt cache entry, refetching: $url"
    end

    # 3. Fetch from network
    verbose && @info "Fetching fresh data: $url"
    data = fetch_func(url, params)

    # Save to both caches. Empty results stay out of the in-memory cache so a
    # long-lived process (scripts/serve.jl) rechecks them on the next request.
    save_to_cache(data, key, url, cache_config.cache_dir, params)
    if nrow(data) > 0
        _MEMORY_CACHE[key] = data
    end

    return data
end

# ---------------------------------------------------------------------------
# Archival storage – permanent, human-readable paths for race-day snapshots
# ---------------------------------------------------------------------------

"""
    archive_dir() -> String

Root of the permanent race data archive. `VELOGAMES_ARCHIVE` overrides the
default `~/Dropbox/code/velogames/archive`.

A function rather than a `const`: a const is evaluated at precompile time and
baked into the image, so the environment variable would silently stop working.
"""
archive_dir() = get(
    ENV,
    "VELOGAMES_ARCHIVE",
    joinpath(homedir(), "Dropbox", "code", "velogames", "archive"),
)

"""
Extension every archive file carries. The one place it is written down.
"""
const ARCHIVE_EXT = ".arrow"

"""
Archive trees that are no longer data types, with where they went and why.

Documentation, not machinery: the entries are here so the type manifest can
account for every directory in the archive without anyone having to rediscover
what these held. These trees are Arrow like everything else: they were left as
Feather V1 on the argument that a historical record does not need the current
format, which lost to the simpler one that those 40 files were the only thing
keeping an end-of-life dependency in the manifest. `_inputs/` holds `.mhtml`
pages and no tabular data, so nothing there was converted.
"""
const RETIRED_ARCHIVE_TYPES = [
    (
        name = "pcs_form",
        moved_to = "_retired/pcs_form",
        reason = "PCS form score, dropped by the April 2026 ablation and deleted from the code in August. The only surviving record of what the signal contained, and roadmap.md cites its evidence.",
    ),
    (
        name = "qualitative",
        moved_to = "_retired/qualitative",
        reason = "Hand-entered qualitative intelligence, dropped by the same ablation. Irreplaceable — nobody is going to re-type it.",
    ),
    (
        name = "prediction",
        moved_to = "_retired/prediction",
        reason = "Singular typo of `predictions`, the drift WP5's guard exists to stop. Its one file (strade-bianche 2026) was a 38-column superset of the 13-column plural and was swapped in before the tree retired.",
    ),
    (
        name = "pcs_breakaways",
        moved_to = "_inputs/pcs_breakaways",
        reason = "Four `.mhtml` pages and no tabular data — a raw input masquerading as a data type. At the top level it would force the manifest to carry an entry for a tree holding no archive files.",
    ),
    (
        name = "league_winners",
        moved_to = "_retired/league_winners.toml",
        reason = "A hand-maintained, append-only five-field summary of the league snapshots, which lived here only because the snapshots themselves lived somewhere nothing backed up. Phase 1b moved the snapshots into `league/raw` and the winners into `league/winners`; the file was migrated once and kept as the pre-archive record, since it is the only contemporaneous evidence for the four 2026 races no surviving snapshot predates.",
    ),
]

"""
Archive trees that hold raw documents rather than tables.

They are part of the contract — `league/raw` is the most irreplaceable thing in
the archive — but they carry no columns, so they cannot go in `ARCHIVE_TYPES`,
whose entries mean "a frame with these mandatory columns" and are what
`save_race_snapshot` validates against. The audit and the manifest read both
consts; nothing else needs to know the difference.
"""
const RAW_ARCHIVE_TREES = [(
    name = "league/raw",
    pattern = "{game_slug}_{year}_{league_id}/{YYYY-MM-DD}.json",
    refetchable = false,
    note = "Dated, content-deduped copies of the vgleague scrape: every entrant's roster, cost and score for every race. Never overwritten, because entrants rename their teams and the only honest record is what the site said on a given date. Velogames publishes no history, so a league's rosters exist only while the league does.",
),]


"""
Every live archive data type, with the columns a file of that type must carry.

`save_race_snapshot` reads this table: an unknown type is an error and creates no
directory, and a frame missing a mandatory column is an error rather than a
snapshot nobody can use. The five archive drift modes this closes are set out in
`docs/data-dictionary.md`; the short version is that the archive is a boundary
crossing processes, languages and years, so it is the one place in this package
that checks its inputs.

The mandatory lists are a **census** of what is on disk — the intersection of the
column sets across every live file of a type — cross-checked against what the
writer provably emits, not a wish list. A list stricter than the writers emit
turns an irreplaceable snapshot into a lost one: odds and oracle are written
through `_try_archive`, which swallows the error into a warning, so an
over-strict entry would silently drop a human-pasted odds sheet nobody can
re-paste. Two census facts the lists respect: `vg_results` carries `year` on only
some files, and `vg_stage_riders` carries `class`, `classraw` and `selected` on
only some.

`refetchable` is the column that says which trees need backing up: `false` means
the file is the only copy — a market that has closed, a Velogames page that will
retire, a model output from a particular afternoon.
"""
const ARCHIVE_TYPES = Dict(
    "odds" => (
        version = 1,
        mandatory = [:riderkey, :rider, :odds],
        refetchable = false,
        note = "Bookmaker winner market, pasted by hand from Oddschecker on race eve. Decimal odds, median across bookmakers.",
    ),
    "odds_points" => (
        version = 1,
        mandatory = [:riderkey, :rider, :odds],
        refetchable = false,
        note = "As `odds`, for a stage race's points classification.",
    ),
    "odds_kom" => (
        version = 1,
        mandatory = [:riderkey, :rider, :odds],
        refetchable = false,
        note = "As `odds`, for a stage race's mountains classification.",
    ),
    "odds_stagewin" => (
        version = 1,
        mandatory = [:riderkey, :rider, :odds],
        refetchable = false,
        note = "As `odds`, for a single stage's winner market.",
    ),
    "oracle" => (
        version = 1,
        mandatory = [:riderkey, :rider, :win_prob],
        refetchable = false,
        note = "Cycling Oracle win probabilities, normalised to sum to 1. The blog post is edited and eventually disappears.",
    ),
    "oracle_points" => (
        version = 1,
        mandatory = [:riderkey, :rider, :win_prob],
        refetchable = false,
        note = "As `oracle`, for a stage race's points classification.",
    ),
    "oracle_kom" => (
        version = 1,
        mandatory = [:riderkey, :rider, :win_prob],
        refetchable = false,
        note = "As `oracle`, for a stage race's mountains classification.",
    ),
    "pcs_abandons" => (
        version = 1,
        mandatory = [:riderkey, :rider, :abandon_stage],
        refetchable = true,
        note = "Stage each non-finisher left a grand tour, derived from the per-stage results.",
    ),
    "pcs_gc_results" => (
        version = 1,
        mandatory = [:riderkey, :rider, :team, :position],
        refetchable = true,
        note = "Final general classification, scoped to the /gc page's active tab.",
    ),
    "pcs_results" => (
        version = 1,
        mandatory = [:riderkey, :rider, :team, :position, :in_breakaway, :breakaway_km],
        refetchable = true,
        note = "One-day finishing order. The breakaway columns come from JavaScript-rendered markup and are false/missing on an HTTP scrape.",
    ),
    "pcs_seasons" => (
        version = 1,
        mandatory = [:riderkey, :year, :pcs_points, :pcs_rank],
        refetchable = false,
        note = "Per-season PCS points and rank per rider. The current season's row moves as the year runs, so this is the as-of-race-day copy that keeps backtests honest.",
    ),
    "pcs_specialty" => (
        version = 1,
        mandatory = [:riderkey, :rider, :oneday, :gc, :tt, :sprint, :climber],
        refetchable = false,
        note = "PCS specialty ratings as of race day. Live ratings drift, so re-fetching would leak the future into a backtest.",
    ),
    "pcs_specialty_seasons" => (
        version = 1,
        mandatory = [:riderkey, :year, :specialty, :points],
        refetchable = false,
        note = "Long-format per-season specialty points, for recomputing recency weights as of a race date.",
    ),
    "pcs_stage_profiles" => (
        version = 1,
        mandatory = [
            :stage_number,
            :stage_type,
            :distance_km,
            :profile_score,
            :vertical_meters,
            :gradient_final_km,
            :n_hc_climbs,
            :n_cat1_climbs,
            :n_intermediate_sprints,
            :is_summit_finish,
        ],
        refetchable = true,
        note = "One row per stage, one column per `StageProfile` field. Written by `stage_profiles_frame` from both the pre-race and post-race paths; PCS revises distance and ProfileScore between the two.",
    ),
    "pcs_stage_results" => (
        version = 1,
        mandatory = [:riderkey, :rider, :team, :position, :stage],
        refetchable = true,
        note = "Every rider's finishing position on every stage of a grand tour.",
    ),
    "predictions" => (
        version = 2,
        mandatory = [
            :riderkey,
            :rider,
            :team,
            :cost,
            :chosen,
            :selection_frequency,
            :expected_vg_points,
        ],
        refetchable = false,
        note = "The model's pre-race output, the input to prospective evaluation and league scoring. Eight 2026 files predate the hardened schema and are missing some of these; the audit lists them, and they cannot be re-created.",
    ),
    "vg_racelist" => (
        version = 1,
        mandatory = [:race_number, :deadline, :name, :category, :namekey],
        refetchable = false,
        note = "The season's classics calendar. Keyed by VG game slug, not `pcs_slug`. Velogames retires `races.php` for past seasons.",
    ),
    "vg_results" => (
        version = 1,
        mandatory = [:riderkey, :rider, :team, :score],
        refetchable = false,
        note = "Realised Velogames points per rider for one race. Carries `year` on some files only. Scores are revised for about 24 hours after a race.",
    ),
    "vg_riders" => (
        version = 1,
        mandatory = [:riderkey, :rider, :team, :cost, :points],
        refetchable = false,
        note = "The classics rider pool: the only surviving record of rider costs for a season, since `riders.php` retires and no other source carries cost. Keyed by VG game slug, not `pcs_slug`.",
    ),
    "vg_startlist" => (
        version = 1,
        mandatory = [:race_number, :rider, :riderkey, :team, :cost],
        refetchable = false,
        note = "Who actually started one race, with that race's prices and (grand tours) classes, from `riders.php`'s Start List column. **Exactly one row per `(race_number, riderkey)`**, accumulating down the season; keyed by VG game slug, not `pcs_slug`. A re-capture must replace that race's rows, not append to them: `load_report_data` joins this frame, so a duplicated rider is counted twice in the page's points total and in the cheapest-team stat. **Written by vgleague, in Python** — the page shows only the race in progress, so it has to be captured while that race is on. Reporting joins it instead of filtering the season pool through PCS results.",
    ),
    "vg_scoring" => (
        version = 1,
        mandatory = [:field, :position, :points],
        refetchable = false,
        note = "A stage race's published scoring table, scraped from its rules page.",
    ),
    "vg_stage_results" => (
        version = 1,
        mandatory = [:riderkey, :rider, :team, :score, :stage],
        refetchable = false,
        note = "Velogames points per rider per stage of a grand tour.",
    ),
    "vg_stage_riders" => (
        version = 1,
        mandatory = [:riderkey, :rider, :team, :cost, :points],
        refetchable = false,
        note = "A grand tour's rider pool. Carries `class`, `classraw` and `selected` on some files only.",
    ),
    "vg_stage_totals" => (
        version = 1,
        mandatory = [:riderkey, :rider, :team, :score],
        refetchable = false,
        note = "Velogames points per rider across a whole grand tour.",
    ),
    "league/rosters" => (
        version = 1,
        mandatory = [
            :username,
            :teamname,
            :race_number,
            :race_name,
            :rider,
            :cost,
            :score,
            :race_score,
        ],
        refetchable = false,
        note = "Entrant × race × rider panel for one league-season: who picked whom, at what price, for how many points. Derived from the newest `league/raw` snapshot. Keyed by `{game_slug}_{league_id}`, not `pcs_slug`.",
    ),
    "league/meta" => (
        version = 1,
        mandatory = [:race_number, :race_name, :deadline, :category, :series_type],
        refetchable = false,
        note = "One league-season's race catalogue, with the league-level fields repeated down the rows so a reader that has the table has the league. Keyed by `{game_slug}_{league_id}`.",
    ),
    "league/winners" => (
        version = 1,
        mandatory = [:pcs_slug, :year, :username, :teamname, :score, :snapshot_date],
        refetchable = false,
        note = "Who won each race in the league, derived once from the raw snapshot contemporaneous with the race and never re-derived: entrants rename their teams, so a later derivation gives a different answer. Replaces `league_winners.toml`. Keyed by `{game_slug}_{league_id}`.",
    ),
)

"""
    missing_mandatory_columns(data_type, df) -> Vector{Symbol}

Which of `data_type`'s mandatory columns `df` lacks. Empty for an unknown type —
the unknown type is `save_race_snapshot`'s error to raise, and readers of legacy
files have nothing to check against.

The single source of the column check, shared by the write-time error and the
read-time warning in `prospective_eval.jl`.
"""
function missing_mandatory_columns(data_type::AbstractString, df::DataFrame)
    spec = get(ARCHIVE_TYPES, String(data_type), nothing)
    spec === nothing && return Symbol[]
    return setdiff(spec.mandatory, propertynames(df))
end

"""
Provenance keys written into every archive file's Arrow schema metadata.

Metadata rather than columns because the grain is the file: one file is one
fetch, and the motivating question — which side of Velogames' 24-hour score
revision a row came from — is a property of the fetch. Columns would also
collide on the joins in `backtest.jl` and `prospective_eval.jl`, where both
sides would carry `fetched_at`, and would be silently dropped by
`_archive_predictions`' allowlist.

`source_url` is filled in where the URL is already to hand and left empty
elsewhere.
"""
const ARCHIVE_PROVENANCE_KEYS =
    ["data_type", "schema_version", "fetched_at", "machine", "source_url"]

_archive_provenance(data_type::AbstractString, version::Int, source_url::AbstractString) =
    Dict(
        "data_type" => String(data_type),
        "schema_version" => string(version),
        "fetched_at" => string(now()),
        "machine" => gethostname(),
        "source_url" => String(source_url),
    )

"""
    archive_provenance(path) -> Union{Dict{String,String}, Nothing}
    archive_provenance(data_type, pcs_slug, year; archive_dir) -> Union{Dict{String,String}, Nothing}

The provenance stamped on an archive file, or `nothing` for a file written
before WP5 (which is most of them — the audit is what reports those, not a
warning on every read).
"""
function archive_provenance(path::AbstractString)
    isfile(path) || return nothing
    meta = Arrow.getmetadata(Arrow.Table(path))
    (meta === nothing || isempty(meta)) && return nothing
    return Dict(String(k) => String(v) for (k, v) in meta)
end

archive_provenance(
    data_type::String,
    pcs_slug::String,
    year::Int;
    archive_dir::String = archive_dir(),
) = archive_provenance(archive_path(data_type, pcs_slug, year; archive_dir = archive_dir))

"""
    archive_path(data_type, pcs_slug, year; archive_dir) -> String

Compute the archive file path for a given data type, race, and year.
Returns a path like `<archive_dir>/odds/paris-roubaix/2025.arrow`.
"""
function archive_path(
    data_type::String,
    pcs_slug::String,
    year::Int;
    archive_dir::String = archive_dir(),
)
    return joinpath(archive_dir, data_type, pcs_slug, "$(year)$(ARCHIVE_EXT)")
end

"""
    archive_races(data_type; archive_dir) -> Vector{String}

Every race slug archived under `data_type`, sorted. Empty when the type has no
directory. Only directories count: `pcs_breakaways` holds loose `.mhtml`
inputs, and the tree carries `.DS_Store` throughout.
"""
function archive_races(data_type::String; archive_dir::String = archive_dir())
    dir = joinpath(archive_dir, data_type)
    isdir(dir) || return String[]
    return sort!([
        e for e in readdir(dir) if !startswith(e, ".") && isdir(joinpath(dir, e))
    ])
end

"""
    archive_years(data_type, pcs_slug; archive_dir) -> Vector{Int}

Every year archived for one race under `data_type`, ascending. Empty when the
race has no directory.
"""
function archive_years(
    data_type::String,
    pcs_slug::String;
    archive_dir::String = archive_dir(),
)
    dir = joinpath(archive_dir, data_type, pcs_slug)
    isdir(dir) || return Int[]
    pattern = Regex("^(\\d{4})\\Q" * ARCHIVE_EXT * "\\E\$")
    years = Int[]
    for f in readdir(dir)
        m = match(pattern, f)
        m === nothing || push!(years, parse(Int, m[1]))
    end
    return sort!(years)
end

"""
    has_race_snapshot(data_type, pcs_slug, year; archive_dir) -> Bool

Whether a snapshot exists, without reading it.
"""
has_race_snapshot(
    data_type::String,
    pcs_slug::String,
    year::Int;
    archive_dir::String = archive_dir(),
) = isfile(archive_path(data_type, pcs_slug, year; archive_dir = archive_dir))

"""
    atomic_write(f, path) -> String

Write `path` by handing `f` a temporary path in the same directory and renaming
it into place. The temporary file is removed if `f` throws.

The archive sits in Dropbox, is written by launchd and by `serve.jl`, and is due
to be read by a Python package on its own schedule — with no locking anywhere.
A writer interrupted part-way through `Arrow.write` leaves a truncated file that
`load_race_snapshot` reports as unreadable, or a short one that reads cleanly
and is wrong. `rename` is atomic within a filesystem, so a reader sees either
the old file or the new one and never half of either.

Three things the implementation depends on:

  * the temporary file lives in the **target directory**, because that is what
    keeps the rename inside one filesystem;
  * it is **dot-prefixed**, because that is what `audit_archive` and
    `archive_years` skip — so a write in flight is not a stray file and not a
    year, and neither is one leaked by a kill;
  * `mv(...; force = true)` tries `rename` first and only falls back to
    unlink-and-copy if that raises, so this is a genuine atomic replace.

The pid is in the name so two writers racing on one path cannot corrupt each
other's temporary file. That makes the *file* safe, not the write: the last
rename still wins.
"""
function atomic_write(f::Function, path::AbstractString)
    tmp = joinpath(dirname(path), ".$(basename(path)).$(getpid()).tmp")
    try
        f(tmp)
        mv(tmp, path; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
    return String(path)
end

"""
    save_race_snapshot(df, data_type, pcs_slug, year; archive_dir, source_url) -> Nothing

Save a DataFrame to the permanent archive. Creates directories as needed.
Overwrites any existing snapshot for the same race/year/type, and stamps
provenance into the file's Arrow schema metadata.

Two things error rather than write: a `data_type` absent from `ARCHIVE_TYPES`,
and a frame missing one of that type's mandatory columns. The first check runs
before `mkpath`, so a typo'd type leaves no directory behind — that empty
directory is what made `prediction` look like a real type beside `predictions`
for four months.

Pass `source_url` where the URL is already to hand.
"""
function save_race_snapshot(
    df::DataFrame,
    data_type::String,
    pcs_slug::String,
    year::Int;
    archive_dir::String = archive_dir(),
    source_url::AbstractString = "",
)
    spec = get(ARCHIVE_TYPES, data_type, nothing)
    spec === nothing && error(
        "save_race_snapshot: unknown archive data type \"$data_type\". Add an entry to " *
        "ARCHIVE_TYPES in cache_utils.jl — and check first whether it is one of the " *
        "$(length(ARCHIVE_TYPES)) types we already have under a different name: " *
        join(sort(collect(keys(ARCHIVE_TYPES))), ", "),
    )

    missing_cols = missing_mandatory_columns(data_type, df)
    isempty(missing_cols) || error(
        "save_race_snapshot: $data_type frame for $pcs_slug $year is missing mandatory " *
        "columns $missing_cols — refusing to write a snapshot nothing can read",
    )

    # Both of these stay below the checks above: a typo'd type must leave no
    # directory behind, which is the whole point of checking before `mkpath`.
    path = archive_path(data_type, pcs_slug, year; archive_dir = archive_dir)
    mkpath(dirname(path))
    atomic_write(path) do tmp
        Arrow.write(
            tmp,
            df;
            metadata = _archive_provenance(data_type, spec.version, source_url),
        )
    end
    @info "Archived $data_type for $pcs_slug $year → $path"
    return nothing
end

"""
    load_race_snapshot(data_type, pcs_slug, year; archive_dir) -> Union{DataFrame, Nothing}

Load a DataFrame from the permanent archive. Returns `nothing` if the file does not exist.

Warns when a file was written at a different `schema_version` from the one
`ARCHIVE_TYPES` now declares. A file with no provenance at all is silent: every
file written before WP5 is in that state, and a backtest opens hundreds of them
in a run. Finding those is `scripts/archive_audit.jl`'s job.
"""
function load_race_snapshot(
    data_type::String,
    pcs_slug::String,
    year::Int;
    archive_dir::String = archive_dir(),
)
    path = archive_path(data_type, pcs_slug, year; archive_dir = archive_dir)
    if isfile(path)
        try
            tbl = Arrow.Table(path)
            _warn_on_version_drift(tbl, data_type, pcs_slug, year)
            return DataFrame(tbl; copycols = true)
        catch e
            @warn "Failed to load archive $path: $e"
            return nothing
        end
    end
    return nothing
end

function _warn_on_version_drift(tbl, data_type::String, pcs_slug::String, year::Int)
    spec = get(ARCHIVE_TYPES, data_type, nothing)
    spec === nothing && return nothing
    meta = Arrow.getmetadata(tbl)
    (meta === nothing || !haskey(meta, "schema_version")) && return nothing
    written = tryparse(Int, meta["schema_version"])
    if written !== nothing && written != spec.version
        @warn "Archived $data_type for $pcs_slug $year was written at schema_version $written; ARCHIVE_TYPES declares $(spec.version)"
    end
    return nothing
end

"""
    archive_manifest_path(; archive_dir) -> String

`<archive_dir>/_manifest.toml`: the archive's self-description, for readers in
other languages that cannot see the Julia const.
"""
archive_manifest_path(; archive_dir::String = archive_dir()) =
    joinpath(archive_dir, "_manifest.toml")

"""
    archive_manifest_text() -> String

The manifest as it should be on disk — a pure function of `ARCHIVE_TYPES` and
`RETIRED_ARCHIVE_TYPES`, so `--check` is a string comparison and there is one
source of truth rather than two hand-maintained lists.

Written by a command rather than as a side effect of every save: rewriting a
file in the archive root hundreds of times a run is how Dropbox produces a
conflicted copy, and `serve.jl` and launchd would tear it concurrently.
"""
function archive_manifest_text()
    esc(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"")
    io = IOBuffer()
    write(
        io,
        """
        # Velogames archive manifest — derived from `ARCHIVE_TYPES`,
        # `RAW_ARCHIVE_TREES` and `RETIRED_ARCHIVE_TYPES` in src/cache_utils.jl, which
        # are the source of truth.
        # Write it with `julia --project scripts/archive_audit.jl --write-manifest`;
        # `--check` compares it against the const and exits non-zero if they differ.
        # Every typed file is `<data_type>/<key>/<year>.arrow`, Arrow IPC, with
        # provenance (data_type, schema_version, fetched_at, machine, source_url) in its
        # schema metadata. `<key>` is a PCS race slug for race types, a Velogames game
        # slug for `vg_riders` and `vg_racelist`, and `{game_slug}_{league_id}` for the
        # `league/*` types. Trees under [raw] hold documents rather than tables.
        """,
    )
    for name in sort(collect(keys(ARCHIVE_TYPES)))
        t = ARCHIVE_TYPES[name]
        write(io, "\n[types.\"$name\"]\n")
        write(io, "version = $(t.version)\n")
        write(io, "refetchable = $(t.refetchable)\n")
        write(io, "mandatory = [", join(("\"$(c)\"" for c in t.mandatory), ", "), "]\n")
        write(io, "note = \"$(esc(t.note))\"\n")
    end
    for r in RAW_ARCHIVE_TREES
        write(io, "\n[raw.\"$(r.name)\"]\n")
        write(io, "pattern = \"$(esc(r.pattern))\"\n")
        write(io, "refetchable = $(r.refetchable)\n")
        write(io, "note = \"$(esc(r.note))\"\n")
    end
    for r in RETIRED_ARCHIVE_TYPES
        write(io, "\n[retired.\"$(r.name)\"]\n")
        write(io, "moved_to = \"$(esc(r.moved_to))\"\n")
        write(io, "reason = \"$(esc(r.reason))\"\n")
    end
    return String(take!(io))
end

"""
    write_archive_manifest(; archive_dir) -> String

Write `_manifest.toml` and return its path.
"""
function write_archive_manifest(; archive_dir::String = archive_dir())
    path = archive_manifest_path(; archive_dir = archive_dir)
    mkpath(dirname(path))
    return atomic_write(p -> write(p, archive_manifest_text()), path)
end

"""
    archive_manifest_matches(; archive_dir) -> Bool

Whether the manifest on disk is the one the consts describe.
"""
function archive_manifest_matches(; archive_dir::String = archive_dir())
    path = archive_manifest_path(; archive_dir = archive_dir)
    return isfile(path) && read(path, String) == archive_manifest_text()
end

"""Type directories present on disk, `league/rosters` and the like included."""
function _archive_type_dirs(root::String)
    # `_retired` and `_inputs` are ordinary directories one level up, so they are
    # excluded by name rather than by assuming every top-level directory is a type.
    # A directory that some type is *namespaced under* (`league/`) is descended
    # into one level instead, so `league/rosters` is audited as the type it is
    # and `league/raw`, which holds documents rather than tables, is left to the
    # manifest.
    listing(dir) = sort([
        e for e in readdir(dir) if
        isdir(joinpath(dir, e)) && !startswith(e, ".") && !startswith(e, "_")
    ])
    namespaces = Set(
        first(split(n, '/')) for n in
        Iterators.flatten((keys(ARCHIVE_TYPES), (t.name for t in RAW_ARCHIVE_TREES))) if
        occursin('/', n)
    )
    raw_trees = Set(t.name for t in RAW_ARCHIVE_TREES)

    types = String[]
    for e in listing(root)
        if e in namespaces
            for sub in listing(joinpath(root, e))
                name = "$e/$sub"
                name in raw_trees || push!(types, name)
            end
        else
            push!(types, e)
        end
    end
    return types
end

"""
    audit_archive(; archive_dir) -> NamedTuple

Walk the archive and report what the write guard cannot: legacy files that
predate it. Returns `unknown_types`, `stray_files`, `empty_races`,
`missing_columns`, `missing_provenance`, `unreadable` and per-type `counts`.

The guard stops new drift; this is how you find out about the old kind. It also
serves as WP1b's verification tool (every file is Arrow and loads) and WP4's
acceptance test (which prediction archives are still deficient).
"""
function audit_archive(; archive_dir::String = archive_dir())
    root = archive_dir
    unknown_types = String[]
    stray_files = String[]
    empty_races = String[]
    missing_columns = NamedTuple{(:path, :missing),Tuple{String,Vector{Symbol}}}[]
    missing_provenance = String[]
    unreadable = String[]
    counts = NamedTuple{(:data_type, :races, :files, :rows),Tuple{String,Int,Int,Int}}[]

    isdir(root) || return (;
        unknown_types,
        stray_files,
        empty_races,
        missing_columns,
        missing_provenance,
        unreadable,
        counts,
    )

    year_file = Regex("^\\d{4}\\Q" * ARCHIVE_EXT * "\\E\$")

    for data_type in _archive_type_dirs(root)
        haskey(ARCHIVE_TYPES, data_type) || push!(unknown_types, data_type)
        n_files = 0
        n_rows = 0
        races = archive_races(data_type; archive_dir = root)
        for race in races
            racedir = joinpath(root, data_type, race)
            files = [f for f in readdir(racedir) if !startswith(f, ".")]
            archived = filter(f -> occursin(year_file, f), files)
            append!(stray_files, [joinpath(racedir, f) for f in setdiff(files, archived)])
            # A race directory does not imply a data file: three in the live tree
            # hold nothing, which is why file counts trail directory counts.
            isempty(archived) && push!(empty_races, joinpath(data_type, race))
            for f in archived
                path = joinpath(racedir, f)
                tbl = try
                    Arrow.Table(path)
                catch
                    push!(unreadable, path)
                    continue
                end
                n_files += 1
                cols = propertynames(tbl)
                n_rows += isempty(cols) ? 0 : length(getproperty(tbl, cols[1]))
                gaps = setdiff(
                    get(ARCHIVE_TYPES, data_type, (; mandatory = Symbol[])).mandatory,
                    cols,
                )
                isempty(gaps) || push!(missing_columns, (path = path, missing = gaps))
                meta = Arrow.getmetadata(tbl)
                if meta === nothing || !haskey(meta, "schema_version")
                    push!(missing_provenance, path)
                end
            end
        end
        push!(
            counts,
            (data_type = data_type, races = length(races), files = n_files, rows = n_rows),
        )
    end

    return (;
        unknown_types,
        stray_files,
        empty_races,
        missing_columns,
        missing_provenance,
        unreadable,
        counts,
    )
end

"""
Clear cache (all files or specific key)
"""
function clear_cache(cache_dir::String = DEFAULT_CACHE.cache_dir, key::String = "")
    if isempty(key)
        # Clear all cache files
        if isdir(cache_dir)
            rm(cache_dir, recursive = true)
            @info "Cleared all cache files from $cache_dir"
        end
    else
        # Clear specific cache entry
        data_file_feather, meta_file = cache_paths(key, cache_dir)

        removed = false
        for file in [data_file_feather, meta_file]
            if isfile(file)
                rm(file)
                removed = true
            end
        end

        if removed
            @info "Cleared cache entry: $key"
        else
            @info "No cache entry found: $key"
        end
    end
end
