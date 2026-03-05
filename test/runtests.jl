using DataFrames
using Velogames
using Test
using JuMP
using Dates
using Random
using Statistics

# =========================================================================
# Smoke test: VG rider scraping
# =========================================================================

@testset "getvgriders" begin
    url = "https://www.velogames.com/velogame/2025/riders.php"
    df = getvgriders(url, force_refresh = true)
    @test typeof(df) == DataFrame

    expected_cols = ["rider", "team", "classraw", "cost", "points", "riderkey", "class"]
    @test all(col in names(df) for col in expected_cols)

    for col in [:cost]
        if hasproperty(df, col)
            @test all(typeof.(df[!, col]) .== Int64)
        end
    end

    for col in [:points, :value]
        if hasproperty(df, col)
            @test all(typeof.(df[!, col]) .== Float64)
        end
    end

    @test length(unique(df.riderkey)) == length(df.riderkey)

    # Caching round-trip
    df_cached = getvgriders(url)
    @test size(df_cached) == size(df)

    if hasproperty(df, :class)
        @test all(typeof.(df[!, :class]) .== String)
        @test all(df.class .== lowercase.(replace.(df.classraw, " " => "")))
    end
end

# =========================================================================
# Utility functions
# =========================================================================

@testset "Utility Functions" begin
    @testset "createkey" begin
        @test createkey("John Doe") isa String
        @test createkey("John Doe") == createkey("john doe")
        @test createkey("José García") != ""
        @test createkey("") == ""
        @test createkey("Tadej Pogačar") == createkey("Tadej Pogačar")
        # Smart quotes (U+2019, U+2018) must produce the same key as ASCII apostrophe
        @test createkey("Ben O'Connor") == createkey("Ben O\u2019Connor")
        @test createkey("Ben O'Connor") == createkey("Ben O\u2018Connor")
        @test createkey("Andrea d'Amato") == createkey("Andrea d\u2019Amato")
    end

    @testset "normalisename and unpipe" begin
        if isdefined(Velogames, :normalisename)
            @test Velogames.normalisename("John Doe") isa String
        end
        if isdefined(Velogames, :unpipe)
            @test Velogames.unpipe("test|pipe") == "test-pipe"
        end
    end
end

@testset "Empty input edge cases" begin
    result = getodds("")
    @test result isa DataFrame
    @test nrow(result) == 0
    @test names(result) == ["rider", "odds", "riderkey"]

    result = get_cycling_oracle("")
    @test result isa DataFrame
    @test nrow(result) == 0
    @test names(result) == ["rider", "win_prob", "riderkey"]
end

@testset "parse_oddschecker_odds" begin
    # Typical Oddschecker copy-paste: name line followed by tab-separated fractional odds
    sample = """
    Strade Bianche Winner
    Some header text
    POGACAR TADEJ
    1/4\t1/3\t\t2/7\t
    VAN DER POEL MATHIEU
    9\t8\t\t10\t
    UNKNOWN RIDER
    header text here
    """

    df = parse_oddschecker_odds(sample)

    @test df isa DataFrame
    @test names(df) == ["rider", "odds", "riderkey"]
    @test nrow(df) == 2

    # Pogacar: best (minimum decimal) of 1/4+1=1.25, 1/3+1=1.333, 2/7+1=1.286 → 1.25
    pog = df[df.riderkey .== createkey("POGACAR TADEJ"), :]
    @test nrow(pog) == 1
    @test pog.odds[1] ≈ 1.25

    # Van der Poel: best of 9+1=10, 8+1=9, 10+1=11 → 9.0
    vdp = df[df.riderkey .== createkey("VAN DER POEL MATHIEU"), :]
    @test nrow(vdp) == 1
    @test vdp.odds[1] ≈ 9.0

    # Empty input returns empty DataFrame with correct schema
    empty_df = parse_oddschecker_odds("")
    @test empty_df isa DataFrame
    @test nrow(empty_df) == 0
    @test names(empty_df) == ["rider", "odds", "riderkey"]
end

# =========================================================================
# Caching
# =========================================================================

