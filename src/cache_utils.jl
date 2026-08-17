"""
Cache configuration and utilities for Velogames data retrieval.

Two layers:
- **In-memory**: session-scoped `Dict` keyed by cache key. Avoids redundant disk
  reads when the same URL is requested multiple times (e.g. the same rider across
  88 backtest races). Cleared on Julia restart or via `clear_memory_cache!()`.
- **On-disk**: Feather files with JSON metadata and TTL-based expiry.
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

    # Save metadata first (marks this URL as attempted, even if data is empty)
    meta = CacheMetadata(url, now(), "1.0", params)
    write(meta_file, JSON3.write(meta))

    # Save data (Feather can't serialise empty string columns, so skip
    # the data file for empty results — the metadata alone marks the
    # cache entry as valid so cached_fetch won't refetch)
    if nrow(data) > 0
        Feather.write(data_file, data)
    end
end

"""
Load data from cache - handles both DataFrame and JSON data
"""
function load_from_cache(key::String, cache_dir::String)::Union{DataFrame,Nothing}
    data_file_feather, meta_file = cache_paths(key, cache_dir)

    # Try Feather (DataFrame)
    if isfile(data_file_feather)
        try
            return Feather.read(data_file_feather)
        catch e
            @warn "Failed to read cached data $data_file_feather" exception = e
            return nothing
        end
    end

    return nothing
end

"""
Generic cached data fetcher.

Lookup order: in-memory Dict → on-disk Feather → network fetch.
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
        # Metadata exists but no data file → cached empty result
        verbose && @info "Loading cached empty result: $url"
        return DataFrame()
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
Default directory for permanent race data archives.
"""
const DEFAULT_ARCHIVE_DIR = joinpath(homedir(), "Dropbox", "code", "velogames", "archive")

"""
    league_winners_path(; archive_dir) -> String

The league winners record, `<archive_dir>/league_winners.toml`.

It lives in the archive rather than the repo because it is race data, like
everything else here, and because that keeps git out of the unattended publish
path entirely — `auto_publish.sh` pulls code, renders and deploys, and writes
nothing back. Every entry is derivable in principle from the vgleague
snapshots, but those sit in a gitignored, machine-local directory that nothing
backs up, so this file is the durable record.
"""
league_winners_path(; archive_dir::String = DEFAULT_ARCHIVE_DIR) =
    joinpath(archive_dir, "league_winners.toml")

"""
    load_league_winners(; archive_dir) -> Vector{@NamedTuple{pcs_slug::String, year::Int, name::String, score::Int}}

Every recorded league winner, in file order. Empty when the file is absent.
"""
function load_league_winners(; archive_dir::String = DEFAULT_ARCHIVE_DIR)
    path = league_winners_path(; archive_dir)
    isfile(path) || return NamedTuple[]
    return [
        (
            pcs_slug = String(w["pcs_slug"]),
            year = Int(w["year"]),
            name = String(w["name"]),
            score = Int(w["score"]),
        ) for w in get(TOML.parsefile(path), "winners", [])
    ]
end

"""
    append_league_winner(pcs_slug, year, name, score; archive_dir) -> Nothing

Append one `[[winners]]` entry. The file is append-only: correcting a winner
means editing it by hand and deleting that race's rendered HTML so the next
render rebuilds it.
"""
function append_league_winner(
    pcs_slug::AbstractString,
    year::Integer,
    name::AbstractString,
    score::Integer;
    archive_dir::String = DEFAULT_ARCHIVE_DIR,
)
    path = league_winners_path(; archive_dir)
    mkpath(dirname(path))
    escaped = replace(String(name), "\\" => "\\\\", "\"" => "\\\"")
    open(path, "a+") do io
        # A file that doesn't end in a newline would swallow the blank line
        # separating this entry from the last.
        seekend(io)
        if position(io) > 0
            seek(io, position(io) - 1)
            read(io, Char) == '\n' || write(io, "\n")
        end
        write(io, """

        [[winners]]
        pcs_slug = "$pcs_slug"
        year = $year
        name = "$escaped"
        score = $score
        """)
    end
    return nothing
end

"""
    archive_path(data_type, pcs_slug, year; archive_dir) -> String

Compute the archive file path for a given data type, race, and year.
Returns a path like `<archive_dir>/odds/paris-roubaix/2025.feather`.
"""
function archive_path(
    data_type::String,
    pcs_slug::String,
    year::Int;
    archive_dir::String = DEFAULT_ARCHIVE_DIR,
)
    return joinpath(archive_dir, data_type, pcs_slug, "$(year).feather")
end

"""
    save_race_snapshot(df, data_type, pcs_slug, year; archive_dir) -> Nothing

Save a DataFrame to the permanent archive. Creates directories as needed.
Overwrites any existing snapshot for the same race/year/type.
"""
function save_race_snapshot(
    df::DataFrame,
    data_type::String,
    pcs_slug::String,
    year::Int;
    archive_dir::String = DEFAULT_ARCHIVE_DIR,
)
    path = archive_path(data_type, pcs_slug, year; archive_dir = archive_dir)
    mkpath(dirname(path))
    Feather.write(path, df)
    @info "Archived $data_type for $pcs_slug $year → $path"
    return nothing
end

"""
    load_race_snapshot(data_type, pcs_slug, year; archive_dir) -> Union{DataFrame, Nothing}

Load a DataFrame from the permanent archive. Returns `nothing` if the file does not exist.
"""
function load_race_snapshot(
    data_type::String,
    pcs_slug::String,
    year::Int;
    archive_dir::String = DEFAULT_ARCHIVE_DIR,
)
    path = archive_path(data_type, pcs_slug, year; archive_dir = archive_dir)
    if isfile(path)
        try
            return DataFrame(Feather.read(path))
        catch e
            @warn "Failed to load archive $path: $e"
            return nothing
        end
    end
    return nothing
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
