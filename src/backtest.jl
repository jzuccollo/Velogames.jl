"""
Backtesting and model calibration framework.

Evaluates prediction quality against historical race results, runs signal
ablation studies, and tunes BayesianConfig hyperparameters.

Focuses on one-day Superclassico races. Ground truth is PCS finishing
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
end

BacktestRace(name, year, pcs_slug, category) = BacktestRace(name, year, pcs_slug, category, 5)

"""
    BacktestResult

Per-race evaluation: predicted vs actual performance.

Rank-based metrics are always available (from PCS results). VG team metrics
are NaN when VG rider data is unavailable.
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
    # VG team metrics (NaN if unavailable)
    points_captured_ratio::Float64
    predicted_team_points::Float64
    optimal_team_points::Float64
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
    pred_top = Set(partialsortperm(predicted_values, 1:min(n, length(predicted_values)), rev=true))
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
    pred_ranks = invperm(sortperm(predicted_values, rev=true))
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
function build_race_catalogue(years::Vector{Int}; history_years::Int=5)
    races = BacktestRace[]
    for year in years
        for race_info in SUPERCLASICO_RACES_2025
            push!(
                races,
                BacktestRace(
                    race_info.name,
                    year,
                    race_info.pcs_slug,
                    race_info.category,
                    history_years,
                ),
            )
        end
    end
    return races
end

# ---------------------------------------------------------------------------
# Core backtesting
# ---------------------------------------------------------------------------

const VG_SUPERCLASICO_URL_TEMPLATE = "https://www.velogames.com/sixes-superclasico/{year}/riders.php"

"""
    backtest_race(race::BacktestRace; kwargs...) -> BacktestResult

Run prediction pipeline on a historical race and compare to actual results.

## Keyword arguments
- `signals::Vector{Symbol}` — which signals to include (default: all available).
  Valid symbols: `:pcs`, `:vg_season`, `:race_history`, `:vg_history`
- `bayesian_config::BayesianConfig` — hyperparameters (default: `DEFAULT_BAYESIAN_CONFIG`)
- `n_sims::Int` — MC iterations (default: 2000, lower than production for speed)
- `cache_config::CacheConfig` — cache settings (default: `DEFAULT_CACHE`)
- `force_refresh::Bool` — bypass cache (default: false)
"""
function backtest_race(
    race::BacktestRace;
    signals::Vector{Symbol}=[:pcs, :vg_season, :race_history],
    bayesian_config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    n_sims::Int=2000,
    cache_config::CacheConfig=DEFAULT_CACHE,
    force_refresh::Bool=false,
)
    # --- 1. Fetch actual PCS results (ground truth) ---
    actual_df = getpcsraceresults(
        race.pcs_slug,
        race.year;
        cache_config=cache_config,
        force_refresh=force_refresh,
    )
    if nrow(actual_df) == 0
        error("No PCS results found for $(race.name) $(race.year)")
    end
    # Exclude DNF/DNS (position >= 900)
    actual_df = filter(:position => p -> p < 900, actual_df)
    if nrow(actual_df) < 10
        error("Too few finishers ($(nrow(actual_df))) for $(race.name) $(race.year)")
    end

    # --- 2. Build rider DataFrame ---
    # Try VG roster first (gives costs and season points)
    riderdf = _build_rider_df(race, actual_df, cache_config, force_refresh)

    # --- 3. Conditionally fetch signals ---

    # PCS specialty scores
    if :pcs in signals
        rider_names = String.(riderdf.rider)
        pcspts = getpcsriderpts_batch(
            rider_names;
            cache_config=cache_config,
            force_refresh=force_refresh,
        )
        pcs_cols = intersect(
            names(pcspts),
            ["riderkey", "oneday", "gc", "tt", "sprint", "climber"],
        )
        if !isempty(pcs_cols)
            riderdf = leftjoin(riderdf, pcspts[:, pcs_cols], on=:riderkey, makeunique=true)
            for col in [:oneday, :gc, :tt, :sprint, :climber]
                if col in propertynames(riderdf)
                    riderdf[!, col] = coalesce.(riderdf[!, col], 0)
                end
            end
        end
    end

    # Zero out VG season points if signal is disabled
    if !(:vg_season in signals)
        riderdf[!, :points] .= 0.0
    end

    # PCS race history (only years before the backtest year)
    race_history_df = nothing
    if :race_history in signals && !isempty(race.pcs_slug)
        years = collect((race.year-race.history_years):(race.year-1))
        try
            race_history_df = getpcsracehistory(
                race.pcs_slug,
                years;
                cache_config=cache_config,
                force_refresh=force_refresh,
            )
            race_history_df[!, :variance_penalty] .= 0.0

            # Similar-race history
            similar_slugs = get(SIMILAR_RACES, race.pcs_slug, String[])
            for slug in similar_slugs
                try
                    similar_df = getpcsracehistory(
                        slug,
                        years;
                        cache_config=cache_config,
                        force_refresh=force_refresh,
                    )
                    if nrow(similar_df) > 0
                        similar_df[!, :variance_penalty] .= 1.0
                        race_history_df = vcat(race_history_df, similar_df; cols=:union)
                    end
                catch
                    # Skip unavailable similar races
                end
            end
        catch e
            @warn "Failed to fetch race history for $(race.pcs_slug): $e"
        end
    end

    # VG race history — not implemented for v1 (requires per-race result URLs)
    vg_history_df = nothing

    # --- 4. Run prediction pipeline ---
    scoring = get_scoring(race.category > 0 ? race.category : 2)
    predicted = predict_expected_points(
        riderdf,
        scoring;
        race_history_df=race_history_df,
        vg_history_df=vg_history_df,
        n_sims=n_sims,
        race_type=:oneday,
        bayesian_config=bayesian_config,
    )

    # --- 5. Compute rank-based metrics ---
    # Join predictions with actual results
    metrics_df = innerjoin(
        predicted[:, [:riderkey, :strength, :expected_vg_points]],
        actual_df[:, [:riderkey, :position]],
        on=:riderkey,
    )

    if nrow(metrics_df) < 5
        error("Too few matched riders ($(nrow(metrics_df))) for $(race.name) $(race.year)")
    end

    rho = spearman_correlation(metrics_df.strength, Float64.(metrics_df.position) .* -1.0)
    overlap5 = top_n_overlap(metrics_df.expected_vg_points, metrics_df.position, 5)
    overlap10 = top_n_overlap(metrics_df.expected_vg_points, metrics_df.position, 10)
    mae = mean_abs_rank_error(metrics_df.expected_vg_points, metrics_df.position)

    # --- 6. VG team metrics (if costs available) ---
    pcr, pred_pts, opt_pts = NaN, NaN, NaN
    if :cost in propertynames(predicted) && any(predicted.cost .> 0)
        try
            pcr, pred_pts, opt_pts = _compute_team_metrics(predicted, actual_df)
        catch e
            @warn "Could not compute team metrics for $(race.name) $(race.year): $e"
        end
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
    )
