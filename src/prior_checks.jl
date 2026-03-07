"""
Prior predictive checks and simulation-based calibration (SBC) for the
Bayesian strength estimation model.

These tools validate model behaviour without historical data by simulating
from the generative process and checking whether implied outcomes match
cycling domain knowledge.
"""

"""Standard normal CDF via the Abramowitz & Stegun approximation (max error ~1.5e-7)."""
function _normal_cdf(z::Float64)
    if z < -8.0
        return 0.0
    elseif z > 8.0
        return 1.0
    end
    t = 1.0 / (1.0 + 0.2316419 * abs(z))
    d = 0.3989422804014327  # 1/sqrt(2π)
    poly =
        t * (
            0.319381530 +
            t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429)))
        )
    p = d * exp(-0.5 * z^2) * poly
    return z >= 0 ? 1.0 - p : p
end

# ---------------------------------------------------------------------------
# Stylised facts — empirical targets for prior predictive checks
# ---------------------------------------------------------------------------

@kwdef struct StylisedFacts
    favourite_win_rate::Tuple{Float64,Float64} = (0.10, 0.35)
    top5_from_top10::Tuple{Float64,Float64} = (0.4, 0.8)
    top10_from_top30::Tuple{Float64,Float64} = (0.5, 0.9)
    rank_correlation::Tuple{Float64,Float64} = (0.3, 0.75)
    posterior_sd_well_covered::Tuple{Float64,Float64} = (0.3, 1.2)
    posterior_sd_sparse::Tuple{Float64,Float64} = (1.0, 3.5)
end

const DEFAULT_STYLISED_FACTS = StylisedFacts()

# ---------------------------------------------------------------------------
# Synthetic signal generation
# ---------------------------------------------------------------------------

"""
Generate synthetic signals for a rider with known true strength, adding noise
at the variances specified by config. Returns kwargs suitable for
`estimate_rider_strength`.

`available_signals` controls which signals are generated (default: all).
"""
function _generate_synthetic_signals(
    rng::AbstractRNG,
    true_strength::Float64,
    config::BayesianConfig;
    available_signals::Set{Symbol} = Set([
        :pcs,
        :vg,
        :form,
        :trajectory,
        :history,
        :vg_history,
        :odds,
        :oracle,
    ]),
    n_history::Int = 3,
    n_starters::Int = 150,
)
    # PCS specialty
    pcs_score, has_pcs = if :pcs in available_signals
        true_strength + randn(rng) * sqrt(pcs_variance(config)), true
    else
        0.0, false
    end

    # VG season points
    vg_points = :vg in available_signals ?
        true_strength + randn(rng) * sqrt(vg_variance(config)) : 0.0

    # Form
    form_score = :form in available_signals ?
        true_strength + randn(rng) * sqrt(form_variance(config)) : 0.0

    # Trajectory
    trajectory_score = :trajectory in available_signals ?
        true_strength * 0.3 + randn(rng) * sqrt(trajectory_variance(config)) : 0.0

    # Race history
    race_history, race_history_years_ago, race_history_variance_penalties =
        if :history in available_signals
            hist = Float64[]
            years = Int[]
            for y = 0:(n_history-1)
                var = hist_base_variance(config) + config.hist_decay_rate * y
                push!(hist, true_strength + randn(rng) * sqrt(var))
                push!(years, y)
            end
            hist, years, zeros(n_history)
        else
            Float64[], Int[], Float64[]
        end

    # VG race history
    vg_race_history, vg_race_history_years_ago = if :vg_history in available_signals
        vg_hist = Float64[]
        vg_years = Int[]
        for y = 0:(n_history-1)
            var = vg_hist_base_variance(config) + config.vg_hist_decay_rate * y
            push!(vg_hist, true_strength + randn(rng) * sqrt(var))
            push!(vg_years, y)
        end
        vg_hist, vg_years
    else
        Float64[], Int[]
    end

    # Odds
    odds_implied_prob = if :odds in available_signals
        odds_strength = true_strength + randn(rng) * sqrt(odds_variance(config))
        clamp((1.0 / n_starters) * exp(odds_strength * config.odds_normalisation), 0.001, 0.99)
    else
        0.0
    end

    # Oracle
    oracle_implied_prob = if :oracle in available_signals
        oracle_strength = true_strength + randn(rng) * sqrt(oracle_variance(config))
        clamp((1.0 / n_starters) * exp(oracle_strength * config.odds_normalisation), 0.001, 0.99)
    else
        0.0
    end

    return RiderSignalData(;
        pcs_score, has_pcs, vg_points, form_score, trajectory_score,
        race_history, race_history_years_ago, race_history_variance_penalties,
        vg_race_history, vg_race_history_years_ago,
        odds_implied_prob, oracle_implied_prob,
    )
