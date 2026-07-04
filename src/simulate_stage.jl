# simulate_stage.jl — per-stage grand tour simulation, diagnostics, and
# stage-type strength projection (compute_stage_strengths).

# ---------------------------------------------------------------------------
# Per-stage grand tour simulation
# ---------------------------------------------------------------------------

"""
Per-stage and per-classification diagnostic counters from `simulate_stage_race`.

Counts are aggregated across simulations. To convert to probabilities, divide
by `n_sims`. Used by reporting scripts to surface "rider X has a 23% chance of
finishing on the podium of stage 5" or "rider Y has a 67% chance of being in
the GC top 10".

- `stage_finish_counts[stage_idx, rider, k]` for k ∈ 1:3 — per-stage podium counts
- `stage_top10_counts[stage_idx, rider]` — per-stage top-10 finishes
- `final_gc_position_counts[rider, k]` for k ∈ 1:final_gc_top — final GC at position k
- `final_points_position_counts[rider, k]` for k ∈ 1:final_points_top — same, points jersey
- `final_mountains_position_counts[rider, k]` — same, mountains/KOM jersey
- `final_team_position_counts[team_name][k]` — final team classification at position k
"""
struct StageRaceDiagnostics
    n_sims::Int
    stage_finish_counts::Array{Int,3}      # n_stages × n_riders × 3
    stage_top10_counts::Matrix{Int}        # n_stages × n_riders
    final_gc_position_counts::Matrix{Int}  # n_riders × top_k
    final_points_position_counts::Matrix{Int}
    final_mountains_position_counts::Matrix{Int}
    final_team_position_counts::Dict{String,Vector{Int}}  # team_name → positions
end

# Per-stage points-jersey allocation, intermediate-sprint banner points, and
# per-event breakaway-noise scales now live in `StageSimConfig` (race_helpers.jl)
# so they can be threaded and calibrated. `_breakaway_sd` blends a per-event,
# per-dimension breakaway σ against `stage_dimension_weights`; `_aleatoric_sd`
# does the same for the race-day scatter scale `a_type`.
@inline function _breakaway_sd(event::Symbol, w::NamedTuple, breakaway_noise::NamedTuple)
    scale = getproperty(breakaway_noise, event)
    return w.flat * scale.flat +
           w.hilly * scale.hilly +
           w.mountain * scale.mountain +
           w.itt * scale.itt
end

@inline function _aleatoric_sd(w::NamedTuple, an::NamedTuple)
    return w.flat * an.flat + w.hilly * an.hilly + w.mountain * an.mountain + w.itt * an.itt
end

@inline function _score_stage_finish_and_assists!(
    stage_pts::Vector{Float64},
    positions::Vector{Int},
    teams::Vector{String},
    scoring::StageRaceScoringTable,
    stype::Symbol,
    n_riders::Int,
)
    fill!(stage_pts, 0.0)
    for i = 1:n_riders
        stage_pts[i] = Float64(stage_finish_points_for_position(positions[i], scoring))
    end
    assist_depth = length(scoring.stage_assist_points)
    if stype != :itt && stype != :ttt && assist_depth > 0
        for i = 1:n_riders
            if positions[i] <= assist_depth
                for j = 1:n_riders
                    if j != i && teams[j] == teams[i]
                        stage_pts[j] += scoring.stage_assist_points[positions[i]]
                    end
                end
            end
        end
    end
    return nothing
end

@inline function _score_daily_gc_and_assists!(
    stage_pts::Vector{Float64},
    gc_positions::Vector{Int},
    teams::Vector{String},
    scoring::StageRaceScoringTable,
    stype::Symbol,
    n_riders::Int,
)
    for i = 1:n_riders
        stage_pts[i] += daily_gc_points_for_position(gc_positions[i], scoring)
    end
    assist_depth = length(scoring.gc_assist_points)
    if stype != :itt && stype != :ttt && assist_depth > 0
        for i = 1:n_riders
            if gc_positions[i] <= assist_depth
                for j = 1:n_riders
                    if j != i && teams[j] == teams[i]
                        stage_pts[j] += scoring.gc_assist_points[gc_positions[i]]
                    end
                end
            end
        end
    end
    return nothing
end

