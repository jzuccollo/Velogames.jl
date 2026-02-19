"""
## `solverace_sixes`

Construct an optimal team for a Superclassico Sixes one-day race using Monte Carlo
simulation of expected Velogames points.

This is the recommended solver for one-day classics. It replaces the simple
weighted-average approach with a proper expected VG points model that accounts
for finish position scoring, teammate assists, and breakaway points.

## Pipeline:
1. Fetch VG rider data (costs, season points, teams)
2. Fetch PCS specialty ratings for each rider
3. Fetch PCS race-specific history (past editions)
4. Optionally fetch betting odds
5. Estimate rider strength via Bayesian updating
6. Monte Carlo simulate finishing positions
7. Compute expected VG points per rider
8. Optimize team selection to maximize expected VG points

## Arguments
- `config::RaceConfig` - race configuration (from `setup_race`)
- `racehash::String` - VG startlist hash filter (default: "" for all riders)
- `history_years::Int` - how many years of race history to use (default: 5)
- `odds_url::String` - Betfair odds URL (default: "" for no odds)
- `n_sims::Int` - Monte Carlo simulations (default: 10000)
- `excluded_riders::Vector{String}` - rider names to exclude

## Returns
A DataFrame with the selected team and prediction details including
expected VG points, strength estimates, and component breakdowns.
"""
function solverace_sixes(config::RaceConfig;
    racehash::String="",
    history_years::Int=5,
    odds_url::String="",
    n_sims::Int=10000,
    excluded_riders::Vector{String}=String[],
    cache_config::CacheConfig=DEFAULT_CACHE,
    force_refresh::Bool=false)

    # --- 1. Fetch VG rider data ---
    @info "Fetching VG rider data from $(config.current_url)..."
    riderdf = getvgriders(config.current_url; cache_config=cache_config, force_refresh=force_refresh)

    # Filter by startlist hash if provided
    if !isempty(racehash)
        riderdf = filter(row -> hasproperty(row, :startlist) ? row.startlist == racehash : true, riderdf)
        @info "Filtered to $(nrow(riderdf)) riders for startlist: $racehash"
    end

    # Exclude riders
    if !isempty(excluded_riders)
        before = nrow(riderdf)
        riderdf = filter(row -> !(row.rider in excluded_riders), riderdf)
        @info "Excluded $(before - nrow(riderdf)) riders"
    end

    if nrow(riderdf) < 6
        @warn "Not enough riders ($(nrow(riderdf))) for team selection"
        return DataFrame()
    end

    # --- 2. Fetch PCS specialty ratings ---
    @info "Fetching PCS specialty ratings for $(nrow(riderdf)) riders..."
    rider_names = String.(riderdf.rider)
    pcsriderpts = getpcsriderpts_batch(rider_names; cache_config=cache_config, force_refresh=force_refresh)

    # Join PCS data onto rider data
    pcs_cols = intersect(names(pcsriderpts), ["riderkey", "oneday", "gc", "tt", "sprint", "climber"])
    if !isempty(pcs_cols)
        riderdf = leftjoin(riderdf, pcsriderpts[:, pcs_cols], on=:riderkey, makeunique=true)
        # Fill missing PCS values with 0
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
        years = collect((current_year - history_years):(current_year - 1))
        @info "Fetching race history for $(config.pcs_slug): $years..."
        try
            race_history_df = getpcsracehistory(config.pcs_slug, years;
                cache_config=cache_config, force_refresh=force_refresh)
            @info "Got $(nrow(race_history_df)) historical results"
        catch e
            @warn "Failed to fetch race history: $e"
        end
    end

    # --- 4. Fetch odds (optional) ---
    odds_df = nothing
    if !isempty(odds_url)
        try
            odds_df = getodds(odds_url; cache_config=cache_config, force_refresh=force_refresh)
            @info "Got odds for $(nrow(odds_df)) riders"
        catch e
            @warn "Failed to fetch odds: $e"
        end
    end

    # --- Data quality summary ---
    n_total = nrow(riderdf)
    n_pcs_specialty = if :oneday in propertynames(riderdf)
        count(row -> !ismissing(row.oneday) && row.oneday > 0, eachrow(riderdf))
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

    @info "📊 Data quality summary" riders=n_total pcs_specialty="$n_pcs_specialty/$n_total" race_history="$n_history/$n_total" odds="$n_odds/$n_total"
    if n_pcs_specialty == 0
        @warn "No riders have PCS specialty data — strength estimates will rely on VG season points only"
    end
    if race_history_df !== nothing && n_history == 0
        @warn "No riders matched to race history — historical finishing positions won't inform predictions"
    end

    # --- 5-7. Predict expected VG points ---
    scoring = get_scoring(config.category > 0 ? config.category : 2)  # default Cat 2 if unknown

    @info "Predicting expected VG points (Cat $(config.category), $n_sims sims)..."
    predicted = predict_expected_points(riderdf, scoring;
        race_history_df=race_history_df,
        odds_df=odds_df,
        n_sims=n_sims)

    # --- 8. Optimize team selection ---
    @info "Optimizing team selection..."

    # The cost column may be :cost or :vgcost depending on processing
    cost_col = :vgcost in propertynames(predicted) ? :vgcost :
               :cost in propertynames(predicted) ? :cost : nothing
    if cost_col === nothing
        error("No cost column found in rider data")
    end

    results = buildmodeloneday(predicted, config.team_size, :expected_vg_points, cost_col;
        totalcost=100)

    if results === nothing
        @warn "Optimization failed - no feasible solution found"
        return DataFrame()
    end

    # Extract chosen riders
    chosen_vec = [results[r] for r in predicted.rider]
    predicted[!, :chosen] = chosen_vec .> 0.5
    chosenteam = filter(:chosen => ==(true), predicted)

    total_cost = sum(chosenteam[!, cost_col])
    total_evg = sum(chosenteam.expected_vg_points)
    @info "Selected $(nrow(chosenteam)) riders | Cost: $total_cost | Expected VG points: $(round(total_evg, digits=1))"

    return predicted, chosenteam
