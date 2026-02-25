# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

"""Extract the chosen team from optimisation results and log a summary."""
function _extract_chosen_team(results, predicted::DataFrame, cost_col::Symbol)
    chosen_vec = [results[r] for r in predicted.riderkey]
    predicted[!, :chosen] = chosen_vec .> 0.5
    chosenteam = filter(:chosen => ==(true), predicted)

    total_cost = sum(chosenteam[!, cost_col])
    total_evg = sum(chosenteam.expected_vg_points)
    @info "Selected $(nrow(chosenteam)) riders | Cost: $total_cost | Expected VG points: $(round(total_evg, digits=1))"

    return predicted, chosenteam
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
        riderdf = filter(
            row -> hasproperty(row, :startlist) ? row.startlist == racehash : true,
            riderdf,
        )
        @info "Filtered to $(nrow(riderdf)) riders for startlist: $racehash"
    end

    # Exclude riders
    if !isempty(excluded_riders)
        before = nrow(riderdf)
        riderdf = filter(row -> !(row.rider in excluded_riders), riderdf)
        @info "Excluded $(before - nrow(riderdf)) riders"
    end

    # Filter against PCS confirmed startlist
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

    # --- 4. Fetch Betfair odds (optional) ---
    odds_df = nothing
    if !isempty(betfair_market_id)
        try
            odds_df = getodds(
                betfair_market_id;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(odds_df) > 0
                @info "Got Betfair odds for $(nrow(odds_df)) riders"
                # Archive for future backtesting
                if !isempty(config.pcs_slug)
                    try
                        save_race_snapshot(odds_df, "odds", config.pcs_slug, config.year)
                    catch e
                        @warn "Failed to archive odds: $e"
                    end
                end
            else
                @info "Betfair market returned no active runners"
            end
        catch e
            @warn "Failed to fetch Betfair odds: $e"
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
    n_odds = if odds_df !== nothing
        length(intersect(riderdf.riderkey, odds_df.riderkey))
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

    @info "Data quality summary" riders = n_total pcs_specialty = "$n_pcs/$n_total" race_history = "$n_history/$n_total" vg_history = "$n_vg_history/$n_total" odds = "$n_odds/$n_total" oracle = "$n_oracle/$n_total"
    if n_pcs == 0
        @warn "No riders have PCS specialty data — strength estimates will rely on VG season points only"
    end
    if race_history_df !== nothing && n_history == 0
        @warn "No riders matched to race history — historical finishing positions won't inform predictions"
    end

    return RaceData(riderdf, race_history_df, odds_df, oracle_df, vg_history_df, nothing)
end


# ---------------------------------------------------------------------------
# One-day solver
# ---------------------------------------------------------------------------

"""
## `solve_oneday`

Construct an optimal team for a Sixes Classics one-day race using Monte Carlo
simulation of expected Velogames points.

## Pipeline:
1. Fetch VG rider data (costs, season points, teams)
2. Fetch PCS specialty ratings for each rider
3. Fetch PCS race-specific history (past editions)
4. Optionally fetch betting odds and Cycling Oracle predictions
5. Estimate rider strength via Bayesian updating
6. Monte Carlo simulate finishing positions
7. Compute expected VG points per rider
8. Optimise team selection to maximise expected VG points

## Arguments
- `config::RaceConfig` - race configuration (from `setup_race`)
- `racehash::String` - VG startlist hash filter (default: "" for all riders)
- `history_years::Int` - how many years of race history to use (default: 5)
- `betfair_market_id::String` - Betfair Exchange market ID (default: "" for no odds)
- `oracle_url::String` - Cycling Oracle prediction URL (default: "" for no oracle)
- `n_sims::Int` - Monte Carlo simulations (default: 10000)
- `excluded_riders::Vector{String}` - rider names to exclude
- `filter_startlist::Bool` - filter against PCS confirmed startlist (default: true)

## Returns
A tuple `(predicted, chosenteam)` where `predicted` is a DataFrame of all riders
with expected VG points, and `chosenteam` is the optimal 6-rider team.
"""
function solve_oneday(
    config::RaceConfig;
    racehash::String = "",
    history_years::Int = 5,
    betfair_market_id::String = "",
    oracle_url::String = "",
    n_sims::Int = 10000,
    excluded_riders::Vector{String} = String[],
    filter_startlist::Bool = true,
    cache_config::CacheConfig = config.cache,
    force_refresh::Bool = false,
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
    )
    if data === nothing
        return DataFrame(), DataFrame()
    end

    # --- 5-7. Predict expected VG points ---
    scoring = get_scoring(config.category > 0 ? config.category : 2)  # default Cat 2 if unknown

    @info "Predicting expected VG points (Cat $(config.category), $n_sims sims)..."
    predicted =
        predict_expected_points(data, scoring; n_sims = n_sims, race_year = config.year)

    # --- 8. Optimise team selection ---
    @info "Optimising team selection..."

    cost_col = :cost

    results = build_model_oneday(
        predicted,
        config.team_size,
        :expected_vg_points,
        cost_col;
        totalcost = 100,
    )

    if results === nothing
        @warn "Optimisation failed - no feasible solution found"
        return DataFrame(), DataFrame()
    end

    return _extract_chosen_team(results, predicted, cost_col)
end


"""
## `solve_stage`

Construct an optimal team for a stage race using Monte Carlo simulation of
expected Velogames points.

Uses class-aware strength estimation: rider PCS specialty scores are blended
according to their VG classification (all-rounder, climber, sprinter, unclassed)
to produce a single strength estimate that reflects their likely contribution
across the whole stage race.

This is an aggregate approach — it simulates overall finishing positions rather
than individual stages. See the roadmap for planned stage-by-stage simulation.

## Pipeline:
1. Fetch VG rider data (costs, season points, teams, classifications)
2. Fetch PCS specialty ratings for each rider
3. Fetch PCS race history (past editions, optional)
4. Optionally fetch betting odds and Cycling Oracle predictions
5. Estimate strength via class-aware Bayesian updating
6. Monte Carlo simulate overall finishing positions
7. Compute expected VG points via stage race scoring table
8. Optimise team selection with rider classification constraints

## Arguments
- `config::RaceConfig` - race configuration (from `setup_race`)
- `racehash::String` - VG startlist hash filter (default: "" for all riders)
- `history_years::Int` - how many years of race history to use (default: 3)
- `betfair_market_id::String` - Betfair Exchange market ID (default: "" for no odds)
- `oracle_url::String` - Cycling Oracle prediction URL (default: "" for no oracle)
- `n_sims::Int` - Monte Carlo simulations (default: 10000)
- `excluded_riders::Vector{String}` - rider names to exclude
- `filter_startlist::Bool` - filter against PCS confirmed startlist (default: true)

## Returns
A tuple `(predicted, chosenteam)` where `predicted` is a DataFrame of all riders
with expected VG points, and `chosenteam` is the optimal 9-rider team.
"""
function solve_stage(
    config::RaceConfig;
    racehash::String = "",
    history_years::Int = 3,
    betfair_market_id::String = "",
    oracle_url::String = "",
    n_sims::Int = 10000,
    excluded_riders::Vector{String} = String[],
    filter_startlist::Bool = true,
    cache_config::CacheConfig = config.cache,
    force_refresh::Bool = false,
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
    )
    if data === nothing
        return DataFrame(), DataFrame()
    end

    # --- 5-7. Predict expected VG points (stage race mode) ---
    scoring = get_scoring(:stage)

    @info "Predicting expected VG points (stage race, $n_sims sims)..."
    predicted = predict_expected_points(
        data,
        scoring;
        n_sims = n_sims,
        race_type = :stage,
        race_year = config.year,
    )

    # --- 8. Optimise team selection with class constraints ---
    @info "Optimising team selection (9 riders, class constraints)..."

    cost_col = :cost

    results = build_model_stage(
        predicted,
        config.team_size,
        :expected_vg_points,
        cost_col;
        totalcost = 100,
    )

    if results === nothing
        @warn "Optimisation failed - no feasible solution found"
        return DataFrame(), DataFrame()
    end

    return _extract_chosen_team(results, predicted, cost_col)
end