# Team time trial: the whole squad rides together and shares one result, so the
# outcome is a ranking of TEAMS (by mean TT strength), not individuals. Every
# rider takes their team's placing as their finishing position.
function _assign_team_positions!(
    positions::Vector{Int},
    noisy::Vector{Float64},
    teams::Vector{String},
    abandoned::Vector{Bool},
    n_riders::Int,
)
    # Average TT strength over the riders still in the race. An abandoned rider's
    # noisy is -Inf, so including them would collapse the whole squad's mean to
    # -Inf and rank every active teammate last. A team with no active riders left
    # ranks bottom (mean -Inf).
    team_sum = Dict{String,Float64}()
    team_n = Dict{String,Int}()
    for i = 1:n_riders
        (!isempty(abandoned) && abandoned[i]) && continue
        team_sum[teams[i]] = get(team_sum, teams[i], 0.0) + noisy[i]
        team_n[teams[i]] = get(team_n, teams[i], 0) + 1
    end
    team_mean(t) = get(team_n, t, 0) == 0 ? -Inf : team_sum[t] / team_n[t]
    ranked = sort(unique(teams), by = team_mean, rev = true)
    team_rank = Dict(t => r for (r, t) in enumerate(ranked))
    for i = 1:n_riders
        positions[i] = team_rank[teams[i]]
    end
    return nothing
end

# Score a team time trial: every rider earns the points for their team's
# placing. Uses the dedicated `ttt_team_points` table, falling back to the
# normal stage-finish table if VG published no TTT-specific scoring.
@inline function _score_ttt_team!(
    stage_pts::Vector{Float64},
    positions::Vector{Int},
    scoring::StageRaceScoringTable,
    n_riders::Int,
)
    fill!(stage_pts, 0.0)
    pts_table =
        isempty(scoring.ttt_team_points) ? scoring.stage_finish_points :
        scoring.ttt_team_points
    depth = length(pts_table)
    for i = 1:n_riders
        positions[i] <= depth && (stage_pts[i] += pts_table[positions[i]])
    end
    return nothing
end

@inline function _score_points_jersey_stage!(
    points_jersey_total::Vector{Float64},
    noisy::Vector{Float64},
    order::Vector{Int},
    w::NamedTuple,
    stype::Symbol,
    n_riders::Int,
    rng::AbstractRNG,
    sim_cfg::StageSimConfig,
)
    alloc = sim_cfg.points_jersey_allocation
    pts_alloc = get(alloc, stype, alloc.hilly)
    alloc_depth = length(pts_alloc)
    br_sd = _breakaway_sd(:points_jersey, w, sim_cfg.breakaway_noise)
    if br_sd > 0.0
        pts_noisy = similar(noisy)
        for i = 1:n_riders
            pts_noisy[i] = noisy[i] + br_sd * randn(rng)
        end
        pts_order = sortperm(pts_noisy, rev = true)
    else
        pts_order = order
    end
    for rank = 1:min(alloc_depth, n_riders)
        points_jersey_total[pts_order[rank]] += pts_alloc[rank]
    end
    return nothing
end

@inline function _score_intermediate_sprint!(
    points_jersey_total::Vector{Float64},
    stage_strengths::Dict{Symbol,Vector{Float64}},
    fallback_strengths::Vector{Float64},
    uncertainties::Vector{Float64},
    alpha::Float64,
    a_stage::Float64,
    rider_noise::Vector{Float64},
    stage_noise::Vector{Float64},
    stype::Symbol,
    n_riders::Int,
    int_points::Vector{Float64},
    abandoned::Vector{Bool},
)
    if stype != :flat && stype != :hilly
        return nothing
    end
    flat_str = get(stage_strengths, :flat, fallback_strengths)
    int_noisy = Vector{Float64}(undef, n_riders)
    # Same variance decomposition as the stage finish: persistent epistemic
    # wobble (α·σ·rider, correlated with the stage) + aleatoric race-day scatter
    # (a_stage·stage). Reuses the stage's own noise draws so a rider's banner
    # result is correlated with their stage-finish result. Abandoned riders are
    # frozen out (they don't contest the banner).
    for i = 1:n_riders
        int_noisy[i] =
            (!isempty(abandoned) && abandoned[i]) ? -Inf :
            flat_str[i] +
            uncertainties[i] * alpha * rider_noise[i] +
            a_stage * stage_noise[i]
    end
    int_order = sortperm(int_noisy, rev = true)
    for rank = 1:min(length(int_points), n_riders)
        points_jersey_total[int_order[rank]] += int_points[rank]
    end
    return nothing
