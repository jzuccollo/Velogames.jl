# =========================================================================
# Stage race simulation pipeline
# =========================================================================

@testset "StageProfile constructors" begin
    f = flat_stage(1)
    @test f.stage_type == :flat
    @test f.stage_number == 1
    @test f.n_hc_climbs == 0

    m = mountain_stage(5; hc = 2, cat1 = 1, summit = true)
    @test m.stage_type == :mountain
    @test m.n_hc_climbs == 2
    @test m.n_cat1_climbs == 1
    @test m.is_summit_finish == true

    h = hilly_stage(3)
    @test h.stage_type == :hilly

    t = itt_stage(10)
    @test t.stage_type == :itt
end

@testset "stage_dimension_weights continuous blending" begin
    # Pure ITT
    itt = StageProfile(10, :itt, 42.0, 5, 105, 0.0, 0, 0, 0, false)
    w = stage_dimension_weights(itt)
    @test w.itt == 1.0
    @test w.flat == 0.0 && w.hilly == 0.0 && w.mountain == 0.0

    # Low-PS stage classified hilly is mostly flat (sprinters compete).
    # Real example: Giro 2026 stage 6 — 680m vert, PS=14.
    mild_hilly = StageProfile(6, :hilly, 141.0, 14, 680, 0.0, 0, 0, 1, false)
    w = stage_dimension_weights(mild_hilly)
    @test w.flat == 1.0
    @test w.hilly == 0.0
    @test w.mountain == 0.0

    # Mid-PS hilly with summit finish (PS=152) blends toward mountain.
    hard_hilly = StageProfile(8, :hilly, 156.0, 152, 1804, 5.0, 0, 0, 1, true)
    w = stage_dimension_weights(hard_hilly)
    @test w.flat == 0.0
    @test w.mountain > w.hilly  # summit finish pushes past midpoint

    # High-PS mountain stage is fully mountain.
    big_mtn = StageProfile(14, :mountain, 133.0, 381, 4209, 7.0, 1, 1, 0, true)
    w = stage_dimension_weights(big_mtn)
    @test w.mountain == 1.0
    @test w.flat == 0.0 && w.hilly == 0.0

    # Weights always sum to 1
    for s in (mild_hilly, hard_hilly, big_mtn, itt)
        w = stage_dimension_weights(s)
        @test isapprox(w.flat + w.hilly + w.mountain + w.itt, 1.0; atol = 1e-9)
    end

    # Fallback when profile_score is missing/0: discrete stage_type lookup.
    no_ps = StageProfile(1, :hilly, 180.0, 0, 1500, 0.0, 0, 0, 1, false)
    w = stage_dimension_weights(no_ps)
    @test w.hilly == 1.0
end

@testset "StageRaceScoringTable helpers" begin
    scoring = SCORING_GRAND_TOUR

    # Stage finish points
    @test stage_finish_points_for_position(1, scoring) == 220
    @test stage_finish_points_for_position(20, scoring) == 4
    @test stage_finish_points_for_position(21, scoring) == 0
    @test stage_finish_points_for_position(0, scoring) == 0

    # Daily GC points
    @test daily_gc_points_for_position(1, scoring) == 30
    @test daily_gc_points_for_position(20, scoring) == 1
    @test daily_gc_points_for_position(21, scoring) == 0

    # Final GC points
    @test final_gc_points_for_position(1, scoring) == 600
    @test final_gc_points_for_position(30, scoring) == 5
    @test final_gc_points_for_position(31, scoring) == 0

    # Scoring table field lengths
    @test length(scoring.stage_finish_points) == 20
    @test length(scoring.daily_gc_points) == 20
    @test length(scoring.final_gc_points) == 30
    @test length(scoring.final_team_class) == 5
    @test length(scoring.final_points_class) == 10
    @test length(scoring.final_mountains_class) == 10
    @test length(scoring.stage_assist_points) == 3
    @test length(scoring.gc_assist_points) == 3
    @test length(scoring.team_class_assist_points) == 3
end

# =========================================================================
# Multi-dimensional strength estimation (stage races)
# =========================================================================

@testset "estimate_strengths multidim per-dimension shapes" begin
    rider_df = DataFrame(
        rider = ["GC Star", "Sprinter", "Climber", "Rouleur", "TT Spec"],
        riderkey = ["gc", "sprint", "climb", "rouleur", "ttspec"],
        team = ["A", "B", "C", "D", "E"],
        cost = [20, 16, 18, 10, 14],
        classraw = ["All Rounder", "Sprinter", "Climber", "Unclassed", "All Rounder"],
        points = [1500.0, 1200.0, 800.0, 400.0, 600.0],
        gc = [2000.0, 200.0, 800.0, 600.0, 1200.0],
        tt = [1500.0, 300.0, 400.0, 500.0, 2000.0],
        sprint = [300.0, 2000.0, 100.0, 400.0, 200.0],
        climber = [1200.0, 100.0, 2000.0, 300.0, 500.0],
        oneday = [1800.0, 800.0, 600.0, 700.0, 1000.0],
        has_pcs_data = [true, true, true, true, true],
    )

    result = estimate_strengths(rider_df; race_type = :stage)

    # All per-dim columns are present
    for dsym in (:flat, :hilly, :mountain, :itt, :gc)
        @test Symbol("strength_$dsym") in propertynames(result)
        @test Symbol("uncertainty_$dsym") in propertynames(result)
    end

    # Back-compat: scalar :strength == :strength_gc
    @test result.strength == result.strength_gc
    @test result.uncertainty == result.uncertainty_gc

    # Sprinter (rider 2): higher flat strength than mountain
    @test result.strength_flat[2] > result.strength_mountain[2]

    # Climber (rider 3): higher mountain strength than flat
    @test result.strength_mountain[3] > result.strength_flat[3]

    # TT specialist (rider 5): higher ITT strength than flat
    @test result.strength_itt[5] > result.strength_flat[5]
