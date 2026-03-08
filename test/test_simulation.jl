@testset "Bayesian Strength Estimation" begin
    prior = BayesianPosterior(0.0, 4.0)
    posterior = bayesian_update(prior, 2.0, 1.0)
    @test 0.0 < posterior.mean < 2.0
    @test posterior.variance < min(prior.variance, 1.0)

    @test isapprox(bayesian_update(prior, 2.0, 0.01).mean, 2.0; atol = 0.1)
    @test isapprox(bayesian_update(prior, 2.0, 1000.0).mean, 0.0; atol = 0.1)

    strong = estimate_rider_strength(pcs_score = 2.0)
    weak = estimate_rider_strength(pcs_score = -2.0)
    @test strong.mean > weak.mean

    precise = estimate_rider_strength(
        pcs_score = 1.5,
        vg_points = 1.5,
        race_history = [1.5, 1.3],
        race_history_years_ago = [1, 2],
    )
    @test precise.variance < estimate_rider_strength(pcs_score = 1.5).variance

    @test estimate_rider_strength(
        pcs_score = 0.0,
        odds_implied_prob = 0.1,
        n_starters = 150,
    ).mean > 0.0

    @test estimate_rider_strength(
        pcs_score = 0.0,
        oracle_implied_prob = 0.1,
        n_starters = 150,
    ).mean > 0.0

    # Form signal shifts mean and reduces variance
    with_form = estimate_rider_strength(pcs_score = 0.0, form_score = 1.5)
    without_form = estimate_rider_strength(pcs_score = 0.0)
    @test with_form.mean > without_form.mean
    @test with_form.variance < without_form.variance
    @test with_form.shift_form > 0.0
    @test without_form.shift_form == 0.0

    @test position_to_strength(1, 150) >
          position_to_strength(50, 150) >
          position_to_strength(100, 150)
    @test position_to_strength(1, 150) > 0 && position_to_strength(100, 150) < 0
end

@testset "BayesianConfig" begin
    default_result = estimate_rider_strength(pcs_score = 1.0, vg_points = 0.5)
    @test default_result.mean > 0.0

    custom_config = BayesianConfig(
        market_precision_scale = 2.0,
        history_precision_scale = 2.0,
        ability_precision_scale = 2.0,
        hist_decay_rate = 0.5,
        vg_hist_decay_rate = 0.5,
        odds_normalisation = 2.0,
        signal_correlation = 0.0,
        vg_season_penalty = 5.0,
    )
    custom_result =
        estimate_rider_strength(pcs_score = 1.0, vg_points = 0.5, config = custom_config)
    @test custom_result.mean != default_result.mean

    @test DEFAULT_BAYESIAN_CONFIG isa BayesianConfig
    @test pcs_variance(DEFAULT_BAYESIAN_CONFIG) == 1.0 / DEFAULT_BAYESIAN_CONFIG.ability_precision_scale
    @test DEFAULT_BAYESIAN_CONFIG.signal_correlation == 0.25
    @test DEFAULT_BAYESIAN_CONFIG.prior_variance == 100.0

    # Equicorrelation discount: more signals → wider posterior with ρ > 0
    no_corr = BayesianConfig(
        signal_correlation = 0.0,
    )
    with_corr = BayesianConfig(
        signal_correlation = 0.4,
    )
    r_nocorr = estimate_rider_strength(
        pcs_score = 1.0,
        vg_points = 0.8,
        race_history = [0.5, 0.3],
        race_history_years_ago = [0, 1],
        config = no_corr,
    )
    r_corr = estimate_rider_strength(
        pcs_score = 1.0,
        vg_points = 0.8,
        race_history = [0.5, 0.3],
        race_history_years_ago = [0, 1],
        config = with_corr,
    )
    @test r_corr.variance > r_nocorr.variance  # correlation widens posterior
    @test abs(r_corr.mean - r_nocorr.mean) < 0.3  # mean shifts toward prior but stays close
end