end

# Daily mountains (KOM) classification. On climbing stages the top riders over
# the day's climbs bank `daily_mountains_class` points — a real income stream
# (up to 33/stage) that the sim previously omitted entirely, under-scoring pure
# climbers / polka-dot contenders. Per-climb HC/Cat-1 points can't be modelled
# (the PCS scraper leaves `n_hc_climbs`/`n_cat1_climbs` at 0), so we rank by
# climbing ability plus the stage's realised luck (`noisy - strengths_blend`).
# Note `noisy` already carries the stage-finish breakaway shock on mountain
# stages, so the daily-KOM order is positively correlated with the day's stage
# result — reasonable, since the rider animating a mountain stage typically
# leads over its climbs. Abandoned riders carry -Inf `noisy` and sort out
# automatically.
#
# The same daily points also accrue into `kom_total`, the cumulative per-sim
# KOM tally that decides the final mountains jersey (July 2026 fix: the final
# jersey previously ranked on mountain-stage top-5 FINISHES, which never read
# `kom_s` and ignored hilly stages).
@inline function _score_daily_mountains!(
    stage_pts::Vector{Float64},
    kom_total::Vector{Float64},
    kom_s::Vector{Float64},
    noisy::Vector{Float64},
    strengths_blend::Vector{Float64},
    kom_str::Vector{Float64},
    scoring::StageRaceScoringTable,
    stype::Symbol,
    n_riders::Int,
)
    (stype == :mountain || stype == :hilly) || return nothing
    depth = length(scoring.daily_mountains_class)
    depth == 0 && return nothing
    # KOM-competition ranking = KOM strength + this stage's shared noise term.
    # `kom_s` decouples the jersey competition from finish-position strength.
    for i = 1:n_riders
        kom_str[i] = kom_s[i] + (noisy[i] - strengths_blend[i])
    end
    kom_order = sortperm(kom_str, rev = true)
    for r = 1:min(depth, n_riders)
        pts = scoring.daily_mountains_class[r]
        stage_pts[kom_order[r]] += pts
        kom_total[kom_order[r]] += pts
    end
    return nothing
end

# Discrete breakaway event (grand-tour breakaway modelling, July 2026). Draws
# a per-stage Bernoulli "in the break" event, hilly/mountain stages only, for
# riders with a recorded PCS breakaway-km history (`breakaway_rates[i] > 0`,
# from `compute_breakaway_rates` — see race_solver.jl `_load_breakaway_rates`).
# Riders with no such history (pure sprinters, GC leaders who never go up the
# road) have `breakaway_rates[i] == 0.0` and are skipped WITHOUT consuming an
# `rng` draw, so passing an empty/all-zero `breakaway_rates` (the default)
# leaves the RNG stream — and hence every simulated outcome — bit-identical to
# the pre-breakaway-modelling behaviour.
#
# On trigger, boosts the rider's `noisy` stage-finish strength (mirrors the
# real advantage of contesting a stage from a small escape rather than the
# full bunch) so the effect flows through the EXISTING finish-position
# ranking, points-jersey ranking, and daily-KOM proxy (all keyed off `noisy`)
# without a parallel ranking system. Deliberately does NOT touch
# `cumulative_gc_score`: a domestique's break essentially never moves real
# GC, and keeping GC untouched means this feature cannot inflate the exact
# metrics (final GC bonus, final team classification) used for rank-ρ
# validation elsewhere.
@inline function _draw_breakaway!(
    in_break::Vector{Bool},
    noisy::Vector{Float64},
    breakaway_rates::Vector{Float64},
    boost::Float64,
    stype::Symbol,
    abandoned::Vector{Bool},
    n_riders::Int,
    rng::AbstractRNG,
)
    fill!(in_break, false)
    (isempty(breakaway_rates) || (stype != :hilly && stype != :mountain)) && return in_break
    for i = 1:n_riders
        (abandoned[i] || breakaway_rates[i] <= 0.0) && continue
        if rand(rng) < breakaway_rates[i]
            in_break[i] = true
            noisy[i] += boost
        end
    end
    return in_break
end

