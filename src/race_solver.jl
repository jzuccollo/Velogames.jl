# ---------------------------------------------------------------------------
# Shared data preparation
# ---------------------------------------------------------------------------

"""
    _prepare_rider_data(config, racehash, excluded_riders, history_years, odds_url,
                        min_riders, cache_config, force_refresh; pcs_check_col=:oneday)

Shared data-fetching pipeline for `solve_oneday` and `solve_stage`.

Fetches VG riders, filters by startlist hash and exclusions, joins PCS specialty
ratings, fetches race history and odds, and logs a data quality summary.

Returns `(riderdf, race_history_df, odds_df)` or `nothing` if fewer than
`min_riders` remain after filtering.
"""
function _prepare_rider_data(
    config::RaceConfig,
    racehash::String,
    excluded_riders::Vector{String},
    history_years::Int,
    odds_url::String,
    min_riders::Int,
    cache_config::CacheConfig,
    force_refresh::Bool;
    pcs_check_col::Symbol = :oneday,
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

    # --- 3. Fetch PCS race history ---
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
            @info "Got $(nrow(race_history_df)) historical results"
        catch e
            @warn "Failed to fetch race history: $e"
        end
    end

    # --- 4. Fetch odds (optional) ---
    odds_df = nothing
    if !isempty(odds_url)
        try
            odds_df = getodds(
                odds_url;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            @info "Got odds for $(nrow(odds_df)) riders"
        catch e
            @warn "Failed to fetch odds: $e"
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

    @info "Data quality summary" riders=n_total pcs_specialty="$n_pcs/$n_total" race_history="$n_history/$n_total" odds="$n_odds/$n_total"
    if n_pcs == 0
        @warn "No riders have PCS specialty data — strength estimates will rely on VG season points only"
    end
    if race_history_df !== nothing && n_history == 0
        @warn "No riders matched to race history — historical finishing positions won't inform predictions"
    end

    return (riderdf = riderdf, race_history_df = race_history_df, odds_df = odds_df)
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
4. Optionally fetch betting odds
5. Estimate rider strength via Bayesian updating
6. Monte Carlo simulate finishing positions
7. Compute expected VG points per rider
8. Optimise team selection to maximise expected VG points

## Arguments
- `config::RaceConfig` - race configuration (from `setup_race`)
- `racehash::String` - VG startlist hash filter (default: "" for all riders)
- `history_years::Int` - how many years of race history to use (default: 5)
- `odds_url::String` - Betfair odds URL (default: "" for no odds)
- `n_sims::Int` - Monte Carlo simulations (default: 10000)
- `excluded_riders::Vector{String}` - rider names to exclude

## Returns
A tuple `(predicted, chosenteam)` where `predicted` is a DataFrame of all riders
with expected VG points, and `chosenteam` is the optimal 6-rider team.
"""
function solve_oneday(
    config::RaceConfig;
    racehash::String = "",
    history_years::Int = 5,
    odds_url::String = "",
    n_sims::Int = 10000,
    excluded_riders::Vector{String} = String[],
    cache_config::CacheConfig = config.cache,
    force_refresh::Bool = false,
)
    data = _prepare_rider_data(
        config,
        racehash,
        excluded_riders,
        history_years,
        odds_url,
        config.team_size,
        cache_config,
        force_refresh;
        pcs_check_col = :oneday,
    )
    if data === nothing
        return DataFrame(), DataFrame()
    end
    riderdf, race_history_df, odds_df = data.riderdf, data.race_history_df, data.odds_df

    # --- 5-7. Predict expected VG points ---
    scoring = get_scoring(config.category > 0 ? config.category : 2)  # default Cat 2 if unknown

    @info "Predicting expected VG points (Cat $(config.category), $n_sims sims)..."
    predicted = predict_expected_points(
        riderdf,
        scoring;
        race_history_df = race_history_df,
        odds_df = odds_df,
        n_sims = n_sims,
    )

    # --- 8. Optimise team selection ---
    @info "Optimising team selection..."

    # The cost column may be :cost or :vgcost depending on processing
    cost_col =
        :vgcost in propertynames(predicted) ? :vgcost :
        :cost in propertynames(predicted) ? :cost : nothing
    if cost_col === nothing
        error("No cost column found in rider data")
    end

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
4. Optionally fetch betting odds
5. Estimate strength via class-aware Bayesian updating
6. Monte Carlo simulate overall finishing positions
7. Compute expected VG points via stage race scoring table
8. Optimise team selection with rider classification constraints

## Arguments
- `config::RaceConfig` - race configuration (from `setup_race`)
- `racehash::String` - VG startlist hash filter (default: "" for all riders)
- `history_years::Int` - how many years of race history to use (default: 3)
- `odds_url::String` - betting odds URL (default: "" for no odds)
- `n_sims::Int` - Monte Carlo simulations (default: 10000)
- `excluded_riders::Vector{String}` - rider names to exclude

## Returns
A tuple `(predicted, chosenteam)` where `predicted` is a DataFrame of all riders
with expected VG points, and `chosenteam` is the optimal 9-rider team.
"""
function solve_stage(
    config::RaceConfig;
    racehash::String = "",
    history_years::Int = 3,
    odds_url::String = "",
    n_sims::Int = 10000,
    excluded_riders::Vector{String} = String[],
    cache_config::CacheConfig = config.cache,
    force_refresh::Bool = false,
)
    data = _prepare_rider_data(
        config,
        racehash,
        excluded_riders,
        history_years,
        odds_url,
        config.team_size,
        cache_config,
        force_refresh;
        pcs_check_col = :gc,
    )
    if data === nothing
        return DataFrame(), DataFrame()
    end
    riderdf, race_history_df, odds_df = data.riderdf, data.race_history_df, data.odds_df

    # --- 5-7. Predict expected VG points (stage race mode) ---
    scoring = get_scoring(:stage)

    @info "Predicting expected VG points (stage race, $n_sims sims)..."
    predicted = predict_expected_points(
        riderdf,
        scoring;
        race_history_df = race_history_df,
        odds_df = odds_df,
        n_sims = n_sims,
        race_type = :stage,
    )

    # --- 8. Optimise team selection with class constraints ---
    @info "Optimising team selection (9 riders, class constraints)..."

    cost_col =
        :vgcost in propertynames(predicted) ? :vgcost :
        :cost in propertynames(predicted) ? :cost : nothing
    if cost_col === nothing
        error("No cost column found in rider data")
    end

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


"""
## `solve_stage_legacy`

Legacy solver using weighted average of VG season points and PCS specialty scores.
Kept for backwards compatibility. Prefer `solve_oneday` or `solve_stage` for new work.

## Arguments
- `riderurl::String` - the URL of the rider data on Velogames
- `racetype::Symbol` - the type of race (:oneday, :stage, :gc, :tt, :sprint, :climber). Default is :oneday
- `racehash::String` - if race is one-day, what is the startlist hash? Default is `""`
- `formweight::Number` - the weight to apply to the form score. Default is `0.5`

## Returns
A DataFrame with columns: rider, team, vgcost, vgpoints, classraw
"""
function solve_stage_legacy(
    riderurl::String,
    racetype::Symbol = :oneday,
    racehash::String = "",
    formweight::Number = 0.5;
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    # Input validation
    valid_racetypes = [:oneday, :stage, :gc, :tt, :sprint, :climber]
    if !(racetype in valid_racetypes)
        @warn "Invalid racetype: $racetype. Using :oneday instead."
        racetype = :oneday
    end

    if !(0 <= formweight <= 1)
        throw(ArgumentError("formweight must be between 0 and 1, got $formweight"))
    end

    # Get VG rider data
    riderdf =
        getvgriders(riderurl; cache_config = cache_config, force_refresh = force_refresh)

    # Filter to riders where startlist == racehash (if specified)
    if isempty(racehash)
        startlist = riderdf
        @info "No racehash specified, using all $(nrow(startlist)) riders"
    else
        startlist = filter(row -> row.startlist == racehash, riderdf)
        if nrow(startlist) == 0
            @warn "No riders found for racehash: $racehash"
            return DataFrame(
                rider = String[],
                team = String[],
                vgcost = Int[],
                vgpoints = Float64[],
                classraw = String[],
            )
        end
        @info "Found $(nrow(startlist)) riders for racehash: $racehash"
    end

    # Get PCS rider points
    if nrow(startlist) > 0
        @info "Fetching PCS data for $(nrow(startlist)) riders..."
        rider_names = String.(startlist.rider)
        pcsriderpts = getpcsriderpts_batch(
            rider_names;
            cache_config = cache_config,
            force_refresh = force_refresh,
        )

        if racetype == :stage
            vg_class_to_pcs_col = Dict(
                "All Rounder" => "gc",
                "Climber" => "climber",
                "Sprinter" => "sprint",
                "Unclassed" => "oneday",
            )
            add_pcs_speciality_points!(startlist, pcsriderpts, vg_class_to_pcs_col)
            startlist[!, :pcsptsevent] = coalesce.(startlist.pcs_points, 0.0)
        else # Default to old oneday logic
            racetype_col = racetype in names(pcsriderpts) ? racetype : :oneday
            if racetype_col in names(pcsriderpts)
                startlist = leftjoin(
                    startlist,
                    pcsriderpts[:, ["riderkey", string(racetype_col)]],
                    on = :riderkey,
                )
                startlist[!, :pcsptsevent] = coalesce.(startlist[!, racetype_col], 0.0)
            else
                startlist[!, :pcsptsevent] = zeros(Float64, nrow(startlist))
            end
        end
    else
        startlist[!, :pcsptsevent] = Float64[]
    end

    # Calculate the score for each rider
    startlist[!, :calcscore] =
        formweight * startlist.points + (1 - formweight) * startlist.pcsptsevent

    # Rename cost column for consistency
    rename!(startlist, :cost => :vgcost)

    # Build the model with proper parameters
    if racetype == :stage
        @info "Building stage race optimisation model..."
        results = build_model_stage(startlist, 9, :calcscore, :vgcost; totalcost = 100)
    else
        @info "Building one-day race optimisation model..."
        results = build_model_oneday(startlist, 6, :calcscore, :vgcost; totalcost = 100)
    end

    # Handle optimisation results
    if results === nothing
        @warn "Optimisation failed - no feasible solution found"
        return DataFrame(
            rider = String[],
            team = String[],
            vgcost = Int[],
            vgpoints = Float64[],
            classraw = String[],
        )
    end

    # Extract chosen riders
    chosen_vec = [results[r] for r in startlist.riderkey]
    startlist[!, :chosen] = chosen_vec .> 0.5
    chosenteam = filter(:chosen => ==(true), startlist)

    if nrow(chosenteam) == 0
        @warn "No riders selected by optimisation"
        return DataFrame(
            rider = String[],
            team = String[],
            vgcost = Int[],
            vgpoints = Float64[],
            classraw = String[],
        )
    end

    @info "Selected $(nrow(chosenteam)) riders with total cost: $(sum(chosenteam.vgcost))"

    # Return the selected team
    return select(chosenteam, :rider, :team, :vgcost, :points => :vgpoints, :classraw)
end