@testset "Caching System" begin
    @testset "CacheConfig" begin
        @test DEFAULT_CACHE.max_age_hours == 24
        @test endswith(DEFAULT_CACHE.cache_dir, ".velogames_cache")

        custom_cache = CacheConfig("/tmp/test_cache", 12)
        @test custom_cache.cache_dir == "/tmp/test_cache"
        @test custom_cache.max_age_hours == 12
    end

    @testset "Cache Key Generation" begin
        key1 = Velogames.cache_key("http://example.com")
        key2 = Velogames.cache_key("http://example.com", Dict("param" => "value"))
        key3 = Velogames.cache_key("http://different.com")

        @test length(key1) == 16
        @test key1 != key2
        @test key1 != key3
        @test key2 != key3
    end

    @testset "Cache Clear" begin
        test_cache_dir = "/tmp/velogames_test_cache"
        @test_nowarn clear_cache(test_cache_dir)
    end
end

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

        # Returns nothing when classification columns missing
        result_fallback = build_model_stage(sample_df, 2, :points, :cost)
        @test result_fallback === nothing
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
# Scoring, simulation, and race configuration
# =========================================================================

@testset "Scoring System" begin
    @test SCORING_CAT1.finish_points[1] == 640
    @test SCORING_CAT2.finish_points[1] == 480
    @test SCORING_CAT3.finish_points[1] == 320
    @test SCORING_CAT1.finish_points[30] == 12
    @test SCORING_CAT1.assist_points[1] == 90
    @test SCORING_CAT1.breakaway_points == 60
    @test length(SCORING_CAT1.finish_points) == 30
    @test SCORING_CAT1.finish_points[1] >
          SCORING_CAT2.finish_points[1] >
          SCORING_CAT3.finish_points[1]

    @test SCORING_STAGE.finish_points[1] == 3500
    @test SCORING_STAGE.assist_points == [0, 0, 0]
    @test SCORING_STAGE.breakaway_points == 0
    @test length(SCORING_STAGE.finish_points) == 30

    @test get_scoring(1) === SCORING_CAT1
    @test get_scoring(3) === SCORING_CAT3
    @test get_scoring(:stage) === SCORING_STAGE
    @test_throws ArgumentError get_scoring(0)
    @test_throws ArgumentError get_scoring(4)
    @test_throws ArgumentError get_scoring(:invalid)

    @test finish_points_for_position(1, SCORING_CAT1) == 640
    @test finish_points_for_position(31, SCORING_CAT1) == 0
    @test finish_points_for_position(0, SCORING_CAT1) == 0

    probs_certain_win = zeros(30)
    probs_certain_win[1] = 1.0
    @test expected_finish_points(probs_certain_win, SCORING_CAT1) == 640.0
    @test expected_finish_points(zeros(30), SCORING_CAT1) == 0.0
end

@testset "Race Configuration" begin
    @test length(CLASSICS_RACES_2026) == 44
    @test count(r -> r.category == 1, CLASSICS_RACES_2026) == 7
    @test all(r -> r.category in [1, 2, 3], CLASSICS_RACES_2026)

    omloop = find_race("Omloop")
    @test omloop !== nothing &&
          omloop.category == 2 &&
          omloop.pcs_slug == "omloop-het-nieuwsblad"
    @test find_race("Paris-Roubaix").category == 1
    @test find_race("NonExistentRace") === nothing

    config = RaceConfig(
        "test",
        2025,
        :oneday,
        "test-slug",
        "http://example.com",
        6,
        CacheConfig("/tmp/test", 12),
        2,
        "omloop-het-nieuwsblad",
    )
    @test config.category == 2 && config.pcs_slug == "omloop-het-nieuwsblad"

    pattern = get_url_pattern("omloop")
    @test pattern.category == 2 && pattern.pcs_slug == "omloop-het-nieuwsblad"
    @test get_url_pattern("roubaix").category == 1
    @test get_url_pattern("tdf").category == 0
