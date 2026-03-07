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

# Default cache configuration
const DEFAULT_CACHE = CacheConfig(
    joinpath(homedir(), ".velogames_cache"),
    168,  # 7 days default cache lifetime
)

# Session-scoped in-memory cache (avoids redundant disk reads within a session)
const _MEMORY_CACHE = Dict{String,DataFrame}()

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
    catch _e
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

    # Save data
    Feather.write(data_file, data)

    # Save metadata
    meta = CacheMetadata(url, now(), "1.0", params)
    write(meta_file, JSON3.write(meta))
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
        catch _e
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

    # 2. Check on-disk cache
    if !force_refresh &&
       is_cache_valid(key, cache_config.max_age_hours, cache_config.cache_dir)
        cached_data = load_from_cache(key, cache_config.cache_dir)
        if cached_data !== nothing
            verbose && @info "Loading from cache: $url"
            _MEMORY_CACHE[key] = cached_data
            return cached_data
        end
    end

    # 3. Fetch from network
    verbose && @info "Fetching fresh data: $url"
    data = fetch_func(url, params)

    # Save to both caches
    save_to_cache(data, key, url, cache_config.cache_dir, params)
    _MEMORY_CACHE[key] = data

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
    archive_path(data_type, pcs_slug, year; archive_dir) -> String

Compute the archive file path for a given data type, race, and year.
Returns a path like `~/.velogames_archive/odds/paris-roubaix/2025.feather`.
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