@testset "Floor observations (odds/oracle absence-as-signal)" begin
    # Floor strength should lower the posterior mean
    no_floor = estimate_rider_strength(pcs_score = 0.5, vg_points = 0.3)
    with_floor = estimate_rider_strength(
        pcs_score = 0.5,
        vg_points = 0.3,
        odds_floor_strength = -0.8,
    )
    @test with_floor.mean < no_floor.mean
    @test with_floor.shift_odds < 0.0
    @test no_floor.shift_odds == 0.0

    # Floor uses higher variance than direct odds (wider posterior)
    # Use market_discount=1.0 to isolate floor vs direct odds behaviour
    no_discount = BayesianConfig(market_discount = 1.0)
    direct_odds = estimate_rider_strength(
        pcs_score = 0.5,
        vg_points = 0.3,
        odds_implied_prob = 0.002,
        n_starters = 150,
        config = no_discount,
    )
    with_floor_same = estimate_rider_strength(
        pcs_score = 0.5,
        vg_points = 0.3,
        odds_floor_strength = -0.8,
        config = no_discount,
    )
    # Floor observation should leave more uncertainty than a direct price
    @test with_floor_same.variance > direct_odds.variance

    # Oracle floor works the same way
    with_oracle_floor = estimate_rider_strength(
        pcs_score = 0.5,
        vg_points = 0.3,
        oracle_floor_strength = -0.6,
    )
    @test with_oracle_floor.mean < no_floor.mean
    @test with_oracle_floor.shift_oracle < 0.0

    # Direct odds overrides floor (floor only applies when odds_implied_prob == 0)
    direct_with_floor = estimate_rider_strength(
        pcs_score = 0.5,
        vg_points = 0.3,
        odds_implied_prob = 0.05,
        n_starters = 150,
        odds_floor_strength = -0.8,
    )
    direct_without_floor = estimate_rider_strength(
        pcs_score = 0.5,
        vg_points = 0.3,
        odds_implied_prob = 0.05,
        n_starters = 150,
    )
    @test direct_with_floor.mean ≈ direct_without_floor.mean
end

@testset "Floor observations in estimate_strengths pipeline" begin
    # Build a small rider DataFrame
    rider_df = DataFrame(
        rider = ["Rider A", "Rider B", "Rider C"],
        riderkey = ["ridera", "riderb", "riderc"],
        team = ["Team1", "Team1", "Team2"],
        cost = [20, 10, 6],
        points = [100.0, 50.0, 0.0],
        oneday = [200, 100, 50],
    )

    # Odds cover only Rider A
    odds_df = DataFrame(rider = ["Rider A"], riderkey = ["ridera"], odds = [5.0])

    # Without odds: all riders get no odds signal
    result_no_odds = estimate_strengths(rider_df)
    @test all(result_no_odds.shift_odds .== 0.0)

    # With odds: absent riders should get nonzero odds shifts (floor applied)
    result_with_odds = estimate_strengths(rider_df; odds_df = odds_df)
    @test result_with_odds[result_with_odds.riderkey .== "riderb", :shift_odds][1] != 0.0
    @test result_with_odds[result_with_odds.riderkey .== "riderc", :shift_odds][1] != 0.0

    # Direct-priced rider should also get a nonzero odds shift
    @test result_with_odds[result_with_odds.riderkey .== "ridera", :shift_odds][1] != 0.0
end

@testset "_rand_t distribution" begin
    rng = Random.MersenneTwister(99)
    samples = [Velogames._rand_t(rng, 5) for _ = 1:50000]
    @test abs(mean(samples)) < 0.05  # mean ≈ 0
    @test std(samples) > 1.1  # heavier tails than normal (t(5) variance = 5/3)
end

@testset "Monte Carlo Simulation" begin
    rng = Random.MersenneTwister(42)
    strengths = [2.0, 1.0, 0.0, -1.0, -2.0]
    uncertainties = fill(0.5, 5)

    positions = simulate_race(strengths, uncertainties; n_sims = 10000, rng = rng)
    @test size(positions) == (5, 10000)
    @test sort(positions[:, 1]) == 1:5
    @test count(positions[1, :] .== 1) > count(positions[5, :] .== 1)
    @test mean(positions[1, :]) < mean(positions[5, :])

    # Gaussian mode (simulation_df=nothing) should also work
    rng_gauss = Random.MersenneTwister(42)
    pos_gauss = simulate_race(
        strengths,
        uncertainties;
        n_sims = 1000,
        rng = rng_gauss,
        simulation_df = nothing,
    )
    @test size(pos_gauss) == (5, 1000)

    rng2 = Random.MersenneTwister(123)
    pos2 = simulate_race(
        [3.0, 1.0, 0.0, -1.0, -3.0],
        uncertainties;
        n_sims = 10000,
        rng = rng2,
    )
    probs = position_probabilities(pos2; max_position = 5)
    @test size(probs) == (5, 5)
    @test all(sum(probs, dims = 2) .> 0.99)
    @test probs[1, 1] > probs[5, 1]

    teams = ["TeamA", "TeamA", "TeamB", "TeamB", "TeamC"]
    rng3 = Random.MersenneTwister(456)
    pos3 = simulate_race(
        [3.0, 1.0, 0.0, -1.0, -3.0],
        uncertainties;
        n_sims = 10000,
        rng = rng3,
    )
    evg, dsd = expected_vg_points(pos3, teams, SCORING_CAT2)
    @test evg[1] > evg[5] && all(evg .>= 0)
    @test evg[2] > 0  # TeamA rider 2 gets assist points from strong rider 1
    @test all(dsd .>= 0)
