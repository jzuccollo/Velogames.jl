# =========================================================================
# Stage race simulation pipeline
# =========================================================================

@testset "StageProfile constructors" begin
    f = flat_stage(1)
    @test f.stage_type == :flat
    @test f.stage_number == 1
    @test f.n_hc_climbs == 0

    m = mountain_stage(5; hc=2, cat1=1, summit=true)
    @test m.stage_type == :mountain
    @test m.n_hc_climbs == 2
    @test m.n_cat1_climbs == 1
    @test m.is_summit_finish == true

    h = hilly_stage(3)
    @test h.stage_type == :hilly

    t = itt_stage(10)
    @test t.stage_type == :itt
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
# Stage-type strength modifiers
# =========================================================================

@testset "compute_stage_type_modifiers" begin
    rider_df = DataFrame(
        rider=["GC Star", "Sprinter", "Climber", "Rouleur", "TT Spec"],
        riderkey=["gc", "sprint", "climb", "rouleur", "ttspec"],
        team=["A", "B", "C", "D", "E"],
        cost=[20, 16, 18, 10, 14],
        classraw=["All Rounder", "Sprinter", "Climber", "Unclassed", "All Rounder"],
        gc=[2000.0, 200.0, 800.0, 600.0, 1200.0],
        tt=[1500.0, 300.0, 400.0, 500.0, 2000.0],
        sprint=[300.0, 2000.0, 100.0, 400.0, 200.0],
        climber=[1200.0, 100.0, 2000.0, 300.0, 500.0],
        oneday=[1800.0, 800.0, 600.0, 700.0, 1000.0],
        has_pcs_data=[true, true, true, true, true],
    )
    base_strengths = [2.0, 1.0, 1.5, 0.0, 1.2]

    result = compute_stage_type_modifiers(rider_df, base_strengths; modifier_scale=0.5)

    # Returns all five stage types
    @test Set(keys(result)) == Set([:flat, :hilly, :mountain, :itt, :ttt])

    # Each type has correct length
    for stype in [:flat, :hilly, :mountain, :itt, :ttt]
        @test length(result[stype]) == 5
    end

    # TTT copies ITT
    @test result[:ttt] == result[:itt]

    # Sprinter gets mountain penalty (fixed, not PCS-derived)
    # The sprinter's mountain strength should be lower than their base
    @test result[:mountain][2] < base_strengths[2]

    # Climber should be relatively stronger on mountain stages than flat
    climber_mtn_boost = result[:mountain][3] - base_strengths[3]
    climber_flat_boost = result[:flat][3] - base_strengths[3]
    @test climber_mtn_boost > climber_flat_boost

    # TT specialist should be stronger on ITT than flat
    tt_itt_boost = result[:itt][5] - base_strengths[5]
    tt_flat_boost = result[:flat][5] - base_strengths[5]
    @test tt_itt_boost > tt_flat_boost

    # Sprinter should be relatively stronger on flat than mountain
    sprint_flat = result[:flat][2]
    sprint_mtn = result[:mountain][2]
    @test sprint_flat > sprint_mtn
end

