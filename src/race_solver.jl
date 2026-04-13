# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

"""Extract the chosen team (highest selection_frequency riders) and mark all riders."""
function _extract_chosen_team(predicted::DataFrame, top_teams::Vector{DataFrame})
    if isempty(top_teams)
        predicted[!, :chosen] .= false
        return predicted, DataFrame()
    end
    best_team = top_teams[1]
    best_keys = Set(best_team.riderkey)
    predicted[!, :chosen] = [k in best_keys for k in predicted.riderkey]
    chosenteam = filter(:chosen => ==(true), predicted)

    total_cost = sum(chosenteam.cost)
    total_evg = sum(chosenteam.expected_vg_points)
    @info "Selected $(nrow(chosenteam)) riders | Cost: $total_cost | Expected VG points: $(round(total_evg, digits=1))"

    return predicted, chosenteam
end

"""Archive the predicted DataFrame for prospective evaluation."""
function _archive_predictions(predicted::DataFrame, config::RaceConfig)
    isempty(config.pcs_slug) && return
    # Don't overwrite an existing prediction archive (protects pre-race snapshots
    # from being clobbered by a post-race re-run). Set VELOGAMES_FORCE_ARCHIVE=1
    # to override.
    existing = load_race_snapshot("predictions", config.pcs_slug, config.year)
    if existing !== nothing && get(ENV, "VELOGAMES_FORCE_ARCHIVE", "") != "1"
        @warn "Prediction archive already exists for $(config.pcs_slug) $(config.year) — skipping. Set VELOGAMES_FORCE_ARCHIVE=1 to overwrite."
        return
    end
    cols = intersect(
        propertynames(predicted),
        [
            :riderkey,
            :rider,
            :team,
            :cost,
            :strength,
            :uncertainty,
            :shift_pcs,
            :shift_vg,
            :shift_form,
            :shift_history,
            :shift_vg_history,
            :shift_oracle,
            :shift_qualitative,
            :shift_odds,
            :stage_strength_flat,
            :stage_strength_hilly,
            :stage_strength_mountain,
            :stage_strength_itt,
        ],
    )
    try
        save_race_snapshot(predicted[:, cols], "predictions", config.pcs_slug, config.year)
    catch e
        @warn "Failed to archive predictions: $e"
    end
end

"""Load breakaway rates from PCS data, or return empty vectors if unavailable."""
function _load_breakaway_rates(breakaway_dir::String, riderkeys::AbstractVector)
    isempty(breakaway_dir) && return Float64[], Float64[]
    !isdir(breakaway_dir) && return Float64[], Float64[]
    try
        breakaway_df = load_pcs_breakaway_stats(breakaway_dir)
        rates, sectors = compute_breakaway_rates(breakaway_df, String.(riderkeys))
        n_matched = count(>(0.0), rates)
        @info "Breakaway data: $n_matched/$(length(riderkeys)) riders matched"
        return rates, sectors
    catch e
        @warn "Failed to load breakaway data: $e"
        return Float64[], Float64[]
    end
end

"""
    archive_race_results(race_name, year; cache_config, force_refresh)

Fetch and archive actual PCS results and VG results for a completed race.
Idempotent: safe to re-run. Intended to be called from team_assessor.qmd
after each race to build the prospective validation dataset.
"""
function archive_race_results(
    pcs_slug::String,
    year::Int;
    vg_race_number::Int=0,
    cache_config::CacheConfig=DEFAULT_CACHE,
    force_refresh::Bool=false,
)
    # Archive PCS race results
    try
        pcs_results = getpcsraceresults(
            pcs_slug,
            year;
            cache_config=cache_config,
            force_refresh=force_refresh,
        )
        if nrow(pcs_results) > 0
            save_race_snapshot(pcs_results, "pcs_results", pcs_slug, year)
        end
    catch e
        @warn "Failed to archive PCS results for $pcs_slug $year: $e"
    end

    # Archive VG race results if race number provided
    if vg_race_number > 0
        try
            vg_results = getvgraceresults(
                year,
                vg_race_number;
                cache_config=cache_config,
                force_refresh=force_refresh,
            )
            if nrow(vg_results) > 0
                save_race_snapshot(vg_results, "vg_results", pcs_slug, year)
            end
        catch e
            @warn "Failed to archive VG results for $pcs_slug $year: $e"
        end
    end
