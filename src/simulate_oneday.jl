# simulate_oneday.jl — one-day Monte Carlo race simulation and expected VG points.

"""
    position_to_strength(position::Int, n_starters::Int) -> Float64

Convert a finishing position to a strength score (z-score-like).
Position 1 maps to a high positive score, position n_starters maps to a low negative score.
Uses logit transform of fractional rank, clamped to (0, 1) for safety.
This gives ~2.5 for position 1 in a 150-rider race, ~-2.5 for last.
"""
function position_to_strength(position::Int, n_starters::Int)
    # Fractional rank: 0 (best) to 1 (worst)
    frac = position / (n_starters + 1)
    # Clamp symmetrically: positions beyond the field get the same magnitude
    # as first place, ensuring the logit scale is balanced. The lower bound
    # (1/(n+1)) corresponds to 1st place; the upper bound (n/(n+1)) to last.
    bound = 1.0 / (n_starters + 1)
    frac = clamp(frac, bound, 1.0 - bound)
    return -log(frac / (1.0 - frac))  # logit transform
end

# ---------------------------------------------------------------------------
# Monte Carlo race simulation
# ---------------------------------------------------------------------------

function _rand_t(rng::AbstractRNG, df::Int)
    z = randn(rng)
    v = sum(randn(rng)^2 for _ = 1:df)
    return z * sqrt(df / v)
end

# Marsaglia–Tsang Gamma sampler (shape ≥ 1, unit scale). Used for the shared
# per-stage "brutal day" attrition shock. Returns mean = shape.
function _rand_gamma(rng::AbstractRNG, shape::Float64)
    d = shape - 1.0 / 3.0
    c = 1.0 / sqrt(9.0 * d)
    while true
        x = randn(rng)
        v = (1.0 + c * x)^3
        v <= 0.0 && continue
        u = rand(rng)
        if log(u) < 0.5 * x^2 + d - d * v + d * log(v)
            return d * v
        end
    end
end

# Normalise a raw VG class label ("All Rounder", "Sprinter", …) to the keys used
# by `StageSimConfig.attrition_class_mult`. Unknown labels fall back to unclassed.
@inline function _norm_class(raw)
    s = replace(lowercase(String(raw)), " " => "")
    s == "sprinter" ? :sprinter :
    s == "climber" ? :climber : s == "allrounder" ? :allrounder : :unclassed
end

"""
    simulate_race(strengths, uncertainties; n_sims, rng, simulation_df) -> Matrix{Int}

Simulate a race `n_sims` times using Monte Carlo.

For each simulation, adds noise (scaled by each rider's uncertainty)
to their strength score, then ranks riders by noisy strength (highest = 1st place).
Uses Student's t-distribution with `simulation_df` degrees of freedom for
heavy-tailed noise (set `simulation_df=nothing` for Gaussian).

Returns a `n_riders x n_sims` matrix where entry [i, s] is rider i's finishing
position in simulation s.
"""
function simulate_race(
    strengths::Vector{Float64},
    uncertainties::Vector{Float64};
    n_sims::Int = 10000,
    rng::AbstractRNG = Random.default_rng(),
    simulation_df::Union{Int,Nothing} = nothing,
)
    n_riders = length(strengths)
    @assert length(uncertainties) == n_riders "Length mismatch: strengths and uncertainties"

    positions = Matrix{Int}(undef, n_riders, n_sims)
    noisy_strengths = Vector{Float64}(undef, n_riders)

    for s = 1:n_sims
        for i = 1:n_riders
            noise = simulation_df === nothing ? randn(rng) : _rand_t(rng, simulation_df)
            noisy_strengths[i] = strengths[i] + uncertainties[i] * noise
        end
        order = sortperm(noisy_strengths, rev = true)
        for (pos, rider_idx) in enumerate(order)
            positions[rider_idx, s] = pos
        end
    end

    return positions
end

"""
    position_probabilities(sim_positions::Matrix{Int}; max_position::Int=30) -> Matrix{Float64}

Convert simulation results to probability distributions over positions.

Returns a `n_riders x max_position` matrix where entry [i, k] is the probability
that rider i finishes in position k.
"""
function position_probabilities(sim_positions::Matrix{Int}; max_position::Int = 30)
    n_riders, n_sims = size(sim_positions)
    probs = zeros(Float64, n_riders, max_position)

    for i = 1:n_riders
        for s = 1:n_sims
            pos = sim_positions[i, s]
            if 1 <= pos <= max_position
                probs[i, pos] += 1.0
            end
        end
        probs[i, :] ./= n_sims
    end

    return probs
