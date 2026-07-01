"""
Shared data assembly functions used by both the production pipeline
(`_prepare_rider_data` in race_solver.jl) and backtesting pipeline
(`prefetch_race_data` in backtest.jl).

Eliminates divergence by providing a single implementation of race
history, VG history, PCS specialty join logic, and the shared `RaceData`
container.
"""


# ---------------------------------------------------------------------------
# Similar-race variance penalties (added to a history observation's variance to
# reflect how cleanly form transfers from a different race).
# ---------------------------------------------------------------------------

"""Variance penalty for a terrain-matched classics similar-race result."""
const SIMILAR_RACE_VARIANCE_PENALTY = 1.0

"""Variance penalty for a grand-tour cross-history result (Giro/Vuelta → Tour,
etc.). Larger than the classics penalty because GT GC form transfers more
noisily; recency decay is applied per-edition on top of this. Tuning knob for
the GT cross-history experiment."""
const GT_SIMILAR_VARIANCE_PENALTY = 3.0


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
@kwdef struct RaceData
    rider_df::DataFrame
    race_history_df::Union{DataFrame,Nothing} = nothing
    odds_df::Union{DataFrame,Nothing} = nothing
    oracle_df::Union{DataFrame,Nothing} = nothing
    vg_history_df::Union{DataFrame,Nothing} = nothing
    qualitative_df::Union{DataFrame,Nothing} = nothing
    form_df::Union{DataFrame,Nothing} = nothing
    seasons_df::Union{DataFrame,Nothing} = nothing
    actual_df::Union{DataFrame,Nothing} = nothing
    # Multi-source oracle (stage races): points jersey + KOM jersey predictions
    points_oracle_df::Union{DataFrame,Nothing} = nothing
    kom_oracle_df::Union{DataFrame,Nothing} = nothing
    # Bookmaker secondary markets (stage races): points jersey, KOM, stage-win
    points_odds_df::Union{DataFrame,Nothing} = nothing
    kom_odds_df::Union{DataFrame,Nothing} = nothing
    stagewin_odds_df::Union{DataFrame,Nothing} = nothing
    # Prior-edition classification history (stage races): points jersey + KOM standings
    points_history_df::Union{DataFrame,Nothing} = nothing
    kom_history_df::Union{DataFrame,Nothing} = nothing
end


# ---------------------------------------------------------------------------
# PCS specialty join
# ---------------------------------------------------------------------------

