"""
Backtesting and model calibration framework.

Evaluates prediction quality against historical race results, runs signal
ablation studies, and tunes BayesianConfig hyperparameters.

Focuses on one-day classics races. Ground truth is PCS finishing
positions (always available) supplemented by VG points when accessible.
"""

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

"""
    BacktestRace

A historical race for backtesting. Built from `CLASSICS_RACES_2026`
by `build_race_catalogue()`.
"""
struct BacktestRace
    name::String
    year::Int
    pcs_slug::String
    category::Int
    history_years::Int
    date::Union{Date,Nothing}
end

BacktestRace(name, year, pcs_slug, category) =
    BacktestRace(name, year, pcs_slug, category, 5, nothing)
BacktestRace(name, year, pcs_slug, category, history_years) =
    BacktestRace(name, year, pcs_slug, category, history_years, nothing)


"""
    BacktestResult

Per-race evaluation: predicted vs actual performance.

Rank-based metrics are always available (from PCS results). VG team metrics
are NaN when VG rider data is unavailable. Calibration diagnostics measure
whether posterior uncertainty estimates are well-calibrated.
"""
struct BacktestResult
    race::BacktestRace
    signals_used::Vector{Symbol}
    n_riders::Int
    # Rank-based metrics
    spearman_rho::Float64
    top5_overlap::Int
    top10_overlap::Int
    mean_abs_rank_error::Float64
    # VG team metrics using actual scoring tables (NaN if unavailable)
    points_captured_ratio::Float64
    predicted_team_vg_points::Float64
    optimal_team_vg_points::Float64
    # Calibration diagnostics
    calibration_z_scores::Vector{Float64}
    calibration_strengths::Vector{Float64}
    calibration_mean::Float64
    calibration_std::Float64
    coverage_1sigma::Float64
    coverage_2sigma::Float64
    # Signal contribution (mean shift per signal across matched riders)
    mean_signal_shifts::Dict{Symbol,Float64}
    # Optional rider-level detail for diagnostic deep dives
    rider_details::Union{DataFrame,Nothing}
end

# ---------------------------------------------------------------------------
# Metric helpers
# ---------------------------------------------------------------------------

"""
    spearman_correlation(x, y) -> Float64

Spearman rank correlation between two vectors. Handles ties via average ranks.
"""
function spearman_correlation(x::AbstractVector, y::AbstractVector)
    n = length(x)
    @assert n == length(y) "Vectors must have equal length"
    n < 3 && return NaN

    rx = _average_ranks(x)
    ry = _average_ranks(y)

    d = rx .- ry
    return 1.0 - 6.0 * sum(d .^ 2) / (n * (n^2 - 1))
end

"""Compute average ranks for a vector (handling ties)."""
function _average_ranks(x::AbstractVector)
    n = length(x)
    order = sortperm(x)
    ranks = Vector{Float64}(undef, n)
    i = 1
    while i <= n
        j = i
        while j < n && x[order[j+1]] == x[order[j]]
            j += 1
        end
        avg_rank = (i + j) / 2.0
        for k = i:j
            ranks[order[k]] = avg_rank
        end
        i = j + 1
    end
    return ranks
end

"""
    top_n_overlap(predicted_values, actual_values, n) -> Int

Count how many of the top-N predicted riders are also in the actual top N.
Higher predicted values and lower actual values (positions) are better.
"""
function top_n_overlap(
    predicted_values::AbstractVector,
    actual_positions::AbstractVector{<:Integer},
    n::Int,
)
    @assert length(predicted_values) == length(actual_positions)
    pred_top = Set(
        partialsortperm(predicted_values, 1:min(n, length(predicted_values)), rev = true),
    )
    actual_top = Set(partialsortperm(actual_positions, 1:min(n, length(actual_positions))))
    return length(intersect(pred_top, actual_top))
end

"""
    mean_abs_rank_error(predicted_values, actual_positions) -> Float64

Mean absolute difference between predicted rank (from strength) and actual
finishing position.
"""
function mean_abs_rank_error(
    predicted_values::AbstractVector,
    actual_positions::AbstractVector{<:Integer},
)
    pred_ranks = invperm(sortperm(predicted_values, rev = true))
    return mean(abs.(pred_ranks .- actual_positions))
end

# ---------------------------------------------------------------------------
# Race catalogue
# ---------------------------------------------------------------------------

"""
    build_race_catalogue(years::Vector{Int}) -> Vector{BacktestRace}

Build a catalogue of historical races from `CLASSICS_RACES_2026`.
Assumes the schedule is broadly stable across years; races missing from
PCS are skipped at backtest time.
"""
function build_race_catalogue(years::Vector{Int}; history_years::Int = 5)
    races = BacktestRace[]
    for year in years
        for race_info in CLASSICS_RACES_2026
            # Parse template date and substitute the backtest year
            template_date = Date(race_info.date)
            race_date = Date(year, Dates.month(template_date), Dates.day(template_date))
            push!(
                races,
                BacktestRace(
                    race_info.name,
                    year,
                    race_info.pcs_slug,
                    race_info.category,
                    history_years,
                    race_date,
                ),
            )
        end
    end
    return races
end

# ---------------------------------------------------------------------------
# Data pre-fetching
# ---------------------------------------------------------------------------

# Uses vg_classics_url() from race_helpers.jl

"""
    prefetch_race_data(race::BacktestRace; cache_config, force_refresh) -> RaceData

Fetch all data for a historical race (PCS results, VG roster, PCS specialty
scores, race history) and return a reusable `RaceData` struct. This is the
I/O-heavy step; subsequent `backtest_race` calls with this data are pure
compute.

PCS specialty scores are always fetched (signal selection happens later).
Odds and oracle are set to `nothing` (no historical data for these).
"""

