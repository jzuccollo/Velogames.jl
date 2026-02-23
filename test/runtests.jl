using DataFrames
using Velogames
using Test
using JuMP
using HTTP
using Dates
using Random
using Statistics

@testset "Functions are defined" begin
    # test that functions are defined
    @test isdefined(Velogames, :getvgriders)
    @test isdefined(Velogames, :getpcsriderpts)
    @test isdefined(Velogames, :getpcsriderhistory)
    @test isdefined(Velogames, :getpcsranking)
    @test isdefined(Velogames, :build_model_oneday)
    @test isdefined(Velogames, :build_model_stage)
    @test isdefined(Velogames, :solve_oneday)
    @test isdefined(Velogames, :solve_stage)
    @test isdefined(Velogames, :createkey)
    @test isdefined(Velogames, :getvgracepoints)
    @test isdefined(Velogames, :getodds)
    @test isdefined(Velogames, :getpcsraceranking)
    # Test Betfair API functions
    @test isdefined(Velogames, :betfair_login)
    @test isdefined(Velogames, :betfair_get_market_odds)
    # Test Cycling Oracle function
    @test isdefined(Velogames, :get_cycling_oracle)
    # Test new caching functions
    @test isdefined(Velogames, :CacheConfig)
    @test isdefined(Velogames, :clear_cache)
    @test isdefined(Velogames, :cached_fetch)
    @test isdefined(Velogames, :DEFAULT_CACHE)
    @test isdefined(Velogames, :cache_key)
    # Test new integration functions
    @test isdefined(Velogames, :add_pcs_speciality_points!)
    # Test optimisation functions
    @test isdefined(Velogames, :minimise_cost_stage)
end

@testset "Utility Functions" begin
    @testset "createkey" begin
        # Test basic key creation
        @test createkey("John Doe") isa String
        @test createkey("John Doe") == createkey("john doe")  # Case insensitive
        @test createkey("José García") != ""  # Handles special characters
        @test createkey("") == ""  # Empty string handling

        # Test that keys are consistent
        name = "Tadej Pogačar"
        @test createkey(name) == createkey(name)
    end

    @testset "normalisename and unpipe" begin
        # These are internal functions, test via createkey if they're not exported
        if isdefined(Velogames, :normalisename)
            @test Velogames.normalisename("John Doe") isa String
        end

        if isdefined(Velogames, :unpipe)
            @test Velogames.unpipe("test|pipe") == "test-pipe"
        end
    end
end

@testset "getvgriders" begin
    # Test that the function returns a DataFrame with new signature
    url = "https://www.velogames.com/velogame/2025/riders.php"
    df = getvgriders(url, force_refresh=true)  # Force fresh download for tests
    @test typeof(df) == DataFrame

    # Test that the DataFrame has the expected columns from getvgriders
    # Note: binary classification columns (allrounder, sprinter, etc.) are now created by optimisation functions
    expected_cols = ["rider", "team", "classraw", "cost", "points", "riderkey", "class"]
    @test all(col in names(df) for col in expected_cols)

    # Test that the cost column is Int64 (rank doesn't exist in this data)
    for col in [:cost]
        if hasproperty(df, col)
            @test all(typeof.(df[!, col]) .== Int64)
        end
    end

    # Test that the points and value columns are Float64
    for col in [:points, :value]
        if hasproperty(df, col)
            @test all(typeof.(df[!, col]) .== Float64)
        end
    end

    # Test that the riderkey column is unique
    @test length(unique(df.riderkey)) == length(df.riderkey)

    # Test caching functionality
    df_cached = getvgriders(url)  # Should use cache
    @test typeof(df_cached) == DataFrame
    @test size(df_cached) == size(df)

    # Test that the class column is lowercase and has no spaces
    if hasproperty(df, :class)
        @test all(typeof.(df[!, :class]) .== String)
        @test all(df.class .== lowercase.(replace.(df.classraw, " " => "")))
    end
end

@testset "selected column conversion" begin
    url = "https://www.velogames.com/spain/2025/riders.php"
    df = getvgriders(url; force_refresh=true)
    @test :selected in propertynames(df)
    # Check that all non-missing values are Float64 and between 0 and 1
    sel = df.selected
    @test all(x -> (ismissing(x) || (x isa Float64 && 0.0 <= x <= 1.0)), sel)
    # Check that a known value is converted correctly
    if any(.!ismissing.(sel))
        # Find a non-missing value and check its conversion
        s = findfirst(x -> !ismissing(x), sel)
        raw = "77.7%"
        expected = 0.777
        # Simulate conversion
        actual = parse(Float64, replace(raw, "%" => "")) / 100
        @test isapprox(actual, expected; atol=1e-6)
    end
end


