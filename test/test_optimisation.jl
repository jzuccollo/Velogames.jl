# =========================================================================
# Model building
# =========================================================================

@testset "Model Building Functions" begin
    sample_df = DataFrame(
        rider=["Rider A", "Rider B", "Rider C", "Rider D"],
        cost=[10, 15, 20, 25],
        points=[50.0, 75.0, 100.0, 125.0],
        riderkey=["ridera", "riderb", "riderc", "riderd"],
    )

    @testset "build_model_oneday" begin
        result = build_model_oneday(sample_df, 2, :points, :cost)
        @test result isa JuMP.Containers.DenseAxisArray
        @test length(result) == 4

        result2 = build_model_oneday(sample_df, 2, :points, :cost, totalcost=50)
        @test result2 isa JuMP.Containers.DenseAxisArray
        @test length(result2) == 4
    end

    @testset "build_model_stage" begin
        sample_df_stage = copy(sample_df)
        sample_df_stage.allrounder = [1, 0, 1, 1]
        sample_df_stage.sprinter = [0, 1, 0, 1]
        sample_df_stage.climber = [1, 0, 1, 1]
        sample_df_stage.unclassed = [1, 1, 1, 1]

        result = build_model_stage(sample_df_stage, 4, :points, :cost)
        @test (result isa JuMP.Containers.DenseAxisArray) || (result === nothing)
        if result !== nothing
            @test length(result) == 4
        end

        # Solves without classification constraints when columns missing
        result_fallback = build_model_stage(sample_df, 2, :points, :cost)
        @test result_fallback isa JuMP.Containers.DenseAxisArray
    end

    @testset "build_model_stage for historical analysis" begin
        test_data = DataFrame(
            rider=[
                "Rider A",
                "Rider B",
                "Rider C",
                "Rider D",
                "Rider E",
                "Rider F",
                "Rider G",
                "Rider H",
                "Rider I",
            ],
            riderkey=[
                "ridera",
                "riderb",
                "riderc",
                "riderd",
                "ridere",
                "riderf",
                "riderg",
                "riderh",
                "rideri",
            ],
            points=[500, 400, 300, 250, 200, 150, 100, 50, 25],
            cost=[20, 16, 14, 12, 10, 8, 6, 4, 2],
            class=[
                "All rounder",
                "All rounder",
                "Climber",
                "Climber",
                "Sprinter",
                "Unclassed",
                "Unclassed",
                "Unclassed",
                "Unclassed",
            ],
        )

        result = build_model_stage(test_data, 9, :points, :cost; totalcost=100)
        @test result !== nothing
        @test length(result) == nrow(test_data)

        chosen = [result[rk] > 0.5 for rk in test_data.riderkey]
        selected_team = test_data[chosen, :]

        @test nrow(selected_team) == 9
        @test sum(selected_team.cost) <= 100
        @test sum(selected_team.class .== "All rounder") >= 2
        @test sum(selected_team.class .== "Sprinter") >= 1
        @test sum(selected_team.class .== "Climber") >= 2
        @test sum(selected_team.class .== "Unclassed") >= 3
    end

    @testset "minimise_cost_stage" begin
        test_data = DataFrame(
            rider=[
                "Rider A",
                "Rider B",
                "Rider C",
                "Rider D",
                "Rider E",
                "Rider F",
                "Rider G",
                "Rider H",
                "Rider I",
            ],
            riderkey=[
                "ridera",
                "riderb",
                "riderc",
                "riderd",
                "ridere",
                "riderf",
                "riderg",
                "riderh",
                "rideri",
            ],
            points=[500, 400, 300, 250, 200, 150, 100, 50, 25],
            cost=[20, 16, 14, 12, 10, 8, 6, 4, 2],
            class=[
                "All rounder",
                "All rounder",
                "Climber",
                "Climber",
                "Sprinter",
                "Unclassed",
                "Unclassed",
                "Unclassed",
                "Unclassed",
            ],
        )

        target_score = 1000
        result =
            minimise_cost_stage(test_data, target_score, 9, :points, :cost; totalcost=100)

        @test result !== nothing
        @test length(result) == nrow(test_data)

        chosen = [result[rk] > 0.5 for rk in test_data.riderkey]
        selected_team = test_data[chosen, :]

        @test nrow(selected_team) == 9
        @test sum(selected_team.points) > target_score
        @test sum(selected_team.class .== "All rounder") >= 2
        @test sum(selected_team.class .== "Sprinter") >= 1
        @test sum(selected_team.class .== "Climber") >= 2
        @test sum(selected_team.class .== "Unclassed") >= 3
    end

    @testset "Insufficient data returns nothing" begin
        insufficient_data = DataFrame(
            rider=["Rider A", "Rider B"],
            riderkey=["ridera", "riderb"],
            points=[500, 400],
            cost=[20, 16],
            class=["All rounder", "Climber"],
        )

        result1 = build_model_stage(insufficient_data, 9, :points, :cost; totalcost=100)
        @test result1 === nothing

        result2 =
            minimise_cost_stage(insufficient_data, 100, 9, :points, :cost; totalcost=100)
        @test result2 === nothing
    end