end

@testset "estimate_strengths and predict_expected_points" begin
    rider_df = DataFrame(
        rider = ["Strong", "Medium", "Weak", "Also Weak", "Very Weak", "Last"],
        team = ["A", "A", "B", "B", "C", "C"],
        cost = [20, 15, 10, 8, 6, 4],
        points = [500.0, 300.0, 150.0, 100.0, 50.0, 20.0],
        riderkey = ["strong", "medium", "weak", "alsoweak", "veryweak", "last"],
        oneday = [2000, 1200, 800, 500, 200, 50],
    )

    # estimate_strengths returns strength/uncertainty/signal columns
    strengths_df = estimate_strengths(rider_df)
    for col in [:strength, :uncertainty, :shift_pcs, :has_pcs]
        @test col in propertynames(strengths_df)
    end
    @test strengths_df.strength[1] > strengths_df.strength[6]
    @test strengths_df.shift_pcs[1] > 0.0

    # predict_expected_points adds expected_vg_points via MC simulation
    result = predict_expected_points(rider_df, SCORING_CAT2; n_sims = 5000)
    for col in [:expected_vg_points, :strength, :uncertainty, :shift_pcs]
        @test col in propertynames(result)
    end
    @test result.expected_vg_points[1] > result.expected_vg_points[6]
    @test result.strength[1] > result.strength[6]
    @test all(result.expected_vg_points .>= 0)

    # Race history shifts strength estimates
    history_df = DataFrame(
        riderkey = ["strong", "strong", "medium"],
        position = [1, 3, 10],
        year = [2024, 2023, 2024],
    )
    result_hist = predict_expected_points(
        rider_df,
        SCORING_CAT2;
        race_history_df = history_df,
        n_sims = 5000,
    )
    @test result_hist.strength[1] != result.strength[1]

    # Stage race mode uses class-aware blending
    rider_df_stage = copy(rider_df)
    rider_df_stage.classraw =
        ["All Rounder", "Climber", "Sprinter", "Unclassed", "Unclassed", "Unclassed"]
    rider_df_stage.gc = [2000, 500, 200, 800, 100, 50]
    rider_df_stage.tt = [1500, 400, 300, 600, 200, 100]
    rider_df_stage.sprint = [300, 100, 1800, 200, 150, 80]
    rider_df_stage.climber = [1800, 1500, 100, 400, 200, 50]

    result_stage = predict_expected_points(
        rider_df_stage,
        SCORING_STAGE;
        n_sims = 5000,
        race_type = :stage,
    )
    for col in [:expected_vg_points, :strength, :uncertainty]
        @test col in propertynames(result_stage)
    end
    @test all(result_stage.expected_vg_points .>= 0)
end

@testset "join_pcs_specialty! tracks data provenance" begin
    riderdf = DataFrame(rider = ["Found", "Missing"], riderkey = ["found", "missing"])
    pcsriderpts = DataFrame(
        riderkey = ["found", "missing"],
        oneday = [1200, missing],
        gc = [800, missing],
        tt = [600, missing],
        sprint = [300, missing],
        climber = [500, missing],
    )
    result = Velogames.join_pcs_specialty!(riderdf, pcsriderpts)
    @test :has_pcs_data in propertynames(result)
    @test result.has_pcs_data[1] == true   # "Found" had real data
    @test result.has_pcs_data[2] == false  # "Missing" had all missing
    # Coalescing still works
    @test result.oneday[1] == 1200
    @test result.oneday[2] == 0

    # Empty PCS data
    riderdf2 = DataFrame(rider = ["A"], riderkey = ["a"])
    pcsriderpts2 = DataFrame(riderkey = String[])
    result2 = Velogames.join_pcs_specialty!(riderdf2, pcsriderpts2)
    @test :has_pcs_data in propertynames(result2)
    @test result2.has_pcs_data[1] == false