end

# ---------------------------------------------------------------------------
# Prior predictive check
# ---------------------------------------------------------------------------

struct PriorCheckResult
    favourite_win_rate::Float64
    top5_from_top10::Float64
    top10_from_top30::Float64
    rank_correlation::Float64
    mean_posterior_sd::Float64
    mean_posterior_sd_sparse::Float64
    n_races::Int
end

"""
    prior_predictive_check(config; n_races=200, n_riders=150, rng=default_rng(),
                           available_signals, sparse_signals) -> PriorCheckResult

Simulate races from the model's generative process:
1. Draw true strengths from N(0, 1)
2. Generate synthetic signals by adding noise at each signal's variance
3. Run `estimate_rider_strength` to get posteriors
4. Simulate finishing positions from true strengths
5. Compare posterior predictions to true outcomes

`available_signals` controls which signals well-covered riders have.
`sparse_signals` controls which signals sparse riders have (default: pcs only).
"""
function prior_predictive_check(
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG;
    n_races::Int = 200,
    n_riders::Int = 150,
    rng::AbstractRNG = Random.default_rng(),
    available_signals::Set{Symbol} = Set([
        :pcs,
        :vg,
        :form,
        :trajectory,
        :history,
        :vg_history,
        :odds,
        :oracle,
    ]),
    sparse_signals::Set{Symbol} = Set([:pcs]),
)
    fav_wins = 0
    top5_from_top10_count = 0
    top5_total = 0
    top10_from_top30_count = 0
    top10_total = 0
    rank_corrs = Float64[]
    posterior_sds = Float64[]
    posterior_sds_sparse = Float64[]

    for _ = 1:n_races
        true_strengths = randn(rng, n_riders)

        # First 30 riders are "well-covered", rest are sparse
        n_covered = min(30, n_riders)
        posterior_means = zeros(n_riders)
        posterior_vars = zeros(n_riders)

        for i = 1:n_riders
            signals = i <= n_covered ? available_signals : sparse_signals
            signals = _generate_synthetic_signals(
                rng,
                true_strengths[i],
                config;
                available_signals = signals,
                n_starters = n_riders,
            )
            est = estimate_rider_strength(signals; n_starters = n_riders, config = config)
            posterior_means[i] = est.mean
            posterior_vars[i] = est.variance
            sd = sqrt(est.variance)
            if i <= n_covered
                push!(posterior_sds, sd)
            else
                push!(posterior_sds_sparse, sd)
            end
        end

        # Simulate finishing positions from true strengths (lower = better)
        true_positions = sortperm(sortperm(-true_strengths))
        predicted_positions = sortperm(sortperm(-posterior_means))

        # Favourite win rate: does the predicted-strongest rider win?
        if true_positions[argmin(predicted_positions)] == 1
            fav_wins += 1
        end

        # Top-5 from predicted top-10
        pred_top10 = Set(partialsortperm(-posterior_means, 1:10))
        true_top5 = Set(partialsortperm(-true_strengths, 1:5))
        true_top10 = Set(partialsortperm(-true_strengths, 1:10))
        top5_from_top10_count += length(intersect(true_top5, pred_top10))
        top5_total += 5

        # Top-10 from predicted top-30
        pred_top30 = Set(partialsortperm(-posterior_means, 1:30))
        top10_from_top30_count += length(intersect(true_top10, pred_top30))
        top10_total += 10

        # Rank correlation (Spearman)
        push!(rank_corrs, cor(float.(true_positions), float.(predicted_positions)))
    end

    PriorCheckResult(
        fav_wins / n_races,
        top5_from_top10_count / top5_total,
        top10_from_top30_count / top10_total,
        mean(rank_corrs),
        mean(posterior_sds),
        isempty(posterior_sds_sparse) ? NaN : mean(posterior_sds_sparse),
        n_races,
    )
end

# ---------------------------------------------------------------------------
# Check against stylised facts
# ---------------------------------------------------------------------------

