"""
Cache configuration and utilities for Velogames data retrieval
"""

"""
Cache configuration structure
"""
struct CacheConfig
    cache_dir::String
    max_age_hours::Int
    enabled::Bool
end

# Default cache configuration
const DEFAULT_CACHE = CacheConfig(
    joinpath(homedir(), ".velogames_cache"),
    24,  # 24 hours default cache lifetime
    true,
)

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
        age_hours = (now() - meta.timestamp).value / (1000 * 60 * 60)
        return age_hours < max_age_hours
    catch
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
        catch
            return nothing
        end
    end

    return nothing
end

"""
Generic cached data fetcher
"""
function cached_fetch(
    fetch_func::Function,
    url::String,
    params::Dict = Dict();
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
    verbose::Bool = true,
)
    if !cache_config.enabled
        return fetch_func(url, params)
    end

    key = cache_key(url, params)

    # Check cache first (unless force refresh)
    if !force_refresh &&
       is_cache_valid(key, cache_config.max_age_hours, cache_config.cache_dir)
        cached_data = load_from_cache(key, cache_config.cache_dir)
        if cached_data !== nothing
            verbose && @info "Loading from cache: $url"
            return cached_data
        end
    end

    # Fetch fresh data
    verbose && @info "Fetching fresh data: $url"
    data = fetch_func(url, params)

    # Save to cache
    save_to_cache(data, key, url, cache_config.cache_dir, params)

    return data
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