end

@testset "Pedersen-shaped sprinter sanity check" begin
    # Top sprinter, low GC PCS, no oracle/odds data — should NOT be penalised
    # on :flat by the GC oracle floor (the architectural fix in Phase 1).
    n_riders = 20
    rider_df = DataFrame(
        rider = ["Pedersen-shape"; ["Filler $i" for i = 1:(n_riders-1)]],
        riderkey = ["pedersen"; ["filler$i" for i = 1:(n_riders-1)]],
        team = ["TeamA"; fill("Other", n_riders-1)],
        cost = [20; fill(8, n_riders-1)],
        classraw = ["Sprinter"; fill("Unclassed", n_riders-1)],
        points = [2500.0; fill(500.0, n_riders-1)],
        gc = [200.0; fill(400.0, n_riders-1)],
        tt = [300.0; fill(400.0, n_riders-1)],
        sprint = [3500.0; fill(200.0, n_riders-1)],
        climber = [100.0; fill(300.0, n_riders-1)],
        oneday = [2500.0; fill(500.0, n_riders-1)],
        has_pcs_data = fill(true, n_riders),
    )

    # Synthetic GC oracle covering only 3 GC contenders (none of them Pedersen)
    oracle_df = DataFrame(
        rider = ["GC Contender 1", "GC Contender 2", "GC Contender 3"],
        riderkey = ["filler1", "filler2", "filler3"],
        win_prob = [0.30, 0.20, 0.15],
    )

    result = estimate_strengths(rider_df; oracle_df = oracle_df, race_type = :stage)

    # Pedersen-shape: strong flat, weak GC
    @test result.strength_flat[1] > 1.0
    @test result.strength_gc[1] < result.strength_flat[1]

    # The Oracle floor pushed his GC dimension down — but only GC, not flat
    @test result.strength_flat[1] > result.strength_gc[1] + 0.5

    # On the flat dimension, Pedersen-shape outranks the field (top 10%)
    flat_rank = sum(result.strength_flat .> result.strength_flat[1]) + 1
    @test flat_rank <= max(2, div(n_riders, 10))
end

# =========================================================================
# Full stage race simulation
# =========================================================================

@testset "simulate_stage_race" begin
    rng = Random.MersenneTwister(42)
    n_riders = 10
    n_sims = 200
    scoring = SCORING_GRAND_TOUR

    # Build stage profiles: a small 3-stage race
    stages = [flat_stage(1), mountain_stage(2), itt_stage(3)]

    # Create synthetic stage strengths
    base = collect(range(2.0, -2.0, length = n_riders))
    stage_strengths = Dict{Symbol,Vector{Float64}}(
        :flat => base .+ 0.3 .* randn(rng, n_riders),
        :hilly => base .+ 0.3 .* randn(rng, n_riders),
        :mountain => base .+ 0.3 .* randn(rng, n_riders),
        :itt => base .+ 0.3 .* randn(rng, n_riders),
        :ttt => base .+ 0.3 .* randn(rng, n_riders),
    )
    uncertainties = fill(0.5, n_riders)
    teams = repeat(["TeamA", "TeamB", "TeamC", "TeamD", "TeamE"], 2)

    rng2 = Random.MersenneTwister(123)
    sim, _diag = simulate_stage_race(
        stages,
        stage_strengths,
        uncertainties,
        teams,
        scoring;
        n_sims = n_sims,
        cross_stage_alpha = 0.7,
        rng = rng2,
    )

    # Correct output dimensions
    @test size(sim) == (n_riders, n_sims)

    # All points are non-negative
    @test all(sim .>= 0.0)

    # Stronger riders should average more points
    mean_pts = vec(mean(sim, dims = 2))
    @test mean_pts[1] > mean_pts[n_riders]

    # At least some riders score non-zero in every simulation
    @test all(sum(sim, dims = 1) .> 0)

    # Same-seed bit-identity: seeded reproducibility is load-bearing (gate
    # results, cross-check, archived comparisons) — pin it explicitly.
    sim_repeat, _ = simulate_stage_race(
        stages,
        stage_strengths,
        uncertainties,
        teams,
        scoring;
        n_sims = n_sims,
        cross_stage_alpha = 0.7,
        rng = Random.MersenneTwister(123),
    )
    @test sim == sim_repeat

    # Total points per sim should be reasonable (stage finish + GC + assists + finals)
    # Each stage awards at least positions 1-20 worth of points
    total_per_sim = vec(sum(sim, dims = 1))
    @test all(total_per_sim .> 0)
end

@testset "simulate_stage_race scoring components" begin
    # Deterministic test: very strong rider 1 should win stages and GC
    rng = Random.MersenneTwister(99)
    n_riders = 5
    scoring = SCORING_GRAND_TOUR
    stages = [flat_stage(1), mountain_stage(2)]

    # Rider 1 is dominant across all stage types
    stage_strengths = Dict{Symbol,Vector{Float64}}(
        :flat => [5.0, 0.0, -0.5, -1.0, -2.0],
        :mountain => [5.0, 0.0, -0.5, -1.0, -2.0],
        :itt => [5.0, 0.0, -0.5, -1.0, -2.0],
        :hilly => [5.0, 0.0, -0.5, -1.0, -2.0],
        :ttt => [5.0, 0.0, -0.5, -1.0, -2.0],
    )
    uncertainties = fill(0.3, n_riders)  # low uncertainty for determinism
    teams = ["A", "A", "B", "B", "C"]

    sim, _diag = simulate_stage_race(
        stages,
        stage_strengths,
        uncertainties,
        teams,
        scoring;
        n_sims = 500,
        rng = rng,
    )

    mean_pts = vec(mean(sim, dims = 2))

    # Rider 1 should dominate
    @test mean_pts[1] > mean_pts[2]
    @test mean_pts[1] > mean_pts[5]

    # Rider 2 (teammate of rider 1) should get assist points
    # Rider 2's mean should be noticeably above rider 3 (similar strength, different team)
    @test mean_pts[2] > mean_pts[3]

    # Final GC bonus (600 pts for winner) means rider 1 gets substantially more than
    # just stage finishes (220 per stage win × 2 = 440)
    @test mean_pts[1] > 440 + 600  # stage wins + GC win minimum