end

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

    custom_config = BayesianConfig(0.5, 0.5, 2.0, 3.0, 1.0, 0.5, 1.5, 0.5, 0.5, 1.5, 2.5, 2.0, 0.0, 5.0, 100.0)
    custom_result =
        estimate_rider_strength(pcs_score = 1.0, vg_points = 0.5, config = custom_config)
    @test custom_result.mean != default_result.mean

    @test DEFAULT_BAYESIAN_CONFIG isa BayesianConfig
    @test DEFAULT_BAYESIAN_CONFIG.pcs_variance == 2.6
    @test DEFAULT_BAYESIAN_CONFIG.signal_correlation == 0.15
    @test DEFAULT_BAYESIAN_CONFIG.prior_variance == 100.0

    # Equicorrelation discount: more signals → wider posterior with ρ > 0
    no_corr = BayesianConfig(5.0, 1.4, 2.0, 3.0, 3.0, 1.5, 3.0, 0.65, 0.5, 1.5, 2.5, 2.0, 0.0, 5.0, 100.0)
    with_corr = BayesianConfig(5.0, 1.4, 2.0, 3.0, 3.0, 1.5, 3.0, 0.65, 0.5, 1.5, 2.5, 2.0, 0.4, 5.0, 100.0)
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
    evg = expected_vg_points(pos3, teams, SCORING_CAT2)
    @test evg[1] > evg[5] && all(evg .>= 0)
    @test evg[2] > 0  # TeamA rider 2 gets assist points from strong rider 1
end

@testset "predict_expected_points end-to-end" begin
    rider_df = DataFrame(
        rider = ["Strong", "Medium", "Weak", "Also Weak", "Very Weak", "Last"],
        team = ["A", "A", "B", "B", "C", "C"],
        cost = [20, 15, 10, 8, 6, 4],
        points = [500.0, 300.0, 150.0, 100.0, 50.0, 20.0],
        riderkey = ["strong", "medium", "weak", "alsoweak", "veryweak", "last"],
        oneday = [2000, 1200, 800, 500, 200, 50],
    )

    result = predict_expected_points(rider_df, SCORING_CAT2; n_sims = 5000)

    for col in [
        :expected_vg_points,
        :strength,
        :uncertainty,
        :expected_finish_pts,
        :expected_assist_pts,
        :expected_breakaway_pts,
        :shift_pcs,
    ]
        @test col in propertynames(result)
    end

    @test result.expected_vg_points[1] > result.expected_vg_points[6]
    @test result.strength[1] > result.strength[6]
    @test all(result.expected_vg_points .>= 0)
    @test result.shift_pcs[1] > 0.0  # strong rider has positive PCS shift

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
    @test result_hist.strength[1] != result.strength[1]  # history shifts the mean

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
    @test all(result_stage.expected_breakaway_pts .== 0)
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

@testset "predict_expected_points zeros out uninformative riders" begin
    # Unknown rider on same team as a strong rider — gets assist points but no finish/breakaway
    # Zeroing uses two criteria: no external signal (has_any_signal=false) OR
    # posterior uncertainty barely reduced from prior (catches e.g. PCS pages with tiny scores)
    rider_df = DataFrame(
        rider = ["Known", "Unknown", "KnownTeammate"],
        team = ["A", "B", "B"],
        cost = [20, 4, 18],
        points = [500.0, 0.0, 400.0],
        riderkey = ["known", "unknown", "knownteammate"],
        oneday = [2000, 0, 1800],
        has_pcs_data = [true, false, true],
    )
    result = predict_expected_points(rider_df, SCORING_CAT2; n_sims = 5000)
    @test result.expected_vg_points[1] > 0
    # Unknown rider has no external signal — finish/breakaway zeroed,
    # but assist preserved (depends on teammate, not rider's own signal)
    @test result.has_any_signal[2] == false
    @test result.expected_finish_pts[2] == 0.0
    @test result.expected_breakaway_pts[2] == 0.0
    @test result.expected_assist_pts[2] > 0.0  # teammate finishes top 3 sometimes
    @test result.expected_vg_points[2] ≈ result.expected_assist_pts[2] atol = 0.1
    # Known riders have signals and keep their points
    @test result.has_any_signal[1] == true
    @test result.expected_finish_pts[1] > 0
end

@testset "Stage race PCS blending" begin
    row = (gc = 1000.0, tt = 500.0, climber = 800.0, sprint = 200.0, oneday = 600.0)

    @test isapprox(compute_stage_race_pcs_score(row, "allrounder"), 825.0; atol = 0.1)
    @test isapprox(compute_stage_race_pcs_score(row, "climber"), 785.0; atol = 0.1)
    @test compute_stage_race_pcs_score(row, "unknown") ==
          compute_stage_race_pcs_score(row, "unclassed")
end