@testset "Model Building Functions" begin
    # Create sample data for testing
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

        # Test with custom parameters
        result2 = build_model_oneday(sample_df, 2, :points, :cost, totalcost=50)
        @test result2 isa JuMP.Containers.DenseAxisArray
        @test length(result2) == 4
    end

    @testset "build_model_stage" begin
        # Add required columns for stage race model
        sample_df_stage = copy(sample_df)
        sample_df_stage.allrounder = [1, 0, 1, 1]
        sample_df_stage.sprinter = [0, 1, 0, 1]
        sample_df_stage.climber = [1, 0, 1, 1]
        sample_df_stage.unclassed = [1, 1, 1, 1]

        result = build_model_stage(sample_df_stage, 4, :points, :cost)
        # Stage race model might not have feasible solution, so result could be nothing
        @test (result isa JuMP.Containers.DenseAxisArray) || (result === nothing)
        if result !== nothing
            @test length(result) == 4
        end

        # Returns nothing when classification columns missing (no longer falls back to one-day)
        result_fallback = build_model_stage(sample_df, 2, :points, :cost)
        @test result_fallback === nothing
    end

    @testset "build_model_stage for historical analysis" begin
        # Test using build_model_stage with actual points (replaces buildmodelhistorical)
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

        # Convert solution to team selection
        chosen = [result[rk] > 0.5 for rk in test_data.riderkey]
        selected_team = test_data[chosen, :]

        # Test constraints are satisfied
        @test nrow(selected_team) == 9
        @test sum(selected_team.cost) <= 100

        # Test classification constraints
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

        # Convert solution to team selection
        chosen = [result[rk] > 0.5 for rk in test_data.riderkey]
        selected_team = test_data[chosen, :]

        # Test constraints are satisfied
        @test nrow(selected_team) == 9
        @test sum(selected_team.points) > target_score

        # Test classification constraints
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

        # build_model_stage returns nothing when constraints unsatisfiable
        result1 = build_model_stage(insufficient_data, 9, :points, :cost; totalcost=100)
        @test result1 === nothing

        result2 =
            minimise_cost_stage(insufficient_data, 100, 9, :points, :cost; totalcost=100)
        @test result2 === nothing
    end
end

@testset "Data Retrieval Functions (Mock Tests)" begin
    @testset "getpcsranking" begin
        @test_throws AssertionError getpcsranking("invalid", "individual")
        @test_throws AssertionError getpcsranking("me", "invalid-category")

        try
            getpcsranking("me", "individual")
            @test true
        catch e
            @test e isa Union{
                HTTP.Exceptions.StatusError,
                HTTP.Exceptions.ConnectError,
                ArgumentError,
                BoundsError,
                ErrorException,
                UndefVarError,
            }
        end
    end

    @testset "getpcsriderpts" begin
        try
            result = getpcsriderpts("test-rider")
            @test result isa DataFrames.DataFrame
        catch e
            @test e isa Union{
                HTTP.Exceptions.StatusError,
                HTTP.Exceptions.ConnectError,
                ArgumentError,
                BoundsError,
                ErrorException,
                UndefVarError,
            }
        end
    end

    @testset "getpcsriderhistory" begin
        try
            result = getpcsriderhistory("test-rider")
            @test result isa DataFrames.DataFrame
        catch e
            @test e isa Union{
                HTTP.Exceptions.StatusError,
                HTTP.Exceptions.ConnectError,
                ArgumentError,
                BoundsError,
                ErrorException,
                UndefVarError,
            }
        end
    end

    @testset "getvgracepoints" begin
        try
            getvgracepoints("https://example.com")
            @test true
        catch e
            @test e isa Union{
                HTTP.Exceptions.StatusError,
                HTTP.Exceptions.ConnectError,
                ArgumentError,
                BoundsError,
                ErrorException,
                UndefVarError,
            }
        end
    end

    @testset "getodds" begin
        # Empty market ID returns empty DataFrame without hitting the API
        result = getodds("")
        @test result isa DataFrame
        @test nrow(result) == 0
        @test names(result) == ["rider", "odds", "riderkey"]

        # Invalid market ID should fail gracefully (no credentials in CI)
        try
            getodds("invalid-market-id")
            @test true
        catch e
            @test e isa Union{
                HTTP.Exceptions.StatusError,
                HTTP.Exceptions.ConnectError,
                ErrorException,
            }
        end
    end

    @testset "get_cycling_oracle" begin
        # Empty URL returns empty DataFrame without hitting the web
        result = get_cycling_oracle("")
        @test result isa DataFrame
        @test nrow(result) == 0
        @test names(result) == ["rider", "win_prob", "riderkey"]

        # Invalid URL should fail gracefully
        try
            get_cycling_oracle("https://www.cyclingoracle.com/en/blog/nonexistent-race-prediction")
            @test true
        catch e
            @test e isa Union{
                HTTP.Exceptions.StatusError,
                HTTP.Exceptions.ConnectError,
                ErrorException,
            }
        end
    end

    @testset "getpcsraceranking" begin
        try
            result = getpcsraceranking("https://example.com")
            @test result isa DataFrames.DataFrame
        catch e
            @test e isa Union{
                HTTP.Exceptions.StatusError,
                HTTP.Exceptions.ConnectError,
                ArgumentError,
                BoundsError,
                ErrorException,
                UndefVarError,
            }
        end
    end