end

@testset "simulate_stage_race final team classification uses correct scoring" begin
    # Regression test: team classification should use final_team_class (5 positions)
    # not team_class_assist_points (3 positions)
    rng = Random.MersenneTwister(42)
    scoring = SCORING_GRAND_TOUR
    stages = [flat_stage(1)]
    n_riders = 15

    # 5 distinct teams, 3 riders each
    stage_strengths = Dict{Symbol,Vector{Float64}}(
        :flat => collect(range(3.0, -3.0, length = n_riders)),
        :hilly => collect(range(3.0, -3.0, length = n_riders)),
        :mountain => collect(range(3.0, -3.0, length = n_riders)),
        :itt => collect(range(3.0, -3.0, length = n_riders)),
        :ttt => collect(range(3.0, -3.0, length = n_riders)),
    )
    uncertainties = fill(0.01, n_riders)  # near-deterministic
    teams = repeat(["T1", "T2", "T3", "T4", "T5"], 3)

    sim, _diag = simulate_stage_race(
        stages,
        stage_strengths,
        uncertainties,
        teams,
        scoring;
        n_sims = 100,
        rng = rng,
    )

    # With near-zero uncertainty, the team ranking is deterministic.
    # All teams should receive some classification points (final_team_class has 5 positions).
    # Before the fix, teams ranked 4th and 5th would get team_class_assist_points[3] = 2
    # instead of final_team_class[4] = 20 and final_team_class[5] = 10.
    team_totals = Dict{String,Float64}()
    mean_pts = vec(mean(sim, dims = 2))
    for (i, t) in enumerate(teams)
        team_totals[t] = get(team_totals, t, 0.0) + mean_pts[i]
    end

    # All 5 teams should have non-zero total points
    for t in ["T1", "T2", "T3", "T4", "T5"]
        @test team_totals[t] > 0
    end
end

@testset "simulate_stage_race ITT skips assists" begin
    # On ITT stages, no stage assist or GC assist points should be awarded
    rng = Random.MersenneTwister(42)
    scoring = SCORING_GRAND_TOUR
    stages = [itt_stage(1)]
    n_riders = 4

    stage_strengths = Dict{Symbol,Vector{Float64}}(
        :flat => [3.0, 1.0, -1.0, -3.0],
        :hilly => [3.0, 1.0, -1.0, -3.0],
        :mountain => [3.0, 1.0, -1.0, -3.0],
        :itt => [3.0, 1.0, -1.0, -3.0],
        :ttt => [3.0, 1.0, -1.0, -3.0],
    )
    uncertainties = fill(0.01, n_riders)
    # All same team — would get lots of assists on non-ITT stages
    teams = ["A", "A", "A", "A"]

    sim_itt, _diag_itt = simulate_stage_race(
        stages,
        stage_strengths,
        uncertainties,
        teams,
        scoring;
        n_sims = 100,
        rng = rng,
    )

    # Compare with flat stage (same strengths, but assists should apply)
    rng2 = Random.MersenneTwister(42)
    stages_flat = [flat_stage(1)]
    sim_flat, _diag_flat = simulate_stage_race(
        stages_flat,
        stage_strengths,
        uncertainties,
        teams,
        scoring;
        n_sims = 100,
        rng = rng2,
    )

    # Teammates (riders 2-4) should score more on flat (with assists) than ITT
    # (Rider 1 wins both, but teammates only get assists on flat)
    mean_itt = vec(mean(sim_itt, dims = 2))
    mean_flat = vec(mean(sim_flat, dims = 2))

    # Riders 2-4 are teammates of the winner; they get assist on flat but not ITT
    @test mean_flat[2] > mean_itt[2]
    @test mean_flat[3] > mean_itt[3]
    @test mean_flat[4] > mean_itt[4]
end

@testset "simulate_stage_race cross_stage_alpha" begin
    # Different alpha values should produce different simulation results
    scoring = SCORING_GRAND_TOUR
    stages = [flat_stage(1), mountain_stage(2), hilly_stage(3)]
    n_riders = 8

    base = collect(range(2.0, -2.0, length = n_riders))
    stage_strengths = Dict{Symbol,Vector{Float64}}(
        :flat => copy(base),
        :hilly => copy(base),
        :mountain => copy(base),
        :itt => copy(base),
        :ttt => copy(base),
    )
    uncertainties = fill(1.0, n_riders)
    teams = repeat(["A", "B", "C", "D"], 2)

    rng1 = Random.MersenneTwister(42)
    sim_high, _diag_high = simulate_stage_race(
        stages,
        stage_strengths,
        uncertainties,
        teams,
        scoring;
        n_sims = 500,
        cross_stage_alpha = 0.95,
        rng = rng1,
    )

    rng2 = Random.MersenneTwister(42)
    sim_low, _diag_low = simulate_stage_race(
        stages,
        stage_strengths,
        uncertainties,
        teams,
        scoring;
        n_sims = 500,
        cross_stage_alpha = 0.1,
        rng = rng2,
    )

    # Different alpha values should produce different point distributions
    mean_high = vec(mean(sim_high, dims = 2))
    mean_low = vec(mean(sim_low, dims = 2))
    @test !all(isapprox.(mean_high, mean_low; atol = 1.0))

    # Both should still have correct output shape and non-negative values
    @test size(sim_high) == (n_riders, 500)
    @test size(sim_low) == (n_riders, 500)
    @test all(sim_high .>= 0) && all(sim_low .>= 0)
