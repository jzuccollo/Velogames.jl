# ---------------------------------------------------------------------------
# Shared data preparation
# ---------------------------------------------------------------------------

"""
    _prepare_rider_data(config, racehash, excluded_riders, history_years,
                        betfair_market_id, oracle_url, min_riders, cache_config,
                        force_refresh; pcs_check_col=:oneday,
                        filter_startlist=true, vg_history=Dict{Int,String}())

Shared data-fetching pipeline for `solve_oneday` and `solve_stage`.

Fetches VG riders, filters by startlist hash and exclusions, optionally filters
against PCS confirmed startlist, joins PCS specialty ratings, fetches race history
(including similar races), VG historical race points, odds, and Cycling Oracle
predictions, and logs a data quality summary.

Returns `(riderdf, race_history_df, odds_df, oracle_df, vg_history_df)` or
`nothing` if fewer than `min_riders` remain after filtering.
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
    vg_history::Dict{Int,String} = Dict{Int,String}(),
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

    # Join PCS data onto rider data
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

    # --- 3. Fetch PCS race history (primary + similar races) ---
    race_history_df = nothing
    if !isempty(config.pcs_slug) && history_years > 0
        current_year = config.year
        years = collect((current_year-history_years):(current_year-1))
        @info "Fetching race history for $(config.pcs_slug): $years..."
        try
            race_history_df = getpcsracehistory(
                config.pcs_slug,
                years;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            race_history_df[!, :variance_penalty] .= 0.0
            @info "Got $(nrow(race_history_df)) primary race history results"
        catch e
            @warn "Failed to fetch race history: $e"
        end

        # Fetch similar-race history with variance penalty
        similar_slugs = get(SIMILAR_RACES, config.pcs_slug, String[])
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
                catch e
                    @warn "Failed to fetch similar-race history for $slug: $e"
                end
            end
            n_similar = race_history_df !== nothing ?
                count(==(1.0), race_history_df.variance_penalty) : 0
            @info "Got $n_similar similar-race history results"
        end
    end

    # --- 3b. Fetch VG historical race points (optional) ---
    vg_history_df = nothing
    if !isempty(vg_history)
        dfs = DataFrame[]
        for (year, url) in vg_history
            try
                df = getvgracepoints(
                    url;
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
                df[!, :year] .= year
                push!(dfs, df)
            catch e
                @warn "Failed to fetch VG results for $year: $e"
            end
        end
        if !isempty(dfs)
            vg_history_df = vcat(dfs...)
            @info "Got VG historical results: $(nrow(vg_history_df)) riders across $(length(dfs)) years"
        end
    end

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

    @info "Data quality summary" riders=n_total pcs_specialty="$n_pcs/$n_total" race_history="$n_history/$n_total" vg_history="$n_vg_history/$n_total" odds="$n_odds/$n_total" oracle="$n_oracle/$n_total"
    if n_pcs == 0
        @warn "No riders have PCS specialty data — strength estimates will rely on VG season points only"
    end
    if race_history_df !== nothing && n_history == 0
        @warn "No riders matched to race history — historical finishing positions won't inform predictions"
    end

    return (riderdf = riderdf, race_history_df = race_history_df, odds_df = odds_df, oracle_df = oracle_df, vg_history_df = vg_history_df)
end


# ---------------------------------------------------------------------------
# One-day solver
# ---------------------------------------------------------------------------

"""
## `solve_oneday`

Construct an optimal team for a Superclassico Sixes one-day race using Monte Carlo
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
- `vg_history::Dict{Int,String}` - VG historical race results: year => results URL

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
    vg_history::Dict{Int,String} = Dict{Int,String}(),
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
        vg_history = vg_history,
    )
    if data === nothing
        return DataFrame(), DataFrame()
    end
    riderdf = data.riderdf
    race_history_df = data.race_history_df
    odds_df = data.odds_df
    oracle_df = data.oracle_df
    vg_history_df = data.vg_history_df

    # --- 5-7. Predict expected VG points ---
    scoring = get_scoring(config.category > 0 ? config.category : 2)  # default Cat 2 if unknown

    @info "Predicting expected VG points (Cat $(config.category), $n_sims sims)..."
    predicted = predict_expected_points(
        riderdf,
        scoring;
        race_history_df = race_history_df,
        odds_df = odds_df,
        oracle_df = oracle_df,
        vg_history_df = vg_history_df,
        n_sims = n_sims,
    )

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

    # Extract chosen riders
    chosen_vec = [results[r] for r in predicted.riderkey]
    predicted[!, :chosen] = chosen_vec .> 0.5
    chosenteam = filter(:chosen => ==(true), predicted)

    total_cost = sum(chosenteam[!, cost_col])
    total_evg = sum(chosenteam.expected_vg_points)
    @info "Selected $(nrow(chosenteam)) riders | Cost: $total_cost | Expected VG points: $(round(total_evg, digits=1))"

    return predicted, chosenteam
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
- `vg_history::Dict{Int,String}` - VG historical race results: year => results URL

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
    vg_history::Dict{Int,String} = Dict{Int,String}(),
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
        vg_history = vg_history,
    )
    if data === nothing
        return DataFrame(), DataFrame()
    end
    riderdf = data.riderdf
    race_history_df = data.race_history_df
    odds_df = data.odds_df
    oracle_df = data.oracle_df
    vg_history_df = data.vg_history_df

    # --- 5-7. Predict expected VG points (stage race mode) ---
    scoring = get_scoring(:stage)

    @info "Predicting expected VG points (stage race, $n_sims sims)..."
    predicted = predict_expected_points(
        riderdf,
        scoring;
        race_history_df = race_history_df,
        odds_df = odds_df,
        oracle_df = oracle_df,
        vg_history_df = vg_history_df,
        n_sims = n_sims,
        race_type = :stage,
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

    # Extract chosen riders
    chosen_vec = [results[r] for r in predicted.riderkey]
    predicted[!, :chosen] = chosen_vec .> 0.5
    chosenteam = filter(:chosen => ==(true), predicted)

    total_cost = sum(chosenteam[!, cost_col])
    total_evg = sum(chosenteam.expected_vg_points)
    @info "Selected $(nrow(chosenteam)) riders | Cost: $total_cost | Expected VG points: $(round(total_evg, digits=1))"

    return predicted, chosenteam
end