end

# ---------------------------------------------------------------------------
# Expected VG points from simulations
# ---------------------------------------------------------------------------

"""
    _score_vg_draw!(sim_pts, positions, teams, scoring; breakaway_rates, mean_sectors, rng)

Score a single simulated race outcome into `sim_pts` (length n_riders),
overwriting it. The VG scoring rule, shared by the production selection score
(`resample_optimise!`) and the backtest score (`expected_vg_points`):

- **Finish points** by finishing position (`positions[i]`).
- **Assist points** to every teammate of each top-3 finisher
  (`scoring.assist_points[finisher_position]`).
- **Breakaway sector points** (optional): when `breakaway_rates` is non-empty,
  each rider gets a Bernoulli draw; on success they earn
  `mean_sectors[i] * scoring.breakaway_points`.
"""
function _score_vg_draw!(
    sim_pts::Vector{Float64},
    positions::AbstractVector{Int},
    teams::Vector{String},
    scoring::ScoringTable;
    breakaway_rates::Vector{Float64} = Float64[],
    mean_sectors::Vector{Float64} = Float64[],
    rng::AbstractRNG = Random.default_rng(),
)
    n_riders = length(positions)

    # Finish points
    for i = 1:n_riders
        sim_pts[i] = Float64(finish_points_for_position(positions[i], scoring))
    end

    # Assist points: teammates of top-3 finishers
    for i = 1:n_riders
        if positions[i] <= 3
            top_team = teams[i]
            for j = 1:n_riders
                if j != i && teams[j] == top_team
                    sim_pts[j] += scoring.assist_points[positions[i]]
                end
            end
        end
    end

    # Breakaway sector points (Bernoulli draw per rider)
    if !isempty(breakaway_rates)
        for i = 1:n_riders
            if breakaway_rates[i] > 0.0 && rand(rng) < breakaway_rates[i]
                sim_pts[i] += mean_sectors[i] * scoring.breakaway_points
            end
        end
    end

    return sim_pts
end

"""
    expected_vg_points(sim_positions::Matrix{Int}, rider_teams::Vector{String},
                       scoring::ScoringTable) -> Vector{Float64}

Compute expected Velogames points for each rider from Monte Carlo simulation results.

Includes:
- **Finish points**: based on simulated finishing position (top 30 score)
- **Assist points**: awarded when a teammate finishes top 3

Returns a vector of expected VG points per rider.
"""
function expected_vg_points(
    sim_positions::Matrix{Int},
    rider_teams::Vector{String},
    scoring::ScoringTable,
)
    n_riders, n_sims = size(sim_positions)
    @assert length(rider_teams) == n_riders "Length mismatch: rider_teams"

    total_points = zeros(Float64, n_riders)

    # Welford accumulators for downside semi-deviation
    welford_mean = zeros(Float64, n_riders)
    m2_down = zeros(Float64, n_riders)
    sim_pts = zeros(Float64, n_riders)

    for s = 1:n_sims
        _score_vg_draw!(sim_pts, view(sim_positions, :, s), rider_teams, scoring)

        # Accumulate totals and Welford downside tracking
        for i = 1:n_riders
            total_points[i] += sim_pts[i]
            delta = sim_pts[i] - welford_mean[i]
            welford_mean[i] += delta / s
            delta2 = sim_pts[i] - welford_mean[i]
            if sim_pts[i] < welford_mean[i]
                m2_down[i] += delta * delta2
            end
        end
    end

    mean_pts = total_points ./ n_sims
    downside_semi_dev = sqrt.(m2_down ./ n_sims)
    return mean_pts, downside_semi_dev
end

"""
    breakaway_sectors_from_km(breakaway_km, total_distance_km) -> Int

Count the number of VG breakaway sectors a rider earns based on how far they
were in the break and the total race distance.

VG awards points at four sector checkpoints:
- 50% of total distance
- 50 km to go
- 20 km to go
- 10 km to go

A rider earns a sector point for each checkpoint they were still ahead of the
peloton, i.e. where `breakaway_km >= checkpoint > 0`.
"""
function breakaway_sectors_from_km(breakaway_km::Float64, total_distance_km::Float64)::Int
    total_distance_km <= 0.0 && return 0
    checkpoints = [
        0.5 * total_distance_km,
        total_distance_km - 50.0,
        total_distance_km - 20.0,
        total_distance_km - 10.0,
    ]
    return count(cp -> cp > 0.0 && breakaway_km >= cp, checkpoints)
end