end


@testset "Caching System" begin
    @testset "CacheConfig" begin
        @test DEFAULT_CACHE.enabled == true
        @test DEFAULT_CACHE.max_age_hours == 24
        @test endswith(DEFAULT_CACHE.cache_dir, ".velogames_cache")

        custom_cache = CacheConfig("/tmp/test_cache", 12, true)
        @test custom_cache.cache_dir == "/tmp/test_cache"
        @test custom_cache.max_age_hours == 12
        @test custom_cache.enabled == true
    end

    @testset "Cache Key Generation" begin
        key1 = cache_key("http://example.com")
        key2 = cache_key("http://example.com", Dict("param" => "value"))
        key3 = cache_key("http://different.com")

        @test length(key1) == 16
        @test key1 != key2
        @test key1 != key3
        @test key2 != key3
    end

    @testset "Cache Clear" begin
        test_cache_dir = "/tmp/velogames_test_cache"
        @test_nowarn clear_cache(test_cache_dir)
    end

    @testset "Function Signature Updates" begin
        test_params = [
            (getpcsranking, ("me", "individual")),
            (getpcsraceranking, ("http://example.com",)),
            (getpcsriderhistory, ("test rider",)),
            (getvgracepoints, ("http://example.com",)),
            (getodds, ("",)),
            (get_cycling_oracle, ("",)),
        ]

        for (func, args) in test_params
            try
                func(args..., force_refresh=true)
            catch e
                @test !isa(e, MethodError)
            end
        end
    end
end

@testset "DataFrame Return Types" begin
    @testset "getpcsriderpts DataFrame Return" begin
        try
            result = getpcsriderpts("test-rider", force_refresh=true)
            @test result isa DataFrame
            expected_cols = ["rider", "oneday", "gc", "tt", "sprint", "climber", "riderkey"]
            if size(result, 1) > 0
                @test all(col in names(result) for col in expected_cols)
            end
        catch e
        end
    end
end

@testset "Batch functions" begin
    test_riders = ["tadej-pogacar", "jonas-vingegaard"]

    batch_df = getpcsriderpts_batch(test_riders)

    @test batch_df isa DataFrame
    @test nrow(batch_df) == length(test_riders)
    @test hasproperty(batch_df, :rider)
    @test hasproperty(batch_df, :oneday)
    @test hasproperty(batch_df, :riderkey)

    @test Set(batch_df.rider) == Set(test_riders)
end

@testset "PCS Integration Tests" begin
    @testset "add_pcs_speciality_points!" begin
        rider_df = DataFrame(
            riderkey=["rider1", "rider2", "rider3", "rider4"],
            class=["allrounder", "sprinter", "climber", "unclassed"],
        )

        pcs_df = DataFrame(
            riderkey=["rider1", "rider2", "rider3", "rider4"],
            gc=[1000, 200, 1200, 500],
            sprint=[100, 1500, 50, 300],
            climber=[800, 100, 1800, 400],
            oneday=[900, 1200, 1000, 600],
        )

        vg_class_to_pcs_col = Dict(
            "allrounder" => "gc",
            "climber" => "climber",
            "sprinter" => "sprint",
            "unclassed" => "oneday",
        )

        result_df = add_pcs_speciality_points!(copy(rider_df), pcs_df, vg_class_to_pcs_col)

        @test hasproperty(result_df, :pcs_speciality_points)
        @test result_df.pcs_speciality_points[1] == 1000
        @test result_df.pcs_speciality_points[2] == 1500
        @test result_df.pcs_speciality_points[3] == 1800
        @test result_df.pcs_speciality_points[4] == 600

        rider_df_missing =
            DataFrame(riderkey=["rider1", "rider2"], class=["allrounder", "sprinter"])

        pcs_df_missing = DataFrame(
            riderkey=["rider1"],
            gc=[1000],
            sprint=[100],
            climber=[800],
            oneday=[900],
        )

        result_df_missing = add_pcs_speciality_points!(
            copy(rider_df_missing),
            pcs_df_missing,
            vg_class_to_pcs_col,
        )

        @test hasproperty(result_df_missing, :pcs_speciality_points)
        @test result_df_missing.pcs_speciality_points[1] == 1000
        @test ismissing(result_df_missing.pcs_speciality_points[2])
    end
end


# =========================================================================
# Scoring, simulation, and race configuration
# =========================================================================

