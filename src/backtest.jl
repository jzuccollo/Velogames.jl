"""
Backtesting and model calibration framework.

Evaluates prediction quality against historical race results, runs signal
ablation studies, and tunes BayesianConfig hyperparameters.

Focuses on one-day Superclasico races. Ground truth is PCS finishing
positions (always available) supplemented by VG points when accessible.
"""

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

"""
    BacktestRace

A historical race for backtesting. Built from `SUPERCLASICO_RACES_2025`
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
    calibration_mean::Float64
    calibration_std::Float64
    coverage_1sigma::Float64
    coverage_2sigma::Float64
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

Build a catalogue of historical races from `SUPERCLASICO_RACES_2025`.
Assumes the schedule is broadly stable across years; races missing from
PCS are skipped at backtest time.
"""
function build_race_catalogue(years::Vector{Int}; history_years::Int = 5)
    races = BacktestRace[]
    for year in years
        for race_info in SUPERCLASICO_RACES_2025
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

# Uses VG_SUPERCLASICO_URL from race_helpers.jl

"""
    prefetch_race_data(race::BacktestRace; cache_config, force_refresh) -> RaceData

Fetch all data for a historical race (PCS results, VG roster, PCS specialty
scores, race history) and return a reusable `RaceData` struct. This is the
I/O-heavy step; subsequent `backtest_race` calls with this data are pure
compute.

PCS specialty scores are always fetched (signal selection happens later).
Odds and oracle are set to `nothing` (no historical data for these).
"""
function prefetch_race_data(
    race::BacktestRace;
    vg_racelists::Union{Dict{Int,DataFrame},Nothing} = nothing,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    # --- 1. Fetch actual PCS results (ground truth) ---
    actual_df = getpcsraceresults(
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
    archived_pcs = load_race_snapshot("pcs_specialty", race.pcs_slug, race.year)
    pcspts = if archived_pcs !== nothing
        @info "Using archived PCS specialty scores for $(race.name) $(race.year)"
        archived_pcs
    else
        @debug "No archived PCS scores for $(race.name) $(race.year) — using current PCS data"
        getpcsriderpts_batch(
            rider_names;
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
    end
    riderdf = join_pcs_specialty!(riderdf, pcspts)

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

    return RaceData(riderdf, race_history_df, odds_df, oracle_df, vg_history_df, actual_df)
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
        data[race] = prefetch_race_data(
            race;
            vg_racelists = vg_racelists,
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
        @info "Prefetch [$i/$(length(races))] $(race.name) $(race.year): $(nrow(data[race].rider_df)) riders"
    end
    @info "Prefetched $(length(data))/$(length(races)) races"
    return data
end

# ---------------------------------------------------------------------------
# Core backtesting
# ---------------------------------------------------------------------------

"""
    backtest_race(race, data::RaceData; signals, bayesian_config, n_sims) -> BacktestResult

Evaluate predictions against actual results using pre-fetched data. No I/O —
signal selection operates on copies of the pre-fetched data.
"""
function backtest_race(
    race::BacktestRace,
    data::RaceData;
    signals::Vector{Symbol} = [:pcs, :vg_season, :race_history],
    bayesian_config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    n_sims::Int = 2000,
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

    # --- Run prediction pipeline ---
    scoring = get_scoring(race.category > 0 ? race.category : 2)
    predicted = predict_expected_points(
        riderdf,
        scoring;
        race_history_df = race_history_df,
        odds_df = odds_df,
        oracle_df = oracle_df,
        vg_history_df = vg_history_df,
        n_sims = n_sims,
        race_type = :oneday,
        bayesian_config = bayesian_config,
        race_year = race.year,
        race_date = race.date,
    )

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
    if :cost in propertynames(predicted) && any(predicted.cost .> 0)
        try
            pcr, pred_pts, opt_pts = _compute_team_metrics(predicted, actual_df, scoring)
        catch e
            @warn "Could not compute team metrics for $(race.name) $(race.year): $e"
        end
    end

    # --- Calibration z-scores ---
    cal_df = innerjoin(
        predicted[:, [:riderkey, :strength, :uncertainty]],
        actual_df[:, [:riderkey, :position]],
        on = :riderkey,
    )
    n_matched = nrow(cal_df)
    actual_strengths = [position_to_strength(Int(p), n_matched) for p in cal_df.position]
    z_scores = (actual_strengths .- cal_df.strength) ./ cal_df.uncertainty

    cal_mean = mean(z_scores)
    cal_std = length(z_scores) > 1 ? std(z_scores) : NaN
    cov_1sigma = count(z -> abs(z) <= 1.0, z_scores) / length(z_scores)
    cov_2sigma = count(z -> abs(z) <= 2.0, z_scores) / length(z_scores)

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
        cal_mean,
        cal_std,
        cov_1sigma,
        cov_2sigma,
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
    bayesian_config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    n_sims::Int = 2000,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    data =
        prefetch_race_data(race; cache_config = cache_config, force_refresh = force_refresh)
    return backtest_race(
        race,
        data;
        signals = signals,
        bayesian_config = bayesian_config,
        n_sims = n_sims,
    )
end

"""Build a rider DataFrame for backtesting, preferring VG data when available."""
function _build_rider_df(
    race::BacktestRace,
    actual_df::DataFrame,
    cache_config::CacheConfig,
    force_refresh::Bool,
)
    vg_url = replace(VG_SUPERCLASICO_URL, "{year}" => string(race.year))
    try
        vg_df = getvgriders(
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
            getvgracelist(race.year; cache_config = cache_config, force_refresh = force_refresh)
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
            vg_df = getvgraceresults(
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
    scoring::ScoringTable,
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

    pred_sol = build_model_oneday(joined, 6, :expected_vg_points, :cost; totalcost = 100)
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
    signals::Vector{Symbol} = [:pcs, :vg_season, :race_history],
    bayesian_config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    n_sims::Int = 2000,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    results = BacktestResult[]
    for (i, race) in enumerate(races)
        result = if race_data !== nothing && haskey(race_data, race)
            backtest_race(
                race,
                race_data[race];
                signals = signals,
                bayesian_config = bayesian_config,
                n_sims = n_sims,
            )
        else
            backtest_race(
                race;
                signals = signals,
                bayesian_config = bayesian_config,
                n_sims = n_sims,
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
        end
        push!(results, result)
        @info "[$i/$(length(races))] $(race.name) $(race.year): ρ=$(round(result.spearman_rho, digits=3)), top10=$(result.top10_overlap)"
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
# Ablation study
# ---------------------------------------------------------------------------

"""Signal subsets for ablation study."""
const ABLATION_SETS = [
    ("pcs_only", [:pcs]),
    ("pcs_vg", [:pcs, :vg_season]),
    ("pcs_history", [:pcs, :race_history]),
    ("pcs_vg_history", [:pcs, :vg_season, :race_history]),
    ("all_available", [:pcs, :vg_season, :race_history, :vg_history, :odds, :oracle]),
    ("no_pcs", [:vg_season, :race_history]),
    ("history_only", [:race_history]),
    ("with_odds", [:pcs, :vg_season, :race_history, :odds]),
    ("with_oracle", [:pcs, :vg_season, :race_history, :oracle]),
]

"""
    ablation_study(races::Vector{BacktestRace}; race_data=nothing, kwargs...) -> DataFrame

Run backtesting with each signal subset to measure marginal signal value.

When `race_data` is provided, skips the internal pre-fetch (avoiding redundant I/O).
Otherwise pre-fetches all race data once, then iterates signal subsets using
compute-only evaluation. Returns a DataFrame with a `signal_set` column.
"""
function ablation_study(
    races::Vector{BacktestRace};
    race_data::Union{Dict{BacktestRace,RaceData},Nothing} = nothing,
    bayesian_config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    n_sims::Int = 2000,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    if race_data === nothing
        @info "Ablation study: pre-fetching data for $(length(races)) races..."
        race_data = prefetch_all_races(
            races;
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
    else
        @info "Ablation study: using pre-fetched data for $(length(race_data)) races"
    end

    all_dfs = DataFrame[]
    available_races = [r for r in races if haskey(race_data, r)]

    for (label, sigs) in ABLATION_SETS
        @info "Running ablation: $label (signals: $(join(string.(sigs), ", ")))"
        results = backtest_season(
            available_races;
            race_data = race_data,
            signals = sigs,
            bayesian_config = bayesian_config,
            n_sims = n_sims,
        )
        if !isempty(results)
            summary = summarise_backtest(results)
            summary[!, :signal_set] .= label
            push!(all_dfs, summary)
        end
    end

    return isempty(all_dfs) ? DataFrame() : vcat(all_dfs...; cols = :union)
end

# ---------------------------------------------------------------------------
# Hyperparameter tuning
# ---------------------------------------------------------------------------

"""Bounded parameter ranges for hyperparameter search."""
const PARAM_BOUNDS = (
    pcs_variance = (1.0, 10.0),
    vg_variance = (1.0, 8.0),
    hist_base_variance = (0.3, 3.0),
    hist_decay_rate = (0.1, 1.5),
    vg_hist_base_variance = (0.5, 4.0),
    vg_hist_decay_rate = (0.1, 1.5),
)

"""Sample a random BayesianConfig within PARAM_BOUNDS."""
function _random_bayesian_config(rng::AbstractRNG = Random.default_rng())
    BayesianConfig(
        rand(rng) * (PARAM_BOUNDS.pcs_variance[2] - PARAM_BOUNDS.pcs_variance[1]) +
        PARAM_BOUNDS.pcs_variance[1],
        rand(rng) * (PARAM_BOUNDS.vg_variance[2] - PARAM_BOUNDS.vg_variance[1]) +
        PARAM_BOUNDS.vg_variance[1],
        rand(rng) *
        (PARAM_BOUNDS.hist_base_variance[2] - PARAM_BOUNDS.hist_base_variance[1]) +
        PARAM_BOUNDS.hist_base_variance[1],
        rand(rng) * (PARAM_BOUNDS.hist_decay_rate[2] - PARAM_BOUNDS.hist_decay_rate[1]) +
        PARAM_BOUNDS.hist_decay_rate[1],
        rand(rng) *
        (PARAM_BOUNDS.vg_hist_base_variance[2] - PARAM_BOUNDS.vg_hist_base_variance[1]) +
        PARAM_BOUNDS.vg_hist_base_variance[1],
        rand(rng) *
        (PARAM_BOUNDS.vg_hist_decay_rate[2] - PARAM_BOUNDS.vg_hist_decay_rate[1]) +
        PARAM_BOUNDS.vg_hist_decay_rate[1],
        DEFAULT_BAYESIAN_CONFIG.odds_variance,
        DEFAULT_BAYESIAN_CONFIG.oracle_variance,
        DEFAULT_BAYESIAN_CONFIG.odds_normalisation,
    )
end

"""Extract tunable parameter values from a BayesianConfig."""
function _config_to_dict(config::BayesianConfig)
    Dict(
        :pcs_variance => config.pcs_variance,
        :vg_variance => config.vg_variance,
        :hist_base_variance => config.hist_base_variance,
        :hist_decay_rate => config.hist_decay_rate,
        :vg_hist_base_variance => config.vg_hist_base_variance,
        :vg_hist_decay_rate => config.vg_hist_decay_rate,
    )
end

"""
    tune_hyperparameters(races; race_data=nothing, objective, n_iter, signals, n_sims, cache_config) -> (BayesianConfig, DataFrame)

Tune BayesianConfig via random search. Evaluates `n_iter` random configurations
(plus the default) on all races and returns the best.

When `race_data` is provided, skips the internal pre-fetch (avoiding redundant I/O).

Returns a tuple of (best BayesianConfig, evaluation log DataFrame).
"""
function tune_hyperparameters(
    races::Vector{BacktestRace};
    race_data::Union{Dict{BacktestRace,RaceData},Nothing} = nothing,
    objective::Symbol = :spearman_rho,
    n_iter::Int = 100,
    signals::Vector{Symbol} = [:pcs, :vg_season, :race_history],
    n_sims::Int = 2000,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
    rng::AbstractRNG = Random.default_rng(),
)
    if race_data === nothing
        @info "Tuning: pre-fetching data for $(length(races)) races..."
        race_data = prefetch_all_races(
            races;
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
    else
        @info "Tuning: using pre-fetched data for $(length(race_data)) races"
    end
    available_races = [r for r in races if haskey(race_data, r)]

    @info "Random search: $n_iter candidates, $(length(available_races)) races"

    # Include default config as candidate 0
    candidates = BayesianConfig[DEFAULT_BAYESIAN_CONFIG]
    for _ = 1:n_iter
        push!(candidates, _random_bayesian_config(rng))
    end

    # Evaluate each candidate (compute-only)
    log_rows = []
    best_score = -Inf
    best_config = DEFAULT_BAYESIAN_CONFIG

    for (i, config) in enumerate(candidates)
        label = i == 1 ? "default" : "random_$i"
        results = backtest_season(
            available_races;
            race_data = race_data,
            signals = signals,
            bayesian_config = config,
            n_sims = n_sims,
        )
        if isempty(results)
            continue
        end

        scores = _extract_metric(results, objective)
        valid = filter(!isnan, scores)
        score = isempty(valid) ? NaN : mean(valid)

        params = _config_to_dict(config)
        push!(
            log_rows,
            merge(
                params,
                Dict(:candidate => label, :mean_score => score, :n_races => length(valid)),
            ),
        )
        @info "  [$i/$(length(candidates))] $label: $objective = $(round(score, digits=4))"

        if !isnan(score) && score > best_score
            best_score = score
            best_config = config
        end
    end

    log_df = DataFrame(log_rows)
    sort!(log_df, :mean_score, rev = true)

    @info "Best config: $(round(best_score, digits=4)) ($objective)"
    return best_config, log_df
end


"""Extract a specific metric from BacktestResult vector."""
function _extract_metric(results::Vector{BacktestResult}, metric::Symbol)
    if metric == :spearman_rho
        return [r.spearman_rho for r in results]
    elseif metric == :top10_overlap
        return Float64[r.top10_overlap for r in results]
    elseif metric == :top5_overlap
        return Float64[r.top5_overlap for r in results]
    elseif metric == :points_captured_ratio
        return [r.points_captured_ratio for r in results]
    elseif metric == :mean_abs_rank_error
        # Lower is better, so negate for maximisation
        return [-r.mean_abs_rank_error for r in results]
    else
        error("Unknown metric: $metric")
    end
end
