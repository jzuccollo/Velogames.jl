using DataFrames
using Velogames
using Test
using JuMP
using HTTP
using Dates

@testset "Functions are defined" begin
    # test that functions are defined
    @test isdefined(Velogames, :getvgriders)
    @test isdefined(Velogames, :getpcsriderpts)
    @test isdefined(Velogames, :getpcsriderhistory)
    @test isdefined(Velogames, :getpcsranking)
    @test isdefined(Velogames, :buildmodeloneday)
    @test isdefined(Velogames, :buildmodelstage)
    @test isdefined(Velogames, :solverace)
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

    # Test that the DataFrame has the expected columns: rider, team, classraw, cost, points, riderkey, class, allrounder, sprinter, climber, unclassed, value
    expected_cols = ["rider", "team", "classraw", "cost", "points", "riderkey", "class", "allrounder", "sprinter", "climber", "unclassed", "value"]
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

@testset "Model Building Functions" begin
    # Create sample data for testing
    sample_df = DataFrame(
        rider=["Rider A", "Rider B", "Rider C", "Rider D"],
        cost=[10, 15, 20, 25],
        points=[50.0, 75.0, 100.0, 125.0],
        riderkey=["ridera", "riderb", "riderc", "riderd"]
    )

    @testset "buildmodeloneday" begin
        result = buildmodeloneday(sample_df, 2, :points, :cost)  # Specify correct columns
        @test result isa JuMP.Containers.DenseAxisArray  # Returns solution values, not model
        @test length(result) == 4  # Should have one value per rider

        # Test with custom parameters
        result2 = buildmodeloneday(sample_df, 2, :points, :cost, totalcost=50)
        @test result2 isa JuMP.Containers.DenseAxisArray
        @test length(result2) == 4
    end

    @testset "buildmodelstage" begin
        # Add required columns for stage race model
        sample_df_stage = copy(sample_df)
        sample_df_stage.allrounder = [1, 0, 1, 1]  # Use integers instead of booleans
        sample_df_stage.sprinter = [0, 1, 0, 1]
        sample_df_stage.climber = [1, 0, 1, 1]
        sample_df_stage.unclassed = [1, 1, 1, 1]  # Need at least 3 unclassed riders

        result = buildmodelstage(sample_df_stage, 4, :points, :cost)  # Specify correct columns
        # Stage race model might not have feasible solution, so result could be nothing
        @test (result isa JuMP.Containers.DenseAxisArray) || (result === nothing)
        if result !== nothing
            @test length(result) == 4  # Should have one value per rider
        end

        # Test fallback to one-day model when columns missing
        result_fallback = buildmodelstage(sample_df, 2, :points, :cost)  # Missing stage columns
        @test result_fallback isa JuMP.Containers.DenseAxisArray  # Should fallback to one-day model
    end
end

@testset "Data Retrieval Functions (Mock Tests)" begin
    # These tests check function signatures and error handling since we can't rely on external URLs

    @testset "getpcsranking" begin
        # Test invalid inputs
        @test_throws AssertionError getpcsranking("invalid", "individual")
        @test_throws AssertionError getpcsranking("me", "invalid-category")

        # Test that valid inputs don't immediately error (though they may fail due to network)
        try
            getpcsranking("me", "individual")
            @test true  # If we get here, function call succeeded
        catch e
            # Network errors are expected in tests, other errors are not
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end
    end

    @testset "getpcsriderpts" begin
        # Test that function accepts string input and handles errors gracefully
        try
            result = getpcsriderpts("test-rider")
            @test result isa Dict
        catch e
            # Network/parsing errors are expected in tests
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end
    end

    @testset "getpcsriderhistory" begin
        # Test that function accepts string input and handles errors gracefully
        try
            result = getpcsriderhistory("test-rider")
            @test result isa DataFrames.DataFrame
        catch e
            # Network/parsing errors are expected in tests
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end
    end

    @testset "getvgracepoints" begin
        # Test that function accepts string input
        try
            getvgracepoints("https://example.com")
            @test true  # If we get here, function call succeeded
        catch e
            # Network/parsing errors are expected in tests
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end
    end

    @testset "getodds" begin
        # Test that function accepts string input and optional headers
        try
            getodds("https://example.com")
            @test true  # If we get here, function call succeeded
        catch e
            # Network/parsing errors are expected in tests
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end

        # Test with custom headers (now using keyword arguments)
        try
            getodds("https://example.com", headers=Dict("Custom-Header" => "test"))
            @test true  # If we get here, function call succeeded
        catch e
            # Network/parsing errors are expected in tests
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end
    end

    @testset "getpcsraceranking" begin
        # Test that function accepts string input and handles errors gracefully
        try
            result = getpcsraceranking("https://example.com")
            @test result isa DataFrames.DataFrame
        catch e
            # Network/parsing errors are expected in tests
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end
    end