# Flat "breakaway at 50% distance" bonus (`scoring.breakaway_points`, 20 pts —
# previously dead for stage races, see scoring.jl SCORING_GRAND_TOUR). Awarded
# unconditionally to every rider `_draw_breakaway!` selected for this stage,
# on top of whatever they score for their (boosted) finish position. Must run
# AFTER `_score_stage_finish_and_assists!`, which `fill!`s `stage_pts` to zero.
@inline function _score_breakaway_bonus!(
    stage_pts::Vector{Float64},
    in_break::Vector{Bool},
    bp::Int,
    n_riders::Int,
)
    bp == 0 && return nothing
    for i = 1:n_riders
        in_break[i] && (stage_pts[i] += bp)
    end
    return nothing
end

"""
    stage_dimension_weights(stage::StageProfile) -> NamedTuple

Continuous weighting across `(flat, hilly, mountain, itt)` for a single stage,
derived primarily from PCS ProfileScore + summit-finish flag. Used by
`simulate_stage_race` to blend per-dimension rider strengths.

Replaces a discrete `stage_type` lookup that incorrectly treated all "hilly"
stages identically — a Giro Tipo B with 680m vert and PS=14 (essentially a
sprint stage) drew the same per-dimension projection as a hard summit-finish
hilly with PS=152.

Anchor points (linear interpolation between), tuned against the empirical PS
distribution seen on a real grand tour where PCS-flat stages score PS≈7-28,
hilly score PS≈14-152, and mountain score PS≈89-396:
- PS ≤ 40:   `flat = 1.0`
- PS = 90:   `hilly = 1.0`
- PS ≥ 250:  `mountain = 1.0`

Summit finish reallocates 30% of `hilly` weight to `mountain` (a hilly stage
ending uphill rewards climbers more than a hilly stage ending in a town
sprint). ITT and TTT remain pure (TTT is treated as ITT for strength).

Falls back to discrete `stage_type` when `profile_score ≤ 0` (synthetic test
stages or unparsed PCS pages).
"""
function stage_dimension_weights(stage::StageProfile)
    if stage.stage_type == :itt || stage.stage_type == :ttt
        return (flat = 0.0, hilly = 0.0, mountain = 0.0, itt = 1.0)
    end
    if stage.profile_score <= 0
        return stage.stage_type == :flat ?
               (flat = 1.0, hilly = 0.0, mountain = 0.0, itt = 0.0) :
               stage.stage_type == :mountain ?
               (flat = 0.0, hilly = 0.0, mountain = 1.0, itt = 0.0) :
               (flat = 0.0, hilly = 1.0, mountain = 0.0, itt = 0.0)
    end
    ps = Float64(stage.profile_score)
    # Flat-to-hilly ramp starts at PS 40 (not 20): a rolling sprint stage with a
    # modest ProfileScore (~50-60) is still won by sprinters in a bunch finish,
    # so it should stay majority-flat rather than tipping puncheurs/GC riders
    # onto the podium. PS 58 → ~64% flat / 36% hilly.
    if ps <= 40.0
        f, h, m = 1.0, 0.0, 0.0
    elseif ps <= 90.0
        h = (ps - 40.0) / 50.0
        f = 1.0 - h
        m = 0.0
    elseif ps <= 250.0
        m = (ps - 90.0) / 160.0
        h = 1.0 - m
        f = 0.0
    else
        f, h, m = 0.0, 0.0, 1.0
    end
    if stage.is_summit_finish && h > 0.0
        shift = 0.3 * h
        h -= shift
        m += shift
    end
    return (flat = f, hilly = h, mountain = m, itt = 0.0)
end

