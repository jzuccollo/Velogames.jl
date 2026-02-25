"""
Shared data assembly functions used by both the production pipeline
(`_prepare_rider_data` in race_solver.jl) and backtesting pipeline
(`prefetch_race_data` in backtest.jl).

Eliminates divergence by providing a single implementation of race
history, VG history, PCS specialty join logic, and the shared `RaceData`
container.
"""


# ---------------------------------------------------------------------------
# Shared data container
# ---------------------------------------------------------------------------

"""
    RaceData

Pre-fetched data for a race, reusable across multiple backtest evaluations
(different signal subsets, hyperparameter candidates) without repeated I/O.

Also used by production solvers (`solve_oneday`, `solve_stage`) as the
standard data container between fetching and prediction.
"""
struct RaceData
    rider_df::DataFrame
    race_history_df::Union{DataFrame,Nothing}
    odds_df::Union{DataFrame,Nothing}
    oracle_df::Union{DataFrame,Nothing}
    vg_history_df::Union{DataFrame,Nothing}
    actual_df::Union{DataFrame,Nothing}
end


# ---------------------------------------------------------------------------
# PCS specialty join
# ---------------------------------------------------------------------------

"""
    join_pcs_specialty!(riderdf::DataFrame, pcsriderpts::DataFrame) -> DataFrame

Left-join PCS specialty columns (oneday, gc, tt, sprint, climber) onto `riderdf`
by `:riderkey`, filling missing values with 0. Returns the modified DataFrame.
"""
function join_pcs_specialty!(riderdf::DataFrame, pcsriderpts::DataFrame)
    pcs_cols = intersect(
        names(pcsriderpts),
        ["riderkey", "oneday", "gc", "tt", "sprint", "climber"],
    )
    if !isempty(pcs_cols)
        riderdf =
            leftjoin(riderdf, pcsriderpts[:, pcs_cols], on = :riderkey, makeunique = true)
        for col in [:oneday, :gc, :tt, :sprint, :climber]
            if col in propertynames(riderdf)
                riderdf[!, col] = coalesce.(riderdf[!, col], 0)
            end
        end
    end
    return riderdf
end


# ---------------------------------------------------------------------------
# PCS race history assembly
# ---------------------------------------------------------------------------