@testset "PCS Scraper Infrastructure" begin
    @testset "find_column alias resolution" begin
        df = DataFrame("h2hRider" => ["Pogačar"], "Points" => [4852], "Team" => ["UAE"])

        @test Velogames.find_column(df, Velogames.PCS_RIDER_ALIASES) == Symbol("h2hRider")
        @test Velogames.find_column(df, Velogames.PCS_POINTS_ALIASES) == :Points
        @test Velogames.find_column(df, Velogames.PCS_TEAM_ALIASES) == :Team
        @test Velogames.find_column(df, ["nonexistent", "missing"]) === nothing

        df2 = DataFrame("Name" => ["A"], "Rider" => ["B"])
        @test Velogames.find_column(df2, ["rider", "name"]) == :Rider

        df_empty = DataFrame("Rider" => String[])
        @test Velogames.find_column(df_empty, Velogames.PCS_RIDER_ALIASES) == :Rider
    end

    @testset "PCS alias constants" begin
        @test "h2hrider" in Velogames.PCS_RIDER_ALIASES
        @test "rider" in Velogames.PCS_RIDER_ALIASES
        @test "points" in Velogames.PCS_POINTS_ALIASES
        @test "rank" in Velogames.PCS_RANK_ALIASES
        @test "#" in Velogames.PCS_RANK_ALIASES
        @test "team" in Velogames.PCS_TEAM_ALIASES
    end
end

@testset "Similar races mapping" begin
    @test SIMILAR_RACES isa Dict{String,Vector{String}}
    @test haskey(SIMILAR_RACES, "omloop-het-nieuwsblad")
    @test "e3-harelbeke" in SIMILAR_RACES["omloop-het-nieuwsblad"]
    @test haskey(SIMILAR_RACES, "kuurne-brussel-kuurne")
    @test "scheldeprijs" in SIMILAR_RACES["kuurne-brussel-kuurne"]
    @test !haskey(SIMILAR_RACES, "world-championship")
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
    @test with_vg.variance < without_vg.variance

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

    history_df = DataFrame(
        riderkey = ["strong", "strong", "medium", "medium"],
        position = [1, 5, 10, 8],
        year = [2024, 2023, 2024, 2023],
        variance_penalty = [0.0, 0.0, 1.0, 1.0],
    )
    result = predict_expected_points(
        rider_df,
        SCORING_CAT2;
        race_history_df = history_df,
        n_sims = 5000,
    )
    @test all(result.expected_vg_points .>= 0)

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
    @test all(result_vg.expected_vg_points .>= 0)
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

@testset "simulate_vg_points" begin
    rng = Random.MersenneTwister(42)
    strengths = [2.0, 1.0, 0.0, -1.0, -2.0]
    uncertainties = fill(0.5, 5)
    teams = ["A", "A", "B", "B", "C"]

    sim = simulate_race(strengths, uncertainties; n_sims = 10000, rng = rng)

    # Without breakaway should match expected_vg_points
    mean_pts, std_pts, down_std = simulate_vg_points(sim, teams, SCORING_CAT2)
    evg = expected_vg_points(sim, teams, SCORING_CAT2)
    @test length(mean_pts) == 5
    @test length(std_pts) == 5
    @test length(down_std) == 5
    @test all(isapprox.(mean_pts, evg; atol = 0.01))
    @test all(std_pts .>= 0)
    @test all(down_std .>= 0)
    @test std_pts[1] > 0  # strong rider has non-zero SD
    @test down_std[1] > 0  # strong rider has non-zero downside SD
    # Downside semi-deviation <= full SD (only counts below-mean deviations)
    @test all(down_std .<= std_pts .+ 0.01)

    # Stronger riders should have higher mean
    @test mean_pts[1] > mean_pts[5]

    # With breakaway increases mean for one-day scoring
    mean_brk, std_brk, _ =
        simulate_vg_points(sim, teams, SCORING_CAT2; include_breakaway = true)
    @test all(mean_brk .>= mean_pts .- 0.01)  # breakaway adds points (tolerance for float)

    # Stage race scoring has no breakaway points
    mean_stage, _, _ = simulate_vg_points(sim, teams, SCORING_STAGE; include_breakaway = false)
    mean_stage_brk, _, _ =
        simulate_vg_points(sim, teams, SCORING_STAGE; include_breakaway = true)
    # SCORING_STAGE.breakaway_points == 0, so include_breakaway has no effect
    @test all(isapprox.(mean_stage, mean_stage_brk; atol = 0.01))
end