end

# =========================================================================
# resample_optimise_stage!
# =========================================================================

@testset "resample_optimise_stage!" begin
    rng = Random.MersenneTwister(42)
    n_riders = 20
    scoring = SCORING_GRAND_TOUR
    stages = [flat_stage(1), mountain_stage(2), itt_stage(3)]

    # Build a rider DataFrame with classification columns
    rider_df = DataFrame(
        rider = ["R$i" for i = 1:n_riders],
        riderkey = ["r$i" for i = 1:n_riders],
        team = repeat(["A", "B", "C", "D"], 5),
        cost = repeat([15, 12, 10, 8, 5], 4),
        classraw = repeat(
            [
                "All Rounder",
                "All Rounder",
                "Climber",
                "Climber",
                "Climber",
                "Sprinter",
                "Sprinter",
                "Unclassed",
                "Unclassed",
                "Unclassed",
            ],
            2,
        ),
        strength = Float64.(repeat([2.0, 1.5, 1.2, 0.8, 0.4], 4)),
        uncertainty = fill(0.5, n_riders),
    )

    # Create stage strengths
    base = Float64.(rider_df.strength)
    stage_strengths = Dict{Symbol,Vector{Float64}}(
        :flat => base .+ 0.1,
        :hilly => copy(base),
        :mountain => base .- 0.1,
        :itt => base .+ 0.05,
        :ttt => base .+ 0.05,
    )

    result_df, top_teams, sim_vg_pts, _diag = resample_optimise_stage!(
        rider_df,
        stages,
        stage_strengths,
        scoring,
        build_model_stage;
        team_size = 9,
        n_resamples = 50,
        rng = rng,
        risk_aversion = 0.5,
    )

    # Output columns are present
    @test :selection_frequency in propertynames(result_df)
    @test :expected_vg_points in propertynames(result_df)
    @test :downside_semi_dev in propertynames(result_df)

    # Correct dimensions
    @test nrow(result_df) == n_riders
    @test size(sim_vg_pts) == (n_riders, 50)

    # Selection frequencies are valid probabilities
    @test all(0.0 .<= result_df.selection_frequency .<= 1.0)

    # Expected points are non-negative
    @test all(result_df.expected_vg_points .>= 0.0)
    @test all(result_df.downside_semi_dev .>= 0.0)

    # At least one top team was found
    @test !isempty(top_teams)

    # Top team has 9 riders and cost <= 100
    if !isempty(top_teams)
        @test nrow(top_teams[1]) == 9
        @test sum(top_teams[1].cost) <= 100
    end

    # Working column cleaned up
    @test :_final_pts ∉ propertynames(result_df)

    # Simulation matrix has non-negative values
    @test all(sim_vg_pts .>= 0.0)
end

# =========================================================================
# Helpers extracted in May 2026 cleanup
# =========================================================================

@testset "StageSimConfig breakaway noise + _breakaway_sd" begin
    bn = Velogames.DEFAULT_STAGE_SIM_CONFIG.breakaway_noise
    # Default breakaway σ — pin them so refactors don't silently change scoring
    @test bn.stage_finish.flat == 0.0
    @test bn.stage_finish.hilly == 1.0
    @test bn.stage_finish.mountain == 1.5
    @test bn.points_jersey.flat == 0.0
    @test bn.points_jersey.hilly == 1.5
    @test bn.points_jersey.mountain == 2.5

    # Pure flat stage gets zero breakaway noise on both events
    flat_w = (flat = 1.0, hilly = 0.0, mountain = 0.0, itt = 0.0)
    @test Velogames._breakaway_sd(:stage_finish, flat_w, bn) == 0.0
    @test Velogames._breakaway_sd(:points_jersey, flat_w, bn) == 0.0

    # Pure mountain stage gets the full mountain σ
    mtn_w = (flat = 0.0, hilly = 0.0, mountain = 1.0, itt = 0.0)
    @test Velogames._breakaway_sd(:stage_finish, mtn_w, bn) == 1.5
    @test Velogames._breakaway_sd(:points_jersey, mtn_w, bn) == 2.5

    # Aleatoric scale blends per-dimension a_type by stage weights
    an = Velogames.DEFAULT_STAGE_SIM_CONFIG.aleatoric_noise
    @test Velogames._aleatoric_sd(flat_w, an) == an.flat
    @test Velogames._aleatoric_sd(mtn_w, an) == an.mountain

    # Intermediate-sprint pin (WP1.2, decision D3): the vector is awarded as-is;
    # the old runtime 0.5x multiplier is folded into these defaults (half the
    # published VG 20/12/8/6/4/2/1). Changing either without the other is a
    # silent 2x scoring change.
    @test Velogames.DEFAULT_STAGE_SIM_CONFIG.intermediate_sprint_points ==
          [10.0, 6.0, 4.0, 3.0, 2.0, 1.0, 0.5]
end

# =========================================================================
# GT VG-history signal (Option A prototype, July 2026 — roadmap.md
# "GT VG-history strength signal")
# =========================================================================