@testset "compute_stage_type_modifiers without PCS data" begin
    # Riders without PCS data should get zero modifier (base strength unchanged)
    rider_df = DataFrame(
        rider=["Known", "Unknown"],
        riderkey=["known", "unknown"],
        team=["A", "B"],
        cost=[20, 4],
        classraw=["All Rounder", "Unclassed"],
        gc=[2000.0, 0.0],
        tt=[1500.0, 0.0],
        sprint=[300.0, 0.0],
        climber=[1200.0, 0.0],
        oneday=[1800.0, 0.0],
        has_pcs_data=[true, false],
    )
    base_strengths = [2.0, -1.0]

    result = compute_stage_type_modifiers(rider_df, base_strengths; modifier_scale=0.5)

    # Unknown rider gets base strength for all stage types (no modifier)
    for stype in [:flat, :hilly, :mountain, :itt]
        @test result[stype][2] == base_strengths[2]
    end

    # Known rider gets modified strengths
    @test any(result[stype][1] != base_strengths[1] for stype in [:flat, :hilly, :mountain, :itt])
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
    base = collect(range(2.0, -2.0, length=n_riders))
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
    sim = simulate_stage_race(
        stages, stage_strengths, uncertainties, teams, scoring;
        n_sims=n_sims, cross_stage_alpha=0.7, rng=rng2,
    )

    # Correct output dimensions
    @test size(sim) == (n_riders, n_sims)

    # All points are non-negative
    @test all(sim .>= 0.0)

    # Stronger riders should average more points
    mean_pts = vec(mean(sim, dims=2))
    @test mean_pts[1] > mean_pts[n_riders]

    # At least some riders score non-zero in every simulation
    @test all(sum(sim, dims=1) .> 0)

    # Total points per sim should be reasonable (stage finish + GC + assists + finals)
    # Each stage awards at least positions 1-20 worth of points
    total_per_sim = vec(sum(sim, dims=1))
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

    sim = simulate_stage_race(
        stages, stage_strengths, uncertainties, teams, scoring;
        n_sims=500, rng=rng,
    )

    mean_pts = vec(mean(sim, dims=2))

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
        :flat => collect(range(3.0, -3.0, length=n_riders)),
        :hilly => collect(range(3.0, -3.0, length=n_riders)),
        :mountain => collect(range(3.0, -3.0, length=n_riders)),
        :itt => collect(range(3.0, -3.0, length=n_riders)),
        :ttt => collect(range(3.0, -3.0, length=n_riders)),
    )
    uncertainties = fill(0.01, n_riders)  # near-deterministic
    teams = repeat(["T1", "T2", "T3", "T4", "T5"], 3)

    sim = simulate_stage_race(
        stages, stage_strengths, uncertainties, teams, scoring;
        n_sims=100, rng=rng,
    )

    # With near-zero uncertainty, the team ranking is deterministic.
    # All teams should receive some classification points (final_team_class has 5 positions).
    # Before the fix, teams ranked 4th and 5th would get team_class_assist_points[3] = 2
    # instead of final_team_class[4] = 20 and final_team_class[5] = 10.
    team_totals = Dict{String,Float64}()
    mean_pts = vec(mean(sim, dims=2))
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

    sim_itt = simulate_stage_race(
        stages, stage_strengths, uncertainties, teams, scoring;
        n_sims=100, rng=rng,
    )

    # Compare with flat stage (same strengths, but assists should apply)
    rng2 = Random.MersenneTwister(42)
    stages_flat = [flat_stage(1)]
    sim_flat = simulate_stage_race(
        stages_flat, stage_strengths, uncertainties, teams, scoring;
        n_sims=100, rng=rng2,
    )

    # Teammates (riders 2-4) should score more on flat (with assists) than ITT
    # (Rider 1 wins both, but teammates only get assists on flat)
    mean_itt = vec(mean(sim_itt, dims=2))
    mean_flat = vec(mean(sim_flat, dims=2))

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

    base = collect(range(2.0, -2.0, length=n_riders))
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
    sim_high = simulate_stage_race(
        stages, stage_strengths, uncertainties, teams, scoring;
        n_sims=500, cross_stage_alpha=0.95, rng=rng1,
    )

    rng2 = Random.MersenneTwister(42)
    sim_low = simulate_stage_race(
        stages, stage_strengths, uncertainties, teams, scoring;
        n_sims=500, cross_stage_alpha=0.1, rng=rng2,
    )

    # Different alpha values should produce different point distributions
    mean_high = vec(mean(sim_high, dims=2))
    mean_low = vec(mean(sim_low, dims=2))
    @test !all(isapprox.(mean_high, mean_low; atol=1.0))

    # Both should still have correct output shape and non-negative values
    @test size(sim_high) == (n_riders, 500)
    @test size(sim_low) == (n_riders, 500)
    @test all(sim_high .>= 0) && all(sim_low .>= 0)
end

# =========================================================================
# resample_optimise_stage
# =========================================================================

@testset "resample_optimise_stage" begin
    rng = Random.MersenneTwister(42)
    n_riders = 20
    scoring = SCORING_GRAND_TOUR
    stages = [flat_stage(1), mountain_stage(2), itt_stage(3)]

    # Build a rider DataFrame with classification columns
    rider_df = DataFrame(
        rider=["R$i" for i in 1:n_riders],
        riderkey=["r$i" for i in 1:n_riders],
        team=repeat(["A", "B", "C", "D"], 5),
        cost=repeat([15, 12, 10, 8, 5], 4),
        classraw=repeat(
            ["All Rounder", "All Rounder", "Climber", "Climber", "Climber",
                "Sprinter", "Sprinter", "Unclassed", "Unclassed", "Unclassed"],
            2,
        ),
        strength=Float64.(repeat([2.0, 1.5, 1.2, 0.8, 0.4], 4)),
        uncertainty=fill(0.5, n_riders),
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

    result_df, top_teams, sim_vg_pts = resample_optimise_stage(
        rider_df,
        stages,
        stage_strengths,
        scoring,
        build_model_stage;
        team_size=9,
        n_resamples=50,
        rng=rng,
        risk_aversion=0.5,
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