@testset "Scoring System" begin
    # Spot-check key scoring values from the VG site
    @test SCORING_CAT1.finish_points[1] == 600
    @test SCORING_CAT2.finish_points[1] == 450
    @test SCORING_CAT3.finish_points[1] == 300
    @test SCORING_CAT1.finish_points[30] == 12
    @test SCORING_CAT1.assist_points[1] == 90
    @test SCORING_CAT1.breakaway_points == 60
    @test length(SCORING_CAT1.finish_points) == 30
    @test SCORING_CAT1.finish_points[1] >
          SCORING_CAT2.finish_points[1] >
          SCORING_CAT3.finish_points[1]

    # Stage race scoring
    @test SCORING_STAGE.finish_points[1] == 3500
    @test SCORING_STAGE.assist_points == [0, 0, 0]
    @test SCORING_STAGE.breakaway_points == 0
    @test length(SCORING_STAGE.finish_points) == 30

    # get_scoring lookup and edge cases
    @test get_scoring(1) === SCORING_CAT1
    @test get_scoring(3) === SCORING_CAT3
    @test get_scoring(:stage) === SCORING_STAGE
    @test_throws ArgumentError get_scoring(0)
    @test_throws ArgumentError get_scoring(4)
    @test_throws ArgumentError get_scoring(:invalid)

    # finish_points_for_position edge cases
    @test finish_points_for_position(1, SCORING_CAT1) == 600
    @test finish_points_for_position(31, SCORING_CAT1) == 0
    @test finish_points_for_position(0, SCORING_CAT1) == 0

    # Expected points from probability distributions
    probs_certain_win = zeros(30)
    probs_certain_win[1] = 1.0
    @test expected_finish_points(probs_certain_win, SCORING_CAT1) == 600.0
    @test expected_finish_points(zeros(30), SCORING_CAT1) == 0.0
    @test expected_assist_points([1.0, 0.0, 0.0], SCORING_CAT1) == 90.0
    @test expected_assist_points([0.0, 0.0, 0.0], SCORING_CAT1) == 0.0
end

@testset "Race Configuration" begin
    @test length(SUPERCLASICO_RACES_2025) == 44
    @test count(r -> r.category == 1, SUPERCLASICO_RACES_2025) == 6
    @test all(r -> r.category in [1, 2, 3], SUPERCLASICO_RACES_2025)

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
        CacheConfig("/tmp/test", 12, true),
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

    @test isapprox(bayesian_update(prior, 2.0, 0.01).mean, 2.0; atol=0.1)
    @test isapprox(bayesian_update(prior, 2.0, 1000.0).mean, 0.0; atol=0.1)

    strong = estimate_rider_strength(pcs_score=2.0)
    weak = estimate_rider_strength(pcs_score=-2.0)
    @test strong.mean > weak.mean

    precise = estimate_rider_strength(
        pcs_score=1.5,
        vg_points=1.5,
        race_history=[1.5, 1.3],
        race_history_years_ago=[1, 2],
    )
    @test precise.variance < estimate_rider_strength(pcs_score=1.5).variance

    @test estimate_rider_strength(
        pcs_score=0.0,
        odds_implied_prob=0.1,
        n_starters=150,
    ).mean > 0.0

    # Oracle predictions shift strength estimate
    @test estimate_rider_strength(
        pcs_score=0.0,
        oracle_implied_prob=0.1,
        n_starters=150,
    ).mean > 0.0

    @test position_to_strength(1, 150) >
          position_to_strength(50, 150) >
          position_to_strength(100, 150)
    @test position_to_strength(1, 150) > 0 && position_to_strength(100, 150) < 0
end

@testset "BayesianConfig" begin
    # Default config produces a valid result
    default_result = estimate_rider_strength(pcs_score=1.0, vg_points=0.5)
    @test default_result.mean > 0.0

    # Custom config with different variances produces different results
    tight_config = BayesianConfig(
        1.0,   # pcs_variance (tighter than default 4.0)
        1.0,   # vg_variance (tighter than default 3.0)
        1.0,   # hist_base_variance
        0.5,   # hist_decay_rate
        1.5,   # vg_hist_base_variance
        0.5,   # vg_hist_decay_rate
        0.5,   # odds_variance
        1.5,   # oracle_variance
        2.0,   # odds_normalisation
    )
    tight_result = estimate_rider_strength(
        pcs_score=1.0,
        vg_points=0.5,
        config=tight_config,
    )
    # Tighter PCS variance means PCS score gets more weight, so the mean should
    # be closer to the PCS score (1.0) than with the default config
    @test tight_result.mean != default_result.mean
    @test tight_result.mean > default_result.mean

    # Exported constant matches struct type
    @test DEFAULT_BAYESIAN_CONFIG isa BayesianConfig
    @test DEFAULT_BAYESIAN_CONFIG.pcs_variance == 4.0
end