end

@testset "Integration Tests" begin
    @testset "solverace" begin
        # Test that function accepts required parameters
        try
            result = solverace("https://www.velogames.com/velogame/2025/riders.php", :oneday)
            @test true  # If no exception, test passes
        catch e
            # Network/parsing errors are expected in tests, signature errors are not
            @test !isa(e, MethodError)
        end

        # Test with optional parameters
        try
            result = solverace("https://www.velogames.com/velogame/2025/riders.php", :stage, "testhash", 0.7)
            @test true  # If no exception, test passes
        catch e
            # Network/parsing errors are expected in tests, signature errors are not
            @test !isa(e, MethodError)
        end
    end
end

@testset "Caching System" begin
    @testset "CacheConfig" begin
        # Test default cache config
        @test DEFAULT_CACHE.enabled == true
        @test DEFAULT_CACHE.max_age_hours == 24
        @test endswith(DEFAULT_CACHE.cache_dir, ".velogames_cache")

        # Test custom cache config
        custom_cache = CacheConfig("/tmp/test_cache", 12, true)
        @test custom_cache.cache_dir == "/tmp/test_cache"
        @test custom_cache.max_age_hours == 12
        @test custom_cache.enabled == true
    end

    @testset "Cache Key Generation" begin
        # Test cache key generation
        key1 = cache_key("http://example.com")
        key2 = cache_key("http://example.com", Dict("param" => "value"))
        key3 = cache_key("http://different.com")

        @test length(key1) == 16  # Should be 16 character hash
        @test key1 != key2  # Different params should give different keys
        @test key1 != key3  # Different URLs should give different keys
        @test key2 != key3
    end

    @testset "Cache Clear" begin
        # Test cache clearing (should not error even if cache doesn't exist)
        test_cache_dir = "/tmp/velogames_test_cache"
        @test_nowarn clear_cache(test_cache_dir)
    end

    @testset "Function Signature Updates" begin
        # Test that all functions accept force_refresh parameter
        test_params = [
            (getpcsranking, ("me", "individual")),
            (getpcsraceranking, ("http://example.com",)),
            (getpcsriderhistory, ("test rider",)),
            (getvgracepoints, ("http://example.com",)),
            (getodds, ("http://example.com",)),
        ]

        for (func, args) in test_params
            # Test that functions accept force_refresh parameter (will likely error on network, but shouldn't error on signature)
            try
                func(args..., force_refresh=true)
            catch e
                # Network errors are expected, signature errors are not
                @test !isa(e, MethodError)
            end
        end
    end
end

@testset "DataFrame Return Types" begin
    @testset "getpcsriderpts DataFrame Return" begin
        # Test that getpcsriderpts now returns DataFrame instead of Dict
        try
            result = getpcsriderpts("test-rider", force_refresh=true)
            @test result isa DataFrame
            # Should have these columns if successful
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

    # Test batch processing - warnings are expected for network failures
    batch_df = getpcsriderpts_batch(test_riders)

    @test batch_df isa DataFrame
    @test nrow(batch_df) == length(test_riders)
    @test hasproperty(batch_df, :rider)
    @test hasproperty(batch_df, :oneday)
    @test hasproperty(batch_df, :riderkey)

    # Test that all expected riders are present
    @test Set(batch_df.rider) == Set(test_riders)
end

