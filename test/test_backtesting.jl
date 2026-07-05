@testset "Backtesting Framework" begin
    @testset "spearman_correlation" begin
        @test Velogames.spearman_correlation(
            [1.0, 2.0, 3.0, 4.0, 5.0],
            [1.0, 2.0, 3.0, 4.0, 5.0],
        ) ≈ 1.0

        @test Velogames.spearman_correlation(
            [1.0, 2.0, 3.0, 4.0, 5.0],
            [5.0, 4.0, 3.0, 2.0, 1.0],
        ) ≈ -1.0

        rho = Velogames.spearman_correlation(
            [1.0, 2.0, 3.0, 4.0, 5.0],
            [3.0, 1.0, 5.0, 2.0, 4.0],
        )
        @test abs(rho) < 0.5

        @test isnan(Velogames.spearman_correlation([1.0, 2.0], [2.0, 1.0]))

        rho_ties = Velogames.spearman_correlation(
            [1.0, 1.0, 3.0, 4.0, 5.0],
            [1.0, 2.0, 3.0, 4.0, 5.0],
        )
        @test !isnan(rho_ties)
        @test rho_ties > 0.8
    end

    @testset "top_n_overlap" begin
        predicted = [100.0, 80.0, 60.0, 40.0, 20.0]
        actual_pos = [1, 2, 3, 4, 5]

        @test Velogames.top_n_overlap(predicted, actual_pos, 3) == 3
        @test Velogames.top_n_overlap(predicted, actual_pos, 5) == 5

        predicted2 = [100.0, 80.0, 60.0, 40.0, 20.0]
        actual_pos2 = [5, 4, 3, 2, 1]
        @test Velogames.top_n_overlap(predicted2, actual_pos2, 3) == 1
    end

    @testset "mean_abs_rank_error" begin
        predicted = [100.0, 80.0, 60.0, 40.0, 20.0]
        actual_pos = [1, 2, 3, 4, 5]
        @test Velogames.mean_abs_rank_error(predicted, actual_pos) ≈ 0.0

        actual_pos2 = [2, 1, 4, 3, 5]
        mae = Velogames.mean_abs_rank_error(predicted, actual_pos2)
        @test mae > 0
        @test mae < 2.0
    end

    @testset "build_race_catalogue" begin
        catalogue = build_race_catalogue([2024])
        @test length(catalogue) == length(CLASSICS_RACES_2026)
        @test all(r -> r.year == 2024, catalogue)
        @test all(r -> r.history_years == 5, catalogue)

        catalogue2 = build_race_catalogue([2023, 2024])
        @test length(catalogue2) == 2 * length(CLASSICS_RACES_2026)

        catalogue3 = build_race_catalogue([2024]; history_years = 3)
        @test all(r -> r.history_years == 3, catalogue3)
    end

    @testset "summarise_backtest" begin
        df = summarise_backtest(BacktestResult[])
        @test nrow(df) == 0

        results = [
            BacktestResult(
                BacktestRace("Race A", 2024, "race-a", 2),
                [:pcs],
                50,
                0.6,
                3,
                7,
                15.2,
                0.8,
                100.0,
                125.0,
                randn(50),
                randn(50),
                0.1,
                1.05,
                0.68,
                0.94,
                Dict{Symbol,Float64}(:shift_vg => 0.1, :shift_history => -0.2),
                nothing,
            ),
            BacktestResult(
                BacktestRace("Race B", 2024, "race-b", 1),
                [:pcs],
                40,
                0.7,
                4,
                8,
                12.0,
                0.9,
                110.0,
                122.0,
                randn(40),
                randn(40),
                -0.05,
                0.98,
                0.70,
                0.96,
                Dict{Symbol,Float64}(:shift_vg => -0.05),
                nothing,
            ),
        ]
        df = summarise_backtest(results)
        @test nrow(df) == 4  # 2 races + mean + median
        @test "Race A" in df.race
        @test "— MEAN —" in df.race
        @test :calibration_mean in propertynames(df)
        @test :coverage_1sigma in propertynames(df)
    end

    @testset "stage-race harness" begin
        # Synthetic fixture: 12 riders, all cost 10, actual totals descending
        # 120..10 — no network, no archive.
        riders = DataFrame(
            riderkey = ["r$(lpad(i, 2, '0'))" for i = 1:12],
            rider = ["Rider $i" for i = 1:12],
            team = ["T$(mod1(i, 4))" for i = 1:12],
            cost = fill(10, 12),
            actual_total = Float64.(130 .- 10 .* (1:12)),
        )
        gt_hist = DataFrame(
            riderkey = ["r01", "r01", "r02", "r03", "r04"],
            score = [100.0, 150.0, 80.0, 999.0, 500.0],
            year = [2023, 2024, 2023, 2024, 2026],
            gt_slug = ["test-tour", "test-tour", "test-tour", "other-tour", "test-tour"],
        )
        gc = DataFrame(
            riderkey = ["r$(lpad(i, 2, '0'))" for i = 1:11],
            position = [collect(1:10); Velogames.DNF_POSITION],
        )
        fixture(race_data) = StageRaceBacktestData(
            "test-tour",
            "testvg",
            2026,
            nothing,
            riders,
            race_data,
            Velogames.StageProfile[],
            Velogames.SCORING_GRAND_TOUR,
            Float64[],
            gt_hist,
            gc,
            nothing,
            nothing,
        )
        data = fixture(RaceData(rider_df = riders))

        # Deterministic predictor: actual totals with ranks 9 and 10 swapped.
        pred_pts = Float64.(130 .- 10 .* (1:12))
        pred_pts[9], pred_pts[10] = pred_pts[10], pred_pts[9]
        swap_pred =
            d -> DataFrame(riderkey = riders.riderkey, expected_vg_points = pred_pts)

        # Primary :vg_total metrics, exactly. Hindsight optimum = riders 1-9
        # (720 pts); the swap predictor's team = riders 1-8 + r10 (710 pts).
        res = backtest_stage_race(data; predictors = ["swap" => swap_pred])
        @test nrow(res) == 1
        @test res.team_actual[1] == 710.0
        @test res.optimal_actual[1] == 720.0
        @test res.team_points_captured[1] == round(710 / 720, digits = 3)
        # One adjacent-rank swap over 12 riders: ρ = 1 - 12/(12·143)
        @test res.rho_full[1] == round(1 - 12 / (12 * 143), digits = 3)
        @test res.rho_top20[1] == res.rho_full[1]  # n < 20 → same subset
        @test res.overlap9[1] == 8
        @test res.overlap20[1] == 12

        # Secondary target: ρ vs GC standings over the 10 finishers (DNF and
        # missing riders excluded); same swap → ρ = 1 - 12/(10·99).
        res_gc = backtest_stage_race(
            data;
            predictors = ["swap" => swap_pred],
            target = :gc,
        )
        @test res_gc.n[1] == 10
        @test res_gc.rho[1] == round(1 - 12 / (10 * 99), digits = 3)

        # Persistence built-in: most recent prior same-GT edition; cross-GT
        # rows and the race year itself excluded; no history → 0.
        pe = Velogames.persistence_evg(data)
        @test pe.expected_vg_points[1] == 150.0  # r01: 2024 beats 2023
        @test pe.expected_vg_points[2] == 80.0   # r02: single edition
        @test pe.expected_vg_points[3] == 0.0    # r03: other GT only
        @test pe.expected_vg_points[4] == 0.0    # r04: 2026 row is the target year
        @test all(pe.expected_vg_points[5:12] .== 0.0)

        # Degenerate (constant) prediction: rank metrics must be missing, not
        # the tie-artefact 0.5 (an all-zero persistence baseline hits this).
        flat_pred =
            d -> DataFrame(riderkey = riders.riderkey, expected_vg_points = zeros(12))
        res_flat = backtest_stage_race(data; predictors = ["flat" => flat_pred])
        @test res_flat.rho_full[1] === missing
        @test res_flat.rho_top20[1] === missing
        res_flat_gc =
            backtest_stage_race(data; predictors = ["flat" => flat_pred], target = :gc)
        @test res_flat_gc.rho[1] === missing

        # Odds built-in: absent odds → predictor skipped entirely.
        @test Velogames.odds_evg(data) === nothing
        @test nrow(backtest_stage_race(data; predictors = [:odds])) == 0

        # With odds: implied probability ranking flows through the metrics.
        odds_data = fixture(
            RaceData(
                rider_df = riders,
                odds_df = DataFrame(riderkey = ["r05"], odds = [2.0]),
            ),
        )
        oe = Velogames.odds_evg(odds_data)
        @test oe.expected_vg_points[5] == 0.5
        @test all(oe.expected_vg_points[Not(5)] .== 0.0)
        res_odds = backtest_stage_race(odds_data; predictors = [:odds])
        @test res_odds.predictor == ["odds"]
        @test 0.0 < res_odds.team_points_captured[1] <= 1.0
    end
end