end

"""Build a rider DataFrame for backtesting, preferring VG data when available."""
function _build_rider_df(
    race::BacktestRace,
    actual_df::DataFrame,
    cache_config::CacheConfig,
    force_refresh::Bool,
)
    vg_url = replace(VG_SUPERCLASICO_URL_TEMPLATE, "{year}" => string(race.year))
    try
        vg_df = getvgriders(
            vg_url;
            cache_config=cache_config,
            force_refresh=force_refresh,
            verbose=false,
        )
        # Inner join with actual results to get only participating riders
        rider_keys = actual_df[:, [:riderkey]]
        riderdf = semijoin(vg_df, rider_keys, on=:riderkey)
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
        rider=actual_df.rider,
        team=hasproperty(actual_df, :team) ? actual_df.team : fill("Unknown", nrow(actual_df)),
        riderkey=actual_df.riderkey,
        cost=fill(10, nrow(actual_df)),
        points=fill(0.0, nrow(actual_df)),
    )
end

"""Compute VG team selection metrics: predicted vs hindsight-optimal team."""
function _compute_team_metrics(predicted::DataFrame, actual_df::DataFrame)
    # Join actual VG points onto predictions (use PCS position as proxy if no VG points)
    joined = innerjoin(
        predicted,
        actual_df[:, [:riderkey, :position]],
        on=:riderkey,
        makeunique=true,
    )

    # Optimal team: select by best actual finishing position (lowest = best)
    # Use negative position as proxy "actual points" for the optimiser
    joined[!, :actual_proxy_points] = Float64.(maximum(joined.position) .- joined.position .+ 1)

    # Predicted team
    pred_sol = build_model_oneday(joined, 6, :expected_vg_points, :cost; totalcost=100)
    if pred_sol === nothing
        return NaN, NaN, NaN
    end

    # Optimal team (hindsight)
    opt_sol = build_model_oneday(joined, 6, :actual_proxy_points, :cost; totalcost=100)
    if opt_sol === nothing
        return NaN, NaN, NaN
    end

    # Compute team "points" using the actual proxy
    pred_team_pts = sum(
        joined.actual_proxy_points[i] for
        i = 1:nrow(joined) if JuMP.value(pred_sol[joined.riderkey[i]]) > 0.5
    )
    opt_team_pts = sum(
        joined.actual_proxy_points[i] for
        i = 1:nrow(joined) if JuMP.value(opt_sol[joined.riderkey[i]]) > 0.5
    )

    pcr = opt_team_pts > 0 ? pred_team_pts / opt_team_pts : NaN
    return pcr, pred_team_pts, opt_team_pts