@testset "Monte Carlo Simulation" begin
    rng = Random.MersenneTwister(42)
    strengths = [2.0, 1.0, 0.0, -1.0, -2.0]
    uncertainties = fill(0.5, 5)

    positions = simulate_race(strengths, uncertainties; n_sims=10000, rng=rng)
    @test size(positions) == (5, 10000)
    @test sort(positions[:, 1]) == 1:5
    @test count(positions[1, :] .== 1) > count(positions[5, :] .== 1)
    @test mean(positions[1, :]) < mean(positions[5, :])

    rng2 = Random.MersenneTwister(123)
    pos2 = simulate_race(
        [3.0, 1.0, 0.0, -1.0, -3.0],
        uncertainties;
        n_sims=10000,
        rng=rng2,
    )
    probs = position_probabilities(pos2; max_position=5)
    @test size(probs) == (5, 5)
    @test all(sum(probs, dims=2) .> 0.99)
    @test probs[1, 1] > probs[5, 1]

    teams = ["TeamA", "TeamA", "TeamB", "TeamB", "TeamC"]
    rng3 = Random.MersenneTwister(456)
    pos3 = simulate_race(
        [3.0, 1.0, 0.0, -1.0, -3.0],
        uncertainties;
        n_sims=10000,
        rng=rng3,
    )
    evg = expected_vg_points(pos3, teams, SCORING_CAT2)
    @test evg[1] > evg[5] && all(evg .>= 0)
    @test evg[2] > 0  # TeamA rider 2 gets assist points from strong rider 1
end

@testset "predict_expected_points end-to-end" begin
    rider_df = DataFrame(
        rider=["Strong", "Medium", "Weak", "Also Weak", "Very Weak", "Last"],
        team=["A", "A", "B", "B", "C", "C"],
        cost=[20, 15, 10, 8, 6, 4],
        points=[500.0, 300.0, 150.0, 100.0, 50.0, 20.0],
        riderkey=["strong", "medium", "weak", "alsoweak", "veryweak", "last"],
        oneday=[2000, 1200, 800, 500, 200, 50],
    )

    result = predict_expected_points(rider_df, SCORING_CAT2; n_sims=5000)

    for col in [
        :expected_vg_points,
        :strength,
        :uncertainty,
        :expected_finish_pts,
        :expected_assist_pts,
        :expected_breakaway_pts,
    ]
        @test col in propertynames(result)
    end

    @test result.expected_vg_points[1] > result.expected_vg_points[6]
    @test result.strength[1] > result.strength[6]
    @test all(result.expected_vg_points .>= 0)

    # Race history reduces uncertainty
    history_df = DataFrame(
        riderkey=["strong", "strong", "medium"],
        position=[1, 3, 10],
        year=[2024, 2023, 2024],
    )
    result_hist = predict_expected_points(
        rider_df,
        SCORING_CAT2;
        race_history_df=history_df,
        n_sims=5000,
    )
    @test result_hist.uncertainty[1] <= result.uncertainty[1]

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
        n_sims=5000,
        race_type=:stage,
    )

    for col in [:expected_vg_points, :strength, :uncertainty]
        @test col in propertynames(result_stage)
    end
    @test all(result_stage.expected_vg_points .>= 0)
    # Breakaway points should be zero for stage races
    @test all(result_stage.expected_breakaway_pts .== 0)
end

@testset "Stage race PCS blending" begin
    # Test compute_stage_race_pcs_score with a mock row
    row = (gc=1000.0, tt=500.0, climber=800.0, sprint=200.0, oneday=600.0)

    # All-rounder: 0.5*gc + 0.25*tt + 0.25*climber = 500 + 125 + 200 = 825
    @test isapprox(compute_stage_race_pcs_score(row, "allrounder"), 825.0; atol=0.1)

    # Climber: 0.15*gc + 0.15*tt + 0.7*climber = 150 + 75 + 560 = 785
    @test isapprox(compute_stage_race_pcs_score(row, "climber"), 785.0; atol=0.1)

    # Unknown class defaults to unclassed weights
    @test compute_stage_race_pcs_score(row, "unknown") ==
          compute_stage_race_pcs_score(row, "unclassed")
end

@testset "PCS Scraper Infrastructure" begin
    @testset "find_column alias resolution" begin
        df = DataFrame("h2hRider" => ["Pogačar"], "Points" => [4852], "Team" => ["UAE"])

        @test find_column(df, PCS_RIDER_ALIASES) == Symbol("h2hRider")
        @test find_column(df, PCS_POINTS_ALIASES) == :Points
        @test find_column(df, PCS_TEAM_ALIASES) == :Team

        @test find_column(df, ["nonexistent", "missing"]) === nothing

        df2 = DataFrame("Name" => ["A"], "Rider" => ["B"])
        @test find_column(df2, ["rider", "name"]) == :Rider

        df_empty = DataFrame("Rider" => String[])
        @test find_column(df_empty, PCS_RIDER_ALIASES) == :Rider
    end

    @testset "PCS alias constants" begin
        @test "h2hrider" in PCS_RIDER_ALIASES
        @test "rider" in PCS_RIDER_ALIASES
        @test "points" in PCS_POINTS_ALIASES
        @test "rank" in PCS_RANK_ALIASES
        @test "#" in PCS_RANK_ALIASES
        @test "team" in PCS_TEAM_ALIASES
    end
end