end

# =========================================================================
# Integration tests
# =========================================================================

@testset "predict + build_model_oneday integration" begin
    rng = Random.MersenneTwister(42)
    rider_df = DataFrame(
        rider=["R$i" for i = 1:12],
        team=repeat(["A", "B", "C", "D"], 3),
        cost=[20, 18, 16, 14, 12, 10, 8, 6, 5, 4, 3, 2],
        points=Float64.([500, 400, 350, 300, 250, 200, 150, 100, 80, 60, 40, 20]),
        riderkey=["r$i" for i = 1:12],
        oneday=[2000, 1500, 1200, 1000, 800, 600, 400, 300, 200, 150, 100, 50],
    )
    predicted = predict_expected_points(rider_df, SCORING_CAT2; n_sims=5000, rng=rng)
    @test :expected_vg_points in propertynames(predicted)

    sol = build_model_oneday(predicted, 6, :expected_vg_points, :cost; totalcost=100)
    @test sol !== nothing

    chosen = filter(row -> JuMP.value(sol[row.riderkey]) > 0.5, predicted)
    @test nrow(chosen) == 6
    @test sum(chosen.cost) <= 100
end

@testset "predict + build_model_stage integration" begin
    rng = Random.MersenneTwister(42)
    rider_df = DataFrame(
        rider=["R$i" for i = 1:20],
        team=repeat(["A", "B", "C", "D"], 5),
        cost=repeat([15, 12, 10, 8, 5], 4),
        points=Float64.(repeat([400, 300, 200, 100, 50], 4)),
        riderkey=["r$i" for i = 1:20],
        classraw=repeat(
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
        gc=Float64.(repeat([1500, 1200, 800, 600, 400], 4)),
        tt=Float64.(repeat([1000, 800, 600, 400, 200], 4)),
        climber=Float64.(repeat([500, 400, 1200, 1000, 800], 4)),
        sprint=Float64.(repeat([200, 150, 100, 500, 300], 4)),
        oneday=Float64.(repeat([800, 600, 400, 300, 200], 4)),
    )
    predicted = predict_expected_points(
        rider_df,
        SCORING_STAGE;
        n_sims=5000,
        race_type=:stage,
        rng=rng,
    )
    @test :expected_vg_points in propertynames(predicted)

    sol = build_model_stage(predicted, 9, :expected_vg_points, :cost; totalcost=100)
    @test sol !== nothing

    chosen = filter(row -> JuMP.value(sol[row.riderkey]) > 0.5, predicted)
    @test nrow(chosen) == 9
    @test sum(chosen.cost) <= 100
end

@testset "simulate_vg_points" begin
    rng = Random.MersenneTwister(42)
    strengths = [2.0, 1.0, 0.0, -1.0, -2.0]
    uncertainties = fill(0.5, 5)
    teams = ["A", "A", "B", "B", "C"]

    sim = simulate_race(strengths, uncertainties; n_sims=10000, rng=rng)

    # Without breakaway should match expected_vg_points
    mean_pts, std_pts, down_std = simulate_vg_points(sim, teams, SCORING_CAT2)
    evg, evg_dsd = expected_vg_points(sim, teams, SCORING_CAT2)
    @test length(mean_pts) == 5
    @test length(std_pts) == 5
    @test length(down_std) == 5
    @test all(isapprox.(mean_pts, evg; atol=0.01))
    @test all(std_pts .>= 0)
    @test all(down_std .>= 0)
    @test std_pts[1] > 0  # strong rider has non-zero SD
    @test down_std[1] > 0  # strong rider has non-zero downside SD
    # Downside semi-deviation <= full SD (only counts below-mean deviations)
    @test all(down_std .<= std_pts .+ 0.01)

    # Stronger riders should have higher mean
    @test mean_pts[1] > mean_pts[5]

    # With empirical breakaway rates, mean should be >= no-breakaway (adds non-negative points)
    rng2 = Random.MersenneTwister(99)
    bk_rates = [0.3, 0.1, 0.1, 0.05, 0.0]
    mean_secs = [2.0, 1.0, 1.0, 1.0, 0.0]
    mean_brk, _, _ = simulate_vg_points(
        sim,
        teams,
        SCORING_CAT2;
        breakaway_rates=bk_rates,
        mean_sectors=mean_secs,
        rng=rng2,
    )
    @test all(mean_brk .>= mean_pts .- 0.01)
    @test mean_brk[5] ≈ mean_pts[5] atol = 0.01  # rate=0 → no breakaway points

    # Stage race: breakaway_points==0, so Bernoulli draw has no effect
    rng3 = Random.MersenneTwister(99)
    mean_stage, _, _ = simulate_vg_points(sim, teams, SCORING_STAGE)
    mean_stage_brk, _, _ = simulate_vg_points(
        sim,
        teams,
        SCORING_STAGE;
        breakaway_rates=bk_rates,
        mean_sectors=mean_secs,
        rng=rng3,
    )
    @test all(isapprox.(mean_stage, mean_stage_brk; atol=0.01))
end

@testset "breakaway_sectors_from_km" begin
    # 200km race: checkpoints at 100, 150, 180, 190
    @test breakaway_sectors_from_km(200.0, 200.0) == 4  # in break for full race
    @test breakaway_sectors_from_km(190.0, 200.0) == 4  # past all checkpoints
    @test breakaway_sectors_from_km(150.0, 200.0) == 2  # reached 100km and 150km
    @test breakaway_sectors_from_km(100.0, 200.0) == 1  # only 50% checkpoint
    @test breakaway_sectors_from_km(50.0, 200.0) == 0   # caught before halfway
    @test breakaway_sectors_from_km(0.0, 200.0) == 0
    @test breakaway_sectors_from_km(150.0, 0.0) == 0    # unknown distance → 0

    # 257km race (Paris-Roubaix): checkpoints at 128.5, 207, 237, 247
    @test breakaway_sectors_from_km(173.0, 257.0) == 1  # passes 128.5 only
    @test breakaway_sectors_from_km(240.0, 257.0) == 3  # passes 128.5, 207, 237
    @test breakaway_sectors_from_km(257.0, 257.0) == 4  # all checkpoints
end

@testset "resample_optimise" begin
    rng = Random.MersenneTwister(42)
    rider_df = DataFrame(
        rider=["R$i" for i = 1:12],
        team=repeat(["A", "B", "C", "D"], 3),
        cost=[20, 18, 16, 14, 12, 10, 8, 6, 5, 4, 4, 4],
        points=Float64.([500, 400, 350, 300, 250, 200, 150, 100, 80, 0, 0, 0]),
        riderkey=["r$i" for i = 1:12],
        oneday=[2000, 1500, 1200, 1000, 800, 600, 400, 300, 200, 10, 10, 10],
        has_pcs_data=[trues(9); trues(3)],
    )

    strengths_df = estimate_strengths(rider_df)

    result_df, top_teams, sim_vg_pts = resample_optimise(
        strengths_df,
        SCORING_CAT2,
        build_model_oneday;
        team_size=6,
        n_resamples=100,
        rng=rng,
    )

    @test :selection_frequency in propertynames(result_df)
    @test :expected_vg_points in propertynames(result_df)
    @test :downside_semi_dev in propertynames(result_df)
    @test !isempty(top_teams)
    @test nrow(top_teams[1]) == 6
    @test sum(top_teams[1].cost) <= 100
    @test all(result_df.selection_frequency .>= 0.0)
    @test all(result_df.selection_frequency .<= 1.0)
    @test all(result_df.downside_semi_dev .>= 0.0)
    # _final_pts working column should be cleaned up
    @test :_final_pts ∉ propertynames(result_df)
    # sim_vg_points matrix has correct dimensions
    @test size(sim_vg_pts) == (nrow(result_df), 100)
    @test all(sim_vg_pts .>= 0.0)
end