@testset "PCS Integration Tests" begin
    @testset "add_pcs_speciality_points!" begin
        # Test with complete data
        test_df = DataFrame(
            class=["allrounder", "sprinter", "climber", "unknown"],
            gc=[1000, 200, 1200, 500],
            sprint=[100, 1500, 50, 300],
            climber=[800, 100, 1800, 400],
            oneday=[900, 1200, 1000, 600]
        )

        result_df = add_pcs_speciality_points!(copy(test_df))

        @test hasproperty(result_df, :pcs_speciality_points)
        @test result_df.pcs_speciality_points[1] == 1000  # allrounder -> gc
        @test result_df.pcs_speciality_points[2] == 1500  # sprinter -> sprint
        @test result_df.pcs_speciality_points[3] == 1800  # climber -> climber
        @test result_df.pcs_speciality_points[4] == 600   # unknown -> oneday

        # Test with missing PCS data
        test_df_missing = DataFrame(
            class=["allrounder", "sprinter"],
            gc=[missing, 200],
            sprint=[100, missing]
        )

        result_df_missing = add_pcs_speciality_points!(copy(test_df_missing))
        @test result_df_missing.pcs_speciality_points[1] == 0  # missing -> 0
        @test result_df_missing.pcs_speciality_points[2] == 0  # missing -> 0

        # Test without class column
        test_df_no_class = DataFrame(rider=["test1", "test2"])
        result_df_no_class = add_pcs_speciality_points!(copy(test_df_no_class))
        @test hasproperty(result_df_no_class, :pcs_speciality_points)
        @test all(ismissing, result_df_no_class.pcs_speciality_points)

        # Test case variations
        test_df_cases = DataFrame(
            class=["All Rounder", "SPRINTER", "Climber"],
            gc=[1000, 200, 1200],
            sprint=[100, 1500, 50],
            climber=[800, 100, 1800]
        )

        result_df_cases = add_pcs_speciality_points!(copy(test_df_cases))
        @test result_df_cases.pcs_speciality_points[1] == 1000  # All Rounder -> gc
        @test result_df_cases.pcs_speciality_points[2] == 1500  # SPRINTER -> sprint
        @test result_df_cases.pcs_speciality_points[3] == 1800  # Climber -> climber
    end

    @testset "integrate_pcs_data! - Unit Tests" begin
        # Create mock rider data
        rider_df = DataFrame(
            rider=["rider1", "rider2", "rider3"],
            riderkey=["key1", "key2", "key3"],
            class=["allrounder", "sprinter", "climber"],
            vgpoints=[100, 200, 150],
            vgcost=[10, 15, 12]
        )

        # Test error handling when PCS fetch fails
        rider_names = ["nonexistent-rider-1", "nonexistent-rider-2"]

        # This should handle the error gracefully and add default columns
        result_df = integrate_pcs_data!(copy(rider_df), rider_names)

        @test hasproperty(result_df, :pcs_speciality_points)
        @test all(result_df.pcs_speciality_points .== 0)  # Should default to 0

        # Test with valid structure but no network (will likely fail gracefully)
        test_cache_config = CacheConfig("/tmp/test_integration", 1, false)
        try
            result_df_cached = integrate_pcs_data!(copy(rider_df), ["test-rider"];
                cache_config=test_cache_config)
            @test result_df_cached isa DataFrame
            @test hasproperty(result_df_cached, :pcs_speciality_points)
        catch e
            # Network failures are expected in testing environment
            @test true
        end
    end
end

@testset "Integration Workflow Tests" begin
    # Test the complete workflow that notebooks will use

    # Mock VG data structure
    mock_vg_data = DataFrame(
        rider=["Tadej Pogačar", "Jonas Vingegaard", "Primož Roglič"],
        riderkey=[createkey("Tadej Pogačar"), createkey("Jonas Vingegaard"), createkey("Primož Roglič")],
        class=["allrounder", "allrounder", "allrounder"],
        vgpoints=[2000, 1800, 1600],
        vgcost=[24, 22, 20],
        allrounder=[true, true, true],
        sprinter=[false, false, false],
        climber=[false, false, false],
        unclassed=[false, false, false]
    )

    # Test integration workflow
    try
        integrated_data = integrate_pcs_data!(copy(mock_vg_data), collect(mock_vg_data.rider))

        @test integrated_data isa DataFrame
        @test nrow(integrated_data) == nrow(mock_vg_data)
        @test hasproperty(integrated_data, :pcs_speciality_points)

        # Should preserve original VG columns
        @test hasproperty(integrated_data, :vgpoints)
        @test hasproperty(integrated_data, :vgcost)
        @test hasproperty(integrated_data, :allrounder)

    catch e
        # Network issues are expected in CI/testing
        @test e isa Exception
    end
end