@testset "risk_aversion in predict_expected_points" begin
    rider_df = DataFrame(
        rider = ["Strong", "Medium", "Weak", "Uncertain"],
        team = ["A", "A", "B", "B"],
        cost = [20, 15, 10, 4],
        points = [500.0, 300.0, 150.0, 0.0],
        riderkey = ["strong", "medium", "weak", "uncertain"],
        oneday = [2000, 1200, 800, 50],
        has_pcs_data = [true, true, true, true],
    )

    # gamma=0 recovers current behaviour
    result0 =
        predict_expected_points(rider_df, SCORING_CAT2; n_sims = 5000, risk_aversion = 0.0)
    @test :std_vg_points in propertynames(result0)
    @test :downside_std_vg_points in propertynames(result0)
    @test :risk_adjusted_vg_points in propertynames(result0)
    @test all(result0.risk_adjusted_vg_points .== result0.expected_vg_points)
    # Downside semi-deviation should be <= full SD
    @test all(result0.downside_std_vg_points .<= result0.std_vg_points .+ 0.1)

    # gamma>0 penalises high-uncertainty riders
    result1 =
        predict_expected_points(rider_df, SCORING_CAT2; n_sims = 5000, risk_aversion = 0.5)
    @test all(result1.risk_adjusted_vg_points .<= result1.expected_vg_points .+ 0.1)
    # Ratio-based formula always produces non-negative values
    @test all(result1.risk_adjusted_vg_points .>= 0.0)
    # The uncertain rider (low PCS, high prior variance) should be penalised more
    strong_penalty = result1.expected_vg_points[1] - result1.risk_adjusted_vg_points[1]
    uncertain_penalty = result1.expected_vg_points[4] - result1.risk_adjusted_vg_points[4]
    @test uncertain_penalty >= 0
    @test strong_penalty >= 0
end

@testset "risk-adjusted team selection integration" begin
    rng = Random.MersenneTwister(42)
    # Create a field with some reliable riders and some lottery tickets
    rider_df = DataFrame(
        rider = ["R$i" for i = 1:12],
        team = repeat(["A", "B", "C", "D"], 3),
        cost = [20, 18, 16, 14, 12, 10, 8, 6, 5, 4, 4, 4],
        points = Float64.([500, 400, 350, 300, 250, 200, 150, 100, 80, 0, 0, 0]),
        riderkey = ["r$i" for i = 1:12],
        oneday = [2000, 1500, 1200, 1000, 800, 600, 400, 300, 200, 10, 10, 10],
        has_pcs_data = [trues(9); trues(3)],
    )

    predicted = predict_expected_points(
        rider_df,
        SCORING_CAT2;
        n_sims = 5000,
        rng = rng,
        risk_aversion = 0.5,
    )

    # Optimise on risk-adjusted column
    sol = build_model_oneday(predicted, 6, :risk_adjusted_vg_points, :cost; totalcost = 100)
    @test sol !== nothing

    chosen = filter(row -> JuMP.value(sol[row.riderkey]) > 0.5, predicted)
    @test nrow(chosen) == 6
    @test sum(chosen.cost) <= 100
end

@testset "ratio risk metric handles no-signal riders correctly" begin
    rider_df = DataFrame(
        rider = ["Star", "Solid", "Unknown"],
        team = ["A", "B", "C"],
        cost = [20, 12, 4],
        points = [500.0, 200.0, 0.0],
        riderkey = ["star", "solid", "unknown"],
        oneday = [2000, 800, 0],
        has_pcs_data = [true, true, false],
    )
    result = predict_expected_points(
        rider_df, SCORING_CAT2; n_sims = 5000, risk_aversion = 1.0,
    )
    # Ratio formula is always non-negative
    @test all(result.risk_adjusted_vg_points .>= 0.0)
    # Known riders should have higher risk-adjusted points than the unknown rider
    @test result.risk_adjusted_vg_points[1] > result.risk_adjusted_vg_points[3]
    @test result.risk_adjusted_vg_points[2] > result.risk_adjusted_vg_points[3]
end