"""
    join_pcs_specialty!(riderdf::DataFrame, pcsriderpts::DataFrame) -> DataFrame

Left-join PCS specialty columns (oneday, gc, tt, sprint, climber) onto `riderdf`
by `:riderkey`, filling missing values with 0. Also adds a `:has_pcs_data` boolean
column tracking whether PCS data was successfully retrieved (before coalescing).
"""
function join_pcs_specialty!(riderdf::DataFrame, pcsriderpts::DataFrame)
    pcs_cols = intersect(
        names(pcsriderpts),
        ["riderkey", "oneday", "gc", "tt", "sprint", "climber"],
    )
    if !isempty(pcs_cols)
        riderdf =
            leftjoin(riderdf, pcsriderpts[:, pcs_cols], on = :riderkey, makeunique = true)
        # Track which riders had PCS data before coalescing missing → 0
        specialty_cols =
            intersect(propertynames(riderdf), [:oneday, :gc, :tt, :sprint, :climber])
        riderdf[!, :has_pcs_data] = [
            any(!ismissing(riderdf[i, col]) for col in specialty_cols) for
            i = 1:nrow(riderdf)
        ]
        for col in [:oneday, :gc, :tt, :sprint, :climber]
            if col in propertynames(riderdf)
                riderdf[!, col] = coalesce.(riderdf[!, col], 0)
            end
        end
    else
        riderdf[!, :has_pcs_data] = falses(nrow(riderdf))
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
    include_gt_history::Bool = true,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    isempty(pcs_slug) && return nothing
    history_years <= 0 && return nothing

    years = collect((race_year-history_years):(race_year-1))
    race_history_df = nothing

    # Grand tours expose their result at /gc; /result returns the final stage's
    # sprint, not the GC. Fetch the GC explicitly for stage races.
    primary_prefer_gc = haskey(GT_SIMILAR_RACES, pcs_slug)

    # --- Prior-year primary race history ---
    try
        race_history_df = getpcsracehistory(
            pcs_slug,
            years;
            prefer_gc = primary_prefer_gc,
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
        race_history_df[!, :variance_penalty] .= 0.0
        @info "Got $(nrow(race_history_df)) primary race history results"
    catch e
        @warn "Failed to fetch race history for $pcs_slug: $e"
    end

    # --- Similar-race history: terrain-matched classics (penalty 1.0) plus
    #     grand-tour cross-history (larger penalty). GT GC form transfers more
    #     noisily than a terrain-matched classic, so its observations carry more
    #     variance; recency decay on top is applied per-edition downstream. ---
    gt_slugs = include_gt_history ? get(GT_SIMILAR_RACES, pcs_slug, String[]) : String[]
    similar_specs = vcat(
        [(slug = s, penalty = SIMILAR_RACE_VARIANCE_PENALTY, prefer_gc = false)
         for s in get(SIMILAR_RACES, pcs_slug, String[])],
        [(slug = s, penalty = GT_SIMILAR_VARIANCE_PENALTY, prefer_gc = true)
         for s in gt_slugs],
    )

    # --- Prior-year similar-race history ---
    if !isempty(similar_specs)
        @info "Fetching similar-race history from: $(join([s.slug for s in similar_specs], ", "))..."
        for spec in similar_specs
            try
                similar_df = getpcsracehistory(
                    spec.slug,
                    years;
                    prefer_gc = spec.prefer_gc,
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
                if nrow(similar_df) > 0
                    similar_df[!, :variance_penalty] .= spec.penalty
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
            race_history_df !== nothing ? count(>(0.0), race_history_df.variance_penalty) :
            0
        @info "Got $n_similar similar-race history results"
    end

    # --- Within-year similar race results (PCS) ---
    if race_date !== nothing && !isempty(similar_specs)
        for spec in similar_specs
            similar_date = resolve_race_date(spec.slug, race_year)
            (similar_date === nothing || similar_date >= race_date) && continue
            try
                similar_df = getpcsraceresults(
                    spec.slug,
                    race_year;
                    prefer_gc = spec.prefer_gc,
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
                if nrow(similar_df) > 0
                    similar_df[!, :year] .= race_year
                    similar_df[!, :variance_penalty] .= spec.penalty
                    race_history_df =
                        race_history_df === nothing ? similar_df :
                        vcat(race_history_df, similar_df; cols = :union)
                    @debug "Added $(nrow(similar_df)) within-year PCS results from $(spec.slug) ($race_year)"
                end
            catch e
                @debug "Failed to fetch within-year PCS results for $(spec.slug) $race_year: $e"
            end
        end
    end

    return race_history_df
end


"""
    assemble_pcs_classification_history(pcs_slug, race_year, history_years, classification; ...)

Fetch prior-edition standings for a grand-tour secondary classification
(`:points` or `:kom`): same-race prior editions (penalty 0) plus grand-tour
cross-history (Giro/Vuelta ↔ Tour, penalty `GT_SIMILAR_VARIANCE_PENALTY`),
prior-year and within-year (gated on `race_date`). Returns a DataFrame with
`riderkey`, `position`, `year`, `variance_penalty`, or `nothing`.
"""
function assemble_pcs_classification_history(
    pcs_slug::String,
    race_year::Int,
    history_years::Int,
    classification::Symbol;
    race_date::Union{Date,Nothing} = nothing,
    include_gt_history::Bool = true,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    isempty(pcs_slug) && return nothing
    history_years <= 0 && return nothing
    years = collect((race_year-history_years):(race_year-1))
    result = nothing

    function add!(slug, yrs, penalty)
        for y in yrs
            try
                df = getpcsraceresults(slug, y; classification = classification,
                    cache_config = cache_config, force_refresh = force_refresh)
                nrow(df) == 0 && continue
                df[!, :year] .= y
                df[!, :variance_penalty] .= penalty
                result = result === nothing ? df : vcat(result, df; cols = :union)
            catch _e
                # Skip unavailable editions
            end
        end
    end

    add!(pcs_slug, years, 0.0)                      # same-race prior editions
    if include_gt_history                            # grand-tour cross-history
        for other in get(GT_SIMILAR_RACES, pcs_slug, String[])
            add!(other, years, GT_SIMILAR_VARIANCE_PENALTY)
            other_date = resolve_race_date(other, race_year)
            if other_date !== nothing && race_date !== nothing && other_date < race_date
                add!(other, [race_year], GT_SIMILAR_VARIANCE_PENALTY)
            end
        end
    end
    return result
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
    history_years_range =
        collect(max(VG_CLASSICS_FIRST_YEAR, race_year-history_years):(race_year-1))

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
        if race_num === nothing
            @debug "No VG race match for '$name' (slug '$slug') in $yr"
            return nothing
        end
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