end

# ---------------------------------------------------------------------------
# Season-level backtesting
# ---------------------------------------------------------------------------

"""
    backtest_season(races::Vector{BacktestRace}; kwargs...) -> Vector{BacktestResult}

Run `backtest_race()` for each race, catching and logging per-race errors.
Keyword arguments are forwarded to `backtest_race()`.
"""
function backtest_season(races::Vector{BacktestRace}; kwargs...)
    results = BacktestResult[]
    for (i, race) in enumerate(races)
        try
            result = backtest_race(race; kwargs...)
            push!(results, result)
            @info "[$i/$(length(races))] $(race.name) $(race.year): ρ=$(round(result.spearman_rho, digits=3)), top10=$(result.top10_overlap)"
        catch e
            @warn "[$i/$(length(races))] $(race.name) $(race.year) failed: $e"
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
            race=r.race.name,
            year=r.race.year,
            category=r.race.category,
            signals=join(string.(r.signals_used), "+"),
            n_riders=r.n_riders,
            spearman_rho=round(r.spearman_rho, digits=3),
            top5_overlap=r.top5_overlap,
            top10_overlap=r.top10_overlap,
            mean_abs_rank_error=round(r.mean_abs_rank_error, digits=1),
            points_captured_ratio=round(r.points_captured_ratio, digits=3),
        )
    end
    df = DataFrame(rows)

    # Aggregate statistics
    valid_rho = filter(!isnan, df.spearman_rho)
    valid_pcr = filter(!isnan, df.points_captured_ratio)
    if !isempty(valid_rho)
        agg = DataFrame(
            race=["— MEAN —", "— MEDIAN —"],
            year=[0, 0],
            category=[0, 0],
            signals=[first(df.signals), first(df.signals)],
            n_riders=[round(Int, mean(df.n_riders)), round(Int, median(df.n_riders))],
            spearman_rho=[round(mean(valid_rho), digits=3), round(median(valid_rho), digits=3)],
            top5_overlap=[round(Int, mean(df.top5_overlap)), round(Int, median(df.top5_overlap))],
            top10_overlap=[
                round(Int, mean(df.top10_overlap)),
                round(Int, median(df.top10_overlap)),
            ],
            mean_abs_rank_error=[
                round(mean(df.mean_abs_rank_error), digits=1),
                round(median(df.mean_abs_rank_error), digits=1),
            ],
            points_captured_ratio=[
                isempty(valid_pcr) ? NaN : round(mean(valid_pcr), digits=3),
                isempty(valid_pcr) ? NaN : round(median(valid_pcr), digits=3),
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
    ("all_available", [:pcs, :vg_season, :race_history, :vg_history]),
    ("no_pcs", [:vg_season, :race_history]),
    ("history_only", [:race_history]),
]

"""
    ablation_study(races::Vector{BacktestRace}; kwargs...) -> DataFrame

Run backtesting with each signal subset to measure marginal signal value.

Returns a DataFrame with a `signal_set` column identifying each configuration.
Keyword arguments (except `signals`) are forwarded to `backtest_season()`.
"""
function ablation_study(
    races::Vector{BacktestRace};
    bayesian_config::BayesianConfig=DEFAULT_BAYESIAN_CONFIG,
    n_sims::Int=2000,
    cache_config::CacheConfig=DEFAULT_CACHE,
    force_refresh::Bool=false,
)
    all_dfs = DataFrame[]

    for (label, sigs) in ABLATION_SETS
        @info "Running ablation: $label (signals: $(join(string.(sigs), ", ")))"
        results = backtest_season(
            races;
            signals=sigs,
            bayesian_config=bayesian_config,
            n_sims=n_sims,
            cache_config=cache_config,
            force_refresh=force_refresh,
        )
        if !isempty(results)
            summary = summarise_backtest(results)
            summary[!, :signal_set] .= label
            push!(all_dfs, summary)
        end
    end

    return isempty(all_dfs) ? DataFrame() : vcat(all_dfs...; cols=:union)
end

# ---------------------------------------------------------------------------
# Hyperparameter tuning
# ---------------------------------------------------------------------------

"""Bounded parameter ranges for hyperparameter search."""
const PARAM_BOUNDS = (
    pcs_variance=(1.0, 10.0),
    vg_variance=(1.0, 8.0),
    hist_base_variance=(0.3, 3.0),
    hist_decay_rate=(0.1, 1.5),
    vg_hist_base_variance=(0.5, 4.0),
    vg_hist_decay_rate=(0.1, 1.5),
)

"""Sample a random BayesianConfig within PARAM_BOUNDS."""
function _random_bayesian_config(rng::AbstractRNG=Random.default_rng())
    BayesianConfig(
        rand(rng) * (PARAM_BOUNDS.pcs_variance[2] - PARAM_BOUNDS.pcs_variance[1]) +
        PARAM_BOUNDS.pcs_variance[1],
        rand(rng) * (PARAM_BOUNDS.vg_variance[2] - PARAM_BOUNDS.vg_variance[1]) +
        PARAM_BOUNDS.vg_variance[1],
        rand(rng) * (PARAM_BOUNDS.hist_base_variance[2] - PARAM_BOUNDS.hist_base_variance[1]) +
        PARAM_BOUNDS.hist_base_variance[1],
        rand(rng) * (PARAM_BOUNDS.hist_decay_rate[2] - PARAM_BOUNDS.hist_decay_rate[1]) +
        PARAM_BOUNDS.hist_decay_rate[1],
        rand(rng) * (PARAM_BOUNDS.vg_hist_base_variance[2] - PARAM_BOUNDS.vg_hist_base_variance[1]) +
        PARAM_BOUNDS.vg_hist_base_variance[1],
        rand(rng) * (PARAM_BOUNDS.vg_hist_decay_rate[2] - PARAM_BOUNDS.vg_hist_decay_rate[1]) +
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
    tune_hyperparameters(races; objective, n_iter, signals, n_sims, cache_config) -> (BayesianConfig, DataFrame)

Tune BayesianConfig via random search with two-stage cross-validation.

## Stage 1: Coarse search
Sample `n_iter` random configurations, evaluate each on all races, rank by
mean `objective` metric.

## Stage 2: CV refinement
Take the top 10 candidates and run leave-one-race-out cross-validation.
Select the configuration with the best mean held-out score.

## Returns
Tuple of (best BayesianConfig, evaluation log DataFrame).
"""
function tune_hyperparameters(
    races::Vector{BacktestRace};
    objective::Symbol=:spearman_rho,
    n_iter::Int=100,
    signals::Vector{Symbol}=[:pcs, :vg_season, :race_history],
    n_sims::Int=2000,
    cache_config::CacheConfig=DEFAULT_CACHE,
    force_refresh::Bool=false,
    rng::AbstractRNG=Random.default_rng(),
)
    @info "Stage 1: Coarse search ($n_iter candidates, $(length(races)) races)"

    # Include default config as candidate 0
    candidates = BayesianConfig[DEFAULT_BAYESIAN_CONFIG]
    for _ = 1:n_iter
        push!(candidates, _random_bayesian_config(rng))
    end

    # Evaluate each candidate
    log_rows = []
    for (i, config) in enumerate(candidates)
        label = i == 1 ? "default" : "random_$i"
        results = backtest_season(
            races;
            signals=signals,
            bayesian_config=config,
            n_sims=n_sims,
            cache_config=cache_config,
            force_refresh=force_refresh,
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
    end

    log_df = DataFrame(log_rows)
    sort!(log_df, :mean_score, rev=true)

    # Stage 2: CV refinement on top 10
    n_top = min(10, nrow(log_df))
    @info "Stage 2: Leave-one-out CV on top $n_top candidates"

    top_candidates = log_df[1:n_top, :candidate]
    top_configs = [candidates[findfirst(==(c == "default" ? 1 : parse(Int, split(c, "_")[2])), 1:length(candidates))] for c in top_candidates]

    # Simpler approach: map candidate label back to config
    candidate_map = Dict{String,BayesianConfig}()
    candidate_map["default"] = candidates[1]
    for i = 2:length(candidates)
        candidate_map["random_$i"] = candidates[i]
    end

    best_score = -Inf
    best_config = DEFAULT_BAYESIAN_CONFIG

    for label in top_candidates
        config = candidate_map[label]
        cv_scores = Float64[]

        for (j, held_out_race) in enumerate(races)
            train_races = [r for (k, r) in enumerate(races) if k != j]
            results = backtest_season(
                train_races;
                signals=signals,
                bayesian_config=config,
                n_sims=n_sims,
                cache_config=cache_config,
                force_refresh=force_refresh,
            )
            scores = _extract_metric(results, objective)
            valid = filter(!isnan, scores)
            if !isempty(valid)
                push!(cv_scores, mean(valid))
            end
        end

        cv_mean = isempty(cv_scores) ? NaN : mean(cv_scores)
        @info "  CV $label: $objective = $(round(cv_mean, digits=4))"

        if !isnan(cv_mean) && cv_mean > best_score
            best_score = cv_mean
            best_config = config
        end
    end

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