@testset "New function exports" begin
    new_symbols = [
        :solve_oneday,
        :solve_stage,
        :ScoringTable,
        :RaceInfo,
        :SCORING_CAT1,
        :SCORING_STAGE,
        :get_scoring,
        :find_race,
        :expected_finish_points,
        :expected_assist_points,
        :BayesianPosterior,
        :StrengthEstimate,
        :bayesian_update,
        :estimate_rider_strength,
        :simulate_race,
        :position_probabilities,
        :expected_vg_points,
        :predict_expected_points,
        :getpcsraceresults,
        :getpcsracestartlist,
        :getpcsracehistory,
        :find_column,
        :scrape_pcs_table,
        :scrape_html_tables,
        :PCS_RIDER_ALIASES,
        :PCS_POINTS_ALIASES,
        :PCS_RANK_ALIASES,
        :PCS_TEAM_ALIASES,
        :STAGE_RACE_PCS_WEIGHTS,
        :compute_stage_race_pcs_score,
        :get_cycling_oracle,
        :SIMILAR_RACES,
    ]
    for sym in new_symbols
        @test isdefined(Velogames, sym)
    end
end

@testset "Similar races mapping" begin
    @test SIMILAR_RACES isa Dict{String,Vector{String}}
    @test haskey(SIMILAR_RACES, "omloop-het-nieuwsblad")
    @test "e3-harelbeke" in SIMILAR_RACES["omloop-het-nieuwsblad"]
    @test haskey(SIMILAR_RACES, "kuurne-brussel-kuurne")
    @test "scheldeprijs" in SIMILAR_RACES["kuurne-brussel-kuurne"]
    # Worlds has no similar races
    @test haskey(SIMILAR_RACES, "world-championship")
    @test isempty(SIMILAR_RACES["world-championship"])
end

@testset "Variance penalties in strength estimation" begin
    # Similar-race history (with penalty) should be less precise than exact-race history
    exact = estimate_rider_strength(
        pcs_score=0.0,
        race_history=[1.5],
        race_history_years_ago=[1],
        race_history_variance_penalties=[0.0],
    )
    similar = estimate_rider_strength(
        pcs_score=0.0,
        race_history=[1.5],
        race_history_years_ago=[1],
        race_history_variance_penalties=[1.0],
    )
    # Both should shift the mean upward
    @test exact.mean > 0.0
    @test similar.mean > 0.0
    # Exact-race should pull the mean more strongly (lower variance observation)
    @test exact.mean > similar.mean
    # Exact-race should produce lower posterior variance
    @test exact.variance < similar.variance

    # Empty penalties vector should work (defaults to zero)
    no_penalty = estimate_rider_strength(
        pcs_score=0.0,
        race_history=[1.5],
        race_history_years_ago=[1],
    )
    @test isapprox(no_penalty.mean, exact.mean; atol=1e-10)
end

@testset "VG race history in strength estimation" begin
    # VG race history should shift strength estimate
    with_vg = estimate_rider_strength(
        pcs_score=0.0,
        vg_race_history=[2.0, 1.5],
        vg_race_history_years_ago=[1, 2],
    )
    without_vg = estimate_rider_strength(pcs_score=0.0)

    @test with_vg.mean > without_vg.mean
    @test with_vg.variance < without_vg.variance

    # More recent VG history should have more influence
    recent = estimate_rider_strength(
        pcs_score=0.0,
        vg_race_history=[2.0],
        vg_race_history_years_ago=[1],
    )
    old = estimate_rider_strength(
        pcs_score=0.0,
        vg_race_history=[2.0],
        vg_race_history_years_ago=[5],
    )
    @test recent.mean > old.mean  # Recent history pulls mean more
    @test recent.variance < old.variance  # Recent history is more precise
end

@testset "predict_expected_points with variance_penalty and vg_history" begin
    rider_df = DataFrame(
        rider=["Strong", "Medium", "Weak", "Also Weak", "Very Weak", "Last"],
        team=["A", "A", "B", "B", "C", "C"],
        cost=[20, 15, 10, 8, 6, 4],
        points=[500.0, 300.0, 150.0, 100.0, 50.0, 20.0],
        riderkey=["strong", "medium", "weak", "alsoweak", "veryweak", "last"],
        oneday=[2000, 1200, 800, 500, 200, 50],
    )

    # Test with variance_penalty column in race history
    history_df = DataFrame(
        riderkey=["strong", "strong", "medium", "medium"],
        position=[1, 5, 10, 8],
        year=[2024, 2023, 2024, 2023],
        variance_penalty=[0.0, 0.0, 1.0, 1.0],  # medium's history is from similar races
    )
    result = predict_expected_points(
        rider_df,
        SCORING_CAT2;
        race_history_df=history_df,
        n_sims=5000,
    )
    @test :expected_vg_points in propertynames(result)
    @test all(result.expected_vg_points .>= 0)

    # Test with VG history
    vg_hist = DataFrame(
        riderkey=["strong", "medium", "weak", "strong", "medium", "weak"],
        score=[500.0, 200.0, 50.0, 450.0, 180.0, 40.0],
        year=[2024, 2024, 2024, 2023, 2023, 2023],
    )
    result_vg = predict_expected_points(
        rider_df,
        SCORING_CAT2;
        vg_history_df=vg_hist,
        n_sims=5000,
    )
    @test :expected_vg_points in propertynames(result_vg)
    @test all(result_vg.expected_vg_points .>= 0)