end

@testset "estimate_strengths handles uninformative riders" begin
    rider_df = DataFrame(
        rider = ["Known", "Unknown", "KnownTeammate"],
        team = ["A", "B", "B"],
        cost = [20, 4, 18],
        points = [500.0, 0.0, 400.0],
        riderkey = ["known", "unknown", "knownteammate"],
        oneday = [2000, 0, 1800],
        has_pcs_data = [true, false, true],
    )
    result = estimate_strengths(rider_df)
    # Unknown rider has high uncertainty and low strength
    @test result.uncertainty[2] > result.uncertainty[1]
    @test result.strength[1] > result.strength[2]
    # Known riders have PCS signal
    @test result.has_pcs[1] == true
    @test result.has_pcs[2] == false
end

@testset "Stage race PCS blending" begin
    row = (gc = 1000.0, tt = 500.0, climber = 800.0, sprint = 200.0, oneday = 600.0)

    @test isapprox(compute_stage_race_pcs_score(row, "allrounder"), 825.0; atol = 0.1)
    @test isapprox(compute_stage_race_pcs_score(row, "climber"), 785.0; atol = 0.1)
    @test compute_stage_race_pcs_score(row, "unknown") ==
          compute_stage_race_pcs_score(row, "unclassed")
end

@testset "Variance penalties in strength estimation" begin
    exact = estimate_rider_strength(
        pcs_score = 0.0,
        race_history = [1.5],
        race_history_years_ago = [1],
        race_history_variance_penalties = [0.0],
    )
    similar = estimate_rider_strength(
        pcs_score = 0.0,
        race_history = [1.5],
        race_history_years_ago = [1],
        race_history_variance_penalties = [1.0],
    )
    @test exact.mean > 0.0
    @test similar.mean > 0.0
    @test exact.mean > similar.mean
    @test exact.variance < similar.variance

    no_penalty = estimate_rider_strength(
        pcs_score = 0.0,
        race_history = [1.5],
        race_history_years_ago = [1],
    )
    @test isapprox(no_penalty.mean, exact.mean; atol = 1e-10)
end

@testset "VG race history in strength estimation" begin
    with_vg = estimate_rider_strength(
        pcs_score = 0.0,
        vg_race_history = [2.0, 1.5],
        vg_race_history_years_ago = [1, 2],
    )
    without_vg = estimate_rider_strength(pcs_score = 0.0)

    @test with_vg.mean > without_vg.mean

    recent = estimate_rider_strength(
        pcs_score = 0.0,
        vg_race_history = [2.0],
        vg_race_history_years_ago = [1],
    )
    old = estimate_rider_strength(
        pcs_score = 0.0,
        vg_race_history = [2.0],
        vg_race_history_years_ago = [5],
    )
    @test recent.mean > old.mean
    @test recent.variance < old.variance
end

