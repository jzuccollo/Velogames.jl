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

    @testset "_random_bayesian_config produces valid configs" begin
        rng = Random.MersenneTwister(42)
        config = Velogames._random_bayesian_config(rng)
        @test config.market_precision_scale >=
              Velogames.PARAM_BOUNDS.market_precision_scale[1]
        @test config.market_precision_scale <=
              Velogames.PARAM_BOUNDS.market_precision_scale[2]
        @test config.history_precision_scale >=
              Velogames.PARAM_BOUNDS.history_precision_scale[1]
        @test config.history_precision_scale <=
              Velogames.PARAM_BOUNDS.history_precision_scale[2]
        @test config.ability_precision_scale >=
              Velogames.PARAM_BOUNDS.ability_precision_scale[1]
        @test config.ability_precision_scale <=
              Velogames.PARAM_BOUNDS.ability_precision_scale[2]
        @test config.hist_decay_rate >= Velogames.PARAM_BOUNDS.hist_decay_rate[1]
        @test config.hist_decay_rate <= Velogames.PARAM_BOUNDS.hist_decay_rate[2]
        @test config.vg_hist_decay_rate >= Velogames.PARAM_BOUNDS.vg_hist_decay_rate[1]
        @test config.vg_hist_decay_rate <= Velogames.PARAM_BOUNDS.vg_hist_decay_rate[2]
        # Non-tuned parameters should retain defaults
        @test config.odds_normalisation == DEFAULT_BAYESIAN_CONFIG.odds_normalisation
        @test config.prior_variance == DEFAULT_BAYESIAN_CONFIG.prior_variance
    end
end