end


"""
## `solverace`

This function constructs a team for the specified race.

Inputs:

    * `riderurl::String` - the URL of the rider data on Velogames
    * `racetype::Symbol` - the type of race (:oneday, :stage, :gc, :tt, :sprint, :climber). Default is :oneday
    * `racehash::String` - if race is oneday, what is the startlist hash? Default is `""`
    * `formweight::Number` - the weight to apply to the form score. Default is `0.5`

The function returns a DataFrame with the following columns:

    * `rider` - the name of the rider
    * `team` - the team the rider rides for
    * `vgcost` - the cost in VeloGames
    * `vgpoints` - the VeloGames points
    * `classraw` - the rider class
"""
function solverace(riderurl::String, racetype::Symbol=:oneday, racehash::String="", formweight::Number=0.5;
    cache_config::CacheConfig=DEFAULT_CACHE, force_refresh::Bool=false)
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
    riderdf = getvgriders(riderurl; cache_config=cache_config, force_refresh=force_refresh)

    # Filter to riders where startlist == racehash (if specified)
    if isempty(racehash)
        startlist = riderdf
        @info "No racehash specified, using all $(nrow(startlist)) riders"
    else
        startlist = filter(row -> row.startlist == racehash, riderdf)
        if nrow(startlist) == 0
            @warn "No riders found for racehash: $racehash"
            return DataFrame(rider=String[], team=String[], vgcost=Int[], vgpoints=Float64[], classraw=String[])
        end
        @info "Found $(nrow(startlist)) riders for racehash: $racehash"
    end

    # Get PCS rider points
    if nrow(startlist) > 0
        @info "Fetching PCS data for $(nrow(startlist)) riders..."
        rider_names = String.(startlist.rider)
        pcsriderpts = getpcsriderpts_batch(rider_names; cache_config=cache_config, force_refresh=force_refresh)

        if racetype == :stage
            vg_class_to_pcs_col = Dict(
                "All Rounder" => "gc",
                "Climber" => "climber",
                "Sprinter" => "sprint",
                "Unclassed" => "oneday"
            )
            add_pcs_speciality_points!(startlist, pcsriderpts, vg_class_to_pcs_col)
            startlist[!, :pcsptsevent] = coalesce.(startlist.pcs_points, 0.0)
        else # Default to old oneday logic for now
            # Use the specialized PCS points for this rider's class, falling back to oneday
            racetype_col = racetype in names(pcsriderpts) ? racetype : :oneday
            if racetype_col in names(pcsriderpts)
                startlist = leftjoin(startlist, pcsriderpts[:, ["riderkey", string(racetype_col)]], on=:riderkey)
                startlist[!, :pcsptsevent] = coalesce.(startlist[!, racetype_col], 0.0)
            else
                startlist[!, :pcsptsevent] = zeros(Float64, nrow(startlist))
            end
        end
    else
        startlist[!, :pcsptsevent] = Float64[]
    end

    # Calculate the score for each rider
    startlist[!, :calcscore] = formweight * startlist.points + (1 - formweight) * startlist.pcsptsevent

    # Rename cost column for consistency
    rename!(startlist, :cost => :vgcost)

    # Build the model with proper parameters
    if racetype == :stage
        @info "Building stage race optimization model..."
        results = buildmodelstage(startlist, 9, :calcscore, :vgcost; totalcost=100)
    else
        @info "Building one-day race optimization model..."
        results = buildmodeloneday(startlist, 6, :calcscore, :vgcost; totalcost=100)
    end

    # Handle optimization results
    if results === nothing
        @warn "Optimization failed - no feasible solution found"
        return DataFrame(rider=String[], team=String[], vgcost=Int[], vgpoints=Float64[], classraw=String[])
    end

    # Extract chosen riders
    # JuMP returns a DenseAxisArray, convert to Vector in DataFrame order
    chosen_vec = [results[r] for r in startlist.rider]
    startlist[!, :chosen] = chosen_vec .> 0.5
    chosenteam = filter(:chosen => ==(true), startlist)

    if nrow(chosenteam) == 0
        @warn "No riders selected by optimization"
        return DataFrame(rider=String[], team=String[], vgcost=Int[], vgpoints=Float64[], classraw=String[])
    end

    @info "Selected $(nrow(chosenteam)) riders with total cost: $(sum(chosenteam.vgcost))"

    # Return the selected team
    return select(chosenteam, :rider, :team, :vgcost, :points => :vgpoints, :classraw)
end