@testset "predict_expected_points with variance_penalty and vg_history" begin
    rider_df = DataFrame(
        rider = ["Strong", "Medium", "Weak", "Also Weak", "Very Weak", "Last"],
        team = ["A", "A", "B", "B", "C", "C"],
        cost = [20, 15, 10, 8, 6, 4],
        points = [500.0, 300.0, 150.0, 100.0, 50.0, 20.0],
        riderkey = ["strong", "medium", "weak", "alsoweak", "veryweak", "last"],
        oneday = [2000, 1200, 800, 500, 200, 50],
    )

    # Baseline with no history
    baseline = predict_expected_points(rider_df, SCORING_CAT2; n_sims = 5000)

    # History with no variance penalty: strong rider's 1st place should pull strength up
    history_exact = DataFrame(
        riderkey = ["strong", "strong"],
        position = [1, 1],
        year = [2024, 2023],
        variance_penalty = [0.0, 0.0],
    )
    result_exact = predict_expected_points(
        rider_df,
        SCORING_CAT2;
        race_history_df = history_exact,
        n_sims = 5000,
    )
    # History actually shifts strength (not just a no-op)
    @test result_exact.strength[1] != baseline.strength[1]
    @test result_exact.strength[1] > baseline.strength[1]  # two 1st places → upward shift

    # Same history but with penalty=1.0 (similar race): shift should be weaker
    history_penalised = DataFrame(
        riderkey = ["strong", "strong"],
        position = [1, 1],
        year = [2024, 2023],
        variance_penalty = [1.0, 1.0],
    )
    result_penalised = predict_expected_points(
        rider_df,
        SCORING_CAT2;
        race_history_df = history_penalised,
        n_sims = 5000,
    )
    # Penalised history still shifts but by less than exact history
    @test result_penalised.strength[1] > baseline.strength[1]
    @test result_penalised.strength[1] < result_exact.strength[1]

    # VG history shifts strength for riders who have it
    vg_hist = DataFrame(
        riderkey = ["strong", "medium", "weak", "strong", "medium", "weak"],
        score = [500.0, 200.0, 50.0, 450.0, 180.0, 40.0],
        year = [2024, 2024, 2024, 2023, 2023, 2023],
    )
    result_vg = predict_expected_points(
        rider_df,
        SCORING_CAT2;
        vg_history_df = vg_hist,
        n_sims = 5000,
    )
    # VG history shifts strength relative to baseline (not silently ignored)
    @test result_vg.strength[1] != baseline.strength[1]
    @test result_vg.strength[3] != baseline.strength[3]
    # Higher VG scores → stronger upward shift
    @test result_vg.strength[1] > result_vg.strength[3]
end

# =========================================================================
# Cross-season trajectory
# =========================================================================

@testset "Cross-season trajectory signal" begin
    @testset "trajectory shifts strength for improving rider" begin
        rider_df = DataFrame(
            rider = ["Rising", "Declining", "Stable"],
            team = ["A", "B", "C"],
            cost = [15, 15, 15],
            points = [300.0, 300.0, 300.0],
            riderkey = ["rising", "declining", "stable"],
            oneday = [1000, 1000, 1000],
            has_pcs_data = [true, true, true],
        )

        # Seasons data: Rising rider improving, Declining rider getting worse
        seasons_df = DataFrame(
            riderkey = repeat(["rising", "declining", "stable"], inner = 5),
            year = repeat([2022, 2023, 2024, 2025, 2026], 3),
            pcs_points = [
                # Rising: 500 -> 600 -> 800 -> 1200 -> 1500
                500.0,
                600.0,
                800.0,
                1200.0,
                1500.0,
                # Declining: 1500 -> 1200 -> 800 -> 600 -> 500
                1500.0,
                1200.0,
                800.0,
                600.0,
                500.0,
                # Stable: 800 all years
                800.0,
                800.0,
                800.0,
                800.0,
                800.0,
            ],
            pcs_rank = fill(100, 15),
        )

        with_traj = predict_expected_points(
            rider_df,
            SCORING_CAT2;
            n_sims = 5000,
            seasons_df = seasons_df,
            race_year = 2026,
        )

        without_traj = predict_expected_points(
            rider_df,
            SCORING_CAT2;
            n_sims = 5000,
            disable_trajectory = true,
            seasons_df = seasons_df,
            race_year = 2026,
        )

        # Trajectory should produce different expected points
        @test with_traj.shift_trajectory[1] > 0.0   # Rising rider gets positive shift
        @test with_traj.shift_trajectory[2] < 0.0   # Declining rider gets negative shift
        @test with_traj.has_seasons[1] == true
        @test with_traj.has_seasons[2] == true

        # Disabled trajectory should have zero shifts
        @test all(without_traj.shift_trajectory .== 0.0)
    end

    @testset "trajectory handles missing seasons data" begin
        rider_df = DataFrame(
            rider = ["A", "B"],
            team = ["X", "Y"],
            cost = [10, 10],
            points = [200.0, 200.0],
            riderkey = ["a", "b"],
            oneday = [500, 500],
            has_pcs_data = [true, true],
        )

        # No seasons data at all
        result = predict_expected_points(
            rider_df,
            SCORING_CAT2;
            n_sims = 1000,
            seasons_df = nothing,
        )
        @test all(result.shift_trajectory .== 0.0)

        # Only one season (not enough for trajectory)
        single_season = DataFrame(
            riderkey = ["a"],
            year = [2026],
            pcs_points = [1000.0],
            pcs_rank = [50],
        )
        result2 = predict_expected_points(
            rider_df,
            SCORING_CAT2;
            n_sims = 1000,
            seasons_df = single_season,
            race_year = 2026,
        )
        @test result2.shift_trajectory[1] == 0.0
    end

    @testset "getpcsriderseasons_batch empty input" begin
        result = getpcsriderseasons_batch(Dict{String,String}())
        @test nrow(result) == 0
        @test :year in propertynames(result)
        @test :pcs_points in propertynames(result)
        @test :pcs_rank in propertynames(result)
        @test :riderkey in propertynames(result)
    end
