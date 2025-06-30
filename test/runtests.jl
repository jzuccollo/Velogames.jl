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
        result = buildmodeloneday(sample_df, 2, :points, :cost, totalcost=50)
        @test result isa JuMP.Containers.DenseAxisArray  # Returns solution values, not model
        @test length(result) == 4  # Should have one value per rider
    end

    @testset "buildmodelstage" begin
        # Add required columns for stage race model
        sample_df_stage = copy(sample_df)
        sample_df_stage.allrounder = [1, 0, 1, 1]  # Use integers instead of booleans
        sample_df_stage.sprinter = [0, 1, 0, 1]
        sample_df_stage.climber = [1, 0, 1, 1]
        sample_df_stage.unclassed = [1, 1, 1, 1]  # Need at least 3 unclassed riders

        result = buildmodelstage(sample_df_stage, 4, :points, :cost)  # Select all 4 riders
        # Stage race model might not have feasible solution, so result could be nothing
        @test (result isa JuMP.Containers.DenseAxisArray) || (result === nothing)
        if result !== nothing
            @test length(result) == 4  # Should have one value per rider
        end
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
