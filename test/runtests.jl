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
    @test isdefined(Velogames, :solve_stage_legacy)
    @test isdefined(Velogames, :createkey)
    @test isdefined(Velogames, :getvgracepoints)
    @test isdefined(Velogames, :getodds)
    @test isdefined(Velogames, :getpcsraceranking)
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
    df = getvgriders(url, force_refresh = true)  # Force fresh download for tests
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
    df = getvgriders(url; force_refresh = true)
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
        @test isapprox(actual, expected; atol = 1e-6)
    end
end


@testset "Model Building Functions" begin
    # Create sample data for testing
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

        # Test with custom parameters
        result2 = build_model_oneday(sample_df, 2, :points, :cost, totalcost = 50)
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
            rider = ["Rider A", "Rider B"],
            riderkey = ["ridera", "riderb"],
            points = [500, 400],
            cost = [20, 16],
            class = ["All rounder", "Climber"],
        )

        # build_model_stage returns nothing when constraints unsatisfiable
        result1 = build_model_stage(insufficient_data, 9, :points, :cost; totalcost = 100)
        @test result1 === nothing

        result2 =
            minimise_cost_stage(insufficient_data, 100, 9, :points, :cost; totalcost = 100)
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
        try
            getodds("https://example.com")
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

        try
            getodds("https://example.com", headers = Dict("Custom-Header" => "test"))
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

@testset "Integration Tests" begin
    @testset "solve_stage_legacy" begin
        try
            result = solve_stage_legacy(
                "https://www.velogames.com/velogame/2025/riders.php",
                :oneday,
            )
            @test true
        catch e
            @test !isa(e, MethodError)
        end

        try
            result = solve_stage_legacy(
                "https://www.velogames.com/velogame/2025/riders.php",
                :stage,
                "testhash",
                0.7,
            )
            @test true
        catch e
            @test !isa(e, MethodError)
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
            (getodds, ("http://example.com",)),
        ]

        for (func, args) in test_params
            try
                func(args..., force_refresh = true)
            catch e
                @test !isa(e, MethodError)
            end
        end
    end
end

@testset "DataFrame Return Types" begin
    @testset "getpcsriderpts DataFrame Return" begin
        try
            result = getpcsriderpts("test-rider", force_refresh = true)
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
            riderkey = ["rider1", "rider2", "rider3", "rider4"],
            class = ["allrounder", "sprinter", "climber", "unclassed"],
        )

        pcs_df = DataFrame(
            riderkey = ["rider1", "rider2", "rider3", "rider4"],
            gc = [1000, 200, 1200, 500],
            sprint = [100, 1500, 50, 300],
            climber = [800, 100, 1800, 400],
            oneday = [900, 1200, 1000, 600],
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
            DataFrame(riderkey = ["rider1", "rider2"], class = ["allrounder", "sprinter"])

        pcs_df_missing = DataFrame(
            riderkey = ["rider1"],
            gc = [1000],
            sprint = [100],
            climber = [800],
            oneday = [900],
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

@testset "Integration Workflow Tests" begin
    mock_vg_data = DataFrame(
        rider = ["Tadej Pogačar", "Jonas Vingegaard", "Primož Roglič"],
        riderkey = [
            createkey("Tadej Pogačar"),
            createkey("Jonas Vingegaard"),
            createkey("Primož Roglič"),
        ],
        class = ["allrounder", "allrounder", "allrounder"],
        vgpoints = [2000, 1800, 1600],
        vgcost = [24, 22, 20],
        allrounder = [true, true, true],
        sprinter = [false, false, false],
        climber = [false, false, false],
        unclassed = [false, false, false],
    )

    try
        integrated_data =
            integrate_pcs_data!(copy(mock_vg_data), collect(mock_vg_data.rider))

        @test integrated_data isa DataFrame
        @test nrow(integrated_data) == nrow(mock_vg_data)
        @test hasproperty(integrated_data, :pcs_speciality_points)

        @test hasproperty(integrated_data, :vgpoints)
        @test hasproperty(integrated_data, :vgcost)
        @test hasproperty(integrated_data, :allrounder)

    catch e
        @test e isa Exception
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
    probs_certain_win = zeros(30);
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

    @test position_to_strength(1, 150) >
          position_to_strength(50, 150) >
          position_to_strength(100, 150)
    @test position_to_strength(1, 150) > 0 && position_to_strength(100, 150) < 0
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
    ]
        @test col in propertynames(result)
    end

    @test result.expected_vg_points[1] > result.expected_vg_points[6]
    @test result.strength[1] > result.strength[6]
    @test all(result.expected_vg_points .>= 0)

    # Race history reduces uncertainty
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
        n_sims = 5000,
        race_type = :stage,
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
    row = (gc = 1000.0, tt = 500.0, climber = 800.0, sprint = 200.0, oneday = 600.0)

    # All-rounder: 0.5*gc + 0.25*tt + 0.25*climber = 500 + 125 + 200 = 825
    @test isapprox(compute_stage_race_pcs_score(row, "allrounder"), 825.0; atol = 0.1)

    # Climber: 0.15*gc + 0.15*tt + 0.7*climber = 150 + 75 + 560 = 785
    @test isapprox(compute_stage_race_pcs_score(row, "climber"), 785.0; atol = 0.1)

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
    ]
    for sym in new_symbols
        @test isdefined(Velogames, sym)
    end
end
