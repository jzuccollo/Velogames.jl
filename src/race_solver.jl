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
    # Select the key columns for archival
    cols = intersect(
        propertynames(predicted),
        [:riderkey, :rider, :strength, :uncertainty,
         :shift_pcs, :shift_vg, :shift_form, :shift_trajectory,
         :shift_history, :shift_vg_history, :shift_oracle,
         :shift_qualitative, :shift_odds],
    )
    try
        save_race_snapshot(predicted[:, cols], "predictions", config.pcs_slug, config.year)
    catch e
        @warn "Failed to archive predictions: $e"
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
    vg_race_number::Int = 0,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    # Archive PCS race results
    try
        pcs_results = getpcsraceresults(
            pcs_slug, year;
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
            vg_results = getvgraceresults(year, vg_race_number;
                cache_config=cache_config, force_refresh=force_refresh)
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
                        betfair_market_id, oracle_url, min_riders, cache_config,
                        force_refresh; pcs_check_col=:oneday,
                        filter_startlist=true)

Shared data-fetching pipeline for `solve_oneday` and `solve_stage`.

Fetches VG riders, filters by startlist hash and exclusions, optionally filters
against PCS confirmed startlist, joins PCS specialty ratings, fetches race history
(including similar races), VG historical race points, odds, and Cycling Oracle
predictions, and logs a data quality summary.

Returns a `RaceData` struct or `nothing` if fewer than `min_riders` remain
after filtering.
"""
function _prepare_rider_data(
    config::RaceConfig,
    racehash::String,
    excluded_riders::Vector{String},
    history_years::Int,
    betfair_market_id::String,
    oracle_url::String,
    min_riders::Int,
    cache_config::CacheConfig,
    force_refresh::Bool;
    pcs_check_col::Symbol = :oneday,
    filter_startlist::Bool = true,
    qualitative_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
)
    # --- 1. Fetch VG rider data ---
    @info "Fetching VG rider data from $(config.current_url)..."
    riderdf = getvgriders(
        config.current_url;
        cache_config = cache_config,
        force_refresh = force_refresh,
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
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(startlist_df) > 0 && :riderkey in propertynames(startlist_df)
                before = nrow(riderdf)
                riderdf = semijoin(riderdf, startlist_df[:, [:riderkey]], on = :riderkey)
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
        slug_map = pcs_slug_map,
        cache_config = cache_config,
        force_refresh = force_refresh,
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
        race_date = race_date,
        cache_config = cache_config,
        force_refresh = force_refresh,
    )

    # --- 3b. Fetch VG race history (automatic) ---
    race_name = race_info !== nothing ? race_info.name : ""
    vg_history_df = assemble_vg_race_history(
        race_name,
        config.pcs_slug,
        config.year,
        history_years;
        race_date = race_date,
        cache_config = cache_config,
        force_refresh = force_refresh,
    )

    # --- 3c. Fetch PCS form scores (automatic) ---
    form_df = nothing
    if !isempty(config.pcs_slug)
        try
            form_df = getpcsraceform(
                config.pcs_slug,
                config.year;
                cache_config = cache_config,
                force_refresh = force_refresh,
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
    seasons_df = nothing
    if !isempty(pcs_slug_map)
        try
            seasons_df = getpcsriderseasons_batch(
                pcs_slug_map;
                cache_config = cache_config,
                force_refresh = force_refresh,
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

    # --- 4. Odds (Betfair Exchange or pre-parsed Oddschecker) ---
    final_odds_df = if odds_df !== nothing
        odds_df
    elseif !isempty(betfair_market_id)
        try
            df = getodds(
                betfair_market_id;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(df) > 0
                @info "Got Betfair odds for $(nrow(df)) riders"
                df
            else
                @info "Betfair market returned no active runners"
                nothing
            end
        catch e
            @warn "Failed to fetch Betfair odds: $e"
            nothing
        end
    else
        nothing
    end
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
                cache_config = cache_config,
                force_refresh = force_refresh,
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
4. Optionally fetch betting odds and Cycling Oracle predictions
5. Estimate rider strength via Bayesian updating
6. Resampled optimisation: draw strengths, score, optimise, repeat

## Returns
A tuple `(predicted, chosenteam, top_teams)` where `predicted` is a DataFrame
of all riders with expected VG points and selection frequency, `chosenteam` is
the most frequently selected team, and `top_teams` is a vector of the top
alternative teams.
"""
function solve_oneday(
    config::RaceConfig;
    racehash::String = "",
    history_years::Int = 5,
    betfair_market_id::String = "",
    oracle_url::String = "",
    n_resamples::Int = 500,
    excluded_riders::Vector{String} = String[],
    filter_startlist::Bool = true,
    cache_config::CacheConfig = config.cache,
    force_refresh::Bool = false,
    qualitative_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    max_per_team::Int = 0,
    risk_aversion::Float64 = 0.5,
)
    data = _prepare_rider_data(
        config,
        racehash,
        excluded_riders,
        history_years,
        betfair_market_id,
        oracle_url,
        config.team_size,
        cache_config,
        force_refresh;
        pcs_check_col = :oneday,
        filter_startlist = filter_startlist,
        qualitative_df = qualitative_df,
        odds_df = odds_df,
    )
    if data === nothing
        return DataFrame(), DataFrame(), DataFrame[]
    end

    # --- 5. Estimate rider strengths ---
    scoring = get_scoring(config.category > 0 ? config.category : 2)

    @info "Estimating rider strengths (Cat $(config.category))..."
    predicted = estimate_strengths(
        data;
        race_year = config.year,
        domestique_discount = domestique_discount,
    )

    # Archive predictions for prospective evaluation
    _archive_predictions(predicted, config)

    # --- 6. Resampled optimisation ---
    @info "Running resampled optimisation ($n_resamples resamples)..."
    predicted, top_teams = resample_optimise(
        predicted,
        scoring,
        build_model_oneday;
        team_size = config.team_size,
        n_resamples = n_resamples,
        max_per_team = max_per_team,
        risk_aversion = risk_aversion,
    )

    predicted, chosenteam = _extract_chosen_team(predicted, top_teams)

    return predicted, chosenteam, top_teams
