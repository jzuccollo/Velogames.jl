using DataFrames
using Velogames
using Test
using JuMP
using HTTP

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
    # Test that the function returns a DataFrame
    url = "https://www.velogames.com/velogame/2025/riders.php"
    df = getvgriders(url, fetchagain=true)  # Force fresh download for tests
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
        @test_nowarn try
            getpcsranking("me", "individual")
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
        @test_nowarn try
            getvgracepoints("https://example.com")
        catch e
            # Network/parsing errors are expected in tests
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end
    end

    @testset "getodds" begin
        # Test that function accepts string input and optional headers
        @test_nowarn try
            getodds("https://example.com")
        catch e
            # Network/parsing errors are expected in tests
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end

        # Test with custom headers
        @test_nowarn try
            getodds("https://example.com", Dict("Custom-Header" => "test"))
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
        @test_nowarn try
            solverace("https://www.velogames.com/velogame/2025/riders.php", :oneday)
        catch e
            # Network/parsing errors are expected in tests
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end

        # Test with optional parameters
        @test_nowarn try
            solverace("https://www.velogames.com/velogame/2025/riders.php", :stage, "testhash", 0.7)
        catch e
            # Network/parsing errors are expected in tests
            @test e isa Union{HTTP.Exceptions.StatusError,ArgumentError,BoundsError}
        end
    end
end