end

# =========================================================================
# Qualitative intelligence
# =========================================================================

@testset "Qualitative signal in estimate_rider_strength" begin
    # Positive adjustment should increase strength
    with_qual = estimate_rider_strength(
        pcs_score = 0.0,
        qualitative_adjustments = [0.5],
        qualitative_confidences = [0.8],
    )
    without_qual = estimate_rider_strength(pcs_score = 0.0)
    @test with_qual.mean > without_qual.mean
    @test with_qual.variance < without_qual.variance
    @test with_qual.shift_qualitative > 0.0

    # Negative adjustment should decrease strength
    neg = estimate_rider_strength(
        pcs_score = 0.0,
        qualitative_adjustments = [-0.5],
        qualitative_confidences = [0.8],
    )
    @test neg.mean < without_qual.mean
    @test neg.shift_qualitative < 0.0

    # Higher confidence should have stronger effect
    high_conf = estimate_rider_strength(
        pcs_score = 0.0,
        qualitative_adjustments = [1.0],
        qualitative_confidences = [0.8],
    )
    low_conf = estimate_rider_strength(
        pcs_score = 0.0,
        qualitative_adjustments = [1.0],
        qualitative_confidences = [0.3],
    )
    @test abs(high_conf.shift_qualitative) > abs(low_conf.shift_qualitative)

    # Multiple sources should compound
    multi = estimate_rider_strength(
        pcs_score = 0.0,
        qualitative_adjustments = [0.5, 0.5],
        qualitative_confidences = [0.5, 0.5],
    )
    single = estimate_rider_strength(
        pcs_score = 0.0,
        qualitative_adjustments = [0.5],
        qualitative_confidences = [0.5],
    )
    @test multi.mean > single.mean

    # Zero confidence should be ignored
    zero_conf = estimate_rider_strength(
        pcs_score = 0.0,
        qualitative_adjustments = [1.0],
        qualitative_confidences = [0.0],
    )
    @test zero_conf.shift_qualitative == 0.0
end

@testset "Qualitative response parsing" begin
    json = """[
        {"rider": "Mathieu van der Poel", "category": "strong_positive", "confidence": "high", "reasoning": "Top form."},
        {"rider": "Wout van Aert", "category": "slight_negative", "confidence": "medium", "reasoning": "Returning from injury."}
    ]"""
    df = parse_qualitative_response(json)
    @test nrow(df) == 2
    @test :riderkey in propertynames(df)
    @test :adjustment in propertynames(df)
    @test :confidence in propertynames(df)
    @test df[1, :adjustment] == 1.0    # strong_positive
    @test df[1, :confidence] == 0.8    # high
    @test df[2, :adjustment] == -0.25  # slight_negative
    @test df[2, :confidence] == 0.5    # medium

    # Handles code fences
    fenced = "```json\n$json\n```"
    df2 = parse_qualitative_response(fenced)
    @test nrow(df2) == 2

    # Empty array returns empty DataFrame
    df3 = parse_qualitative_response("[]")
    @test nrow(df3) == 0
    @test :riderkey in propertynames(df3)
end

@testset "Qualitative constants" begin
    @test QUALITATIVE_ADJUSTMENTS["strong_positive"] == 1.0
    @test QUALITATIVE_ADJUSTMENTS["strong_negative"] == -1.0
    @test QUALITATIVE_ADJUSTMENTS["neutral"] == 0.0
    @test QUALITATIVE_CONFIDENCES["high"] == 0.8
    @test QUALITATIVE_CONFIDENCES["low"] == 0.3
end