end

# ---------------------------------------------------------------------------
# Shared data preparation
# ---------------------------------------------------------------------------

"""
    _prepare_rider_data(config, racehash, excluded_riders, history_years,
                        oracle_url, min_riders, cache_config,
                        force_refresh; pcs_check_col=:oneday,
                        filter_startlist=true)

Shared data-fetching pipeline for `solve_oneday` and `solve_stage`.

Fetches VG riders, filters by startlist hash and exclusions, optionally filters
against PCS confirmed startlist, joins PCS specialty ratings, fetches race history
(including similar races), VG historical race points, odds, and Cycling Oracle
predictions, and logs a data quality summary. Odds come from a pre-parsed
DataFrame (e.g. Oddschecker paste) passed via the `odds_df` keyword.

Returns a `RaceData` struct or `nothing` if fewer than `min_riders` remain
after filtering.
"""
function _prepare_rider_data(
    config::RaceConfig,
    racehash::String,
    excluded_riders::Vector{String},
    history_years::Int,
    oracle_url::String,
    min_riders::Int,
    cache_config::CacheConfig,
    force_refresh::Bool;
    pcs_check_col::Symbol=:oneday,
    filter_startlist::Bool=true,
    qualitative_df::Union{DataFrame,Nothing}=nothing,
    odds_df::Union{DataFrame,Nothing}=nothing,
)
    # --- 1. Fetch VG rider data ---
    @info "Fetching VG rider data from $(config.current_url)..."
    riderdf = getvgriders(
        config.current_url;
        cache_config=cache_config,
        force_refresh=force_refresh,
    )

    # Filter by startlist hash if provided
    if !isempty(racehash)
        filtered = filter(
            row -> hasproperty(row, :startlist) ? row.startlist == racehash : true,
            riderdf,
        )
        if nrow(filtered) > 0
            riderdf = filtered
            @info "Filtered to $(nrow(riderdf)) riders for startlist: $racehash"
        else
            @warn "No riders matched startlist hash '$racehash' — ignoring hash filter"
        end
    end

    # Exclude riders
    if !isempty(excluded_riders)
        before = nrow(riderdf)
        riderdf = filter(row -> !(row.rider in excluded_riders), riderdf)
        @info "Excluded $(before - nrow(riderdf)) riders"
    end

    # Filter against PCS confirmed startlist
    pcs_slug_map = Dict{String,String}()
    if filter_startlist && !isempty(config.pcs_slug)
        try
            startlist_df = getpcsracestartlist(
                config.pcs_slug,
                config.year;
                cache_config=cache_config,
                force_refresh=force_refresh,
            )
            if nrow(startlist_df) > 0 && :riderkey in propertynames(startlist_df)
                before = nrow(riderdf)
                riderdf = semijoin(riderdf, startlist_df[:, [:riderkey]], on=:riderkey)
                @info "Filtered to $(nrow(riderdf)) riders confirmed on PCS startlist (removed $(before - nrow(riderdf)))"

                # Build riderkey → PCS slug mapping from startlist
                if :pcs_slug in propertynames(startlist_df)
                    for row in eachrow(startlist_df)
                        if !isempty(row.pcs_slug)
                            pcs_slug_map[row.riderkey] = row.pcs_slug
                        end
                    end
                    n_slugs = length(pcs_slug_map)
                    if n_slugs > 0
                        @info "Extracted $n_slugs PCS profile slugs from startlist"
                    end
                end
            end
        catch e
            @warn "Could not fetch PCS startlist: $e — skipping startlist filter"
        end
    end

    if nrow(riderdf) < min_riders
        @warn "Not enough riders ($(nrow(riderdf))) for a $(min_riders)-rider team"
        return nothing
    end

    # --- 2. Fetch PCS specialty ratings ---
    @info "Fetching PCS specialty ratings for $(nrow(riderdf)) riders..."
    rider_names = String.(riderdf.rider)
    pcsriderpts = getpcsriderpts_batch(
        rider_names;
        slug_map=pcs_slug_map,
        cache_config=cache_config,
        force_refresh=force_refresh,
    )

    riderdf = join_pcs_specialty!(riderdf, pcsriderpts)

    # Archive PCS specialty scores for future backtesting
    if !isempty(config.pcs_slug) && nrow(pcsriderpts) > 0
        try
            save_race_snapshot(pcsriderpts, "pcs_specialty", config.pcs_slug, config.year)
        catch e
            @debug "Failed to archive PCS specialty data: $e"
        end
    end

    # --- 3. Fetch PCS race history (primary + similar + within-year) ---
    race_info = _find_race_by_slug(config.pcs_slug)
    race_date =
        race_info !== nothing ? _race_date_for_year(race_info, config.year) : nothing
    race_history_df = assemble_pcs_race_history(
        config.pcs_slug,
        config.year,
        history_years;
        race_date=race_date,
        cache_config=cache_config,
        force_refresh=force_refresh,
    )

    # --- 3b. Fetch VG race history (automatic) ---
    race_name = race_info !== nothing ? race_info.name : ""
    vg_history_df = assemble_vg_race_history(
        race_name,
        config.pcs_slug,
        config.year,
        history_years;
        race_date=race_date,
        cache_config=cache_config,
        force_refresh=force_refresh,
    )

    # --- 3c. Fetch PCS form scores (automatic) ---
    form_df = nothing
    if !isempty(config.pcs_slug)
        try
            form_df = getpcsraceform(
                config.pcs_slug,
                config.year;
                cache_config=cache_config,
                force_refresh=force_refresh,
            )
            if nrow(form_df) > 0
                @info "Got PCS form scores for $(nrow(form_df)) riders"
                try
                    save_race_snapshot(form_df, "pcs_form", config.pcs_slug, config.year)
                catch e
                    @debug "Failed to archive PCS form data: $e"
                end
            end
        catch e
            @warn "Failed to fetch PCS form data: $e"
        end
    end

    # --- 3d. Fetch cross-season PCS points for trajectory (automatic) ---
    # Build slug map from rider names if the startlist didn't provide one
    if isempty(pcs_slug_map)
        for row in eachrow(riderdf)
            slug = normalisename(row.rider)
            slug = get(PCS_SLUG_OVERRIDES, slug, slug)
            pcs_slug_map[row.riderkey] = slug
        end
    end
    seasons_df = nothing
    if !isempty(pcs_slug_map)
        try
            seasons_df = getpcsriderseasons_batch(
                pcs_slug_map;
                cache_config=cache_config,
                force_refresh=force_refresh,
            )
            if nrow(seasons_df) > 0
                n_riders_with_seasons = length(unique(seasons_df.riderkey))
                @info "Got cross-season PCS points for $n_riders_with_seasons riders"
                if !isempty(config.pcs_slug)
                    try
                        save_race_snapshot(
                            seasons_df,
                            "pcs_seasons",
                            config.pcs_slug,
                            config.year,
                        )
                    catch e
                        @debug "Failed to archive PCS seasons data: $e"
                    end
                end
            end
        catch e
            @warn "Failed to fetch PCS seasons data: $e"
        end
    end

    # --- 4. Odds (pre-parsed, e.g. Oddschecker paste) ---
    final_odds_df = odds_df
    if !isnothing(final_odds_df) && nrow(final_odds_df) > 0 && !isempty(config.pcs_slug)
        try
            save_race_snapshot(final_odds_df, "odds", config.pcs_slug, config.year)
        catch e
            @warn "Failed to archive odds: $e"
        end
    end

    # --- 5. Fetch Cycling Oracle predictions (optional) ---
    oracle_df = nothing
    if !isempty(oracle_url)
        try
            oracle_df = get_cycling_oracle(
                oracle_url;
                cache_config=cache_config,
                force_refresh=force_refresh,
            )
            if nrow(oracle_df) > 0
                @info "Got Cycling Oracle predictions for $(nrow(oracle_df)) riders"
                # Archive for future backtesting
                if !isempty(config.pcs_slug)
                    try
                        save_race_snapshot(
                            oracle_df,
                            "oracle",
                            config.pcs_slug,
                            config.year,
                        )
                    catch e
                        @warn "Failed to archive oracle predictions: $e"
                    end
                end
            else
                @info "Cycling Oracle returned no predictions"
            end
        catch e
            @warn "Failed to fetch Cycling Oracle predictions: $e"
        end
    end

    # --- Data quality summary ---
    n_total = nrow(riderdf)
    n_pcs = if pcs_check_col in propertynames(riderdf)
        count(row -> !ismissing(row[pcs_check_col]) && row[pcs_check_col] > 0, eachrow(riderdf))
    else
        0
    end
    n_history = if race_history_df !== nothing
        length(intersect(riderdf.riderkey, unique(race_history_df.riderkey)))
    else
        0
    end
    n_odds = if final_odds_df !== nothing
        length(intersect(riderdf.riderkey, final_odds_df.riderkey))
    else
        0
    end
    n_oracle = if oracle_df !== nothing
        length(intersect(riderdf.riderkey, oracle_df.riderkey))
    else
        0
    end
    n_vg_history = if vg_history_df !== nothing
        length(intersect(riderdf.riderkey, unique(vg_history_df.riderkey)))
    else
        0
    end
    n_qualitative = if qualitative_df !== nothing
        length(intersect(riderdf.riderkey, qualitative_df.riderkey))
    else
        0
    end
    n_form = if form_df !== nothing
        length(intersect(riderdf.riderkey, form_df.riderkey))
    else
        0
    end
    n_seasons = if seasons_df !== nothing
        length(intersect(riderdf.riderkey, unique(seasons_df.riderkey)))
    else
        0
    end

    # Archive qualitative data for prospective evaluation
    if qualitative_df !== nothing && nrow(qualitative_df) > 0 && !isempty(config.pcs_slug)
        try
            save_race_snapshot(qualitative_df, "qualitative", config.pcs_slug, config.year)
        catch e
            @warn "Failed to archive qualitative data: $e"
        end
    end

    @info "Data quality summary" riders = n_total pcs_specialty = "$n_pcs/$n_total" race_history = "$n_history/$n_total" vg_history = "$n_vg_history/$n_total" odds = "$n_odds/$n_total" oracle = "$n_oracle/$n_total" qualitative = "$n_qualitative/$n_total" form = "$n_form/$n_total" seasons = "$n_seasons/$n_total"
    if n_pcs == 0
        @warn "No riders have PCS specialty data — strength estimates will rely on VG season points only"
    end
    if race_history_df !== nothing && n_history == 0
        @warn "No riders matched to race history — historical finishing positions won't inform predictions"
    end

    return RaceData(
        riderdf,
        race_history_df,
        final_odds_df,
        oracle_df,
        vg_history_df,
        qualitative_df,
        form_df,
        seasons_df,
        nothing,
    )