"""
    simulate_stage_race(stages, stage_strengths, uncertainties, teams, scoring;
                        n_sims=500, cross_stage_alpha=0.7, gc_strengths=Float64[],
                        rng, sim_config=DEFAULT_STAGE_SIM_CONFIG)
        -> (Matrix{Float64}, StageRaceDiagnostics)

Simulate a full grand tour stage by stage. Always returns a tuple of
`(vg_points, diagnostics)`:
- `vg_points` — total VG points per rider per simulation draw (`n_riders × n_sims`)
- `diagnostics` — per-stage podium/top-10 counts and final-classification position counts

Each rider's per-stage performance is the sum of a persistent **epistemic** term
(`α·σ·rider_noise`, correlated across stages via `cross_stage_alpha`, scaling with
posterior σ) and an independent **aleatoric** race-day term (`a_type·stage_noise`,
a flat per-stage-type scale that does not scale with σ, drawn fat-tailed Student-t
with `sim_config.aleatoric_df` df). For each stage, riders are ranked by noisy strength, scored for stage finish,
assists, and daily GC. After all stages, final classification bonuses are awarded.

Per-event scoring (stage finish + assists, daily GC + assists, points jersey,
intermediate sprint, KOM) is delegated to `_score_*` helpers above. The aleatoric
scale, breakaway noise, jersey allocation, and intermediate-sprint points all live
in `sim_config::StageSimConfig`.

`breakaway_rates` (optional, aligned to `uncertainties`/`teams` by rider index)
enables the discrete per-rider breakaway event on hilly/mountain stages — see
`_draw_breakaway!`. Empty by default, in which case the feature is fully
inert (no RNG draws consumed, output identical to pre-breakaway-modelling
behaviour). Typically produced by `compute_breakaway_rates` from archived PCS
breakaway-km data with `max_rate = STAGE_BREAKAWAY_MAX_RATE`.
"""
function simulate_stage_race(
    stages::Vector{StageProfile},
    stage_strengths::Dict{Symbol,Vector{Float64}},
    uncertainties::Vector{Float64},
    teams::Vector{String},
    scoring::StageRaceScoringTable;
    n_sims::Int = 500,
    cross_stage_alpha::Float64 = 0.7,
    gc_strengths::Vector{Float64} = Float64[],
    rng::AbstractRNG = Random.default_rng(),
    sim_config::StageSimConfig = DEFAULT_STAGE_SIM_CONFIG,
    rider_classes::Vector{String} = String[],
    breakaway_rates::Vector{Float64} = Float64[],
)
    n_riders = length(uncertainties)
    n_stages = length(stages)
    alpha = cross_stage_alpha

    # Attrition (A2): per-rider class hazard multiplier. Active only when
    # `rider_classes` is supplied (production); tests without classes keep the
    # old no-attrition behaviour. Abandoned riders are frozen out of every
    # per-stage event and all final classifications from their abandon stage on.
    attrition_on = !isempty(rider_classes)
    class_mult = if attrition_on
        [
            getproperty(sim_config.attrition_class_mult, _norm_class(rider_classes[i]))
            for i = 1:n_riders
        ]
    else
        Float64[]
    end
    # GC-favourite protection: fold a per-rider hazard multiplier ≤ 1 into the
    # class multiplier so strong GC favourites (high GC-strength z-score) rarely
    # abandon — they're contending, not strategically pulling out. Only riders
    # >1 SD above the field are protected, so field survival is ~unchanged.
    if attrition_on && !isempty(gc_strengths) && sim_config.gc_favourite_protection > 0
        μ = mean(gc_strengths)
        s = std(gc_strengths)
        if s > 0
            for i = 1:n_riders
                gc_z = (gc_strengths[i] - μ) / s
                prot = exp(-sim_config.gc_favourite_protection * max(0.0, gc_z - 1.0))
                class_mult[i] *= max(sim_config.gc_protection_floor, prot)
            end
        end
    end

    # If gc_strengths not supplied, fall back to per-rider mean across stage types.
    # Production callers always supply gc_strengths via `compute_stage_strengths`;
    # this fallback keeps synthetic test inputs working.
    if isempty(gc_strengths)
        keys_present = collect(keys(stage_strengths))
        gc_strengths =
            [mean(stage_strengths[k][i] for k in keys_present) for i = 1:n_riders]
    end

    sim_vg_points = zeros(Float64, n_riders, n_sims)

    # Diagnostic accumulators (always populated)
    diag_stage_finish = zeros(Int, n_stages, n_riders, 3)
    diag_stage_top10 = zeros(Int, n_stages, n_riders)
    diag_gc_top = length(scoring.final_gc_points)
    diag_points_top = length(scoring.final_points_class)
    diag_mountains_top = length(scoring.final_mountains_class)
    diag_team_top = length(scoring.final_team_class)
    diag_gc_pos = zeros(Int, n_riders, diag_gc_top)
    diag_points_pos = zeros(Int, n_riders, diag_points_top)
    diag_mountains_pos = zeros(Int, n_riders, diag_mountains_top)
    diag_team_pos = Dict{String,Vector{Int}}()
    for t in unique(teams)
        diag_team_pos[t] = zeros(Int, diag_team_top)
    end

    # Pre-allocate working arrays
    noisy = Vector{Float64}(undef, n_riders)
    strengths_blend = Vector{Float64}(undef, n_riders)
    positions = Vector{Int}(undef, n_riders)
    rider_noise = Vector{Float64}(undef, n_riders)
    stage_noise = Vector{Float64}(undef, n_riders)
    cumulative_gc_score = Vector{Float64}(undef, n_riders)
    gc_positions = Vector{Int}(undef, n_riders)
    stage_pts = Vector{Float64}(undef, n_riders)
    points_jersey_total = Vector{Float64}(undef, n_riders)
    kom_total = Vector{Float64}(undef, n_riders)
    kom_str = Vector{Float64}(undef, n_riders)
    abandoned = Vector{Bool}(undef, n_riders)
    in_break = Vector{Bool}(undef, n_riders)

    for sim = 1:n_sims
        for i = 1:n_riders
            rider_noise[i] = randn(rng)
        end

        fill!(cumulative_gc_score, 0.0)
        fill!(points_jersey_total, 0.0)
        fill!(kom_total, 0.0)
        fill!(abandoned, false)
        rider_total_pts = zeros(Float64, n_riders)

        for (stage_idx, stage) in enumerate(stages)
            stype = stage.stage_type
            # Blend per-dim strengths into a per-stage strength vector using
            # PCS ProfileScore-derived weights.
            w = stage_dimension_weights(stage)
            flat_s = get(stage_strengths, :flat, gc_strengths)
            hilly_s = get(stage_strengths, :hilly, gc_strengths)
            mountain_s = get(stage_strengths, :mountain, gc_strengths)
            itt_s = get(stage_strengths, :itt, gc_strengths)
            # KOM-competition strength: climbing base + KOM/breakaway propensity.
            # Drives the daily mountains classification only, never the finish blend.
            kom_s = get(stage_strengths, :kom, mountain_s)
            for i = 1:n_riders
                strengths_blend[i] =
                    w.flat * flat_s[i] +
                    w.hilly * hilly_s[i] +
                    w.mountain * mountain_s[i] +
                    w.itt * itt_s[i]
            end

            # Attrition: draw this stage's abandonments among still-active riders.
            # A single shared "brutal day" shock (Gamma, mean 1) scales every
            # at-risk rider's hazard together, so crashes/echelons/time-cuts take
            # out sprinters in correlated cohorts rather than independently.
            if attrition_on
                base_h = getproperty(sim_config.attrition_hazard, stype)
                shock =
                    _rand_gamma(rng, sim_config.attrition_shock_shape) /
                    sim_config.attrition_shock_shape
                day_h = base_h * shock
                for i = 1:n_riders
                    if !abandoned[i] && rand(rng) < day_h * class_mult[i]
                        abandoned[i] = true
                    end
                end
            end

            # Stage-finish noisy strengths + GC accumulation. Total per-stage
            # performance variance decomposes into two distinct pieces:
            #   epistemic  = α·σ_i·rider_noise_i  — persistent ability wobble,
            #                correlated across all stages (a rider "secretly a
            #                bit better all tour"); scales with posterior σ.
            #   aleatoric  = a_stage·stage_noise_i — independent race-day scatter,
            #                a FLAT per-stage-type scale (a_type, fitted by A1b),
            #                NOT scaled by σ. This is what de-saturates the
            #                stage-finish floor: even a low-uncertainty sprinter
            #                gets real day-to-day placing variance.
            # a_type is drawn fat-tailed (Student-t, `sim_config.aleatoric_df`,
            # default 5) to capture crashes / breakaways / echelons — a distinct
            # noise source from the Gaussian epistemic wobble, hence its own tail
            # rather than the global `simulation_df`. SD contribution ≈ a_stage·√(df/(df-2)).
            #
            # The aleatoric term feeds cumulative GC too ("a good day gains time"),
            # but ONLY in proportion to how much the stage separates GC. On a flat
            # bunch-sprint stage the whole peloton records the same GC time, so
            # finishing 2nd vs 60th must not move GC — otherwise ~8 flat stages
            # inject the largest source of spurious GC volatility from the days
            # GC separates least. `gc_sep` = mountain + ITT weight (summit finishes
            # already reallocate hilly→mountain), so flat/rolling days contribute
            # ~no aleatoric GC time while mountains/ITTs contribute the full amount.
            # The epistemic term (persistent ability) still feeds GC everywhere.
            a_stage = _aleatoric_sd(w, sim_config.aleatoric_noise)
            gc_sep = clamp(w.mountain + w.itt, 0.0, 1.0)
            for i = 1:n_riders
                stage_noise[i] = _rand_t(rng, sim_config.aleatoric_df)
                if abandoned[i]
                    # Frozen out: last in every ranking, no further GC time.
                    noisy[i] = -Inf
                    cumulative_gc_score[i] = -Inf
                    continue
                end
                epistemic = uncertainties[i] * alpha * rider_noise[i]
                aleatoric = a_stage * stage_noise[i]
                noisy[i] = strengths_blend[i] + epistemic + aleatoric
                cumulative_gc_score[i] += gc_strengths[i] + epistemic + gc_sep * aleatoric
            end

            # Stage-finish breakaway noise (decoupled from GC).
            br_finish_sd = _breakaway_sd(:stage_finish, w, sim_config.breakaway_noise)
            if br_finish_sd > 0.0
                for i = 1:n_riders
                    noisy[i] += br_finish_sd * randn(rng)
                end
            end

            # Discrete breakaway event (rider-targeted, data-informed — see
            # `_draw_breakaway!` above). No-op and RNG-inert when
            # `breakaway_rates` is empty (the default).
            _draw_breakaway!(
                in_break,
                noisy,
                breakaway_rates,
                sim_config.breakaway_stage_boost,
                stype,
                abandoned,
                n_riders,
                rng,
            )

            # Rank by noisy stage strength → positions, record podium/top-10.
            # A team time trial is scored as a ranking of teams: every rider
            # shares their squad's placing.
            order = sortperm(noisy, rev = true)
            if stype == :ttt
                _assign_team_positions!(positions, noisy, teams, abandoned, n_riders)
            else
                for (pos, rider_idx) in enumerate(order)
                    positions[rider_idx] = pos
                end
            end
            for i = 1:n_riders
                # Abandoned riders inherit their team's placing on a TTT, so
                # exclude them here or a top-3 team would credit its abandoned
                # members with a stage podium in the diagnostics.
                abandoned[i] && continue
                p = positions[i]
                if p <= 3
                    diag_stage_finish[stage_idx, i, p] += 1
                end
                if p <= 10
                    diag_stage_top10[stage_idx, i] += 1
                end
            end

            if stype == :ttt
                _score_ttt_team!(stage_pts, positions, scoring, n_riders)
            else
                _score_stage_finish_and_assists!(
                    stage_pts,
                    positions,
                    teams,
                    scoring,
                    stype,
                    n_riders,
                )
            end

            # Flat breakaway bonus (unconditional on finish position). Must
            # run after the fill! above, and is a no-op whenever `in_break` is
            # all-false (flat/itt/ttt stages, or breakaway modelling disabled).
            _score_breakaway_bonus!(stage_pts, in_break, scoring.breakaway_points, n_riders)

            # Cumulative GC ranking after this stage.
            gc_order = sortperm(cumulative_gc_score, rev = true)
            for (gc_pos, rider_idx) in enumerate(gc_order)
                gc_positions[rider_idx] = gc_pos
            end

            _score_daily_gc_and_assists!(
                stage_pts,
                gc_positions,
                teams,
                scoring,
                stype,
                n_riders,
            )
            _score_points_jersey_stage!(
                points_jersey_total,
                noisy,
                order,
                w,
                stype,
                n_riders,
                rng,
                sim_config,
            )

            _score_daily_mountains!(
                stage_pts,
                kom_total,
                kom_s,
                noisy,
                strengths_blend,
                kom_str,
                scoring,
                stype,
                n_riders,
            )

            _score_intermediate_sprint!(
                points_jersey_total,
                stage_strengths,
                strengths_blend,
                uncertainties,
                alpha,
                a_stage,
                rider_noise,
                stage_noise,
                stype,
                n_riders,
                sim_config.intermediate_sprint_points,
                abandoned,
            )

            # Abandoned riders are frozen out of every per-stage event: their
            # finish/GC positions are already last (noisy = -Inf), but the
            # teammate-assist loops still credit them, so skip accumulation
            # entirely once they have left the race. Points banked on earlier
            # stages remain in rider_total_pts.
            for i = 1:n_riders
                abandoned[i] || (rider_total_pts[i] += stage_pts[i])
            end
        end

        # --- Final classification bonuses ---
        # Abandoned riders are not classified: freeze them out of the final
        # points and mountains rankings (final GC/team already exclude them via
        # their -Inf cumulative GC score). Points earned before abandoning stand.
        for i = 1:n_riders
            if abandoned[i]
                points_jersey_total[i] = -Inf
                kom_total[i] = -Inf
            end
        end

        # Final GC
        for i = 1:n_riders
            rider_total_pts[i] += final_gc_points_for_position(gc_positions[i], scoring)
            if gc_positions[i] <= diag_gc_top
                diag_gc_pos[i, gc_positions[i]] += 1
            end
        end

        # Final points classification (Tipo A/B/C-weighted points-jersey total)
        sprint_order = sortperm(points_jersey_total, rev = true)
        for rank = 1:min(length(scoring.final_points_class), n_riders)
            rider_idx = sprint_order[rank]
            if points_jersey_total[rider_idx] > 0
                rider_total_pts[rider_idx] += scoring.final_points_class[rank]
                if rank <= diag_points_top
                    diag_points_pos[rider_idx, rank] += 1
                end
            end
        end

        # Final mountains classification: ranked by cumulative daily-KOM points
        # (driven by kom_s across hilly AND mountain stages, same stage set and
        # strength dimension as the daily competition).
        kom_order = sortperm(kom_total, rev = true)
        for rank = 1:min(length(scoring.final_mountains_class), n_riders)
            rider_idx = kom_order[rank]
            if kom_total[rider_idx] > 0
                rider_total_pts[rider_idx] += scoring.final_mountains_class[rank]
                if rank <= diag_mountains_top
                    diag_mountains_pos[rider_idx, rank] += 1
                end
            end
        end

        # Final team classification (sum of top-3 cumulative GC scores per team)
        team_set = unique(teams)
        team_cum_scores = Dict{String,Float64}()
        for t in team_set
            team_idx = findall(==(t), teams)
            sorted_cum = sort(cumulative_gc_score[team_idx], rev = true)
            team_cum_scores[t] = sum(sorted_cum[1:min(3, length(sorted_cum))])
        end
        team_ranking = sort(collect(team_cum_scores), by = x -> x.second, rev = true)
        for rank = 1:min(length(scoring.final_team_class), length(team_ranking))
            t = team_ranking[rank].first
            for i = 1:n_riders
                if teams[i] == t
                    rider_total_pts[i] += scoring.final_team_class[rank]
                end
            end
            if rank <= diag_team_top
                diag_team_pos[t][rank] += 1
            end
        end

        for i = 1:n_riders
            sim_vg_points[i, sim] = rider_total_pts[i]
        end
    end

    diagnostics = StageRaceDiagnostics(
        n_sims,
        diag_stage_finish,
        diag_stage_top10,
        diag_gc_pos,
        diag_points_pos,
        diag_mountains_pos,
        diag_team_pos,
    )
    return sim_vg_points, diagnostics