# =========================================================================
# Backtesting framework
# =========================================================================

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

    @testset "ABLATION_SETS is well-formed" begin
        @test length(Velogames.ABLATION_SETS) == 11
        for (label, sigs) in Velogames.ABLATION_SETS
            @test label isa String
            @test sigs isa Vector{Symbol}
        end
        labels = [l for (l, _) in Velogames.ABLATION_SETS]
        @test "no_signals" in labels
        @test "baseline" in labels
        @test "baseline+odds" in labels
        @test "baseline+oracle" in labels
    end

    @testset "PARAM_BOUNDS are valid" begin
        for field in fieldnames(typeof(Velogames.PARAM_BOUNDS))
            lo, hi = getfield(Velogames.PARAM_BOUNDS, field)
            @test lo < hi
            @test lo >= 0
        end
    end

    @testset "_average_ranks" begin
        ranks = Velogames._average_ranks([30.0, 10.0, 20.0])
        @test ranks == [3.0, 1.0, 2.0]

        ranks2 = Velogames._average_ranks([10.0, 10.0, 20.0])
        @test ranks2[1] == 1.5
        @test ranks2[2] == 1.5
        @test ranks2[3] == 3.0
    end

    @testset "_random_bayesian_config produces valid configs" begin
        rng = Random.MersenneTwister(42)
        config = Velogames._random_bayesian_config(rng)
        @test config.pcs_variance >= Velogames.PARAM_BOUNDS.pcs_variance[1]
        @test config.pcs_variance <= Velogames.PARAM_BOUNDS.pcs_variance[2]
        @test config.vg_variance >= Velogames.PARAM_BOUNDS.vg_variance[1]
        @test config.vg_variance <= Velogames.PARAM_BOUNDS.vg_variance[2]
        @test config.form_variance >= Velogames.PARAM_BOUNDS.form_variance[1]
        @test config.form_variance <= Velogames.PARAM_BOUNDS.form_variance[2]
        @test config.hist_base_variance >= Velogames.PARAM_BOUNDS.hist_base_variance[1]
        @test config.hist_base_variance <= Velogames.PARAM_BOUNDS.hist_base_variance[2]
        @test config.odds_variance >= Velogames.PARAM_BOUNDS.odds_variance[1]
        @test config.odds_variance <= Velogames.PARAM_BOUNDS.odds_variance[2]
        @test config.oracle_variance == DEFAULT_BAYESIAN_CONFIG.oracle_variance
        @test config.odds_normalisation == DEFAULT_BAYESIAN_CONFIG.odds_normalisation
        @test config.prior_variance == DEFAULT_BAYESIAN_CONFIG.prior_variance
    end
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
                500.0, 600.0, 800.0, 1200.0, 1500.0,
                # Declining: 1500 -> 1200 -> 800 -> 600 -> 500
                1500.0, 1200.0, 800.0, 600.0, 500.0,
                # Stable: 800 all years
                800.0, 800.0, 800.0, 800.0, 800.0,
            ],
            pcs_rank = fill(100, 15),
        )

        with_traj = predict_expected_points(
            rider_df, SCORING_CAT2;
            n_sims = 5000,
            seasons_df = seasons_df,
            race_year = 2026,
        )

        without_traj = predict_expected_points(
            rider_df, SCORING_CAT2;
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
            rider_df, SCORING_CAT2;
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
            rider_df, SCORING_CAT2;
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
# Race name matching and VG integration
# =========================================================================

@testset "normalise_race_name" begin
    @test Velogames.normalise_race_name("Omloop Nieuwsblad") ==
          Velogames.normalise_race_name("omloop nieuwsblad")

    @test Velogames.normalise_race_name("Liège-Bastogne-Liège") ==
          Velogames.normalise_race_name("Liege-Bastogne-Liege")

    name = Velogames.normalise_race_name("Milano-Sanremo")
    @test !occursin("-", name)
    @test !isempty(name)
end

@testset "match_vg_race_number" begin
    mock_racelist = DataFrame(
        race_number = [1, 2, 3, 4],
        deadline = [
            "2025-03-01 12:00",
            "2025-03-02 12:00",
            "2025-03-08 12:00",
            "2025-04-06 12:00",
        ],
        name = [
            "Omloop Nieuwsblad",
            "Kuurne-Brussel-Kuurne",
            "Strade Bianche",
            "Ronde van Vlaanderen",
        ],
        category = [2, 3, 2, 1],
        namekey = Velogames.normalise_race_name.([
            "Omloop Nieuwsblad",
            "Kuurne-Brussel-Kuurne",
            "Strade Bianche",
            "Ronde van Vlaanderen",
        ]),
    )

    @test match_vg_race_number("Omloop Nieuwsblad", mock_racelist) == 1
    @test match_vg_race_number("Kuurne-Brussel-Kuurne", mock_racelist) == 2
    @test match_vg_race_number("Ronde van Vlaanderen", mock_racelist) == 4
    @test match_vg_race_number("Tour de France", mock_racelist) === nothing

    empty_racelist = DataFrame(
        race_number = Int[],
        deadline = String[],
        name = String[],
        category = Int[],
        namekey = String[],
    )
    @test match_vg_race_number("Omloop", empty_racelist) === nothing
end

@testset "_compute_cumulative_vg_points edge cases" begin
    race_no_date = BacktestRace("Test", 2024, "test-slug", 2, 5, nothing)
    @test Velogames._compute_cumulative_vg_points(race_no_date) === nothing
end

# =========================================================================
# Archival storage
# =========================================================================

@testset "Archive round-trips for all data types" begin
    test_archive = mktempdir()

    # Odds
    odds_df = DataFrame(rider = ["A", "B"], odds = [2.5, 5.0], riderkey = ["a", "b"])
    save_race_snapshot(odds_df, "odds", "test-race", 2025; archive_dir = test_archive)
    loaded = load_race_snapshot("odds", "test-race", 2025; archive_dir = test_archive)
    @test loaded !== nothing
    @test nrow(loaded) == 2
    @test "A" in loaded.rider
    @test :odds in propertynames(loaded)

    # Oracle
    oracle_df = DataFrame(rider = ["A", "B"], win_prob = [0.3, 0.1], riderkey = ["a", "b"])
    save_race_snapshot(oracle_df, "oracle", "test-race", 2025; archive_dir = test_archive)
    loaded = load_race_snapshot("oracle", "test-race", 2025; archive_dir = test_archive)
    @test loaded !== nothing
    @test nrow(loaded) == 2
    @test :win_prob in propertynames(loaded)

    # VG results
    vg_df = DataFrame(
        rider = ["A", "B"],
        team = ["T1", "T2"],
        score = [500, 200],
        riderkey = ["a", "b"],
    )
    save_race_snapshot(vg_df, "vg_results", "test-race", 2024; archive_dir = test_archive)
    loaded = load_race_snapshot("vg_results", "test-race", 2024; archive_dir = test_archive)
    @test loaded !== nothing
    @test nrow(loaded) == 2
    @test :score in propertynames(loaded)

    # PCS specialty
    pcs_df = DataFrame(
        riderkey = ["a", "b"],
        oneday = [1000, 500],
        gc = [800, 300],
        tt = [600, 200],
        sprint = [100, 400],
        climber = [700, 100],
    )
    save_race_snapshot(
        pcs_df,
        "pcs_specialty",
        "test-race",
        2025;
        archive_dir = test_archive,
    )
    loaded =
        load_race_snapshot("pcs_specialty", "test-race", 2025; archive_dir = test_archive)
    @test loaded !== nothing
    @test nrow(loaded) == 2
    @test :oneday in propertynames(loaded)
    @test :gc in propertynames(loaded)
    @test :tt in propertynames(loaded)

    # Overwrite behaviour
    save_race_snapshot(
        odds_df[1:1, :],
        "odds",
        "test-race",
        2025;
        archive_dir = test_archive,
    )
    loaded = load_race_snapshot("odds", "test-race", 2025; archive_dir = test_archive)
    @test nrow(loaded) == 1

    # Missing snapshot returns nothing
    @test load_race_snapshot("odds", "nonexistent", 2025; archive_dir = test_archive) ===
          nothing

    # archive_path produces expected structure
    p = archive_path("oracle", "milano-sanremo", 2024; archive_dir = test_archive)
    @test endswith(p, joinpath("oracle", "milano-sanremo", "2024.feather"))
end

@testset "Race lookup helpers" begin
    @testset "_find_race_by_slug" begin
        ri = Velogames._find_race_by_slug("paris-roubaix")
        @test ri !== nothing
        @test ri.name == "Paris-Roubaix"
        @test ri.category == 1

        @test Velogames._find_race_by_slug("nonexistent-race") === nothing
    end

    @testset "_race_date_for_year" begin
        ri = Velogames._find_race_by_slug("paris-roubaix")
        @test ri !== nothing
        d = Velogames._race_date_for_year(ri, 2024)
        @test Dates.year(d) == 2024
        @test Dates.month(d) == Dates.month(Date(ri.date))
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