end


# ---------------------------------------------------------------------------
# One-day solver
# ---------------------------------------------------------------------------

"""
## `solve_oneday`

Construct an optimal team for a Sixes Classics one-day race using resampled
optimisation of expected Velogames points.

## Pipeline:
1. Fetch VG rider data (costs, season points, teams)
2. Fetch PCS specialty ratings for each rider
3. Fetch PCS race-specific history (past editions)
4. Optionally use pre-parsed odds and Cycling Oracle predictions
5. Estimate rider strength via Bayesian updating
6. Resampled optimisation: draw strengths, score, optimise, repeat

## Returns
A tuple `(predicted, chosenteam, top_teams, sim_vg_points)` where `predicted` is
a DataFrame of all riders with expected VG points and selection frequency,
`chosenteam` is the most frequently selected team, `top_teams` is a vector of
the top alternative teams, and `sim_vg_points` is a Matrix{Float64}
(n_riders × n_resamples) of per-draw VG points (row order matches `predicted`).
"""
function solve_oneday(
    config::RaceConfig;
    racehash::String="",
    history_years::Int=5,
    oracle_url::String="",
    n_resamples::Int=500,
    excluded_riders::Vector{String}=String[],
    filter_startlist::Bool=true,
    cache_config::CacheConfig=config.cache,
    force_refresh::Bool=false,
    qualitative_df::Union{DataFrame,Nothing}=nothing,
    odds_df::Union{DataFrame,Nothing}=nothing,
    domestique_discount::Float64=0.0,
    max_per_team::Int=0,
    risk_aversion::Float64=0.5,
    breakaway_dir::String="",
    simulation_df::Union{Int,Nothing}=nothing,
)
    data = _prepare_rider_data(
        config,
        racehash,
        excluded_riders,
        history_years,
        oracle_url,
        config.team_size,
        cache_config,
        force_refresh;
        pcs_check_col=:oneday,
        filter_startlist=filter_startlist,
        qualitative_df=qualitative_df,
        odds_df=odds_df,
    )
    if data === nothing
        return DataFrame(), DataFrame(), DataFrame[], Matrix{Float64}(undef, 0, 0)
    end

    # --- 5. Estimate rider strengths ---
    scoring = get_scoring(config.category > 0 ? config.category : 2)

    @info "Estimating rider strengths (Cat $(config.category))..."
    predicted = estimate_strengths(
        data;
        race_year=config.year,
        domestique_discount=domestique_discount,
    )

    # Archive predictions for prospective evaluation
    _archive_predictions(predicted, config)

    # --- 6. Breakaway rates ---
    b_rates, b_sectors = _load_breakaway_rates(breakaway_dir, predicted.riderkey)

    # --- 7. Resampled optimisation ---
    @info "Running resampled optimisation ($n_resamples resamples)..."
    predicted, top_teams, sim_vg_points = resample_optimise(
        predicted,
        scoring,
        build_model_oneday;
        team_size=config.team_size,
        n_resamples=n_resamples,
        max_per_team=max_per_team,
        risk_aversion=risk_aversion,
        breakaway_rates=b_rates,
        breakaway_mean_sectors=b_sectors,
        simulation_df=simulation_df,
    )

    predicted, chosenteam = _extract_chosen_team(predicted, top_teams)

    return predicted, chosenteam, top_teams, sim_vg_points