@testset "GT VG-history signal: lifts break-hunter, clamps leader, inert off" begin
    rider_df = DataFrame(
        rider = ["Star", "Breaker", "Neutral"],
        riderkey = ["star", "breaker", "neutral"],
        team = ["A", "B", "C"],
        cost = [20, 4, 8],
        classraw = ["Climber", "Unclassed", "Unclassed"],
        points = [1500.0, 100.0, 400.0],
        gc = [2000.0, 100.0, 500.0],
        tt = [1000.0, 100.0, 400.0],
        sprint = [200.0, 150.0, 300.0],
        climber = [2000.0, 120.0, 400.0],
        oneday = [1500.0, 200.0, 600.0],
        has_pcs_data = [true, true, true],
    )
    # One prior edition. Breaker posted a huge VG total (break-hunter role);
    # Star a modest one (his ability far exceeds it); f1-f3 shape the within-year
    # z-score distribution. Star and the filler riders sit BELOW Star's ability
    # estimate, Breaker's z sits ABOVE Breaker's (weak) ability estimate.
    gt = DataFrame(
        riderkey = ["breaker", "star", "f1", "f2", "f3"],
        score = [1500, 250, 300, 150, 80],
        year = [2025, 2025, 2025, 2025, 2025],
    )

    off = estimate_strengths(rider_df; race_type = :stage, race_year = 2026)
    on = estimate_strengths(
        rider_df;
        race_type = :stage,
        race_year = 2026,
        gt_vg_history_df = gt,
    )

    bi = findfirst(==("breaker"), on.riderkey)
    si = findfirst(==("star"), on.riderkey)
    ni = findfirst(==("neutral"), on.riderkey)

    # Break-hunter's mountain/hilly strength lifted upward by their strong GT history
    @test on.strength_mountain[bi] > off.strength_mountain[bi]
    @test on.strength_hilly[bi] > off.strength_hilly[bi]
    # Upward-only clamp: the strong climber, whose mountain estimate already exceeds
    # his (low) GT-history z, is untouched — the leader do-no-harm guarantee.
    @test on.strength_mountain[si] ≈ off.strength_mountain[si]
    # Rider absent from GT history keeps the prior unchanged (do-no-harm).
    @test on.strength_mountain[ni] ≈ off.strength_mountain[ni]
    # Never routes to :gc, :itt or :flat for anyone.
    @test on.strength_gc ≈ off.strength_gc
    @test on.strength_itt ≈ off.strength_itt
    @test on.strength_flat ≈ off.strength_flat
    # Passing no GT history at all is fully inert.
    @test on.strength_gc == off.strength_gc
end

@testset "GT VG points-propensity factors: two-sided, shrunk, inert off (Option B)" begin
    # p (ability-implied EVG): leader high, break-hunter low, domestique high,
    # debutant moderate. Real prior GT totals invert the roles: the break-hunter
    # out-scores their ability, the domestique under-scores it, the leader matches.
    keys = ["leader", "breaker", "domestique", "debutant"]
    evg_raw = [3000.0, 40.0, 250.0, 150.0]
    gt = DataFrame(
        riderkey = ["leader", "leader", "breaker", "breaker", "domestique"],
        score = [3100, 2900, 300, 280, 70],
        year = [2025, 2024, 2025, 2024, 2025],
    )

    f = gt_propensity_factors(keys, evg_raw, gt, 2026)

    # Break-hunter scored far above ability ⇒ positive factor (EVG raised).
    @test f[2] > 0.2
    # Locked domestique scored far below ability ⇒ negative factor (EVG lowered).
    # This is the two-sided correction Option A structurally cannot deliver.
    @test f[3] < -0.1
    # Leader's real ≈ predicted ⇒ factor ≈ 0 (do-no-harm on leaders).
    @test abs(f[1]) < 0.1
    # Debutant absent from GT history ⇒ factor exactly 0 (unchanged).
    @test f[4] == 0.0

    # Shrinkage: the two-edition break-hunter keeps more of its raw ratio than a
    # single-edition version of the same rider (partial pooling grows with data).
    gt1 = DataFrame(riderkey = ["breaker"], score = [300], year = [2025])
    f1 = gt_propensity_factors(["breaker"], [40.0], gt1, 2026)
    f2 = gt_propensity_factors(["breaker"], [40.0], gt, 2026)
    @test f2[1] > f1[1] > 0.0

    # No history at all is fully inert (all factors zero).
    @test all(==(0.0), gt_propensity_factors(keys, evg_raw, nothing, 2026))
end

@testset "daily mountains classification scoring" begin
    scoring = SCORING_GRAND_TOUR
    n = 8
    mountain_s = collect(range(3.0, -3.0, length = n))  # rider 1 = best climber
    noisy = copy(mountain_s)
    blend = copy(mountain_s)                            # noise component = noisy - blend = 0
    kom_str = zeros(n)

    # Mountain stage: top climbers bank daily_mountains_class points, and the
    # same points accrue into the cumulative kom_total that decides the final jersey.
    stage_pts = zeros(n)
    kom_total = zeros(n)
    Velogames._score_daily_mountains!(
        stage_pts,
        kom_total,
        mountain_s,
        noisy,
        blend,
        kom_str,
        scoring,
        :mountain,
        n,
    )
    @test stage_pts[1] == scoring.daily_mountains_class[1]        # best climber → top KOM
    @test stage_pts[6] == scoring.daily_mountains_class[6]        # 6th → last scoring slot
    @test stage_pts[7] == 0 && stage_pts[8] == 0                  # outside top 6
    @test kom_total == stage_pts                                  # cumulative tally mirrors daily points

    # Hilly stage also scores (and accumulates); ITT / flat do not.
    stage_pts = zeros(n)
    Velogames._score_daily_mountains!(
        stage_pts,
        kom_total,
        mountain_s,
        noisy,
        blend,
        kom_str,
        scoring,
        :hilly,
        n,
    )
    @test stage_pts[1] == scoring.daily_mountains_class[1]
    @test kom_total[1] == 2 * scoring.daily_mountains_class[1]    # two scoring stages banked
    for st in (:flat, :itt, :ttt)
        stage_pts = zeros(n)
        before = copy(kom_total)
        Velogames._score_daily_mountains!(
            stage_pts,
            kom_total,
            mountain_s,
            noisy,
            blend,
            kom_str,
            scoring,
            st,
            n,
        )
        @test all(stage_pts .== 0)
        @test kom_total == before
    end
