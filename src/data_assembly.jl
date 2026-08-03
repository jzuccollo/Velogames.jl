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
    # Prior-edition GT VG overall totals for THIS grand tour (Option A prototype)
    gt_vg_history_df::Union{DataFrame,Nothing} = nothing
end


# ---------------------------------------------------------------------------
# PCS specialty join
# ---------------------------------------------------------------------------

"""
    join_pcs_specialty(riderdf::DataFrame, pcsriderpts::DataFrame) -> DataFrame

Left-join PCS specialty columns (oneday, gc, tt, sprint, climber) onto `riderdf`
by `:riderkey`, filling missing values with 0. Also adds a `:has_pcs_data` boolean
column tracking whether PCS data was successfully retrieved (before coalescing).
"""
function join_pcs_specialty(riderdf::DataFrame, pcsriderpts::DataFrame)
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
        race_history_df = getpcs_race_history(
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
        [
            (slug = s, penalty = SIMILAR_RACE_VARIANCE_PENALTY, prefer_gc = false) for
            s in get(SIMILAR_RACES, pcs_slug, String[])
        ],
        [
            (slug = s, penalty = GT_SIMILAR_VARIANCE_PENALTY, prefer_gc = true) for
            s in gt_slugs
        ],
    )

    # --- Prior-year similar-race history ---
    if !isempty(similar_specs)
        @info "Fetching similar-race history from: $(join([s.slug for s in similar_specs], ", "))..."
        for spec in similar_specs
            try
                similar_df = getpcs_race_history(
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
            catch e
                @debug "Skipping unavailable similar race $(spec.slug)" exception = e
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
                similar_df = getpcs_race_results(
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
                df = getpcs_race_results(
                    slug,
                    y;
                    classification = classification,
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
                nrow(df) == 0 && continue
                df[!, :year] .= y
                df[!, :variance_penalty] .= penalty
                result = result === nothing ? df : vcat(result, df; cols = :union)
            catch e
                @debug "Skipping unavailable edition $slug $y" exception = e
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
to the `getvg_race_list()` result, to avoid redundant fetches. If not provided,
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
        return getvg_race_list(
            yr;
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
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
        result = getvg_race_results(
            yr,
            race_num;
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
        if nrow(result) > 0 && !isempty(slug)
            try
                save_race_snapshot(result, "vg_results", slug, yr)
            catch e
                @debug "Failed to archive vg_results for $slug $yr" exception = e
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
                    vg_df = getvg_race_results(
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
# Grand-tour VG-history assembly (Option A prototype, July 2026)
# ---------------------------------------------------------------------------

"""
    assemble_gt_vg_history(vg_slug, race_year, history_years;
        cache_config, force_refresh) -> Union{DataFrame, Nothing}

Fetch each prior edition's full-field VG overall totals for THIS grand tour
(same `vg_slug`), across `[race_year - history_years, race_year - 1]`, and stack
them long. Returns a DataFrame with `riderkey`, `score`, `year` (the shape
`_assemble_signals` expects for the GT VG-history signal), or `nothing` if no
edition returned data.

Deliberately same-race (Tour→Tour), not cross-grand-tour: the flagged
break-hunter failures are all Tour-history cases, same-race is the lowest-bias
option (identical scoring/competition), and the memory note records that
cross-GT jersey history transfers poorly. Cross-GT is a possible extension.
"""
function assemble_gt_vg_history(
    vg_slug::String,
    race_year::Int,
    history_years::Int;
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    isempty(vg_slug) && return nothing
    out = nothing
    for hist_year = (race_year-history_years):(race_year-1)
        try
            df = getvg_stage_race_totals(
                hist_year,
                vg_slug;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            (df === nothing || nrow(df) == 0) && continue
            keep = select(df, :riderkey, :score)
            keep[!, :year] .= hist_year
            out = out === nothing ? keep : vcat(out, keep; cols = :union)
        catch e
            @warn "Failed to fetch GT VG totals for $vg_slug $hist_year" exception = e
        end
    end
    if out !== nothing
        @info "GT VG-history: $(nrow(out)) rider-results across $(length(unique(out.year))) editions of '$vg_slug'"
    end
    return out
end


"""
    assemble_season_vg_points(year, round_slugs; cache_config, force_refresh) -> Union{DataFrame, Nothing}

Mean VG points per round across other rounds of the same season-long series
(e.g. the Velogames Womens Cycling Championship), for games whose own `points`
column starts at zero. Returns `riderkey`, `points`, or `nothing`.

Mean, not sum: riders ride wildly different numbers of rounds, and rounds-ridden
is *negatively* rank-correlated with strength (ρ = −0.28 against the bookmaker
market on the 2026 Femmes field), so a cumulative total scores volume rather
than ability. Mean per round ranked best of the variants tried (ρ = 0.70 vs
market, against 0.65 for the sum).

Rounds VG has opened but nobody has scored in yet are skipped. `ridescore.php`
serves the full roster at zero for a round that has not been ridden, and those
rows would otherwise land in the denominator — deflating the mean of exactly the
riders entered in the most upcoming rounds, which is the opposite of what the
mean is here to avoid. The denominator is still rounds a rider was *rostered*
for, not rounds ridden: a DNS is indistinguishable from a scoreless finish on
this page, and both count as a zero-scoring round.
"""
function assemble_season_vg_points(
    year::Int,
    round_slugs::Vector{String};
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    isempty(round_slugs) && return nothing
    rounds = DataFrame[]
    for slug in round_slugs
        try
            df = getvg_stage_race_totals(
                year,
                slug;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if all(iszero, df.score)
                @info "Season round '$slug' $year has no scores yet — skipping"
                continue
            end
            push!(rounds, select(df, :riderkey, :score))
        catch e
            @warn "Failed to fetch season round '$slug' $year" exception = e
        end
    end
    isempty(rounds) && return nothing
    out = combine(groupby(vcat(rounds...), :riderkey), :score => mean => :points)
    @info "Season VG points: $(nrow(out)) riders across $(length(rounds)) scored rounds " *
          "of $year ($(length(round_slugs)) configured)"
    return out
end


# ---------------------------------------------------------------------------
# VG race list pre-fetching
# ---------------------------------------------------------------------------

"""
    prefetch_vg_racelists(years; cache_config, force_refresh) -> Dict{Int, DataFrame}

Pre-fetch VG race lists for multiple years. Returns a Dict mapping year to
the `getvg_race_list()` result. Used to avoid redundant fetches when processing
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
            racelists[yr] = getvg_race_list(
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

# ---------------------------------------------------------------------------
# Report data loading and post-race archival
# ---------------------------------------------------------------------------

"""
    list_completed_races(years; archive_dir) -> DataFrame

Scan the VG results archive for completed races and cross-reference with
`CLASSICS_RACES_2026` for metadata. Returns a DataFrame with columns:
pcs_slug, year, name, date, category.
"""
function list_completed_races(
    years::Vector{Int} = [2025, 2026];
    archive_dir::String = DEFAULT_ARCHIVE_DIR,
)
    rows = NamedTuple{
        (:pcs_slug, :year, :name, :date, :category),
        Tuple{String,Int,String,String,Int},
    }[]
    vg_dir = joinpath(archive_dir, "vg_results")
    isdir(vg_dir) || return DataFrame(rows)

    for slug_dir in readdir(vg_dir; join = true)
        isdir(slug_dir) || continue
        pcs_slug = basename(slug_dir)
        ri = _find_race_by_slug(pcs_slug)
        # Only include one-day classics (races in CLASSICS_RACES_2026)
        ri === nothing && continue
        for f in readdir(slug_dir)
            m = match(r"^(\d{4})\.feather$", f)
            m === nothing && continue
            yr = parse(Int, m[1])
            yr in years || continue
            name = ri !== nothing ? ri.name : replace(pcs_slug, "-" => " ") |> titlecase
            date = ri !== nothing ? replace(ri.date, r"^\d{4}" => string(yr)) : "$yr-01-01"
            cat = ri !== nothing ? ri.category : 0
            push!(
                rows,
                (pcs_slug = pcs_slug, year = yr, name = name, date = date, category = cat),
            )
        end
    end

    df = DataFrame(rows)
    sort!(df, [:date, :name])
    return df
end

"""
    load_report_data(pcs_slug, year) -> Union{DataFrame, Nothing}

Load VG race results and rider costs, join them, and compute value.
Returns a DataFrame with columns: rider, team, cost, score, value, riderkey.
Returns `nothing` if no archived results exist.
"""
function load_report_data(
    pcs_slug::String,
    year::Int;
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    vg_results = load_race_snapshot("vg_results", pcs_slug, year)
    vg_results === nothing && return nothing
    pcs_results = load_race_snapshot("pcs_results", pcs_slug, year)

    # Load rider costs from the classics riders page
    riders_url = vg_classics_url(year)
    riders = getvg_riders(riders_url; cache_config = cache_config)

    # Start from VG riders list and left-join results to get all riders with costs
    df = leftjoin(
        riders[:, [:rider, :team, :riderkey, :cost]],
        vg_results[:, [:riderkey, :score]];
        on = :riderkey,
    )
    # Fill missing scores (riders who didn't score) with 0
    df[!, :score] = coalesce.(df.score, 0)

    # Filter to race starters using PCS results if available
    if pcs_results !== nothing && :riderkey in propertynames(pcs_results)
        starter_keys = Set(pcs_results.riderkey)
        filter!(row -> row.riderkey in starter_keys, df)
    end

    df[!, :value] = round.(df.score ./ max.(df.cost, 1), digits = 1)
    clean_team_names!(df, [:team])
    return df
end

"""
    load_stage_race_report_data(pcs_slug, year; cache_config) -> Union{DataFrame, Nothing}

Load VG grand tour totals and rider costs/classifications, join them, and compute value.
Returns a DataFrame with columns: rider, team, cost, score, value, riderkey, class.
"""
function load_stage_race_report_data(
    pcs_slug::String,
    year::Int;
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    vg_slug = get(_STAGE_RACE_VG_SLUGS, pcs_slug, "")
    isempty(vg_slug) && return nothing

    # Try archived data first, then fetch live
    totals = load_race_snapshot("vg_stage_totals", pcs_slug, year)
    riders_df = load_race_snapshot("vg_stage_riders", pcs_slug, year)

    if totals === nothing
        try
            totals = suppress_output() do
                getvg_stage_race_totals(year, vg_slug; cache_config = cache_config)
            end
        catch e
            @warn "Failed to fetch VG stage race totals for $pcs_slug $year: $e"
            return nothing
        end
    end
    totals === nothing && return nothing

    if riders_df === nothing
        try
            riders_url = "https://www.velogames.com/$vg_slug/$year/riders.php"
            riders_df = suppress_output() do
                getvg_riders(riders_url; cache_config = cache_config)
            end
        catch e
            @warn "Failed to fetch VG riders for $pcs_slug $year: $e"
            return nothing
        end
    end
    riders_df === nothing && return nothing

    # Select columns from riders (cost, class, team info)
    rider_cols = [:rider, :team, :riderkey, :cost]
    if hasproperty(riders_df, :class)
        push!(rider_cols, :class)
    elseif hasproperty(riders_df, :classraw)
        riders_df[!, :class] = lowercase.(replace.(riders_df.classraw, " " => ""))
        push!(rider_cols, :class)
    end

    df = leftjoin(riders_df[:, rider_cols], totals[:, [:riderkey, :score]]; on = :riderkey)
    df[!, :score] = coalesce.(df.score, 0)
    df[!, :value] = round.(df.score ./ max.(df.cost, 1), digits = 1)
    clean_team_names!(df, [:team])
    return df
end

"""
    load_stage_race_per_stage_data(pcs_slug, year, n_stages; cache_config) -> Union{DataFrame, Nothing}

Load per-stage VG scores for all stages of a grand tour. Returns a long-format DataFrame
with columns: rider, team, score, riderkey, stage.
"""
function load_stage_race_per_stage_data(
    pcs_slug::String,
    year::Int,
    n_stages::Int;
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    # Try archived data first
    archived = load_race_snapshot("vg_stage_results", pcs_slug, year)
    if archived !== nothing
        return archived
    end

    vg_slug = get(_STAGE_RACE_VG_SLUGS, pcs_slug, "")
    isempty(vg_slug) && return nothing

    dfs = DataFrame[]
    for s = 1:n_stages
        try
            stage_df = suppress_output() do
                getvg_stage_results(year, vg_slug, s; cache_config = cache_config)
            end
            stage_df[!, :stage] .= s
            push!(dfs, stage_df)
        catch e
            @warn "Failed to fetch stage $s for $pcs_slug $year: $e"
        end
    end

    isempty(dfs) && return nothing
    return vcat(dfs...)
end

"""
    compute_cumulative_scores(per_stage, riderkeys; totals) -> DataFrame

Compute cumulative score progression for a set of riders. Returns long-format DataFrame
with columns: rider, riderkey, stage, cumulative_score, stage_score.

When `totals` is provided (DataFrame with riderkey + score columns from the overall
standings), any difference between the sum of per-stage scores and the overall total
is added as a final pseudo-stage (stage = max_stage + 1) representing end-of-race
classification bonuses.
"""
function compute_cumulative_scores(
    per_stage::DataFrame,
    riderkeys::Vector{String};
    totals::Union{DataFrame,Nothing} = nothing,
)
    key_set = Set(riderkeys)
    sub = filter(row -> row.riderkey in key_set, per_stage)
    result_rows = NamedTuple{
        (:rider, :riderkey, :stage, :cumulative_score, :stage_score),
        Tuple{String,String,Int,Int,Int},
    }[]
    max_stage = maximum(per_stage.stage)
    for key in riderkeys
        rider_data = sort(filter(row -> row.riderkey == key, sub), :stage)
        nrow(rider_data) == 0 && continue
        cum = 0
        rider_name = first(rider_data).rider
        for row in eachrow(rider_data)
            cum += row.score
            push!(
                result_rows,
                (
                    rider = rider_name,
                    riderkey = key,
                    stage = row.stage,
                    cumulative_score = cum,
                    stage_score = row.score,
                ),
            )
        end
        # Add final classification bonuses as pseudo-stage
        if totals !== nothing
            total_rows = filter(r -> r.riderkey == key, totals)
            if nrow(total_rows) > 0
                overall = first(total_rows).score
                bonus = overall - cum
                if bonus > 0
                    cum += bonus
                    push!(
                        result_rows,
                        (
                            rider = rider_name,
                            riderkey = key,
                            stage = max_stage + 1,
                            cumulative_score = cum,
                            stage_score = bonus,
                        ),
                    )
                end
            end
        end
    end
    return DataFrame(result_rows)
end

"""
    compute_stage_type_scores(per_stage, stages) -> DataFrame

Aggregate per-stage scores by stage type for each rider. Returns DataFrame with columns:
riderkey, rider, flat_score, hilly_score, mountain_score, itt_score.
"""
function compute_stage_type_scores(per_stage::DataFrame, stages::Vector{StageProfile})
    type_map = Dict(s.stage_number => s.stage_type for s in stages)
    ps = copy(per_stage)
    ps[!, :stage_type] = [get(type_map, s, :unknown) for s in ps.stage]

    result = combine(
        groupby(ps, [:riderkey, :rider]),
        [:score, :stage_type] => ((sc, st) -> sum(sc[st .== :flat])) => :flat_score,
        [:score, :stage_type] => ((sc, st) -> sum(sc[st .== :hilly])) => :hilly_score,
        [:score, :stage_type] =>
            ((sc, st) -> sum(sc[st .== :mountain])) => :mountain_score,
        [:score, :stage_type] => ((sc, st) -> sum(sc[st .== :itt])) => :itt_score,
    )
    return result
end

"""
    archive_stage_race_results(pcs_slug, year; n_stages, cache_config)

Archive VG totals, rider costs/classes, per-stage scores, and PCS stage profiles
for a completed grand tour. Idempotent (skips if already archived).
"""
function archive_stage_race_results(
    pcs_slug::String,
    year::Int;
    n_stages::Int = 21,
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    vg_slug = get(_STAGE_RACE_VG_SLUGS, pcs_slug, "")
    if isempty(vg_slug)
        @warn "Unknown stage race '$pcs_slug' — cannot archive"
        return
    end

    # Archive VG totals
    if load_race_snapshot("vg_stage_totals", pcs_slug, year) === nothing
        try
            totals = suppress_output() do
                getvg_stage_race_totals(year, vg_slug; cache_config = cache_config)
            end
            save_race_snapshot(totals, "vg_stage_totals", pcs_slug, year)
            @info "Archived vg_stage_totals for $pcs_slug $year"
        catch e
            @warn "Failed to archive VG totals for $pcs_slug $year: $e"
        end
    end

    # Archive VG riders (costs + classifications)
    if load_race_snapshot("vg_stage_riders", pcs_slug, year) === nothing
        try
            riders_url = "https://www.velogames.com/$vg_slug/$year/riders.php"
            riders = suppress_output() do
                getvg_riders(riders_url; cache_config = cache_config)
            end
            save_race_snapshot(riders, "vg_stage_riders", pcs_slug, year)
            @info "Archived vg_stage_riders for $pcs_slug $year"
        catch e
            @warn "Failed to archive VG riders for $pcs_slug $year: $e"
        end
    end

    # Archive per-stage VG results
    if load_race_snapshot("vg_stage_results", pcs_slug, year) === nothing
        per_stage = load_stage_race_per_stage_data(
            pcs_slug,
            year,
            n_stages;
            cache_config = cache_config,
        )
        if per_stage !== nothing
            save_race_snapshot(per_stage, "vg_stage_results", pcs_slug, year)
            @info "Archived vg_stage_results for $pcs_slug $year ($n_stages stages)"
        end
    end

    # Archive PCS stage profiles
    if load_race_snapshot("pcs_stage_profiles", pcs_slug, year) === nothing
        try
            profiles = suppress_output() do
                getpcs_stage_profiles(pcs_slug, year; cache_config = cache_config)
            end
            if !isempty(profiles)
                profiles_df = DataFrame(
                    stage_number = [s.stage_number for s in profiles],
                    stage_type = [string(s.stage_type) for s in profiles],
                    distance_km = [s.distance_km for s in profiles],
                    profile_score = [s.profile_score for s in profiles],
                    vertical_meters = [s.vertical_meters for s in profiles],
                    gradient_final_km = [s.gradient_final_km for s in profiles],
                    n_hc_climbs = [s.n_hc_climbs for s in profiles],
                    n_cat1_climbs = [s.n_cat1_climbs for s in profiles],
                    n_intermediate_sprints = [s.n_intermediate_sprints for s in profiles],
                    is_summit_finish = [s.is_summit_finish for s in profiles],
                )
                save_race_snapshot(profiles_df, "pcs_stage_profiles", pcs_slug, year)
                @info "Archived pcs_stage_profiles for $pcs_slug $year"
            end
        catch e
            @warn "Failed to archive PCS stage profiles for $pcs_slug $year: $e"
        end
    end

    # Archive PCS final GC results (for finisher / DNF detection). prefer_gc fetches the
    # /gc page and scopes to its general-classification tab (not the latest-stage result).
    if load_race_snapshot("pcs_gc_results", pcs_slug, year) === nothing
        try
            gc = suppress_output() do
                getpcs_race_results(
                    pcs_slug,
                    year;
                    prefer_gc = true,
                    cache_config = cache_config,
                )
            end
            nfin = gc === nothing ? 0 : sum(gc.position .< DNF_POSITION)
            if nfin > 0
                save_race_snapshot(
                    gc[:, [:position, :rider, :team, :riderkey]],
                    "pcs_gc_results",
                    pcs_slug,
                    year,
                )
                @info "Archived pcs_gc_results for $pcs_slug $year ($nfin finishers)"
            else
                @warn "PCS GC for $pcs_slug $year has no parseable finishers — skipping (DNF split disabled)"
            end
        catch e
            @warn "Failed to archive PCS GC results for $pcs_slug $year: $e"
        end
    end

    # Archive per-stage PCS results and the derived abandon stages. Both come from a single
    # fetch of every stage's finishing table: pcs_stage_results keeps the positions (used by
    # the rider dossier to show where a grand tour's VG points came from), pcs_abandons keeps
    # only the stage each non-finisher last completed.
    need_stage_results = load_race_snapshot("pcs_stage_results", pcs_slug, year) === nothing
    need_abandons = load_race_snapshot("pcs_abandons", pcs_slug, year) === nothing
    if need_stage_results || need_abandons
        try
            res = suppress_output() do
                getpcs_all_stage_results(pcs_slug, year, n_stages; cache_config = cache_config)
            end

            if need_stage_results && !isempty(res)
                stage_rows = DataFrame(
                    riderkey = String[],
                    rider = String[],
                    team = String[],
                    position = Int[],
                    stage = Int[],
                )
                for (s, df) in res, r in eachrow(df)
                    push!(stage_rows, (r.riderkey, r.rider, r.team, r.position, s))
                end
                if nrow(stage_rows) > 0
                    save_race_snapshot(stage_rows, "pcs_stage_results", pcs_slug, year)
                    @info "Archived pcs_stage_results for $pcs_slug $year ($(nrow(stage_rows)) rider-stages)"
                end
            end

            if need_abandons
                lastfin = Dict{String,Int}()
                namemap = Dict{String,String}()
                for (s, df) in res, r in eachrow(df)
                    namemap[r.riderkey] = r.rider
                    if r.position < DNF_POSITION
                        lastfin[r.riderkey] = max(get(lastfin, r.riderkey, 0), s)
                    end
                end
                # Anchor on the last stage with a real classification, not n_stages: some final
                # stages are neutralised (e.g. the 2025 Vuelta's Madrid finale, protested) and
                # carry no finishing positions, so every finisher's last classified stage is the
                # one before. A healthy stage classifies ~140+ riders.
                classified =
                    [s for (s, df) in res if sum(df.position .< DNF_POSITION) >= 30]
                final_stage = isempty(classified) ? 0 : maximum(classified)
                rows = NamedTuple{
                    (:riderkey, :rider, :abandon_stage),
                    Tuple{String,String,Int},
                }[]
                for (k, lf) in lastfin
                    lf < final_stage && push!(
                        rows,
                        (riderkey = k, rider = namemap[k], abandon_stage = lf + 1),
                    )
                end
                final_finishers = count(==(final_stage), values(lastfin))
                if !isempty(rows) && final_finishers >= 30
                    save_race_snapshot(DataFrame(rows), "pcs_abandons", pcs_slug, year)
                    @info "Archived pcs_abandons for $pcs_slug $year ($(length(rows)) abandons, final classified stage $final_stage of $n_stages)"
                else
                    @warn "PCS stage results for $pcs_slug $year look incomplete ($final_finishers reached the last classified stage) — skipping abandons"
                end
            end
        catch e
            @warn "Failed to archive PCS stage results / abandons for $pcs_slug $year: $e"
        end
    end
end

"""
    load_stage_profiles(pcs_slug, year) -> Vector{StageProfile}

Load archived PCS stage profiles and convert back to StageProfile structs.
Returns empty vector if not archived.
"""
function load_stage_profiles(
    pcs_slug::String,
    year::Int;
    archive_dir::String = DEFAULT_ARCHIVE_DIR,
)
    df = load_race_snapshot("pcs_stage_profiles", pcs_slug, year; archive_dir)
    df === nothing && return StageProfile[]
    return [
        StageProfile(
            row.stage_number,
            Symbol(row.stage_type),
            row.distance_km,
            row.profile_score,
            row.vertical_meters,
            row.gradient_final_km,
            row.n_hc_climbs,
            row.n_cat1_climbs,
            row.n_intermediate_sprints,
            row.is_summit_finish,
        ) for row in eachrow(df)
    ]
end


# ---------------------------------------------------------------------------
# League standings (WP0.1 — measures the actual objective: league placement)
# ---------------------------------------------------------------------------

"""
    load_league_standings(json_path::AbstractString; toml_path=nothing) -> DataFrame

Load full league standings from a `vgleague` JSON snapshot
(`{game_slug}_{year}_{league_id}.json`, produced by the sibling `vgleague`
package — see `../vgleague`). Returns a long DataFrame with one row per
`(username, teamname, race_name, race_number, score)`: every entrant's score
in every race the league has scraped so far.

If `toml_path` is given and exists, manually-recorded standings
(`data/league_standings.toml`) are merged in: any race whose name matches one
in the TOML file (compared via `normalise_race_name`, so a hand-typed variant
still overrides) is replaced by the TOML entries (the scraper hasn't caught up
yet, or the user wants to hand-correct it). TOML rows record the team display
name; where that matches a `teamname` in the JSON, the row is assigned that
entrant's `username` so one entrant keeps a single identity across sources.
See `load_league_standings_toml` for the TOML schema.
"""
function load_league_standings(
    json_path::AbstractString;
    toml_path::Union{AbstractString,Nothing} = nothing,
)
    json_df = load_league_standings_json(json_path)
    toml_df =
        (toml_path === nothing || !isfile(toml_path)) ? DataFrame() :
        load_league_standings_toml(toml_path)

    isempty(toml_df) && return json_df
    isempty(json_df) && return toml_df

    override_races = Set(normalise_race_name.(String.(toml_df.race_name)))
    kept =
        filter(:race_name => (r -> !(normalise_race_name(String(r)) in override_races)), json_df)
    username_of_team =
        Dict(String(t) => String(u) for (t, u) in zip(json_df.teamname, json_df.username))
    toml_df.username = [get(username_of_team, String(t), String(t)) for t in toml_df.teamname]
    return vcat(kept, toml_df; cols = :union)
end

"""
    load_league_standings(; data_dir, game_slug, year, league_id, toml_path=nothing) -> DataFrame

Convenience method: builds the `vgleague` JSON path from its components
(`joinpath(data_dir, "{game_slug}_{year}_{league_id}.json")`) before loading.
"""
function load_league_standings(;
    data_dir::AbstractString,
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString,
    toml_path::Union{AbstractString,Nothing} = nothing,
)
    json_path =
        joinpath(expanduser(data_dir), "$(game_slug)_$(year)_$(league_id).json")
    return load_league_standings(json_path; toml_path = toml_path)
end

"""
    load_league_standings_json(json_path::AbstractString) -> DataFrame

Parse a `vgleague` JSON snapshot directly. Returns an empty DataFrame if the
file doesn't exist. See `load_league_standings` for the combined (JSON + TOML)
entry point normally used.
"""
function load_league_standings_json(json_path::AbstractString)
    isfile(json_path) || return DataFrame()
    data = JSON3.read(read(json_path, String))

    rows = NamedTuple[]
    for (username, team) in pairs(data.teams)
        teamname = String(team.teamname)
        for (race_name, race) in pairs(team.races)
            push!(
                rows,
                (;
                    username = String(username),
                    teamname = teamname,
                    race_name = String(race_name),
                    race_number = Int(race.race_number),
                    score = Float64(race.score),
                ),
            )
        end
    end
    isempty(rows) && return DataFrame()
    return DataFrame(rows)
end

"""
    load_league_standings_toml(toml_path::AbstractString) -> DataFrame

Load manually-recorded league standings (fallback for races the `vgleague`
scraper hasn't picked up yet, or hand corrections). Schema:

```toml
[[races]]
name = "Omloop Nieuwsblad"
standings = [
    { team = "Cobbles & Wobbles", score = 1027 },
    { team = "Mud Springs Eternal", score = 965 },
]
```

Same long shape as `load_league_standings_json`, except `username` is set
equal to `teamname` (manual entries only ever record team names, not VG
logins) and `race_number` is `missing`.
"""
function load_league_standings_toml(toml_path::AbstractString)
    isfile(toml_path) || return DataFrame()
    data = TOML.parsefile(toml_path)

    rows = NamedTuple[]
    for race in get(data, "races", [])
        race_name = race["name"]
        for standing in race["standings"]
            push!(
                rows,
                (;
                    username = standing["team"],
                    teamname = standing["team"],
                    race_name = race_name,
                    race_number = missing,
                    score = Float64(standing["score"]),
                ),
            )
        end
    end
    isempty(rows) && return DataFrame()
    return DataFrame(rows)
end


# ---------------------------------------------------------------------------
# Stage-race classification rendering
# ---------------------------------------------------------------------------