"""
    assemble_pcs_race_history(pcs_slug, race_year, history_years;
        race_date, cache_config, force_refresh) -> Union{DataFrame, Nothing}

Fetch PCS race history: prior-year primary results, prior-year similar-race
results, and optionally within-year similar race results.

Returns a DataFrame with columns `riderkey`, `position`, `year`,
`variance_penalty`, or `nothing` if no history could be fetched.
"""
function assemble_pcs_race_history(
    pcs_slug::String,
    race_year::Int,
    history_years::Int;
    race_date::Union{Date,Nothing} = nothing,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    isempty(pcs_slug) && return nothing
    history_years <= 0 && return nothing

    years = collect((race_year-history_years):(race_year-1))
    race_history_df = nothing

    # --- Prior-year primary race history ---
    try
        race_history_df = getpcsracehistory(
            pcs_slug,
            years;
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
        race_history_df[!, :variance_penalty] .= 0.0
        @info "Got $(nrow(race_history_df)) primary race history results"
    catch e
        @warn "Failed to fetch race history for $pcs_slug: $e"
    end

    # --- Prior-year similar-race history ---
    similar_slugs = get(SIMILAR_RACES, pcs_slug, String[])
    if !isempty(similar_slugs)
        @info "Fetching similar-race history from: $(join(similar_slugs, ", "))..."
        for slug in similar_slugs
            try
                similar_df = getpcsracehistory(
                    slug,
                    years;
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
                if nrow(similar_df) > 0
                    similar_df[!, :variance_penalty] .= 1.0
                    if race_history_df === nothing
                        race_history_df = similar_df
                    else
                        race_history_df = vcat(race_history_df, similar_df; cols = :union)
                    end
                end
            catch _e
                # Skip unavailable similar races
            end
        end
        n_similar =
            race_history_df !== nothing ? count(==(1.0), race_history_df.variance_penalty) :
            0
        @info "Got $n_similar similar-race history results"
    end

    # --- Within-year similar race results (PCS) ---
    if race_date !== nothing && !isempty(similar_slugs)
        for slug in similar_slugs
            similar_info = _find_race_by_slug(slug)
            similar_info === nothing && continue
            similar_date = _race_date_for_year(similar_info, race_year)
            similar_date >= race_date && continue
            try
                similar_df = getpcsraceresults(
                    slug,
                    race_year;
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
                if nrow(similar_df) > 0
                    similar_df[!, :year] .= race_year
                    similar_df[!, :variance_penalty] .= 1.0
                    race_history_df =
                        race_history_df === nothing ? similar_df :
                        vcat(race_history_df, similar_df; cols = :union)
                    @debug "Added $(nrow(similar_df)) within-year PCS results from $slug ($race_year)"
                end
            catch e
                @debug "Failed to fetch within-year PCS results for $slug $race_year: $e"
            end
        end
    end

    return race_history_df
end


# ---------------------------------------------------------------------------
# VG race history assembly
# ---------------------------------------------------------------------------

"""
    assemble_vg_race_history(race_name, pcs_slug, race_year, history_years;
        race_date, vg_racelists, cache_config, force_refresh) -> Union{DataFrame, Nothing}

Fetch VG race history: prior editions, similar races from prior years, and
within-year similar race results.

`vg_racelists` is an optional pre-fetched `Dict{Int, DataFrame}` mapping year
to the `getvgracelist()` result, to avoid redundant fetches. If not provided,
race lists are fetched on demand.

Returns a DataFrame with columns including `riderkey`, `score`, `year`,
or `nothing` if no VG history could be assembled.
"""
function assemble_vg_race_history(
    race_name::String,
    pcs_slug::String,
    race_year::Int,
    history_years::Int;
    race_date::Union{Date,Nothing} = nothing,
    vg_racelists::Union{Dict{Int,DataFrame},Nothing} = nothing,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    vg_history_df = nothing
    history_years_range = collect((race_year-history_years):(race_year-1))

    # Helper: get a VG race list, preferring the pre-fetched dict
    function _get_racelist(yr)
        if vg_racelists !== nothing && haskey(vg_racelists, yr)
            return vg_racelists[yr]
        end
        return getvgracelist(yr; cache_config = cache_config, force_refresh = force_refresh)
    end

    # Helper: fetch or load archived VG results for a specific race/year
    function _fetch_vg_results(name, slug, yr)
        archived = load_race_snapshot("vg_results", slug, yr)
        if archived !== nothing
            return archived
        end
        racelist = _get_racelist(yr)
        race_num = match_vg_race_number(name, racelist)
        # Fallback: try slug as a name (e.g. "gent-wevelgem" matches VG's
        # "Gent-Wevelgem" even when the 2026 RaceInfo name has changed)
        if race_num === nothing && !isempty(slug)
            slug_name = replace(slug, "-" => " ")
            race_num = match_vg_race_number(slug_name, racelist)
        end
        race_num === nothing && return nothing
        result = getvgraceresults(
            yr,
            race_num;
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
        if nrow(result) > 0 && !isempty(slug)
            try
                save_race_snapshot(result, "vg_results", slug, yr)
            catch _e
            end
        end
        return result
    end

    # --- Prior-year primary race VG history ---
    for hist_year in history_years_range
        try
            vg_df = _fetch_vg_results(race_name, pcs_slug, hist_year)
            vg_df === nothing && continue
            if nrow(vg_df) > 0
                vg_df[!, :year] .= hist_year
                vg_history_df =
                    vg_history_df === nothing ? vg_df :
                    vcat(vg_history_df, vg_df; cols = :union)
            end
        catch e
            @warn "Failed to fetch VG results for $race_name $hist_year" exception = e
        end
    end

    # --- Prior-year similar race VG history ---
    similar_slugs = get(SIMILAR_RACES, pcs_slug, String[])
    for slug in similar_slugs
        similar_race_info = _find_race_by_slug(slug)
        if similar_race_info === nothing
            @debug "No RaceInfo found for similar race slug '$slug' — skipping VG history"
            continue
        end
        for hist_year in history_years_range
            try
                vg_df = _fetch_vg_results(similar_race_info.name, slug, hist_year)
                vg_df === nothing && continue
                if nrow(vg_df) > 0
                    vg_df[!, :year] .= hist_year
                    vg_history_df =
                        vg_history_df === nothing ? vg_df :
                        vcat(vg_history_df, vg_df; cols = :union)
                end
            catch e
                @warn "Failed to fetch VG similar-race results for $slug $hist_year" exception =
                    e
            end
        end
    end

    # --- Within-year VG similar race results ---
    if race_date !== nothing && !isempty(similar_slugs)
        try
            racelist_current = _get_racelist(race_year)
            for slug in similar_slugs
                similar_info = _find_race_by_slug(slug)
                similar_info === nothing && continue
                similar_date = _race_date_for_year(similar_info, race_year)
                similar_date >= race_date && continue
                try
                    race_num = match_vg_race_number(similar_info.name, racelist_current)
                    race_num === nothing && continue
                    vg_df = getvgraceresults(
                        race_year,
                        race_num;
                        cache_config = cache_config,
                        force_refresh = force_refresh,
                    )
                    if nrow(vg_df) > 0
                        vg_df[!, :year] .= race_year
                        vg_history_df =
                            vg_history_df === nothing ? vg_df :
                            vcat(vg_history_df, vg_df; cols = :union)
                        @debug "Added $(nrow(vg_df)) within-year VG results from $slug ($race_year)"
                    end
                catch e
                    @warn "Failed to fetch within-year VG results for $slug $race_year" exception =
                        e
                end
            end
        catch e
            @warn "Failed to fetch VG race list for within-year history $race_year" exception =
                e
        end
    end

    if vg_history_df !== nothing
        @info "VG race history: $(nrow(vg_history_df)) rider-results across $(length(unique(vg_history_df.year))) years"
    end

    return vg_history_df
end


# ---------------------------------------------------------------------------
# VG race list pre-fetching
# ---------------------------------------------------------------------------

"""
    prefetch_vg_racelists(years; cache_config, force_refresh) -> Dict{Int, DataFrame}

Pre-fetch VG race lists for multiple years. Returns a Dict mapping year to
the `getvgracelist()` result. Used to avoid redundant fetches when processing
multiple races.
"""
function prefetch_vg_racelists(
    years::Vector{Int};
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    racelists = Dict{Int,DataFrame}()
    for yr in unique(years)
        try
            racelists[yr] = getvgracelist(
                yr;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
        catch e
            @debug "Failed to fetch VG race list for $yr: $e"
        end
    end
    return racelists
end