end

@testset "final mountains jersey ranked by cumulative daily-KOM points" begin
    # WP1.1 (review defects 1+2): a high-kom_s specialist who finishes mid-pack
    # must beat the GC leader to the final mountains jersey. Under the old
    # mountain-top-5-finish-count proxy the leader (who wins every summit) took
    # the jersey and kom_s never touched it.
    scoring = SCORING_GRAND_TOUR
    stages = [mountain_stage(1), mountain_stage(2), hilly_stage(3)]
    n = 6
    base = [3.0, 0.0, 1.0, 0.5, -1.0, -2.0]    # rider 1 = GC leader, rider 2 mid-pack
    kom = [-1.0, 5.0, 0.0, -0.5, -1.5, -2.0]   # rider 2 = KOM specialist
    stage_strengths = Dict{Symbol,Vector{Float64}}(
        :flat => copy(base),
        :hilly => copy(base),
        :mountain => copy(base),
        :itt => copy(base),
        :ttt => copy(base),
        :kom => kom,
    )
    n_sims = 200
    _, diag = simulate_stage_race(
        stages,
        stage_strengths,
        fill(0.3, n),
        ["A", "B", "C", "D", "E", "F"],
        scoring;
        n_sims = n_sims,
        rng = Random.MersenneTwister(5),
    )

    # Specialist (rider 2) takes the final jersey in a clear majority of sims,
    # and far more often than the GC leader (rider 1).
    @test diag.final_mountains_position_counts[2, 1] > n_sims ÷ 2
    @test diag.final_mountains_position_counts[2, 1] >
          diag.final_mountains_position_counts[1, 1]
end

@testset "simulate_stage_race always returns (matrix, diagnostics)" begin
    # Regression test: with the record_diagnostics kwarg removed, the function
    # must unconditionally return a tuple of the right shapes.
    rng = Random.MersenneTwister(7)
    scoring = SCORING_GRAND_TOUR
    stages = [flat_stage(1), mountain_stage(2)]
    n_riders = 6
    base = collect(range(2.0, -2.0, length = n_riders))
    stage_strengths = Dict{Symbol,Vector{Float64}}(
        :flat => copy(base),
        :hilly => copy(base),
        :mountain => copy(base),
        :itt => copy(base),
        :ttt => copy(base),
    )
    result = simulate_stage_race(
        stages,
        stage_strengths,
        fill(0.5, n_riders),
        repeat(["A", "B"], 3),
        scoring;
        n_sims = 20,
        rng = rng,
    )

    @test result isa Tuple
    @test length(result) == 2
    sim, diag = result
    @test sim isa Matrix{Float64}
    @test size(sim) == (n_riders, 20)
    @test diag isa Velogames.StageRaceDiagnostics
    @test diag.n_sims == 20
    @test size(diag.stage_finish_counts) == (length(stages), n_riders, 3)
end

@testset "format_classification_table returns HTML with rider names" begin
    # Synthetic diagnostics: rider 1 wins GC every time, rider 2 always 2nd.
    n_riders = 5
    n_sims = 100
    diag_gc = zeros(Int, n_riders, 30)
    diag_gc[1, 1] = n_sims  # rider 1 always finishes 1st
    diag_gc[2, 2] = n_sims  # rider 2 always finishes 2nd
    diag = Velogames.StageRaceDiagnostics(
        n_sims,
        zeros(Int, 0, 0, 0),
        zeros(Int, 0, 0),
        diag_gc,
        zeros(Int, n_riders, 10),
        zeros(Int, n_riders, 10),
        Dict{String,Vector{Int}}(),
    )

    riders = DataFrame(
        rider = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"],
        team = ["T1", "T2", "T3", "T4", "T5"],
    )

    html = format_classification_table(diag, :gc, riders)
    @test occursin("Alpha", html)
    @test occursin("Bravo", html)
    # Win % for Alpha and Top-10 % for both are 100. Integer-valued columns render
    # without a trailing ".0" (see round_numeric_columns!), so the cell reads "100".
    @test occursin(">100<", html)

    # Empty case: no riders with non-trivial probability
    empty_diag = Velogames.StageRaceDiagnostics(
        n_sims,
        zeros(Int, 0, 0, 0),
        zeros(Int, 0, 0),
        zeros(Int, n_riders, 30),
        zeros(Int, n_riders, 10),
        zeros(Int, n_riders, 10),
        Dict{String,Vector{Int}}(),
    )
    @test occursin(
        "No riders with non-trivial",
        format_classification_table(empty_diag, :gc, riders),
    )
end

@testset "format_team_classification renders dynamic top-K column" begin
    n_sims = 100
    team_pos = Dict{String,Vector{Int}}(
        "Alpha" => [n_sims, 0, 0, 0, 0],   # always 1st
        "Bravo" => [0, n_sims, 0, 0, 0],   # always 2nd
    )
    diag = Velogames.StageRaceDiagnostics(
        n_sims,
        zeros(Int, 0, 0, 0),
        zeros(Int, 0, 0),
        zeros(Int, 0, 0),
        zeros(Int, 0, 0),
        zeros(Int, 0, 0),
        team_pos,
    )

    html = format_team_classification(diag)
    @test occursin("Alpha", html)
    @test occursin("Top-5 %", html)  # column name reflects 5-position scoring table
    # Alpha's Win % and both teams' Top-5 % are 100; integer-valued columns render
    # without a trailing ".0" (see round_numeric_columns!), so the cell reads "100".
    @test occursin(">100<", html)