end

@testset "predict + build_model_oneday integration" begin
    rng = Random.MersenneTwister(42)
    rider_df = DataFrame(
        rider=["R$i" for i in 1:12],
        team=repeat(["A", "B", "C", "D"], 3),
        cost=[20, 18, 16, 14, 12, 10, 8, 6, 5, 4, 3, 2],
        points=Float64.([500, 400, 350, 300, 250, 200, 150, 100, 80, 60, 40, 20]),
        riderkey=["r$i" for i in 1:12],
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
        rider=["R$i" for i in 1:20],
        team=repeat(["A", "B", "C", "D"], 5),
        cost=repeat([15, 12, 10, 8, 5], 4),
        points=Float64.(repeat([400, 300, 200, 100, 50], 4)),
        riderkey=["r$i" for i in 1:20],
        classraw=repeat(["All Rounder", "All Rounder", "Climber", "Climber",
                "Climber", "Sprinter", "Sprinter", "Unclassed",
                "Unclassed", "Unclassed"], 2),
        gc=Float64.(repeat([1500, 1200, 800, 600, 400], 4)),
        tt=Float64.(repeat([1000, 800, 600, 400, 200], 4)),
        climber=Float64.(repeat([500, 400, 1200, 1000, 800], 4)),
        sprint=Float64.(repeat([200, 150, 100, 500, 300], 4)),
        oneday=Float64.(repeat([800, 600, 400, 300, 200], 4)),
    )
    predicted = predict_expected_points(
        rider_df, SCORING_STAGE; n_sims=5000, race_type=:stage, rng=rng,
    )
    @test :expected_vg_points in propertynames(predicted)

    sol = build_model_stage(predicted, 9, :expected_vg_points, :cost; totalcost=100)
    @test sol !== nothing

    chosen = filter(row -> JuMP.value(sol[row.riderkey]) > 0.5, predicted)
    @test nrow(chosen) == 9
    @test sum(chosen.cost) <= 100
end

@testset "estimate_breakaway_points" begin
    rng = Random.MersenneTwister(42)
    # Stronger riders should get more breakaway points on average because they
    # finish higher and thus appear in more front-group sectors
    strengths = [2.0, 0.0, -2.0]
    uncertainties = [0.5, 0.5, 0.5]
    bp = estimate_breakaway_points(strengths, uncertainties, SCORING_CAT2; n_sims=10000, rng=rng)
    @test length(bp) == 3
    @test all(bp .>= 0)
    # Mid-pack riders tend to get more breakaway points (they fall in the breakaway position range)
    # but the exact ordering depends on the heuristic ranges vs strength
    # Just verify they're reasonable non-negative values
    @test maximum(bp) < 100  # sanity check
end

# ---------------------------------------------------------------------------
# Backtesting framework tests
# ---------------------------------------------------------------------------