end


"""
## `solve_stage`

Construct an optimal team for a stage race using resampled optimisation.

Uses class-aware strength estimation and enforces VG classification constraints
(all-rounders, climbers, sprinters, unclassed) during optimisation.

## Returns
A tuple `(predicted, chosenteam, top_teams)`.
"""
function solve_stage(
    config::RaceConfig;
    racehash::String = "",
    history_years::Int = 3,
    betfair_market_id::String = "",
    oracle_url::String = "",
    n_resamples::Int = 500,
    excluded_riders::Vector{String} = String[],
    filter_startlist::Bool = true,
    cache_config::CacheConfig = config.cache,
    force_refresh::Bool = false,
    qualitative_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    max_per_team::Int = 0,
    risk_aversion::Float64 = 0.5,
)
    data = _prepare_rider_data(
        config,
        racehash,
        excluded_riders,
        history_years,
        betfair_market_id,
        oracle_url,
        config.team_size,
        cache_config,
        force_refresh;
        pcs_check_col = :gc,
        filter_startlist = filter_startlist,
        qualitative_df = qualitative_df,
        odds_df = odds_df,
    )
    if data === nothing
        return DataFrame(), DataFrame(), DataFrame[]
    end

    scoring = get_scoring(:stage)

    @info "Estimating rider strengths (stage race)..."
    predicted = estimate_strengths(
        data;
        race_type = :stage,
        race_year = config.year,
        domestique_discount = domestique_discount,
    )

    _archive_predictions(predicted, config)

    @info "Running resampled optimisation ($n_resamples resamples, class constraints)..."
    predicted, top_teams = resample_optimise(
        predicted,
        scoring,
        build_model_stage;
        team_size = config.team_size,
        n_resamples = n_resamples,
        max_per_team = max_per_team,
        risk_aversion = risk_aversion,
    )

    predicted, chosenteam = _extract_chosen_team(predicted, top_teams)

    return predicted, chosenteam, top_teams
end