end

# =========================================================================
# Review remediation (July 2026): empty scoring tables, market-discount mask,
# per-rider recency fallback.
# =========================================================================

@testset "format_classification_table handles empty scoring table" begin
    # A classification whose VG scoring table is empty (heading unmatched, or the
    # race publishes no such jersey) yields a zero-column position-count matrix;
    # the table renderer must not index column 1 (BoundsError) but degrade.
    n_riders = 3
    riders = DataFrame(rider = ["A", "B", "C"], team = ["T1", "T2", "T3"])
    diag = Velogames.StageRaceDiagnostics(
        100,
        zeros(Int, 0, 0, 0),
        zeros(Int, 0, 0),
        zeros(Int, n_riders, 30),   # gc: populated
        zeros(Int, n_riders, 0),    # points: EMPTY (0 scoring positions)
        zeros(Int, n_riders, 10),   # mountains
        Dict{String,Vector{Int}}(),
    )
    html = format_classification_table(diag, :points, riders)
    @test occursin("No points classification scoring available", html)
end

@testset "market discount threshold keeps KOM sharp" begin
    W = Velogames.SIGNAL_DIMENSION_WEIGHTS
    θ = Velogames.MARKET_DIM_THRESHOLD
    # A GC market materially informs :gc and :mountain (rightly discounted) ...
    @test W.odds_gc.gc >= θ
    @test W.odds_gc.mountain >= θ
    # ... but its incidental cross-routes into :kom and :hilly must stay below θ,
    # so a race carrying only GC odds does NOT discount and collapse the KOM
    # channel field-wide (the regression fixed in July 2026).
    @test W.odds_gc.kom < θ
    @test W.odds_gc.hilly < θ
    @test W.oracle_gc.kom < θ
    # A dedicated KOM market does inform :kom.
    @test W.odds_kom.kom >= θ
    # No market routes to :itt at all ⇒ PCS-TT stays sharp regardless.
    @test W.odds_gc.itt == 0.0 && W.odds_points.itt == 0.0 && W.odds_kom.itt == 0.0
end

@testset "recency per-rider fallback to career specialty" begin
    # Two identical strong climbers; rider B's per-season recency scrape "failed"
    # (climber_r missing). B must fall back to career climber points, not collapse
    # to a spurious zero that would sink its mountain strength below a sprinter's.
    rider_df = DataFrame(
        rider = ["Climber A", "Climber B", "Sprinter"],
        riderkey = ["a", "b", "s"],
        team = ["A", "B", "C"],
        cost = [18, 18, 16],
        classraw = ["Climber", "Climber", "Sprinter"],
        points = [800.0, 800.0, 1200.0],
        gc = [800.0, 800.0, 200.0],
        tt = [400.0, 400.0, 300.0],
        sprint = [100.0, 100.0, 2000.0],
        climber = [2000.0, 2000.0, 100.0],
        oneday = [600.0, 600.0, 800.0],
        has_pcs_data = [true, true, true],
        climber_r = [1500.0, missing, 50.0],   # B's recency scrape failed
    )
    result = estimate_strengths(rider_df; race_type = :stage)
    # B (missing recency, strong career) still out-climbs the sprinter on :mountain.
    @test result.strength_mountain[2] > result.strength_mountain[3]
    # And B reads as a climber (mountain > flat), i.e. not zeroed out.
    @test result.strength_mountain[2] > result.strength_flat[2]
end

@testset "aleatoric GC noise gated to separating stages" begin
    # Race-day scatter feeds cumulative GC only in proportion to how much a stage
    # separates GC. With identical strengths/uncertainty, the favourite should
    # win final GC MORE often over flat stages (gc_sep≈0, no aleatoric GC noise)
    # than over mountain stages (gc_sep≈1, full aleatoric GC time gaps).
    scoring = SCORING_GRAND_TOUR
    n_riders = 8
    base = collect(range(3.0, -3.0, length = n_riders))   # rider 1 is the favourite
    stage_strengths = Dict{Symbol,Vector{Float64}}(
        :flat => copy(base),
        :hilly => copy(base),
        :mountain => copy(base),
        :itt => copy(base),
        :ttt => copy(base),
    )
    unc = fill(1.5, n_riders)                            # large ⇒ noise bites
    teams = ["T$i" for i = 1:n_riders]

    _, diag_flat = simulate_stage_race(
        [flat_stage(i) for i = 1:4],
        stage_strengths,
        unc,
        teams,
        scoring;
        n_sims = 2000,
        rng = Random.MersenneTwister(3),
    )
    _, diag_mtn = simulate_stage_race(
        [mountain_stage(i) for i = 1:4],
        stage_strengths,
        unc,
        teams,
        scoring;
        n_sims = 2000,
        rng = Random.MersenneTwister(3),
    )

    @test diag_flat.final_gc_position_counts[1, 1] > diag_mtn.final_gc_position_counts[1, 1]
end

# =========================================================================
# k-best near-optimal team enumeration (team switcher / filler / forks)
# =========================================================================