end


"""
## `solve_stage`

Construct an optimal team for a stage race using resampled optimisation.

When `stages` is non-empty, uses per-stage simulation with stage-type strength
modifiers (the new pipeline). When empty, falls back to the aggregate GC-position
approach.

Uses class-aware strength estimation and enforces VG classification constraints
(all-rounders, climbers, sprinters, unclassed) during optimisation.

## Returns
A tuple `(predicted, chosenteam, top_teams, sim_vg_points)`.
"""
function solve_stage(
    config::RaceConfig;
    stages::Vector{StageProfile}=StageProfile[],
    racehash::String="",
    history_years::Int=3,
    oracle_url::String="",
    n_resamples::Int=500,
    excluded_riders::Vector{String}=String[],
    filter_startlist::Bool=true,
    cache_config::CacheConfig=config.cache,
    force_refresh::Bool=false,
    qualitative_df::Union{DataFrame,Nothing}=nothing,
    odds_df::Union{DataFrame,Nothing}=nothing,
    domestique_discount::Float64=0.0,
    max_per_team::Int=0,
    risk_aversion::Float64=0.5,
    breakaway_dir::String="",
    simulation_df::Union{Int,Nothing}=nothing,
    cross_stage_alpha::Float64=0.7,
    modifier_scale::Float64=0.5,
    stage_scoring::Union{StageRaceScoringTable,Nothing}=nothing,
)
    data = _prepare_rider_data(
        config,
        racehash,
        excluded_riders,
        history_years,
        oracle_url,
        config.team_size,
        cache_config,
        force_refresh;
        pcs_check_col=:gc,
        filter_startlist=filter_startlist,
        qualitative_df=qualitative_df,
        odds_df=odds_df,
    )
    if data === nothing
        return DataFrame(), DataFrame(), DataFrame[], Matrix{Float64}(undef, 0, 0)
    end

    @info "Estimating rider strengths (stage race)..."
    predicted = estimate_strengths(
        data;
        race_type=:stage,
        race_year=config.year,
        domestique_discount=domestique_discount,
    )

    if !isempty(stages)
        # --- Per-stage pipeline ---
        @info "Computing stage-type strength modifiers ($(length(stages)) stages)..."
        stage_strengths = compute_stage_type_modifiers(
            predicted, Float64.(predicted.strength);
            modifier_scale=modifier_scale,
        )

        # Add per-stage-type strengths to the DataFrame for reporting
        for stype in [:flat, :hilly, :mountain, :itt]
            col = Symbol("stage_strength_$stype")
            predicted[!, col] = round.(stage_strengths[stype], digits=3)
        end

        _archive_predictions(predicted, config)

        # Archive stage profiles
        if !isempty(config.pcs_slug)
            try
                stage_df = DataFrame(
                    stage_number=[s.stage_number for s in stages],
                    stage_type=[String(s.stage_type) for s in stages],
                    distance_km=[s.distance_km for s in stages],
                    profile_score=[s.profile_score for s in stages],
                    vertical_meters=[s.vertical_meters for s in stages],
                    n_hc_climbs=[s.n_hc_climbs for s in stages],
                    n_cat1_climbs=[s.n_cat1_climbs for s in stages],
                    is_summit_finish=[s.is_summit_finish for s in stages],
                )
                save_race_snapshot(stage_df, "stage_profiles", config.pcs_slug, config.year)
            catch e
                @debug "Failed to archive stage profiles: $e"
            end
        end

        scoring_table = stage_scoring !== nothing ? stage_scoring : SCORING_GRAND_TOUR
        @info "Running per-stage resampled optimisation ($n_resamples resamples, $(length(stages)) stages)..."
        predicted, top_teams, sim_vg_points = resample_optimise_stage(
            predicted,
            stages,
            stage_strengths,
            scoring_table,
            build_model_stage;
            team_size=config.team_size,
            n_resamples=n_resamples,
            cross_stage_alpha=cross_stage_alpha,
            max_per_team=max_per_team,
            risk_aversion=risk_aversion,
        )
    else
        # --- Aggregate fallback ---
        _archive_predictions(predicted, config)
        scoring = get_scoring(:stage)

        b_rates, b_sectors = _load_breakaway_rates(breakaway_dir, predicted.riderkey)

        @info "Running aggregate resampled optimisation ($n_resamples resamples, class constraints)..."
        predicted, top_teams, sim_vg_points = resample_optimise(
            predicted,
            scoring,
            build_model_stage;
            team_size=config.team_size,
            n_resamples=n_resamples,
            max_per_team=max_per_team,
            risk_aversion=risk_aversion,
            breakaway_rates=b_rates,
            breakaway_mean_sectors=b_sectors,
            simulation_df=simulation_df,
        )
    end

    predicted, chosenteam = _extract_chosen_team(predicted, top_teams)

    return predicted, chosenteam, top_teams, sim_vg_points
end