"""
    check_stylised_facts(config; facts=DEFAULT_STYLISED_FACTS, kwargs...) -> DataFrame

Run `prior_predictive_check` and compare results against stylised fact ranges.
Returns a DataFrame with fact name, expected range, observed value, and pass/fail.
"""
function check_stylised_facts(
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG;
    facts::StylisedFacts = DEFAULT_STYLISED_FACTS,
    kwargs...,
)
    result = prior_predictive_check(config; kwargs...)

    checks = [
        ("favourite_win_rate", facts.favourite_win_rate, result.favourite_win_rate),
        ("top5_from_top10", facts.top5_from_top10, result.top5_from_top10),
        ("top10_from_top30", facts.top10_from_top30, result.top10_from_top30),
        ("rank_correlation", facts.rank_correlation, result.rank_correlation),
        (
            "posterior_sd_well_covered",
            facts.posterior_sd_well_covered,
            result.mean_posterior_sd,
        ),
        ("posterior_sd_sparse", facts.posterior_sd_sparse, result.mean_posterior_sd_sparse),
    ]

    DataFrame(
        fact = [c[1] for c in checks],
        lower = [c[2][1] for c in checks],
        upper = [c[2][2] for c in checks],
        observed = [round(c[3], digits = 3) for c in checks],
        pass = [c[2][1] <= c[3] <= c[2][2] for c in checks],
    )
end

# ---------------------------------------------------------------------------
# Sensitivity sweep
# ---------------------------------------------------------------------------

"""
    sensitivity_sweep(param::Symbol, values; config=DEFAULT_BAYESIAN_CONFIG, kwargs...) -> DataFrame

Sweep a single BayesianConfig parameter across `values` and report diagnostics.
`param` must be a field of BayesianConfig (e.g. `:market_precision_scale`).
"""
function sensitivity_sweep(
    param::Symbol,
    values;
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    kwargs...,
)
    rows = []
    for v in values
        # Build config with overridden parameter
        fields = Dict{Symbol,Any}()
        for f in fieldnames(BayesianConfig)
            fields[f] = getfield(config, f)
        end
        fields[param] = v
        test_config = BayesianConfig(; fields...)

        result = prior_predictive_check(test_config; n_races = 100, kwargs...)
        push!(
            rows,
            (;
                param_value = v,
                favourite_win_rate = round(result.favourite_win_rate, digits = 3),
                top5_from_top10 = round(result.top5_from_top10, digits = 3),
                rank_correlation = round(result.rank_correlation, digits = 3),
                posterior_sd = round(result.mean_posterior_sd, digits = 3),
            ),
        )
    end
    DataFrame(rows)
end

# ---------------------------------------------------------------------------
# Simulation-based calibration (SBC)
# ---------------------------------------------------------------------------

struct SBCResult
    rank_histogram::Vector{Int}
    n_bins::Int
    n_sims::Int
    chi_squared_p::Float64
    mean_rank::Float64
end

"""
    simulation_based_calibration(config; n_sims=500, n_riders=1, rng=default_rng()) -> SBCResult

For each simulation:
1. Draw true strength from N(0, 1)
2. Generate synthetic observations from true strength + noise
3. Run `estimate_rider_strength` to get posterior (mean, variance)
4. Compute the posterior CDF rank of the true strength

If correctly calibrated, the CDF ranks should be Uniform(0, 1), so the
histogram of ranks across bins should be approximately uniform.
"""
function simulation_based_calibration(
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG;
    n_sims::Int = 500,
    n_bins::Int = 20,
    rng::AbstractRNG = Random.default_rng(),
    available_signals::Set{Symbol} = Set([
        :pcs,
        :vg,
        :form,
        :trajectory,
        :history,
        :vg_history,
        :odds,
        :oracle,
    ]),
)
    ranks = Float64[]

    for _ = 1:n_sims
        true_strength = randn(rng)
        signals = _generate_synthetic_signals(
            rng,
            true_strength,
            config;
            available_signals = available_signals,
        )
        est = estimate_rider_strength(signals; config = config)

        # CDF rank: P(X <= true_strength) under Normal(est.mean, est.variance)
        z = (true_strength - est.mean) / sqrt(est.variance)
        cdf_rank = _normal_cdf(z)
        push!(ranks, cdf_rank)
    end

    # Build histogram
    histogram = zeros(Int, n_bins)
    for r in ranks
        bin = clamp(ceil(Int, r * n_bins), 1, n_bins)
        histogram[bin] += 1
    end

    # Chi-squared test for uniformity
    expected = n_sims / n_bins
    chi_sq = sum((histogram .- expected) .^ 2 ./ expected)
    # Approximate p-value using normal approximation to chi-squared
    df = n_bins - 1
    z_chi = (chi_sq - df) / sqrt(2.0 * df)
    p_value = 1.0 - _normal_cdf(z_chi)

    SBCResult(histogram, n_bins, n_sims, p_value, mean(ranks))
end