# A synthetic stage-race frame with enough riders per class to admit many
# feasible 9-rider teams (2 all-rounder, 1 sprinter, 2 climber, 3 unclassed + 1
# wildcard). Distinct integer EVGs so the k-best ordering is unambiguous.
function _kbest_fixture()
    classes = vcat(
        fill("All Rounder", 5),
        fill("Sprinter", 4),
        fill("Climber", 5),
        fill("Unclassed", 10),
    )
    n = length(classes)
    DataFrame(
        riderkey = ["r$i" for i = 1:n],
        rider = ["Rider $i" for i = 1:n],
        team = repeat(["A", "B", "C", "D", "E", "F"], inner = 4),
        classraw = classes,
        cost = repeat([16, 12, 8, 6], outer = 6),
        expected_vg_points = Float64.(collect(n:-1:1) .* 10),
    )
end

function _honours_stage_constraints(team::DataFrame)
    nrow(team) == 9 || return false
    sum(team.cost) <= 100 || return false
    cls = lowercase.(replace.(team.classraw, " " => ""))
    count(==("allrounder"), cls) >= 2 || return false
    count(==("sprinter"), cls) >= 1 || return false
    count(==("climber"), cls) >= 2 || return false
    count(==("unclassed"), cls) >= 3 || return false
    return true
end

@testset "_kbest_team_keys enumeration" begin
    df = _kbest_fixture()
    key_lists = Velogames._kbest_team_keys(
        df,
        build_model_stage,
        :expected_vg_points;
        team_size = 9,
        max_per_team = 0,
        n_alternatives = 8,
    )

    @test length(key_lists) == 8                      # all requested teams found
    ptmap = Dict(df.riderkey .=> df.expected_vg_points)

    # Distinct rosters (no repeated team)
    rosters = [Set(k) for k in key_lists]
    @test length(unique(rosters)) == length(rosters)

    # Ranked by weakly descending objective (best first)
    objs = [sum(ptmap[k] for k in ks) for ks in key_lists]
    @test issorted(objs, rev = true)
    @test objs[1] > objs[end]                         # genuine spread

    # Every team honours budget + class + team-size constraints
    for ks in key_lists
        team = filter(row -> row.riderkey in Set(ks), df)
        @test _honours_stage_constraints(team)
    end

    # n_alternatives is a hard cap; a smaller request is a prefix of the larger.
    fewer = Velogames._kbest_team_keys(
        df,
        build_model_stage,
        :expected_vg_points;
        team_size = 9,
        max_per_team = 0,
        n_alternatives = 3,
    )
    @test length(fewer) == 3
    @test [Set(k) for k in fewer] == rosters[1:3]
end

@testset "compute_filler_pool + compute_structural_forks" begin
    df = _kbest_fixture()
    key_lists = Velogames._kbest_team_keys(
        df,
        build_model_stage,
        :expected_vg_points;
        team_size = 9,
        max_per_team = 0,
        n_alternatives = 8,
    )
    top_teams = [filter(row -> row.riderkey in Set(ks), df) for ks in key_lists]

    core_df, filler_df, n_teams = compute_filler_pool(top_teams)
    @test n_teams == 8
    # Core riders are in every team; filler riders in some but not all.
    core_keys = Set(core_df.riderkey)
    for t in top_teams
        @test core_keys ⊆ Set(t.riderkey)
    end
    @test all(1 .<= filler_df.frequency .< n_teams)
    @test isempty(intersect(core_keys, Set(filler_df.riderkey)))
    # Core + filler together cover the full union of near-optimal rosters.
    union_keys = reduce(union, [Set(t.riderkey) for t in top_teams])
    @test union_keys == core_keys ∪ Set(filler_df.riderkey)

    forks = compute_structural_forks(
        df,
        build_model_stage;
        team_size = 9,
        max_per_team = 0,
        n_forks = 5,
    )
    @test length(forks.forks) <= 5
    # Dropping any rider from the optimum cannot improve it: delta >= 0.
    @test all(f -> f.delta >= -1e-6, forks.forks)
    # Ranked by descending EVG at stake.
    @test issorted([f.delta for f in forks.forks], rev = true)
    # GC-shape fork is absent here (no :strength_gc column).
    @test forks.shape === nothing
end

@testset "multidim block-correlation discount (WP1.6)" begin
    cfg_on = Velogames.BayesianConfig()
    cfg_off = Velogames.BayesianConfig(multidim_block_correlation = false)
    gc = Velogames._DIM_INDEX[:gc]

    multi = Velogames.RiderSignalData(
        has_pcs = true,
        pcs_gc_z = 1.5,
        pcs_climber_z = 1.2,
        rider_class = "allrounder",
        vg_points = 1.0,
        race_history = [1.0, 0.8],
        race_history_years_ago = [1, 2],
        odds_implied_prob = 0.3,
    )
    est_on = Velogames.estimate_rider_strength_multidim(multi; config = cfg_on)
    est_off = Velogames.estimate_rider_strength_multidim(multi; config = cfg_off)

    # Multi-observation dimensions widen; none narrow.
    @test est_on.variance[gc] > est_off.variance[gc]
    @test all(est_on.variance .>= est_off.variance .- 1e-12)
    # The discount shrinks the posterior mean toward the prior (0), never past it.
    @test 0.0 < est_on.mean[gc] < est_off.mean[gc]

    # A rider with at most one observation per dimension is untouched.
    single = Velogames.RiderSignalData(
        has_pcs = false,
        rider_class = "sprinter",
        vg_points = 1.2,
    )
    s_on = Velogames.estimate_rider_strength_multidim(single; config = cfg_on)
    s_off = Velogames.estimate_rider_strength_multidim(single; config = cfg_off)
    @test s_on.mean == s_off.mean
    @test s_on.variance == s_off.variance

    # skip_block_correlation escape hatch reproduces the flag-off result.
    est_skip = Velogames.estimate_rider_strength_multidim(
        multi;
        config = cfg_on,
        skip_block_correlation = true,
    )
    @test est_skip.mean == est_off.mean
    @test est_skip.variance == est_off.variance
end