end


# ---------------------------------------------------------------------------
# Class-aware strength estimation for stage races
# ---------------------------------------------------------------------------
# Stage-race per-stage strength projection
# ---------------------------------------------------------------------------

"""
    compute_stage_strengths(rider_df) -> Dict{Symbol, Vector{Float64}}

Project the multi-dimensional strength posterior onto per-stage-type strength
vectors used by `simulate_stage_race`. Each stage type maps directly to its
dimension column (`:flat → strength_flat`, etc.); `:ttt` reuses `:itt`.

`rider_df` must already carry `strength_flat`, `strength_hilly`,
`strength_mountain`, `strength_itt` columns produced by the multidim path of
`estimate_strengths(... ; race_type=:stage)`.
"""
function compute_stage_strengths(rider_df::DataFrame)
    result = Dict{Symbol,Vector{Float64}}()
    for dsym in (:flat, :hilly, :mountain, :itt)
        result[dsym] = Float64.(rider_df[!, Symbol("strength_$dsym")])
    end
    result[:ttt] = copy(result[:itt])
    # :kom drives the daily mountains-classification scoring only (not the
    # finish-position blend). Fall back to :mountain if the column is absent
    # (synthetic test inputs / one-day-derived frames).
    result[:kom] =
        :strength_kom in propertynames(rider_df) ? Float64.(rider_df[!, :strength_kom]) :
        copy(result[:mountain])
    return result
end