function _build_pcs_slug_map(
    pcs_slug::String,
    year::Int;
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    slug_map = Dict{String,String}()
    try
        startlist_df = getpcs_race_startlist(pcs_slug, year; cache_config, force_refresh)
        if nrow(startlist_df) > 0 && :pcs_slug in propertynames(startlist_df)
            for row in eachrow(startlist_df)
                if !isempty(row.pcs_slug)
                    slug_map[row.riderkey] = row.pcs_slug
                end
            end
        end
    catch e
        @debug "Could not extract PCS slugs from startlist: $e"
    end
    return slug_map
end

function _supplement_missing_pcs!(
    archived_pcs::DataFrame,
    riderdf::DataFrame,
    slug_map::Dict{String,String};
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    specialty_cols = [
        c for
        c in [:gc, :tt, :sprint, :climber, :oneday] if c in propertynames(archived_pcs)
    ]
    isempty(specialty_cols) && return

    race_keys = Set(riderdf.riderkey)
    missing_keys = Set{String}()
    for row in eachrow(archived_pcs)
        if row.riderkey in race_keys && all(ismissing(row[c]) for c in specialty_cols)
            push!(missing_keys, row.riderkey)
        end
    end
    isempty(missing_keys) && return

    missing_names =
        String.([r.rider for r in eachrow(riderdf) if r.riderkey in missing_keys])
    isempty(missing_names) && return

    @debug "Supplementing $(length(missing_names)) riders with missing archived PCS data"
    fresh = getpcs_rider_pts_batch(missing_names; slug_map, cache_config, force_refresh)
    for frow in eachrow(fresh)
        idx = findfirst(==(frow.riderkey), archived_pcs.riderkey)
        idx === nothing && continue
        for c in propertynames(fresh)
            c in propertynames(archived_pcs) && (archived_pcs[idx, c] = frow[c])
        end
    end
end

function prefetch_race_data(
    race::BacktestRace;
    vg_racelists::Union{Dict{Int,DataFrame},Nothing} = nothing,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    # --- 1. Fetch actual PCS results (ground truth) ---
    actual_df = getpcs_race_results(
        race.pcs_slug,
        race.year;
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
    if nrow(actual_df) == 0
        error("No PCS results found for $(race.name) $(race.year)")
    end
    actual_df = filter(:position => p -> p < DNF_POSITION, actual_df)
    if nrow(actual_df) < 10
        error("Too few finishers ($(nrow(actual_df))) for $(race.name) $(race.year)")
    end

    # --- 2. Build rider DataFrame (VG roster or synthetic) ---
    riderdf = _build_rider_df(race, actual_df, cache_config, force_refresh)

    # --- 2b. Fix VG season points leakage: replace end-of-year totals
    #     with cumulative points up to the race date ---
    if race.date !== nothing && :points in propertynames(riderdf)
        current_year_racelist =
            vg_racelists !== nothing ? get(vg_racelists, race.year, nothing) : nothing
        cumulative_pts = _compute_cumulative_vg_points(
            race;
            vg_racelist = current_year_racelist,
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
        if cumulative_pts !== nothing
            for i = 1:nrow(riderdf)
                riderdf[i, :points] = get(cumulative_pts, riderdf[i, :riderkey], 0.0)
            end
            @info "Replaced VG season points with cumulative-to-date for $(race.name) $(race.year)"
        end
    end

    # --- 3. Fetch PCS specialty scores (prefer archived to avoid temporal leakage) ---
    rider_names = String.(riderdf.rider)

    # Build slug map from startlist (shared by both archive-supplement and fresh-fetch paths)
    pcs_slug_map =
        _build_pcs_slug_map(race.pcs_slug, race.year; cache_config, force_refresh)

    archived_pcs = load_race_snapshot("pcs_specialty", race.pcs_slug, race.year)
    pcspts = if archived_pcs !== nothing
        @info "Using archived PCS specialty scores for $(race.name) $(race.year)"
        # Supplement riders with all-missing specialty (archive may predate URL fixes)
        _supplement_missing_pcs!(
            archived_pcs,
            riderdf,
            pcs_slug_map;
            cache_config,
            force_refresh,
        )
        archived_pcs
    else
        @debug "No archived PCS scores for $(race.name) $(race.year) — using current PCS data"
        getpcs_rider_pts_batch(
            rider_names;
            slug_map = pcs_slug_map,
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
    end
    riderdf = join_pcs_specialty(riderdf, pcspts)

    # --- 4. Fetch PCS race history (prior years + similar + within-year) ---
    race_history_df = assemble_pcs_race_history(
        race.pcs_slug,
        race.year,
        race.history_years;
        race_date = race.date,
        cache_config = cache_config,
        force_refresh = force_refresh,
    )

    # --- 5. Try loading archived odds and oracle data ---
    odds_df = load_race_snapshot("odds", race.pcs_slug, race.year)
    if odds_df !== nothing
        @info "Loaded archived odds for $(race.name) $(race.year): $(nrow(odds_df)) riders"
    end

    oracle_df = load_race_snapshot("oracle", race.pcs_slug, race.year)
    if oracle_df !== nothing
        @info "Loaded archived oracle for $(race.name) $(race.year): $(nrow(oracle_df)) riders"
    end

    seasons_df = load_race_snapshot("pcs_seasons", race.pcs_slug, race.year)
    if seasons_df !== nothing
        @info "Loaded archived PCS seasons for $(race.name) $(race.year): $(length(unique(seasons_df.riderkey))) riders"
    else
        if !isempty(pcs_slug_map)
            try
                seasons_df = getpcs_rider_seasons_batch(
                    pcs_slug_map;
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
                if seasons_df !== nothing && nrow(seasons_df) > 0
                    save_race_snapshot(seasons_df, "pcs_seasons", race.pcs_slug, race.year)
                    @info "Archived PCS seasons for $(race.name) $(race.year): $(length(unique(seasons_df.riderkey))) riders"
                end
            catch e
                @warn "Failed to fetch PCS seasons for $(race.name) $(race.year): $e"
            end
        end
    end

    # --- 6. Fetch VG race history (prior editions + similar + within-year) ---
    vg_history_df = assemble_vg_race_history(
        race.name,
        race.pcs_slug,
        race.year,
        race.history_years;
        race_date = race.date,
        vg_racelists = vg_racelists,
        cache_config = cache_config,
        force_refresh = force_refresh,
    )

    return RaceData(;
        rider_df = riderdf,
        race_history_df = race_history_df,
        odds_df = odds_df,
        oracle_df = oracle_df,
        vg_history_df = vg_history_df,
        seasons_df = seasons_df,
        actual_df = actual_df,
    )
end

"""
    prefetch_all_races(races; cache_config, force_refresh) -> Dict{BacktestRace, RaceData}

Bulk pre-fetch data for all races. Pre-fetches VG race lists for all years
upfront to avoid redundant fetches, then passes them through to each race.
Logs progress and skips races that fail.
"""
function prefetch_all_races(
    races::Vector{BacktestRace};
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    # Pre-fetch VG race lists for all years involved
    all_years = unique(
        vcat(
            [r.year for r in races],
            vcat([collect((r.year-r.history_years):(r.year-1)) for r in races]...),
        ),
    )
    @info "Pre-fetching VG race lists for $(length(all_years)) years..."
    vg_racelists = prefetch_vg_racelists(
        all_years;
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
    @info "Got VG race lists for $(length(vg_racelists))/$(length(all_years)) years"

    data = Dict{BacktestRace,RaceData}()
    for (i, race) in enumerate(races)
        try
            data[race] = prefetch_race_data(
                race;
                vg_racelists = vg_racelists,
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            @info "Prefetch [$i/$(length(races))] $(race.name) $(race.year): $(nrow(data[race].rider_df)) riders"
        catch e
            @warn "Prefetch [$i/$(length(races))] FAILED $(race.name) $(race.year): $e"
        end
    end
    @info "Prefetched $(length(data))/$(length(races)) races"
    return data
end

# ---------------------------------------------------------------------------
# Core backtesting
# ---------------------------------------------------------------------------

"""
    backtest_race(race, data::RaceData; signals, config, n_sims) -> BacktestResult

Evaluate predictions against actual results using pre-fetched data. No I/O —
signal selection operates on copies of the pre-fetched data.
"""
function backtest_race(
    race::BacktestRace,
    data::RaceData;
    signals::Vector{Symbol} = [:pcs, :vg_season, :race_history, :vg_history],
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    n_sims::Int = 2000,
    simulation_df::Union{Int,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    risk_aversion::Float64 = 0.0,
    store_rider_details::Bool = false,
)
    actual_df = data.actual_df
    if actual_df === nothing
        error("RaceData has no actual_df (ground truth) for $(race.name) $(race.year)")
    end

    # Copy rider_df so signal selection doesn't mutate pre-fetched data
    riderdf = copy(data.rider_df)

    # Remove PCS columns if :pcs signal is disabled
    if !(:pcs in signals)
        for col in [:oneday, :gc, :tt, :sprint, :climber]
            if col in propertynames(riderdf)
                riderdf[!, col] .= 0
            end
        end
        if :has_pcs_data in propertynames(riderdf)
            riderdf[!, :has_pcs_data] .= false
        end
    end

    # Zero out VG season points if signal is disabled
    if !(:vg_season in signals)
        riderdf[!, :points] .= 0.0
    end

    # Include race history only if signal is enabled
    race_history_df = :race_history in signals ? data.race_history_df : nothing

    # VG race history
    vg_history_df = :vg_history in signals ? data.vg_history_df : nothing

    # Odds and oracle (from archived data)
    odds_df = :odds in signals ? data.odds_df : nothing
    oracle_df = :oracle in signals ? data.oracle_df : nothing

    # Cross-season PCS points (trajectory signal removed, but seasons_df
    # may still be used by estimate_strengths for PCS recency scaling)
    seasons_df = data.seasons_df

    # --- Run prediction pipeline ---
    scoring = get_scoring(race.category > 0 ? race.category : 2)
    ri = _find_race_by_slug(race.pcs_slug)
    race_distance_km = ri !== nothing ? ri.total_distance_km : 0.0
    predicted = predict_expected_points(
        riderdf,
        scoring;
        race_history_df = race_history_df,
        odds_df = odds_df,
        oracle_df = oracle_df,
        vg_history_df = vg_history_df,
        seasons_df = seasons_df,
        n_sims = n_sims,
        race_type = :oneday,
        config = config,
        race_year = race.year,
        race_date = race.date,
        simulation_df = simulation_df,
        domestique_discount = domestique_discount,
        total_distance_km = race_distance_km,
    )

    # --- Apply risk adjustment if risk_aversion > 0 ---
    if risk_aversion > 0 && :downside_semi_dev in propertynames(predicted)
        evg = predicted.expected_vg_points
        dsd = predicted.downside_semi_dev
        cv_down = [ep > 0 ? d / ep : 0.0 for (ep, d) in zip(evg, dsd)]
        predicted[!, :risk_adjusted_vg_points] =
            round.(evg ./ (1.0 .+ risk_aversion .* cv_down), digits = 1)
    end

    # --- Compute rank-based metrics ---
    metrics_df = innerjoin(
        predicted[:, [:riderkey, :strength, :expected_vg_points]],
        actual_df[:, [:riderkey, :position]],
        on = :riderkey,
    )

    if nrow(metrics_df) < 5
        error("Too few matched riders ($(nrow(metrics_df))) for $(race.name) $(race.year)")
    end

    rho = spearman_correlation(metrics_df.strength, Float64.(metrics_df.position) .* -1.0)
    overlap5 = top_n_overlap(metrics_df.expected_vg_points, metrics_df.position, 5)
    overlap10 = top_n_overlap(metrics_df.expected_vg_points, metrics_df.position, 10)
    mae = mean_abs_rank_error(metrics_df.expected_vg_points, metrics_df.position)

    # --- VG team metrics (if costs available) ---
    pcr, pred_pts, opt_pts = NaN, NaN, NaN
    prediction_col =
        risk_aversion > 0 && :risk_adjusted_vg_points in propertynames(predicted) ?
        :risk_adjusted_vg_points : :expected_vg_points
    if :cost in propertynames(predicted) && any(predicted.cost .> 0)
        try
            pcr, pred_pts, opt_pts = _compute_team_metrics(
                predicted,
                actual_df,
                scoring;
                prediction_col = prediction_col,
            )
        catch e
            @warn "Could not compute team metrics for $(race.name) $(race.year): $e"
        end
    end

    # --- Calibration z-scores ---
    cal_cols = [:riderkey, :strength, :uncertainty]
    cal_df = innerjoin(
        predicted[:, cal_cols],
        actual_df[:, [:riderkey, :position]],
        on = :riderkey,
    )
    n_finishers = nrow(actual_df)
    # Z-score actual strengths so they're on the same scale as predicted strengths
    # (which are built from z-scored PCS, VG, history signals).
    # Raw logit values have std ≈ 1.81 vs predicted std ≈ 1.0.
    all_logit = [position_to_strength(p, n_finishers) for p = 1:n_finishers]
    logit_mean = mean(all_logit)
    logit_std = std(all_logit)
    actual_strengths = if logit_std > 0
        [
            (position_to_strength(Int(p), n_finishers) - logit_mean) / logit_std for
            p in cal_df.position
        ]
    else
        zeros(nrow(cal_df))
    end
    z_scores = (actual_strengths .- cal_df.strength) ./ cal_df.uncertainty

    cal_mean = mean(z_scores)
    cal_std = length(z_scores) > 1 ? std(z_scores) : NaN
    cov_1sigma = count(z -> abs(z) <= 1.0, z_scores) / length(z_scores)
    cov_2sigma = count(z -> abs(z) <= 2.0, z_scores) / length(z_scores)

    # --- Signal shift analysis ---
    shift_cols = [
        :shift_pcs,
        :shift_vg,
        :shift_history,
        :shift_vg_history,
        :shift_oracle,
        :shift_odds,
    ]
    mean_shifts = Dict{Symbol,Float64}()
    for col in shift_cols
        if col in propertynames(predicted)
            vals = predicted[!, col]
            nonzero = filter(!=(0.0), vals)
            mean_shifts[col] = isempty(nonzero) ? 0.0 : mean(abs, nonzero)
        end
    end

    # Build rider-level detail for diagnostic deep dives
    rider_detail_df = if store_rider_details
        detail = copy(metrics_df)
        detail[!, :predicted_rank] =
            invperm(sortperm(detail.expected_vg_points, rev = true))
        detail[!, :actual_rank] = invperm(sortperm(detail.position))
        detail[!, :rank_error] = abs.(detail.predicted_rank .- detail.actual_rank)
        detail[
            :,
            [
                :riderkey,
                :strength,
                :expected_vg_points,
                :position,
                :predicted_rank,
                :actual_rank,
                :rank_error,
            ],
        ]
    else
        nothing
    end

    return BacktestResult(
        race,
        signals,
        nrow(metrics_df),
        rho,
        overlap5,
        overlap10,
        mae,
        pcr,
        pred_pts,
        opt_pts,
        z_scores,
        Float64.(cal_df.strength),
        cal_mean,
        cal_std,
        cov_1sigma,
        cov_2sigma,
        mean_shifts,
        rider_detail_df,
    )
end

"""
    backtest_race(race::BacktestRace; kwargs...) -> BacktestResult

Convenience method: fetches data then evaluates. Use the `RaceData` method
for repeated evaluations of the same race.
"""
function backtest_race(
    race::BacktestRace;
    signals::Vector{Symbol} = [:pcs, :vg_season, :race_history],
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    n_sims::Int = 2000,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
    simulation_df::Union{Int,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    risk_aversion::Float64 = 0.0,
    store_rider_details::Bool = false,
)
    data =
        prefetch_race_data(race; cache_config = cache_config, force_refresh = force_refresh)
    return backtest_race(
        race,
        data;
        signals = signals,
        config = config,
        n_sims = n_sims,
        simulation_df = simulation_df,
        domestique_discount = domestique_discount,
        risk_aversion = risk_aversion,
        store_rider_details = store_rider_details,
    )
end

"""Build a rider DataFrame for backtesting, preferring VG data when available."""
function _build_rider_df(
    race::BacktestRace,
    actual_df::DataFrame,
    cache_config::CacheConfig,
    force_refresh::Bool,
)
    vg_url = vg_classics_url(race.year)
    try
        vg_df = getvg_riders(
            vg_url;
            cache_config = cache_config,
            force_refresh = force_refresh,
            verbose = false,
        )
        # Inner join with actual results to get only participating riders
        rider_keys = actual_df[:, [:riderkey]]
        riderdf = semijoin(vg_df, rider_keys, on = :riderkey)
        if nrow(riderdf) >= 10
            @debug "Using VG data: $(nrow(riderdf)) riders matched"
            return riderdf
        end
    catch e
        @debug "VG data unavailable for $(race.year): $e"
    end

    # Fallback: synthetic riders from PCS results
    @debug "Building synthetic rider DataFrame from PCS results"
    return DataFrame(
        rider = actual_df.rider,
        team = hasproperty(actual_df, :team) ? actual_df.team :
               fill("Unknown", nrow(actual_df)),
        riderkey = actual_df.riderkey,
        cost = fill(10, nrow(actual_df)),
        points = fill(0.0, nrow(actual_df)),
    )
end

"""
    _compute_cumulative_vg_points(race; vg_racelist, cache_config, force_refresh) -> Union{Dict{String,Float64}, Nothing}

Compute cumulative VG points for each rider from all races in the same year
that occurred before the target race date. Returns a Dict mapping riderkey
to cumulative score, or `nothing` if the race list cannot be fetched.

Accepts an optional pre-fetched `vg_racelist` DataFrame to avoid redundant fetches.
"""
function _compute_cumulative_vg_points(
    race::BacktestRace;
    vg_racelist::Union{DataFrame,Nothing} = nothing,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    race.date === nothing && return nothing

    if vg_racelist === nothing
        vg_racelist = try
            getvg_race_list(
                race.year;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
        catch e
            @debug "Cannot fetch VG race list for $(race.year): $e"
            return nothing
        end
    end

    # Parse deadlines to dates and filter races before the target
    cumulative = Dict{String,Float64}()
    for row in eachrow(vg_racelist)
        # Parse deadline string to extract the date portion
        race_date = try
            Date(first(split(string(row.deadline), " ")))
        catch _e
            continue
        end
        race_date >= race.date && continue

        # Fetch results for this earlier race
        try
            vg_df = getvg_race_results(
                race.year,
                row.race_number;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            for r in eachrow(vg_df)
                cumulative[r.riderkey] = get(cumulative, r.riderkey, 0.0) + Float64(r.score)
            end
        catch e
            @debug "Failed to fetch VG results for race $(row.race_number) in $(race.year): $e"
        end
    end

    return isempty(cumulative) ? nothing : cumulative
end

"""Compute VG team selection metrics: predicted vs hindsight-optimal team."""
function _compute_team_metrics(
    predicted::DataFrame,
    actual_df::DataFrame,
    scoring::ScoringTable;
    prediction_col::Symbol = :expected_vg_points,
)
    joined = innerjoin(
        predicted,
        actual_df[:, [:riderkey, :position]],
        on = :riderkey,
        makeunique = true,
    )

    # Use actual VG scoring tables instead of a linear proxy
    joined[!, :actual_vg_points] =
        [Float64(finish_points_for_position(Int(p), scoring)) for p in joined.position]

    pred_sol = build_model_oneday(joined, 6, prediction_col, :cost; totalcost = 100)
    if pred_sol === nothing
        return NaN, NaN, NaN
    end

    opt_sol = build_model_oneday(joined, 6, :actual_vg_points, :cost; totalcost = 100)
    if opt_sol === nothing
        return NaN, NaN, NaN
    end

    pred_team_pts = sum(
        joined.actual_vg_points[i] for
        i = 1:nrow(joined) if JuMP.value(pred_sol[joined.riderkey[i]]) > 0.5
    )
    opt_team_pts = sum(
        joined.actual_vg_points[i] for
        i = 1:nrow(joined) if JuMP.value(opt_sol[joined.riderkey[i]]) > 0.5
    )

    pcr = opt_team_pts > 0 ? pred_team_pts / opt_team_pts : NaN
    return pcr, pred_team_pts, opt_team_pts
end

# ---------------------------------------------------------------------------
# Season-level backtesting
# ---------------------------------------------------------------------------

"""
    backtest_season(races; race_data=nothing, kwargs...) -> Vector{BacktestResult}

Run `backtest_race()` for each race, catching and logging per-race errors.

When `race_data` is provided, uses pre-fetched data (no I/O per race).
Otherwise falls back to fetching data for each race individually.
"""
function backtest_season(
    races::Vector{BacktestRace};
    race_data::Union{Dict{BacktestRace,RaceData},Nothing} = nothing,
    signals::Vector{Symbol} = [:pcs, :vg_season, :race_history, :vg_history],
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    n_sims::Int = 2000,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
    simulation_df::Union{Int,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    risk_aversion::Float64 = 0.0,
    store_rider_details::Bool = false,
)
    results = BacktestResult[]
    for (i, race) in enumerate(races)
        try
            result = if race_data !== nothing && haskey(race_data, race)
                backtest_race(
                    race,
                    race_data[race];
                    signals = signals,
                    config = config,
                    n_sims = n_sims,
                    simulation_df = simulation_df,
                    domestique_discount = domestique_discount,
                    risk_aversion = risk_aversion,
                    store_rider_details = store_rider_details,
                )
            else
                backtest_race(
                    race;
                    signals = signals,
                    config = config,
                    n_sims = n_sims,
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                    simulation_df = simulation_df,
                    domestique_discount = domestique_discount,
                    risk_aversion = risk_aversion,
                    store_rider_details = store_rider_details,
                )
            end
            push!(results, result)
            @info "[$i/$(length(races))] $(race.name) $(race.year): ρ=$(round(result.spearman_rho, digits=3)), top10=$(result.top10_overlap)"
        catch e
            @warn "[$i/$(length(races))] FAILED $(race.name) $(race.year): $e"
        end
    end
    @info "Completed $(length(results))/$(length(races)) races"
    return results
end

"""
    summarise_backtest(results::Vector{BacktestResult}) -> DataFrame

Convert results to a summary DataFrame with aggregate statistics.
"""
function summarise_backtest(results::Vector{BacktestResult})
    rows = map(results) do r
        (
            race = r.race.name,
            year = r.race.year,
            category = r.race.category,
            signals = join(string.(r.signals_used), "+"),
            n_riders = r.n_riders,
            spearman_rho = round(r.spearman_rho, digits = 3),
            top5_overlap = r.top5_overlap,
            top10_overlap = r.top10_overlap,
            mean_abs_rank_error = round(r.mean_abs_rank_error, digits = 1),
            points_captured_ratio = round(r.points_captured_ratio, digits = 3),
            calibration_mean = round(r.calibration_mean, digits = 3),
            calibration_std = round(r.calibration_std, digits = 3),
            coverage_1sigma = round(r.coverage_1sigma, digits = 3),
            coverage_2sigma = round(r.coverage_2sigma, digits = 3),
        )
    end
    df = DataFrame(rows)

    # Aggregate statistics
    valid_rho = filter(!isnan, df.spearman_rho)
    valid_pcr = filter(!isnan, df.points_captured_ratio)
    valid_cal_mean = filter(!isnan, df.calibration_mean)
    valid_cal_std = filter(!isnan, df.calibration_std)
    valid_cov1 = filter(!isnan, df.coverage_1sigma)
    valid_cov2 = filter(!isnan, df.coverage_2sigma)
    if !isempty(valid_rho)
        agg = DataFrame(
            race = ["— MEAN —", "— MEDIAN —"],
            year = [0, 0],
            category = [0, 0],
            signals = [first(df.signals), first(df.signals)],
            n_riders = [round(Int, mean(df.n_riders)), round(Int, median(df.n_riders))],
            spearman_rho = [
                round(mean(valid_rho), digits = 3),
                round(median(valid_rho), digits = 3),
            ],
            top5_overlap = [
                round(Int, mean(df.top5_overlap)),
                round(Int, median(df.top5_overlap)),
            ],
            top10_overlap = [
                round(Int, mean(df.top10_overlap)),
                round(Int, median(df.top10_overlap)),
            ],
            mean_abs_rank_error = [
                round(mean(df.mean_abs_rank_error), digits = 1),
                round(median(df.mean_abs_rank_error), digits = 1),
            ],
            points_captured_ratio = [
                isempty(valid_pcr) ? NaN : round(mean(valid_pcr), digits = 3),
                isempty(valid_pcr) ? NaN : round(median(valid_pcr), digits = 3),
            ],
            calibration_mean = [
                isempty(valid_cal_mean) ? NaN : round(mean(valid_cal_mean), digits = 3),
                isempty(valid_cal_mean) ? NaN : round(median(valid_cal_mean), digits = 3),
            ],
            calibration_std = [
                isempty(valid_cal_std) ? NaN : round(mean(valid_cal_std), digits = 3),
                isempty(valid_cal_std) ? NaN : round(median(valid_cal_std), digits = 3),
            ],
            coverage_1sigma = [
                isempty(valid_cov1) ? NaN : round(mean(valid_cov1), digits = 3),
                isempty(valid_cov1) ? NaN : round(median(valid_cov1), digits = 3),
            ],
            coverage_2sigma = [
                isempty(valid_cov2) ? NaN : round(mean(valid_cov2), digits = 3),
                isempty(valid_cov2) ? NaN : round(median(valid_cov2), digits = 3),
            ],
        )
        df = vcat(df, agg)
    end
    return df
end

# ---------------------------------------------------------------------------
# Stage-race backtest harness (WP2.1) — data-reconstruction layer
# ---------------------------------------------------------------------------

"""
    StageRaceBacktestData

Everything needed to (a) reconstruct an as-of-race-day grand-tour prediction
and (b) score it against archived actuals. Built by `prefetch_stage_race_data`.
Any predictor with signature
`predictor(data::StageRaceBacktestData) -> DataFrame(riderkey, expected_vg_points)`
plugs into the harness; `champion_evg` (the full production simulator stack)
is one such predictor.

Fields:
- `pcs_slug`, `year`, `race_date`
- `riders` — one row per starter: `riderkey`, `rider`, `team`, `cost`,
  `classraw`/`class` (from the `vg_stage_riders` archive), reconstructed
  signal columns (`points` zeroed, `<spec>_r` recency specialty, career
  specialty where a race-day snapshot is archived, `has_pcs_data`), and
  `actual_total` — the rider's final VG total from `vg_stage_totals`.
  Riders absent from the totals score 0; DNF/DNS riders keep whatever they
  banked, which the totals already reflect. `NaN` throughout when the edition
  has no archived totals yet (an in-progress race: reconstruction-only, e.g.
  the `crosscheck_option_ab` re-prediction of an unfinished Tour).
- `race_data` — a `RaceData` wrapping `riders` plus the as-of signal frames
  (PCS race history incl. GT cross-history, points/KOM classification
  history, archived odds/oracle where they exist, and the SAME-GT subset of
  prior-edition VG totals as `gt_vg_history_df` for Options A/B, matching
  production). `race_data.rider_df === riders`.
- `stages` — archived PCS stage profiles (`pcs_stage_profiles`)
- `scoring` — archived VG scoring table (`vg_scoring`), else `SCORING_GRAND_TOUR`
- `gt_vg_history` — prior-edition GT VG totals INCLUDING other grand tours
  run strictly before the target (same-year Giro before a Tour, etc.), long
  format `riderkey, score, year, gt_slug`. The same-GT subset feeds the
  production Options A/B; the cross-GT rows are for challenger predictors.
- `gc_results`, `points_results`, `kom_results` — actual classification
  standings for the secondary targets. Outcomes only — never fed to predictors.

Temporal-integrity notes (documented approximations, in the spirit of
`gt_propensity_factors`' current-p shortcut):
1. `points` (VG season points) is zeroed. A GT game's riders page shows
   in-game points — 0 pre-race — and the archived post-race column equals
   the final totals (correlation 1.0), so using it would leak the target.
   Zeroing reproduces the pre-race state: the VG signal is inert, exactly as
   in a production GT run.
2. Per-season PCS specialty uses seasons STRICTLY BEFORE the race year.
   The race-year season-to-date is not archived for past years, and the full
   race-year season would leak post-race results. Production includes the
   race-year to date, so reconstructed specialty is slightly staler.
3. Career-specialty totals join only where a race-day snapshot is archived
   (`pcs_specialty`, 2026 editions). For earlier editions the career fallback
   is absent — a current-day career page would leak — so riders without
   per-season data simply carry no PCS signal.
4. `seasons_df` (PCS season totals → currency factors) is omitted: it only
   scales the career fallback, which is race-day-archived where present.
5. Odds/oracle snapshots exist only for 2026 editions; earlier editions run
   marketless. A reconstruction gap (the market existed on the day), not a leak.
"""
struct StageRaceBacktestData
    pcs_slug::String
    year::Int
    race_date::Union{Date,Nothing}
    riders::DataFrame
    race_data::RaceData
    stages::Vector{StageProfile}
    scoring::StageRaceScoringTable
    gt_vg_history::Union{DataFrame,Nothing}
    gc_results::Union{DataFrame,Nothing}
    points_results::Union{DataFrame,Nothing}
    kom_results::Union{DataFrame,Nothing}
end

"""Per-season specialty points for every rider in `riders`, long format
(`riderkey, specialty, year, points`) — the live-fetch fallback for editions
without an archived `pcs_specialty_seasons` frame. Long-TTL cached, so the
harness is offline after the first run."""
function _fetch_specialty_seasons(
    riders::DataFrame,
    slug_map::Dict{String,String};
    specialties = (:climber, :gc, :tt, :sprint, :oneday),
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    out = DataFrame(
        riderkey = String[],
        specialty = String[],
        year = Int[],
        points = Float64[],
    )
    for row in eachrow(riders)
        slug = get(slug_map, row.riderkey, "")
        if isempty(slug)
            slug =
                get(PCS_SLUG_OVERRIDES, normalisename(row.rider), normalisename(row.rider))
        end
        for spec in specialties
            df = try
                getpcs_specialty_by_season(slug, spec; cache_config = cache_config)
            catch
                continue
            end
            hasproperty(df, :year) || continue
            for r in eachrow(df)
                push!(out, (row.riderkey, String(spec), Int(r.year), Float64(r.points)))
            end
        end
    end
    return out
end

"""Add `<spec>_r` recency-specialty columns to `riders` from a long-format
per-season frame, mirroring `_apply_pcs_recency!` (decay-weighted sum,
`missing` where a rider has no data) but restricted to seasons strictly
before `race_year` — see `StageRaceBacktestData` note 2."""
function _add_specialty_recency!(
    riders::DataFrame,
    seasons_long::DataFrame,
    race_year::Int;
    decay::Float64 = DEFAULT_BAYESIAN_CONFIG.pcs_season_decay,
)
    pre = filter([:year] => (y -> y < race_year), seasons_long)
    for spec in (:climber, :gc, :tt, :sprint, :oneday)
        scores = Vector{Union{Missing,Float64}}(missing, nrow(riders))
        sub = filter(:specialty => ==(String(spec)), pre)
        by_key = Dict{String,Float64}()
        for g in groupby(sub, :riderkey)
            w = exp.(-decay .* (race_year .- Int.(g.year)))
            by_key[first(g.riderkey)] = sum(w .* Float64.(g.points))
        end
        for i = 1:nrow(riders)
            v = get(by_key, riders.riderkey[i], nothing)
            v === nothing || (scores[i] = v)
        end
        riders[!, Symbol(spec, "_r")] = scores
    end
    return riders
end

"""Full-field VG totals for one grand-tour edition: archived `vg_stage_totals`
first, live `getvg_stage_race_totals` (long-TTL cached) as fallback.
Returns `nothing` when neither yields rows."""
function _gt_vg_totals_asof(
    gt_pcs_slug::String,
    gt_vg_slug::String,
    edition_year::Int;
    cache_config::CacheConfig = DEFAULT_CACHE,
    archive_dir::String = archive_dir(),
)
    archived = load_race_snapshot("vg_stage_totals", gt_pcs_slug, edition_year; archive_dir)
    archived !== nothing && nrow(archived) > 0 && return archived
    # Live-fetch only COMPLETED editions: an in-progress GT (e.g. the Tour
    # while prefetching the same year's Vuelta) would freeze partial mid-race
    # totals into the long-TTL cache and into gt_vg_history as if final.
    rd = resolve_race_date(gt_pcs_slug, edition_year)
    rd !== nothing && today() < rd + Day(25) && return nothing
    df = try
        getvg_stage_race_totals(edition_year, gt_vg_slug; cache_config = cache_config)
    catch
        return nothing
    end
    return (df === nothing || nrow(df) == 0) ? nothing : df
end

"""
    prefetch_stage_race_data(pcs_slug, year; history_years=3,
        cache_config=CacheConfig(DEFAULT_CACHE_DIR, 9999),
        archive_dir=archive_dir()) -> StageRaceBacktestData

Reconstruct everything needed to re-predict and score an archived grand tour
as-of race day. Archived inputs (VG roster/totals/scoring, stage profiles,
odds/oracle, GC results) come from `archive_dir`; historical-fact PCS inputs
(race history, classification history and standings, per-season specialty,
startlist) are fetched through the long-TTL `cache_config` so subsequent runs
are offline. See `StageRaceBacktestData` for the temporal-integrity notes.
"""
function prefetch_stage_race_data(
    pcs_slug::String,
    year::Int;
    history_years::Int = 3,
    cache_config::CacheConfig = CacheConfig(DEFAULT_CACHE_DIR, 9999),
    archive_dir::String = archive_dir(),
)
    race_date = resolve_race_date(pcs_slug, year)

    # --- Rider universe (archived VG roster) + actual totals ---
    riders = load_race_snapshot("vg_stage_riders", pcs_slug, year; archive_dir)
    riders === nothing &&
        error("No vg_stage_riders archive for $pcs_slug $year — cannot reconstruct")
    riders = copy(riders)

    totals = load_race_snapshot("vg_stage_totals", pcs_slug, year; archive_dir)
    if totals === nothing
        @warn "No vg_stage_totals archive for $pcs_slug $year — reconstruction only; " *
              ":vg_total scoring unavailable (actual_total = NaN)"
    else
        max_total = maximum(totals.score)
        2000 <= max_total <= 6000 ||
            @warn "vg_stage_totals for $pcs_slug $year looks wrong (winner's total $max_total; expect ~2,500-4,200)"
    end

    # --- Confirmed startlist filter + PCS slug map (mirrors production) ---
    startlist_df = try
        getpcs_race_startlist(pcs_slug, year; cache_config = cache_config)
    catch e
        @warn "No PCS startlist for $pcs_slug $year: $e — keeping full VG roster"
        DataFrame()
    end
    slug_map = Dict{String,String}()
    if nrow(startlist_df) > 0 && :riderkey in propertynames(startlist_df)
        riders = semijoin(riders, startlist_df[:, [:riderkey]], on = :riderkey)
        if :pcs_slug in propertynames(startlist_df)
            for row in eachrow(startlist_df)
                isempty(row.pcs_slug) || (slug_map[row.riderkey] = row.pcs_slug)
            end
        end
    end
    150 <= nrow(riders) <= 190 ||
        @warn "$pcs_slug $year rider universe has $(nrow(riders)) riders (expect ~170-184)"

    if totals === nothing
        riders[!, :actual_total] = fill(NaN, nrow(riders))
    else
        score_of = Dict(String(r.riderkey) => Float64(r.score) for r in eachrow(totals))
        riders[!, :actual_total] = [get(score_of, String(k), 0.0) for k in riders.riderkey]
    end

    # VG season-points signal: pre-race state is 0 for a GT's own game
    # (StageRaceBacktestData note 1 — the archived column is the final totals).
    riders[!, :points] = zeros(Float64, nrow(riders))

    # --- PCS specialty: per-season recency (strictly pre-race-year seasons) ---
    seasons_long = load_race_snapshot("pcs_specialty_seasons", pcs_slug, year; archive_dir)
    if seasons_long === nothing
        @info "No pcs_specialty_seasons archive for $pcs_slug $year — fetching per-season specialty (long-TTL cache)"
        seasons_long =
            _fetch_specialty_seasons(riders, slug_map; cache_config = cache_config)
    end

    # Career specialty only where a race-day snapshot exists (note 3).
    archived_pcs = load_race_snapshot("pcs_specialty", pcs_slug, year; archive_dir)
    if archived_pcs !== nothing
        riders = join_pcs_specialty(riders, archived_pcs)
    else
        # Gate on the same pre-race-year seasons the recency columns use: a
        # debut-season rider (only seasons ≥ race year) must carry NO PCS
        # signal, not a full-precision field-average observation (note 3).
        with_seasons = Set(filter(:year => <(year), seasons_long).riderkey)
        riders[!, :has_pcs_data] = [k in with_seasons for k in riders.riderkey]
    end
    _add_specialty_recency!(riders, seasons_long, year)

    # --- PCS race + classification history (historical facts, cached) ---
    race_history_df = assemble_pcs_race_history(
        pcs_slug,
        year,
        history_years;
        race_date = race_date,
        include_gt_history = true,
        cache_config = cache_config,
    )
    points_history_df = assemble_pcs_classification_history(
        pcs_slug,
        year,
        history_years,
        :points;
        race_date = race_date,
        include_gt_history = false,
        cache_config = cache_config,
    )
    kom_history_df = assemble_pcs_classification_history(
        pcs_slug,
        year,
        history_years,
        :kom;
        race_date = race_date,
        include_gt_history = false,
        cache_config = cache_config,
    )

    # --- Prior-edition GT VG totals: same GT + other GTs strictly before ---
    gt_vg_history =
        DataFrame(riderkey = String[], score = Float64[], year = Int[], gt_slug = String[])
    for gt in vcat([pcs_slug], get(GT_SIMILAR_RACES, pcs_slug, String[]))
        gvs = _STAGE_RACE_VG_SLUGS[gt]
        yrs = collect((year-history_years):(year-1))
        if gt != pcs_slug
            od = resolve_race_date(gt, year)
            od !== nothing && race_date !== nothing && od < race_date && push!(yrs, year)
        end
        for y in yrs
            t = _gt_vg_totals_asof(gt, gvs, y; cache_config, archive_dir)
            t === nothing && continue
            for r in eachrow(t)
                push!(gt_vg_history, (String(r.riderkey), Float64(r.score), y, gt))
            end
        end
    end
    same_gt_history =
        select(filter(:gt_slug => ==(pcs_slug), gt_vg_history), :riderkey, :score, :year)
    nrow(same_gt_history) == 0 && (same_gt_history = nothing)

    # --- Archived market snapshots (2026 editions only; nothing otherwise) ---
    snap(dt) = load_race_snapshot(dt, pcs_slug, year; archive_dir)
    odds_df = snap("odds")
    oracle_df = snap("oracle")
    points_odds_df = snap("odds_points")
    kom_odds_df = snap("odds_kom")
    stagewin_odds_df = snap("odds_stagewin")
    points_oracle_df = snap("oracle_points")
    kom_oracle_df = snap("oracle_kom")

    # Surname-rematch market frames against the roster ONCE here so every
    # predictor sees identical riderkeys regardless of call order: production's
    # `_assemble_signals` rematches these frames IN PLACE at estimation time,
    # which would otherwise make a challenger's market coverage depend on
    # whether the champion ran first on the same struct.
    for mdf in (
        odds_df,
        oracle_df,
        points_odds_df,
        kom_odds_df,
        stagewin_odds_df,
        points_oracle_df,
        kom_oracle_df,
    )
        mdf !== nothing && :rider in propertynames(mdf) && rematch_riderkeys!(mdf, riders)
    end

    # --- Stage profiles + scoring table ---
    stages = load_stage_profiles(pcs_slug, year; archive_dir = archive_dir)
    isempty(stages) && error(
        "No pcs_stage_profiles archive for $pcs_slug $year — per-stage pipeline needs it",
    )
    scoring_df = snap("vg_scoring")
    scoring = scoring_df === nothing ? SCORING_GRAND_TOUR : _df_to_scoring(scoring_df)

    # --- Actual classification outcomes (scoring targets only) ---
    # Live-fetch standings only for COMPLETED races: an in-progress edition's
    # mid-race standings would be cached (9999-day TTL) as if final.
    gc_results = snap("pcs_gc_results")
    race_over = race_date !== nothing && today() >= race_date + Day(25)
    points_results =
        !race_over ? nothing :
        try
            getpcs_race_results(pcs_slug, year; classification = :points, cache_config)
        catch
            nothing
        end
    kom_results =
        !race_over ? nothing :
        try
            getpcs_race_results(pcs_slug, year; classification = :kom, cache_config)
        catch
            nothing
        end

    race_data = RaceData(;
        rider_df = riders,
        race_history_df = race_history_df,
        odds_df = odds_df,
        oracle_df = oracle_df,
        points_oracle_df = points_oracle_df,
        kom_oracle_df = kom_oracle_df,
        points_odds_df = points_odds_df,
        kom_odds_df = kom_odds_df,
        stagewin_odds_df = stagewin_odds_df,
        points_history_df = points_history_df,
        kom_history_df = kom_history_df,
        gt_vg_history_df = same_gt_history,
    )

    n_market = odds_df === nothing ? 0 : nrow(odds_df)
    @info "Prefetched $pcs_slug $year: $(nrow(riders)) riders, " *
          "$(count(>(0.0), riders.actual_total)) with VG points, " *
          "$(length(stages)) stages, market=$(n_market > 0 ? "$n_market odds" : "none"), " *
          "GT VG history $(nrow(gt_vg_history)) rows"

    return StageRaceBacktestData(
        pcs_slug,
        year,
        race_date,
        riders,
        race_data,
        stages,
        scoring,
        gt_vg_history,
        gc_results,
        points_results,
        kom_results,
    )
end

"""
    champion_evg(data::StageRaceBacktestData; n_resamples=500, seed=20260704,
        kwargs...) -> DataFrame(riderkey, expected_vg_points)

The champion predictor: the FULL production simulator stack re-run as-of race
day via `_stage_prediction_core` (multidim `estimate_strengths` →
`compute_stage_strengths` → `resample_optimise_stage!` → Option B post-hoc),
in the gate-adjudicated production configuration: Option A is active because
`prefetch_stage_race_data` always populates `race_data.gt_vg_history_df` (the
signal is data-gated, not kwarg-gated), and Option B is pinned on here
(`:posthoc`) — note `solve_stage`'s own kwarg default is OFF; production turns
it on via `race_config.toml` (`render_stagerace.jl` defaults the knob to
true). Multidim block correlation at its `BayesianConfig` default. Seeded RNG
for reproducibility. Extra `kwargs` forward to `_stage_prediction_core`.
"""
function champion_evg(
    data::StageRaceBacktestData;
    n_resamples::Int = 500,
    seed::Int = 20260704,
    kwargs...,
)
    predicted, _, _, _ = _stage_prediction_core(
        data.race_data,
        data.stages,
        data.scoring;
        race_year = data.year,
        n_resamples = n_resamples,
        use_gt_vg_propensity = true,
        gt_vg_propensity_mode = :posthoc,
        rng = Random.MersenneTwister(seed),
        kwargs...,
    )
    return select(predicted, :riderkey, :expected_vg_points, :downside_semi_dev)
end

"""
    champion_evg_risk(data; risk_aversion=0.5, kwargs...) -> DataFrame

The champion scored the way production actually races it. `champion_evg`
returns raw EVG, and the harness then builds an EVG-max team — but
`resample_optimise!` optimises `expected_vg_points / (1 + risk_aversion *
cv_down)`, and every `solve_stage` path defaults `risk_aversion` to 0.5. So
the two arms enter different teams, and until now only the EVG-max one was
ever measured. Returns the risk-adjusted values in `expected_vg_points` so
the harness's team optimisation reproduces production's choice.
"""
function champion_evg_risk(
    data::StageRaceBacktestData;
    risk_aversion::Float64 = 0.5,
    kwargs...,
)
    pred = champion_evg(data; kwargs...)
    evg = Float64.(pred.expected_vg_points)
    cv_down = [e > 0 ? d / e : 0.0 for (e, d) in zip(evg, pred.downside_semi_dev)]
    return DataFrame(
        riderkey = pred.riderkey,
        expected_vg_points = evg ./ (1.0 .+ risk_aversion .* cv_down),
    )
end

# ---------------------------------------------------------------------------
# Stage-race backtest harness (WP2.1) — predictors, scoring, cross-check
# ---------------------------------------------------------------------------

"""Naive-persistence baseline: each rider's most recent prior-edition VG total
in THIS grand tour (same-GT rows of `data.gt_vg_history`), 0 for riders
without one. For editions whose prior years pre-date the earliest archived VG
totals (2023 targets: no 2020–2022 totals exist anywhere) this is an all-zero
vector — its rank metrics come out `missing` and its "team" is an arbitrary
budget-feasible pick, so read those rows as a no-information floor."""
function persistence_evg(data::StageRaceBacktestData)
    keys_ = String.(data.riders.riderkey)
    latest = Dict{String,Tuple{Int,Float64}}()
    if data.gt_vg_history !== nothing
        for row in eachrow(data.gt_vg_history)
            (row.gt_slug == data.pcs_slug && row.year < data.year) || continue
            best = get(latest, row.riderkey, (typemin(Int), 0.0))
            Int(row.year) > best[1] &&
                (latest[String(row.riderkey)] = (Int(row.year), Float64(row.score)))
        end
    end
    return DataFrame(
        riderkey = keys_,
        expected_vg_points = [last(get(latest, k, (0, 0.0))) for k in keys_],
    )
end

"""Odds-implied baseline: implied win probability `1/odds` per priced rider,
0 for unpriced riders. Returns `nothing` when the edition has no archived odds
(pre-2026) or the market prices nobody on the startlist — either way there is no
market to rank on, and the predictor drops out of the harness output."""
function odds_evg(data::StageRaceBacktestData)
    keys_ = String.(data.riders.riderkey)
    probs = market_win_probs(data.race_data.odds_df, keys_)
    isempty(probs) && return nothing
    return DataFrame(riderkey = keys_, expected_vg_points = probs)
end

const _STAGE_PREDICTORS = Dict{Symbol,Function}(
    :simulator => champion_evg,
    :simulator_risk => champion_evg_risk,
    :persistence => persistence_evg,
    :odds => odds_evg,
)

"""Resolve one predictor spec against a format's built-in table. A `Symbol` names
a built-in; a `name => f` pair supplies a custom one."""
_resolve_predictor(p::Symbol, table::Dict{Symbol,Function}) = (String(p), table[p])
_resolve_predictor(p::Pair, ::Dict{Symbol,Function}) = (String(first(p)), last(p))

"""Spearman ρ rounded to 3 dp, `missing` when either vector is constant — a
degenerate prediction (e.g. an all-zero persistence baseline) has no defined
rank correlation; the tie-averaged formula would otherwise return exactly 0.5.
`missing` cells are excluded from any downstream aggregation."""
_safe_spearman(x, y) =
    (allequal(x) || allequal(y)) ? missing : round(spearman_correlation(x, y), digits = 3)

# ---------------------------------------------------------------------------
# Shared harness core (one-day and stage race)
# ---------------------------------------------------------------------------

"""
    GameFormat(team_size, build_model, name, predictors)

Everything the team-points-captured metric needs to know about which Velogames
game it is scoring. The two harnesses differ only in these four values, so the
scoring core below is written once against this rather than twice against the
two formats — a divergence between them would be invisible, producing plausible
numbers rather than an error.
"""
struct GameFormat
    team_size::Int
    build_model::Function
    name::String
    predictors::Dict{Symbol,Function}
end

"""Select the budget-constrained team of `fmt.team_size` riders maximising
`points_col` and return the chosen riderkeys. Stage-race class constraints apply
automatically when the frame carries VG class data (`build_model_stage`), else
cost-only — the same rule for every predictor and for the hindsight optimum, so
team-points-captured compares like with like. `max_per_team` mirrors production's
diversification cap (`[optimisation] max_per_team`, 2); it is applied to the
optimum as well as to each predictor's team, keeping the metric a measure of
prediction quality within the constraint set production actually races under."""
function _team_keys(
    df::DataFrame,
    points_col::Symbol,
    fmt::GameFormat;
    max_per_team::Integer,
)
    sol = fmt.build_model(
        df,
        fmt.team_size,
        points_col,
        :cost;
        totalcost = 100,
        max_per_team = max_per_team,
    )
    sol === nothing && error("$(fmt.name) team optimisation infeasible on $points_col")
    return [String(k) for k in df.riderkey if sol[k] > 0.5]
end

"""
    _score_team_points_captured(data, predictors, fmt; max_per_team, truth_source) -> Vector{NamedTuple}

The team-points-captured scoring loop both harnesses run: optimise a team on each
predictor's EVG, score it on the archived truth, and divide by the hindsight
optimum under the same constraints. Also returns full-field and top-20 Spearman ρ
and the top-N overlaps.

`data` needs `.riders` (with `riderkey` and `actual_total`), `.pcs_slug` and
`.year`. The top-N overlap column is named for the team size — `overlap6` on a
classic, `overlap9` on a grand tour — so the two report tables keep the headings
they have always had.
"""
function _score_team_points_captured(
    data,
    predictors,
    fmt::GameFormat;
    max_per_team::Integer,
    truth_source::AbstractString,
)
    riders = data.riders
    actual = Float64.(riders.actual_total)
    any(isnan, actual) && error(
        "No $truth_source archived for $(data.pcs_slug) $(data.year) — cannot score team-points-captured",
    )
    work = copy(riders)
    actual_of = Dict(String(k) => a for (k, a) in zip(riders.riderkey, actual))
    opt_score =
        sum(actual_of[k] for k in _team_keys(work, :actual_total, fmt; max_per_team))
    actual_rank = invperm(sortperm(actual, rev = true))
    top20 = partialsortperm(actual, 1:min(20, length(actual)), rev = true)

    rows = NamedTuple[]
    for p in predictors
        name, fn = _resolve_predictor(p, fmt.predictors)
        pred = fn(data)
        pred === nothing && continue
        evg_of =
            Dict(String(r.riderkey) => Float64(r.expected_vg_points) for r in eachrow(pred))
        evg = [get(evg_of, String(k), 0.0) for k in riders.riderkey]
        work[!, :_pred] = evg
        team_score = sum(actual_of[k] for k in _team_keys(work, :_pred, fmt; max_per_team))
        head = (
            race = data.pcs_slug,
            year = data.year,
            predictor = name,
            n = nrow(riders),
            team_points_captured = round(team_score / opt_score, digits = 3),
            team_actual = team_score,
            optimal_actual = opt_score,
            rho_full = _safe_spearman(evg, actual),
            rho_top20 = _safe_spearman(evg[top20], actual[top20]),
        )
        overlaps = NamedTuple{(Symbol("overlap$(fmt.team_size)"), :overlap20)}((
            top_n_overlap(evg, actual_rank, fmt.team_size),
            top_n_overlap(evg, actual_rank, 20),
        ))
        push!(rows, merge(head, overlaps))
    end
    return rows
end

const FORMAT_STAGE = GameFormat(9, build_model_stage, "Stage", _STAGE_PREDICTORS)

"""
    backtest_stage_race(data::StageRaceBacktestData; predictors, target=:vg_total) -> DataFrame
    backtest_stage_race(pcs_slug, year; predictors, target, kwargs...) -> DataFrame

Score predictors against one archived grand-tour edition. A predictor is a
built-in `Symbol` (`:simulator` → `champion_evg`, `:simulator_risk` →
`champion_evg_risk` (the team `solve_stage` actually enters),
`:persistence` → `persistence_evg`, `:odds` → `odds_evg`) or a `name => f` pair where
`f(data::StageRaceBacktestData) -> DataFrame(riderkey, expected_vg_points)`.
Predictors returning `nothing` (e.g. `:odds` on a marketless edition) are
skipped. Riders missing from a predictor's frame score 0.

Primary target `:vg_total` — one row per predictor:
- `team_points_captured` (PRIMARY): actual VG points of the 9-rider team
  optimised on the predictor's EVG, divided by the hindsight-optimal team's
  points on the same constraint set.
- `rho_full` — full-field Spearman ρ of EVG vs actual VG totals.
- `rho_top20` — Spearman ρ over the top 20 riders by ACTUAL total.
- `overlap9` / `overlap20` — top-N overlap between predicted and actual.

Rank-ρ cells are `missing` (not a number) when the prediction vector is
constant over the relevant subset — see `_safe_spearman` — and must be
excluded from cross-edition aggregates.

Secondary targets `:gc` / `:points` / `:kom` — Spearman ρ of the EVG ranking
against the archived classification standings (finishers only).

The string/year method prefetches via `prefetch_stage_race_data` first.
"""
function backtest_stage_race(
    data::StageRaceBacktestData;
    predictors = [:simulator, :simulator_risk, :persistence, :odds],
    target::Symbol = :vg_total,
    max_per_team::Integer = 2,
)
    if target == :vg_total
        return DataFrame(
            _score_team_points_captured(
                data,
                predictors,
                FORMAT_STAGE;
                max_per_team = max_per_team,
                truth_source = "vg_stage_totals",
            ),
        )
    end

    # Secondary targets: rank the EVG against an archived classification, which
    # has no team-selection step and so shares nothing with the scoring core.
    riders = data.riders
    standings =
        target == :gc ? data.gc_results :
        target == :points ? data.points_results :
        target == :kom ? data.kom_results : error("Unknown target $target")
    standings === nothing &&
        error("No archived $target standings for $(data.pcs_slug) $(data.year)")
    pos_of = Dict{String,Int}()
    for r in eachrow(standings)
        0 < r.position < DNF_POSITION && (pos_of[String(r.riderkey)] = Int(r.position))
    end

    rows = NamedTuple[]
    for p in predictors
        name, fn = _resolve_predictor(p, FORMAT_STAGE.predictors)
        pred = fn(data)
        pred === nothing && continue
        evg_of =
            Dict(String(r.riderkey) => Float64(r.expected_vg_points) for r in eachrow(pred))
        evg = [get(evg_of, String(k), 0.0) for k in riders.riderkey]
        idx = [i for (i, k) in enumerate(riders.riderkey) if haskey(pos_of, String(k))]
        pos = Float64[pos_of[String(riders.riderkey[i])] for i in idx]
        push!(
            rows,
            (
                race = data.pcs_slug,
                year = data.year,
                predictor = name,
                target = target,
                n = length(idx),
                rho = _safe_spearman(evg[idx], -pos),
            ),
        )
    end
    return DataFrame(rows)
end

function backtest_stage_race(
    pcs_slug::String,
    year::Int;
    predictors = [:simulator, :simulator_risk, :persistence, :odds],
    target::Symbol = :vg_total,
    history_years::Int = 3,
    max_per_team::Integer = 2,
    cache_config::CacheConfig = CacheConfig(DEFAULT_CACHE_DIR, 9999),
    archive_dir::String = archive_dir(),
)
    data =
        prefetch_stage_race_data(pcs_slug, year; history_years, cache_config, archive_dir)
    return backtest_stage_race(data; predictors, target, max_per_team)
end

"""Copy a `RaceData` with only `gt_vg_history_df` replaced (the Option A/B
signal channel the cross-check toggles). Generic over `fieldnames` so a new
`RaceData` field can never be silently reset to its default here."""
_with_gt_history(rd::RaceData, gt_df::Union{DataFrame,Nothing}) = RaceData(;
    (f => getfield(rd, f) for f in fieldnames(RaceData))...,
    gt_vg_history_df = gt_df,
)

"""
    crosscheck_option_ab(; data=nothing, n_resamples=2500, seed=20260703,
        cache_config, archive_dir) -> DataFrame

Option A/B drift alarm for the harness (WP2.1): reconstruct the 2026 Tour
as-of race day and produce EVG four ways — role-blind (A off, B off), A only,
B only, A+B — with the GT VG-history signal restricted to same-GT editions
≤ 2024, then Spearman-correlate each EVG against riders' real 2025 Tour VG
totals over the riders present in both (n = 96), overall and within top-20 /
top-40 tiers ranked by the real totals. `multidim_block_correlation` is
disabled for these runs (era-matching the original recording, pre-WP1.6).

Two reference sets are carried, with different jobs:

- `base_*` — the PINNED baseline (July 2026, post-WP2.3 code with the branch
  code-review fixes applied). `pass` = every ρ within ±0.03 of it. This is
  the operative alarm: a future change that trips it has shifted the seeded
  pipeline by more than seed noise (±0.008) and should be investigated — or
  the baseline consciously re-based if the movement is intended.
- `rec_*` — the HISTORICAL values recorded in roadmap.md (early July 2026,
  pre-Phase-1 code). Kept for the record, NOT a pass criterion. Known,
  attributed divergences from them: WP1.1 (final-KOM ranking), WP1.4 (RNG
  substream restructure), the WP2.3 layer deletions (attrition and
  GC-favourite protection were ACTIVE in the recorded run; their removal,
  and the removal of the per-sim layer-seed draws, shifts every seeded
  output), the WP2.1 reconstruction approximations, and the review-fix
  market-frame rematching. Net effect ≈ +0.05 on overall ρ, uniform across
  variants; the improved baseline also mechanically shrinks Option B's
  marginal deltas, since B corrects the residual the baseline leaves. n = 96
  and Option A's fingerprint (overall up, top-40 down) reproduce throughout.
"""
function crosscheck_option_ab(;
    data::Union{StageRaceBacktestData,Nothing} = nothing,
    n_resamples::Int = 2500,
    seed::Int = 20260703,
    cache_config::CacheConfig = CacheConfig(DEFAULT_CACHE_DIR, 9999),
    archive_dir::String = archive_dir(),
)
    data === nothing && (
        data = prefetch_stage_race_data(
            "tour-de-france",
            2026;
            cache_config = cache_config,
            archive_dir = archive_dir,
        )
    )

    same_gt = filter(:gt_slug => ==(data.pcs_slug), data.gt_vg_history)
    hist = select(filter(:year => <=(2024), same_gt), :riderkey, :score, :year)
    real_of = Dict(
        String(r.riderkey) => Float64(r.score) for
        r in eachrow(filter(:year => ==(2025), same_gt))
    )

    cfg = BayesianConfig(multidim_block_correlation = false)
    function core_evg(gt_df)
        _, _, sim, _ = _stage_prediction_core(
            _with_gt_history(data.race_data, gt_df),
            data.stages,
            data.scoring;
            race_year = data.year,
            n_resamples = n_resamples,
            config = cfg,
            rng = Random.MersenneTwister(seed),
        )
        return vec(mean(sim, dims = 2))
    end
    evg_blind = core_evg(nothing)
    evg_a = core_evg(hist)
    keys_ = String.(data.riders.riderkey)
    evg_b = evg_blind .* exp.(gt_propensity_factors(keys_, evg_blind, hist, data.year))
    evg_ab = evg_a .* exp.(gt_propensity_factors(keys_, evg_a, hist, data.year))

    common = findall(k -> haskey(real_of, k), keys_)
    real = [real_of[k] for k in keys_[common]]

    # Pinned post-WP2.3 baseline (see docstring) — the operative pass criterion.
    baseline = Dict(
        "role-blind" => (0.750, 0.433, 0.620),
        "A only" => (0.767, 0.394, 0.562),
        "B only" => (0.756, 0.446, 0.581),
        "A+B" => (0.751, 0.389, 0.511),
    )
    # Historical roadmap.md values (pre-Phase-1 code) — kept for the record.
    recorded = Dict(
        "role-blind" => (0.691, 0.469, 0.610),
        "A only" => (0.700, 0.466, 0.546),
        "B only" => (0.723, 0.477, 0.607),
    )

    rows = NamedTuple[]
    for (variant, evg) in
        [("role-blind", evg_blind), ("A only", evg_a), ("B only", evg_b), ("A+B", evg_ab)]
        v = evg[common]
        order = sortperm(real, rev = true)
        rho(idx) = round(spearman_correlation(v[idx], real[idx]), digits = 3)
        overall = rho(eachindex(v))
        t20 = rho(order[1:min(20, length(order))])
        t40 = rho(order[1:min(40, length(order))])
        base = baseline[variant]
        rec = get(recorded, variant, nothing)
        push!(
            rows,
            (
                variant = variant,
                n = length(v),
                rho_overall = overall,
                rho_top20 = t20,
                rho_top40 = t40,
                base_overall = base[1],
                base_top20 = base[2],
                base_top40 = base[3],
                rec_overall = rec === nothing ? missing : rec[1],
                rec_top20 = rec === nothing ? missing : rec[2],
                rec_top40 = rec === nothing ? missing : rec[3],
                pass = all(abs.((overall, t20, t40) .- base) .<= 0.03),
            ),
        )
    end
    return DataFrame(rows)
end


# ===========================================================================
# One-day backtest harness (pluggable champion/challenger) — the one-day twin
# of the stage-race harness above. Same predictor contract:
#   predictor(data::OneDayBacktestData) -> DataFrame(riderkey, expected_vg_points)
# Scores team-points-captured against TRUE scraped VG totals (vg_results archive,
# incl. assist + breakaway), unlike the finish-only `_compute_team_metrics` path
# used by `backtest_race`/`BacktestResult` (both retained, untouched).
# ===========================================================================

"""
    OneDayBacktestData

Everything needed to (a) reconstruct an as-of-race-day one-day prediction and
(b) score it against archived actuals. Built by `prefetch_oneday_backtest_data`.
The one-day twin of `StageRaceBacktestData`.

Any predictor with signature
`predictor(data::OneDayBacktestData) -> DataFrame(riderkey, expected_vg_points)`
plugs into the harness; `champion_oneday_evg` (the full production one-day stack)
is one such predictor.

Fields:
- `pcs_slug`, `year`, `race_date` — edition identity.
- `riders` — one row per starter: `riderkey`, `rider`, `team`, `cost`, and
  `actual_total` (the rider's true scraped VG total from the `vg_results`
  archive; riders absent from the results score 0; `NaN` throughout when no VG
  results are archived yet). `actual_total` is held ONLY here, never on
  `race_data.rider_df`, so predictors cannot read the outcome.
- `race_data` — a `RaceData` (the production one-day container) carrying the
  pre-race signal frames that predictors consume.
- `scoring` — the `ScoringTable` for the race category (Cat 1/2/3).
- `category` — VG scoring category.
"""
struct OneDayBacktestData
    pcs_slug::String
    year::Int
    race_date::Union{Date,Nothing}
    riders::DataFrame
    race_data::RaceData
    scoring::ScoringTable
    category::Int
end


"""
    _oneday_vg_totals_asof(pcs_slug, year; cache_config, archive_dir)
        -> Union{Dict{String,Float64}, Nothing}

Return a `riderkey => true VG total` map for a completed one-day race. Prefers
the `vg_results` archive; falls back to a live scrape
(`getvg_race_list` → `match_vg_race_number` → `getvg_race_results`) that
auto-archives on success (the pattern used by `prospective_eval.jl`). Returns
`nothing` when neither the archive nor the live fetch yields usable results.
"""
function _oneday_vg_totals_asof(
    pcs_slug::String,
    year::Int;
    cache_config::CacheConfig = CacheConfig(DEFAULT_CACHE_DIR, 9999),
    archive_dir::String = archive_dir(),
)
    vg = load_race_snapshot("vg_results", pcs_slug, year; archive_dir = archive_dir)
    if vg === nothing
        try
            ri = _find_race_by_slug(pcs_slug)
            ri === nothing && return nothing
            racelist = getvg_race_list(year; cache_config = cache_config)
            num = match_vg_race_number(ri.name, racelist)
            num === nothing && return nothing
            vg = getvg_race_results(year, num; cache_config = cache_config)
            (vg === nothing || nrow(vg) == 0) && return nothing
            save_race_snapshot(vg, "vg_results", pcs_slug, year; archive_dir = archive_dir)
            @info "Auto-archived VG results for $pcs_slug $year"
        catch e
            @warn "Failed to fetch VG results for $pcs_slug $year: $e"
            return nothing
        end
    end
    (nrow(vg) == 0 || !hasproperty(vg, :riderkey)) && return nothing
    return Dict(String(r.riderkey) => Float64(r.score) for r in eachrow(vg))
end


"""
    prefetch_oneday_backtest_data(race::BacktestRace; kwargs...) -> OneDayBacktestData

Reconstruct an as-of-race-day one-day edition for the harness: the production
one-day `RaceData` (via `prefetch_race_data`) plus true scraped VG totals for
scoring. `actual_total` is `NaN` throughout when no VG results can be obtained
(an in-progress race), which `backtest_oneday_race` rejects for `:vg_total`.
"""
function prefetch_oneday_backtest_data(
    race::BacktestRace;
    vg_racelists::Union{Dict{Int,DataFrame},Nothing} = nothing,
    cache_config::CacheConfig = CacheConfig(DEFAULT_CACHE_DIR, 9999),
    archive_dir::String = archive_dir(),
    force_refresh::Bool = false,
)
    rd = prefetch_race_data(
        race;
        vg_racelists = vg_racelists,
        cache_config = cache_config,
        force_refresh = force_refresh,
    )
    riders = select(rd.rider_df, :riderkey, :rider, :team, :cost)

    # Surname-rematch market frames against the roster ONCE here, exactly as
    # `prefetch_stage_race_data` does, so every predictor sees identical
    # riderkeys regardless of call order: `_assemble_signals` rematches these
    # frames IN PLACE at estimation time, which would otherwise make the `:odds`
    # baseline's market coverage depend on whether a simulator arm ran first on
    # the same struct.
    for mdf in (rd.odds_df, rd.oracle_df)
        mdf !== nothing && :rider in propertynames(mdf) && rematch_riderkeys!(mdf, riders)
    end

    totals = _oneday_vg_totals_asof(race.pcs_slug, race.year; cache_config, archive_dir)
    riders[!, :actual_total] =
        totals === nothing ? fill(NaN, nrow(riders)) :
        [get(totals, String(k), 0.0) for k in riders.riderkey]
    scoring = get_scoring(race.category > 0 ? race.category : 2)
    return OneDayBacktestData(
        race.pcs_slug,
        race.year,
        race.date,
        riders,
        rd,
        scoring,
        race.category,
    )
end


# --- Built-in one-day predictors ---------------------------------------------
# Contract: f(data::OneDayBacktestData) -> DataFrame(riderkey, expected_vg_points)

"""
    champion_oneday_evg(data; n_resamples=500, seed=..., kwargs...) -> DataFrame

The champion predictor: the FULL production one-day stack re-run as-of race day
via `_oneday_prediction_core` (`estimate_strengths` → `resample_optimise!`).
Seeded for reproducibility. Breakaway rates are unavailable in reconstruction,
so the breakaway channel is inert (a small, documented gap). The one-day twin of
`champion_evg`.
"""
function champion_oneday_evg(data::OneDayBacktestData; kwargs...)
    predicted = _oneday_champion_predicted(data; kwargs...)
    return select(predicted, :riderkey, :expected_vg_points, :downside_semi_dev)
end

"""Run the production one-day core as-of race day and return the full predicted
frame. Shared by every champion arm so the resample count and seed cannot drift
apart between them — the market blend's pre-registered trigger is a *paired*
difference against `simulator_risk`, which only means anything if both arms ran
the same simulation."""
function _oneday_champion_predicted(
    data::OneDayBacktestData;
    n_resamples::Int = 500,
    seed::Int = 20260704,
    kwargs...,
)
    predicted, _, _ = _oneday_prediction_core(
        data.race_data,
        data.scoring;
        race_year = data.year,
        n_resamples = n_resamples,
        rng = Random.MersenneTwister(seed),
        kwargs...,
    )
    return predicted
end

"""
    champion_oneday_evg_risk(data; risk_aversion=0.5, kwargs...) -> DataFrame

The one-day champion scored the way `solve_oneday` actually races it — the twin
of `champion_evg_risk`. Returns the risk-adjusted values in
`expected_vg_points` so the harness's team optimisation reproduces production's
choice.
"""
function champion_oneday_evg_risk(
    data::OneDayBacktestData;
    risk_aversion::Float64 = 0.5,
    kwargs...,
)
    pred = champion_oneday_evg(data; kwargs...)
    evg = Float64.(pred.expected_vg_points)
    cv_down = [e > 0 ? d / e : 0.0 for (e, d) in zip(evg, pred.downside_semi_dev)]
    return DataFrame(
        riderkey = pred.riderkey,
        expected_vg_points = evg ./ (1.0 .+ risk_aversion .* cv_down),
    )
end

"""Odds baseline: implied win probability `1/max(odds, 1.01)`, 0 for unpriced
riders. Returns `nothing` on a marketless edition. Mirrors `odds_evg`."""
function odds_oneday_evg(data::OneDayBacktestData)
    keys_ = String.(data.riders.riderkey)
    probs = market_win_probs(data.race_data.odds_df, keys_)
    isempty(probs) && return nothing
    return DataFrame(riderkey = keys_, expected_vg_points = probs)
end

"""
    champion_oneday_market_evg(data; market_blend_weight=0.5, kwargs...) -> DataFrame

The market-blended production arm: the same `_oneday_prediction_core` as
`champion_oneday_evg`, run with `market_blend_weight` so the blend happens at
production's real insertion point (risk-adjusted EVG mixed with implied win
probability, both unit-normalised), and returning the blended column the final
team optimisation maximises. The harness then optimises EVG-max on it, which is
exactly what production does — so this row measures the shipped construction
rule, not a reimplementation of it.

Returns `nothing` on a marketless edition. `champion_oneday_evg` remains the
UNBLENDED arm so the standing champion comparison keeps its meaning.
"""
function champion_oneday_market_evg(
    data::OneDayBacktestData;
    market_blend_weight::Float64 = DEFAULT_MARKET_BLEND_WEIGHT,
    kwargs...,
)
    # Checked up front so a marketless edition skips the resampling run entirely,
    # and via the same helper the blend itself uses — so "priced" means exactly
    # what it means in production.
    isempty(market_win_probs(data.race_data.odds_df, data.riders.riderkey)) &&
        return nothing
    predicted = _oneday_champion_predicted(
        data;
        market_blend_weight = market_blend_weight,
        kwargs...,
    )
    return DataFrame(
        riderkey = predicted.riderkey,
        expected_vg_points = predicted.market_blend_points,
    )
end

"""Max-cost ("star-buying") baseline: EVG = rider cost, so the harness optimiser
buys the most expensive team affordable under budget."""
function maxcost_oneday_evg(data::OneDayBacktestData)
    return DataFrame(
        riderkey = String.(data.riders.riderkey),
        expected_vg_points = Float64.(data.riders.cost),
    )
end

const _ONEDAY_PREDICTORS = Dict{Symbol,Function}(
    :simulator => champion_oneday_evg,
    :simulator_risk => champion_oneday_evg_risk,
    :simulator_market => champion_oneday_market_evg,
    :odds => odds_oneday_evg,
    :maxcost => maxcost_oneday_evg,
)

"""Every built-in one-day arm, in report order."""
const ONEDAY_PREDICTORS_ALL =
    [:simulator, :simulator_risk, :simulator_market, :odds, :maxcost]

const FORMAT_ONEDAY = GameFormat(6, build_model_oneday, "One-day", _ONEDAY_PREDICTORS)


"""
    backtest_oneday_race(data::OneDayBacktestData; predictors) -> DataFrame
    backtest_oneday_race(pcs_slug, year; predictors, kwargs...) -> DataFrame

Score one-day predictors against one archived classic edition. A predictor is a
built-in `Symbol` (`:simulator` → `champion_oneday_evg`, `:simulator_risk` →
`champion_oneday_evg_risk` (the team `solve_oneday` actually enters),
`:simulator_market` → `champion_oneday_market_evg` (the same, with the market
blended in at `w=0.5`), `:odds`,
`:maxcost`) or a `name => f` pair where
`f(data::OneDayBacktestData) -> DataFrame(riderkey, expected_vg_points)`.
Predictors returning `nothing` (e.g. `:odds` on a marketless edition) are
skipped. Riders missing from a predictor's frame score 0.

One row per non-skipped predictor: `race`, `year`, `predictor`, `n`,
`team_points_captured` (PRIMARY — a 6-rider budget team optimised on the
predictor's EVG, scored on TRUE scraped VG totals, divided by the hindsight
optimum), `team_actual`, `optimal_actual`, `rho_full`, `rho_top20`, `overlap6`,
`overlap20`. The one-day twin of `backtest_stage_race`.
"""
function backtest_oneday_race(
    data::OneDayBacktestData;
    predictors = ONEDAY_PREDICTORS_ALL,
    max_per_team::Integer = 2,
)
    return DataFrame(
        _score_team_points_captured(
            data,
            predictors,
            FORMAT_ONEDAY;
            max_per_team = max_per_team,
            truth_source = "vg_results",
        ),
    )
end

function backtest_oneday_race(
    pcs_slug::String,
    year::Int;
    predictors = ONEDAY_PREDICTORS_ALL,
    category::Int = 0,
    history_years::Int = 5,
    max_per_team::Integer = 2,
    cache_config::CacheConfig = CacheConfig(DEFAULT_CACHE_DIR, 9999),
    archive_dir::String = archive_dir(),
)
    ri = _find_race_by_slug(pcs_slug)
    cat = category > 0 ? category : (ri !== nothing ? ri.category : 2)
    date = if ri !== nothing
        t = Date(ri.date)
        Date(year, Dates.month(t), Dates.day(t))
    else
        nothing
    end
    race = BacktestRace(
        ri !== nothing ? ri.name : pcs_slug,
        year,
        pcs_slug,
        cat,
        history_years,
        date,
    )
    data = prefetch_oneday_backtest_data(race; cache_config, archive_dir)
    return backtest_oneday_race(data; predictors, max_per_team)
end


"""
    backtest_oneday_season(races; predictors, race_data) -> DataFrame

Run `backtest_oneday_race` for each edition, catching and skipping editions with
no archived VG truth (or any error), and `vcat` the per-predictor rows. The
one-day analogue of `backtest_season` (which returns `BacktestResult`s); this
returns the flat comparison table across editions.
"""
function backtest_oneday_season(
    races::Vector{BacktestRace};
    predictors = ONEDAY_PREDICTORS_ALL,
    max_per_team::Integer = 2,
    cache_config::CacheConfig = CacheConfig(DEFAULT_CACHE_DIR, 9999),
    archive_dir::String = archive_dir(),
)
    frames = DataFrame[]
    for race in races
        try
            data = prefetch_oneday_backtest_data(race; cache_config, archive_dir)
            push!(frames, backtest_oneday_race(data; predictors, max_per_team))
        catch e
            @warn "Skipping $(race.pcs_slug) $(race.year): $e"
        end
    end
    return isempty(frames) ? DataFrame() : reduce(vcat, frames)
end
