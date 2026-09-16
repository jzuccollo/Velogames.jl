# =========================================================================
# Model building
# =========================================================================

@testset "Model Building Functions" begin
    sample_df = DataFrame(
        rider = ["Rider A", "Rider B", "Rider C", "Rider D"],
        cost = [10, 15, 20, 25],
        points = [50.0, 75.0, 100.0, 125.0],
        riderkey = ["ridera", "riderb", "riderc", "riderd"],
    )

    @testset "build_model_oneday" begin
        result = build_model_oneday(sample_df, 2, :points, :cost)
        @test result isa JuMP.Containers.DenseAxisArray
        @test length(result) == 4

        result2 = build_model_oneday(sample_df, 2, :points, :cost, totalcost = 50)
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
            rider = [
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
            riderkey = [
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
            points = [500, 400, 300, 250, 200, 150, 100, 50, 25],
            cost = [20, 16, 14, 12, 10, 8, 6, 4, 2],
            class = [
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

        result = build_model_stage(test_data, 9, :points, :cost; totalcost = 100)
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
            rider = [
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
            riderkey = [
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
            points = [500, 400, 300, 250, 200, 150, 100, 50, 25],
            cost = [20, 16, 14, 12, 10, 8, 6, 4, 2],
            class = [
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
            minimise_cost_stage(test_data, target_score, 9, :points, :cost; totalcost = 100)

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

    @testset "minimise_cost_stage without classification columns" begin
        test_data = DataFrame(
            rider = ["R$i" for i = 1:10],
            riderkey = ["r$i" for i = 1:10],
            points = [500, 400, 300, 250, 200, 150, 100, 80, 60, 40],
            cost = [18, 16, 14, 12, 10, 8, 6, 5, 4, 3],
        )

        result = minimise_cost_stage(test_data, 1000, 9, :points, :cost; totalcost = 100)
        @test result !== nothing

        chosen = [result[rk] > 0.5 for rk in test_data.riderkey]
        selected_team = test_data[chosen, :]
        @test nrow(selected_team) == 9
        @test sum(selected_team.points) > 1000
    end

    @testset "Insufficient data returns nothing" begin
        insufficient_data = DataFrame(
            rider = ["Rider A", "Rider B"],
            riderkey = ["ridera", "riderb"],
            points = [500, 400],
            cost = [20, 16],
            class = ["All rounder", "Climber"],
        )

        result1 = build_model_stage(insufficient_data, 9, :points, :cost; totalcost = 100)
        @test result1 === nothing

        result2 =
            minimise_cost_stage(insufficient_data, 100, 9, :points, :cost; totalcost = 100)
        @test result2 === nothing
    end
end

# =========================================================================
# Retrospective knapsack tie-breaks
# =========================================================================

# Both retrospective pairs are lexicographic: the first objective alone leaves a
# tie set the solver resolves arbitrarily, so each test builds a frame with a
# tie and asserts the pinned member is the one returned.
@testset "Retrospective team tie-breaks" begin
    @testset "compute_optimal_team breaks score ties on cost" begin
        # cheap6 and dear6 score the same, so the 450-point team is only unique
        # once cost breaks the tie.
        df = DataFrame(
            rider = ["a", "b", "c", "d", "e", "cheap6", "dear6"],
            riderkey = ["a", "b", "c", "d", "e", "cheap6", "dear6"],
            team = ["T$i" for i = 1:7],
            score = [100, 90, 80, 70, 60, 50, 50],
            cost = [10, 10, 10, 10, 10, 2, 9],
        )

        team = compute_optimal_team(df)
        @test team !== nothing
        @test nrow(team) == 6
        @test sum(team.score) == 450
        @test "cheap6" in team.riderkey
        @test "dear6" ∉ team.riderkey
        @test sum(team.cost) == 52
    end

    @testset "compute_optimal_stage_team breaks score ties on cost" begin
        # a9 and a10 tie at 20 points; the class minimums are satisfied either
        # way, so only the cost tie-break separates them.
        df = DataFrame(
            rider = ["a$i" for i = 1:12],
            riderkey = ["a$i" for i = 1:12],
            team = ["T$i" for i = 1:12],
            class = [
                "All rounder",
                "All rounder",
                "Climber",
                "Climber",
                "Sprinter",
                "Unclassed",
                "Unclassed",
                "Unclassed",
                "Unclassed",
                "Unclassed",
                "Sprinter",
                "Climber",
            ],
            score = [100, 90, 80, 70, 60, 50, 40, 30, 20, 20, 10, 10],
            cost = [10, 10, 10, 10, 10, 10, 10, 10, 2, 9, 5, 5],
        )

        team = compute_optimal_stage_team(df)
        @test team !== nothing
        @test nrow(team) == 9
        @test sum(team.score) == 540
        @test "a9" in team.riderkey
        @test "a10" ∉ team.riderkey
        @test sum(team.class .== "All rounder") >= 2
        @test sum(team.class .== "Climber") >= 2
        @test sum(team.class .== "Sprinter") >= 1
        @test sum(team.class .== "Unclassed") >= 3
    end

    @testset "compute_cheapest_winning_team breaks cost ties on score" begin
        # Every 6-rider team clearing 300 at the minimum cost of 50 is optimal
        # on cost alone; the score stage picks the best of them.
        df = DataFrame(
            rider = ["a", "b", "c", "d", "e", "f", "cheap", "dear"],
            riderkey = ["a", "b", "c", "d", "e", "f", "cheap", "dear"],
            team = ["T$i" for i = 1:8],
            score = [100, 90, 80, 70, 60, 50, 0, 0],
            cost = [10, 10, 10, 10, 10, 10, 1, 9],
        )

        team = compute_cheapest_winning_team(df, 300)
        @test team !== nothing
        @test nrow(team) == 6
        @test sum(team.cost) == 50
        @test sum(team.score) == 340   # not 330, which also costs 50
    end

    @testset "cheapest-winning respects the budget" begin
        # Beating 500 needs one of the two 60-credit riders, and no six-rider
        # team containing one fits the budget. A fieldable team exists but loses,
        # so `nothing` here is the budget constraint biting, not infeasibility
        # of the roster.
        df = DataFrame(
            rider = ["a$i" for i = 1:8],
            riderkey = ["a$i" for i = 1:8],
            team = ["T$i" for i = 1:8],
            score = [10, 10, 10, 10, 10, 10, 1000, 1000],
            cost = [10, 10, 10, 10, 10, 10, 60, 60],
        )

        @test compute_optimal_team(df) !== nothing
        @test compute_cheapest_winning_team(df, 500) === nothing
    end
end

# =========================================================================
# Integration tests
# =========================================================================

@testset "predict + build_model_oneday integration" begin
    rng = Random.MersenneTwister(42)
    rider_df = DataFrame(
        rider = ["R$i" for i = 1:12],
        team = repeat(["A", "B", "C", "D"], 3),
        cost = [20, 18, 16, 14, 12, 10, 8, 6, 5, 4, 3, 2],
        points = Float64.([500, 400, 350, 300, 250, 200, 150, 100, 80, 60, 40, 20]),
        riderkey = ["r$i" for i = 1:12],
        oneday = [2000, 1500, 1200, 1000, 800, 600, 400, 300, 200, 150, 100, 50],
    )
    predicted = predict_expected_points(rider_df, SCORING_CAT2; n_sims = 5000, rng = rng)
    @test :expected_vg_points in propertynames(predicted)

    sol = build_model_oneday(predicted, 6, :expected_vg_points, :cost; totalcost = 100)
    @test sol !== nothing

    chosen = filter(row -> JuMP.value(sol[row.riderkey]) > 0.5, predicted)
    @test nrow(chosen) == 6
    @test sum(chosen.cost) <= 100
end

@testset "predict + build_model_stage integration" begin
    rng = Random.MersenneTwister(42)
    rider_df = DataFrame(
        rider = ["R$i" for i = 1:20],
        team = repeat(["A", "B", "C", "D"], 5),
        cost = repeat([15, 12, 10, 8, 5], 4),
        points = Float64.(repeat([400, 300, 200, 100, 50], 4)),
        riderkey = ["r$i" for i = 1:20],
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
        gc = Float64.(repeat([1500, 1200, 800, 600, 400], 4)),
        tt = Float64.(repeat([1000, 800, 600, 400, 200], 4)),
        climber = Float64.(repeat([500, 400, 1200, 1000, 800], 4)),
        sprint = Float64.(repeat([200, 150, 100, 500, 300], 4)),
        oneday = Float64.(repeat([800, 600, 400, 300, 200], 4)),
    )
    predicted = predict_expected_points(
        rider_df,
        SCORING_STAGE;
        n_sims = 5000,
        race_type = :stage,
        rng = rng,
    )
    @test :expected_vg_points in propertynames(predicted)

    sol = build_model_stage(predicted, 9, :expected_vg_points, :cost; totalcost = 100)
    @test sol !== nothing

    chosen = filter(row -> JuMP.value(sol[row.riderkey]) > 0.5, predicted)
    @test nrow(chosen) == 9
    @test sum(chosen.cost) <= 100
end

@testset "_score_vg_draw!" begin
    teams = ["A", "A", "B", "B", "C"]
    scoring = SCORING_CAT2

    # Deterministic single draw: rider 1 wins, rider 3 second, rider 5 third
    positions = [1, 4, 2, 5, 3]
    sim_pts = zeros(Float64, 5)
    Velogames._score_vg_draw!(sim_pts, positions, teams, scoring)

    # Finish points for podium riders (no teammate finished top-3, so no assist added)
    @test sim_pts[1] ≈ Float64(finish_points_for_position(1, scoring))
    @test sim_pts[3] ≈ Float64(finish_points_for_position(2, scoring))
    @test sim_pts[5] ≈ Float64(finish_points_for_position(3, scoring))
    # Assist points: rider 2 (team A) for rider 1's win; rider 4 (team B) for rider 3's 2nd
    @test sim_pts[2] ≈
          Float64(finish_points_for_position(4, scoring)) + scoring.assist_points[1]
    @test sim_pts[4] ≈
          Float64(finish_points_for_position(5, scoring)) + scoring.assist_points[2]

    # Breakaway: a guaranteed draw (rate 1.0) adds mean_sectors * breakaway_points
    sim_pts_brk = zeros(Float64, 5)
    rng = Random.MersenneTwister(1)
    Velogames._score_vg_draw!(
        sim_pts_brk,
        positions,
        teams,
        scoring;
        breakaway_rates = [1.0, 0.0, 0.0, 0.0, 0.0],
        mean_sectors = [3.0, 0.0, 0.0, 0.0, 0.0],
        rng = rng,
    )
    @test sim_pts_brk[1] ≈ sim_pts[1] + 3.0 * scoring.breakaway_points
    # Riders with rate 0 are unchanged from the no-breakaway score
    @test sim_pts_brk[3] ≈ sim_pts[3]

    # Stage scoring has breakaway_points == 0, so the Bernoulli draw has no effect
    sim_pts_stage = zeros(Float64, 5)
    sim_pts_stage_brk = zeros(Float64, 5)
    Velogames._score_vg_draw!(sim_pts_stage, positions, teams, SCORING_STAGE)
    Velogames._score_vg_draw!(
        sim_pts_stage_brk,
        positions,
        teams,
        SCORING_STAGE;
        breakaway_rates = [1.0, 1.0, 1.0, 1.0, 1.0],
        mean_sectors = [2.0, 2.0, 2.0, 2.0, 2.0],
        rng = Random.MersenneTwister(7),
    )
    @test all(isapprox.(sim_pts_stage, sim_pts_stage_brk; atol = 1e-9))
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

"""12-rider field used by both resampling testsets: costs and points descend
together, so riders 10–12 are the cheap outsiders the blend tests reach for."""
_resample_fixture() = DataFrame(
    rider = ["R$i" for i = 1:12],
    team = repeat(["A", "B", "C", "D"], 3),
    cost = [20, 18, 16, 14, 12, 10, 8, 6, 5, 4, 4, 4],
    points = Float64.([500, 400, 350, 300, 250, 200, 150, 100, 80, 0, 0, 0]),
    riderkey = ["r$i" for i = 1:12],
    oneday = [2000, 1500, 1200, 1000, 800, 600, 400, 300, 200, 10, 10, 10],
    has_pcs_data = trues(12),
)

@testset "resample_optimise!" begin
    rng = Random.MersenneTwister(42)
    rider_df = _resample_fixture()

    strengths_df = estimate_strengths(rider_df)

    result_df, top_teams, sim_vg_pts = resample_optimise!(
        strengths_df,
        SCORING_CAT2,
        build_model_oneday;
        team_size = 6,
        n_resamples = 100,
        rng = rng,
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
    @test :_final_pts ∉ propertynames(result_df)
    @test size(sim_vg_pts) == (nrow(result_df), 100)
    @test all(sim_vg_pts .>= 0.0)
end

@testset "market blend" begin
    @testset "market_win_probs" begin
        keys_ = ["r1", "r2", "r3"]
        odds = DataFrame(riderkey = ["r2", "r3"], odds = [2.0, 1.0])
        p = market_win_probs(odds, keys_)
        @test p[1] == 0.0                    # unpriced → 0, the book's own verdict
        @test p[2] == 0.5
        @test p[3] ≈ 1 / 1.01                # odds floored at 1.01
        # No market at all → empty, which callers read as "do not blend"
        @test market_win_probs(nothing, keys_) == Float64[]
        @test market_win_probs(DataFrame(riderkey = ["r1"]), keys_) == Float64[]
        # A frame with the right columns but no rider on this roster is not a
        # market either. Returning zeros(n) would hand the optimiser a flat
        # objective and an arbitrary team instead of "skip me".
        @test market_win_probs(
            DataFrame(riderkey = String[], odds = Float64[]),
            keys_,
        ) == Float64[]
        @test market_win_probs(DataFrame(riderkey = ["nobody"], odds = [2.0]), keys_) ==
              Float64[]
    end

    @testset "blend_market_points normalisation" begin
        pts = [100.0, 50.0, 10.0]
        probs = [0.1, 0.6, 0.0]
        b = blend_market_points(pts, probs, 0.5)
        @test sum(b) ≈ 1.0                   # both arms unit-normalised
        # Each arm is scale-free: rescaling EVG must not shift the blend, or
        # whichever arm carries bigger numbers would dominate the mixture.
        @test blend_market_points(1000 .* pts, probs, 0.5) ≈ b
        @test blend_market_points(pts, 100 .* probs, 0.5) ≈ b
        # Endpoints
        @test blend_market_points(pts, probs, 1.0) ≈ pts ./ sum(pts)
        @test blend_market_points(pts, probs, 0.0) ≈ probs ./ sum(probs)
        # The market arm bites: rider 2 is second on EVG but the market's
        # favourite, and the blend puts them top.
        @test argmax(b) == 2
        # All-zero market (nobody priced) degrades to the simulator's ordering
        # for any w > 0; at w = 0 there is nothing left to order by, which is why
        # callers must not reach here with an empty market (`market_win_probs`
        # returns `Float64[]`, and `_resample_core!` guards on `any(>(0), …)`).
        for w in (0.25, 0.5, 1.0)
            @test sortperm(blend_market_points(pts, zeros(3), w), rev = true) ==
                  sortperm(pts, rev = true)
        end
        @test all(iszero, blend_market_points(pts, zeros(3), 0.0))
    end

    @testset "resample_optimise! blending" begin
        strengths_df = estimate_strengths(_resample_fixture())

        blend_run(df; kwargs...) = resample_optimise!(
            copy(df),
            SCORING_CAT2,
            build_model_oneday;
            team_size = 6,
            n_resamples = 100,
            rng = Random.MersenneTwister(42),
            kwargs...,
        )

        base_df, base_teams, _ = blend_run(strengths_df)
        # The market rates the model's cheap outsiders, and only them.
        probs = [zeros(9); [0.4, 0.35, 0.25]]

        # w = 1 with a real market present must be bit-identical to no blend.
        w1_df, w1_teams, _ = blend_run(strengths_df; market_probs = probs,
            market_blend_weight = 1.0)
        @test :market_blend_points ∉ propertynames(w1_df)
        @test w1_df.expected_vg_points == base_df.expected_vg_points
        @test w1_df.selection_frequency == base_df.selection_frequency
        @test sort(w1_teams[1].riderkey) == sort(base_teams[1].riderkey)

        # A marketless race is untouched. Tested at w = 0, the weight that would
        # do most damage if the guard failed (it would hand the optimiser an
        # all-zero objective); the guard has no other w-dependence, so one is
        # enough. Both spellings of "no market" — all-zero and empty.
        for probs_none in (zeros(12), Float64[])
            m_df, m_teams, _ = blend_run(strengths_df; market_probs = probs_none,
                market_blend_weight = 0.0)
            @test :market_blend_points ∉ propertynames(m_df)
            @test sort(m_teams[1].riderkey) == sort(base_teams[1].riderkey)
        end

        # w < 1 with a market: the blended column is written, and it — not raw
        # EVG — drives the pick. The three market-backed outsiders are the
        # model's worst riders, so a real blend must pull them in.
        b_df, b_teams, _ = blend_run(strengths_df; market_probs = probs,
            market_blend_weight = 0.5)
        @test :market_blend_points in propertynames(b_df)
        @test b_df.expected_vg_points == base_df.expected_vg_points  # EVG untouched
        @test sort(b_teams[1].riderkey) != sort(base_teams[1].riderkey)
        @test count(k -> k in ("r10", "r11", "r12"), b_teams[1].riderkey) >
              count(k -> k in ("r10", "r11", "r12"), base_teams[1].riderkey)

        # w = 0 hands the pick to the market: only the three priced riders carry
        # any weight, so all three must be bought.
        z_df, z_teams, _ = blend_run(strengths_df; market_probs = probs,
            market_blend_weight = 0.0)
        @test issubset(["r10", "r11", "r12"], z_teams[1].riderkey)
    end
end