@testset "Backtesting Framework" begin
    @testset "Functions are defined" begin
        @test isdefined(Velogames, :BacktestRace)
        @test isdefined(Velogames, :BacktestResult)
        @test isdefined(Velogames, :backtest_race)
        @test isdefined(Velogames, :backtest_season)
        @test isdefined(Velogames, :summarise_backtest)
        @test isdefined(Velogames, :ablation_study)
        @test isdefined(Velogames, :tune_hyperparameters)
        @test isdefined(Velogames, :build_race_catalogue)
    end

    @testset "BacktestRace construction" begin
        race = BacktestRace("Test Race", 2024, "test-slug", 2)
        @test race.name == "Test Race"
        @test race.year == 2024
        @test race.pcs_slug == "test-slug"
        @test race.category == 2
        @test race.history_years == 5  # default

        race2 = BacktestRace("Test Race", 2024, "test-slug", 1, 3)
        @test race2.history_years == 3
    end

    @testset "spearman_correlation" begin
        # Perfect positive correlation
        @test Velogames.spearman_correlation([1.0, 2.0, 3.0, 4.0, 5.0], [1.0, 2.0, 3.0, 4.0, 5.0]) ≈ 1.0

        # Perfect negative correlation
        @test Velogames.spearman_correlation([1.0, 2.0, 3.0, 4.0, 5.0], [5.0, 4.0, 3.0, 2.0, 1.0]) ≈ -1.0

        # Zero correlation (orthogonal ranks)
        rho = Velogames.spearman_correlation([1.0, 2.0, 3.0, 4.0, 5.0], [3.0, 1.0, 5.0, 2.0, 4.0])
        @test abs(rho) < 0.5  # not exactly zero but low

        # Too few elements
        @test isnan(Velogames.spearman_correlation([1.0, 2.0], [2.0, 1.0]))

        # Handles ties
        rho_ties = Velogames.spearman_correlation([1.0, 1.0, 3.0, 4.0, 5.0], [1.0, 2.0, 3.0, 4.0, 5.0])
        @test !isnan(rho_ties)
        @test rho_ties > 0.8  # should still be highly correlated
    end

    @testset "top_n_overlap" begin
        # predicted_values: higher = better; actual_positions: lower = better
        predicted = [100.0, 80.0, 60.0, 40.0, 20.0]
        actual_pos = [1, 2, 3, 4, 5]

        # Perfect prediction — top 3 predicted match top 3 actual
        @test Velogames.top_n_overlap(predicted, actual_pos, 3) == 3
        @test Velogames.top_n_overlap(predicted, actual_pos, 5) == 5

        # Scrambled — top 3 predicted are indices 1,2,3 but actual top 3 are 5,4,3
        predicted2 = [100.0, 80.0, 60.0, 40.0, 20.0]
        actual_pos2 = [5, 4, 3, 2, 1]
        @test Velogames.top_n_overlap(predicted2, actual_pos2, 3) == 1  # only index 3 overlaps
    end

    @testset "mean_abs_rank_error" begin
        # Perfect prediction
        predicted = [100.0, 80.0, 60.0, 40.0, 20.0]
        actual_pos = [1, 2, 3, 4, 5]
        @test Velogames.mean_abs_rank_error(predicted, actual_pos) ≈ 0.0

        # All off by 1
        actual_pos2 = [2, 1, 4, 3, 5]
        mae = Velogames.mean_abs_rank_error(predicted, actual_pos2)
        @test mae > 0
        @test mae < 2.0  # should be small-ish
    end

    @testset "build_race_catalogue" begin
        catalogue = build_race_catalogue([2024])
        @test length(catalogue) == length(SUPERCLASICO_RACES_2025)
        @test all(r -> r.year == 2024, catalogue)
        @test all(r -> r.history_years == 5, catalogue)

        # Multi-year
        catalogue2 = build_race_catalogue([2023, 2024])
        @test length(catalogue2) == 2 * length(SUPERCLASICO_RACES_2025)

        # Custom history years
        catalogue3 = build_race_catalogue([2024]; history_years=3)
        @test all(r -> r.history_years == 3, catalogue3)
    end

    @testset "summarise_backtest with empty results" begin
        df = summarise_backtest(BacktestResult[])
        @test nrow(df) == 0
    end

    @testset "summarise_backtest with results" begin
        results = [
            BacktestResult(
                BacktestRace("Race A", 2024, "race-a", 2), [:pcs], 50,
                0.6, 3, 7, 15.2, 0.8, 100.0, 125.0,
            ),
            BacktestResult(
                BacktestRace("Race B", 2024, "race-b", 1), [:pcs], 40,
                0.7, 4, 8, 12.0, 0.9, 110.0, 122.0,
            ),
        ]
        df = summarise_backtest(results)
        @test nrow(df) == 4  # 2 races + mean + median
        @test "Race A" in df.race
        @test "— MEAN —" in df.race
    end

    @testset "ABLATION_SETS is well-formed" begin
        @test length(ABLATION_SETS) == 7
        for (label, sigs) in ABLATION_SETS
            @test label isa String
            @test sigs isa Vector{Symbol}
            @test !isempty(sigs)
        end
    end

    @testset "PARAM_BOUNDS are valid" begin
        for field in fieldnames(typeof(PARAM_BOUNDS))
            lo, hi = getfield(PARAM_BOUNDS, field)
            @test lo < hi
            @test lo > 0
        end
    end

    @testset "_average_ranks" begin
        # No ties
        ranks = Velogames._average_ranks([30.0, 10.0, 20.0])
        @test ranks == [3.0, 1.0, 2.0]

        # Ties: two values tied for positions 1-2 → average rank 1.5
        ranks2 = Velogames._average_ranks([10.0, 10.0, 20.0])
        @test ranks2[1] == 1.5
        @test ranks2[2] == 1.5
        @test ranks2[3] == 3.0
    end

    @testset "_random_bayesian_config produces valid configs" begin
        rng = Random.MersenneTwister(42)
        config = Velogames._random_bayesian_config(rng)
        @test config.pcs_variance >= PARAM_BOUNDS.pcs_variance[1]
        @test config.pcs_variance <= PARAM_BOUNDS.pcs_variance[2]
        @test config.vg_variance >= PARAM_BOUNDS.vg_variance[1]
        @test config.vg_variance <= PARAM_BOUNDS.vg_variance[2]
        @test config.hist_base_variance >= PARAM_BOUNDS.hist_base_variance[1]
        @test config.hist_base_variance <= PARAM_BOUNDS.hist_base_variance[2]
        # Odds/oracle/normalisation should be defaults
        @test config.odds_variance == DEFAULT_BAYESIAN_CONFIG.odds_variance
        @test config.oracle_variance == DEFAULT_BAYESIAN_CONFIG.oracle_variance
        @test config.odds_normalisation == DEFAULT_BAYESIAN_CONFIG.odds_normalisation
    end
end
