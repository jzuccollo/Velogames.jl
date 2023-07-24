using DataFrames
using Velogames
using Test

@testset "Functions are defined" begin
    # test that functions are defined
    @test isdefined(Velogames, :getvgriders)
    @test isdefined(Velogames, :getpcsriderpts)
    @test isdefined(Velogames, :getpcsriderhistory)
    @test isdefined(Velogames, :getpcsranking)
    @test isdefined(Velogames, :build_model_oneday)
    @test isdefined(Velogames, :build_model_stage)
end

@testset "getvgriders" begin
    # Test that the function returns a DataFrame
    url = "https://www.velogames.com/velogame/2023/riders.php"
    df = getvgriders(url)
    @test typeof(df) == DataFrame

    # Test that the DataFrame has the expected columns:  rider, team, class_raw, cost, selected, points, riderkey, class, allrounder, sprinter, climber, unclassed, value
    expected_cols = ["rider", "team", "class_raw", "cost", "selected", "points", "riderkey", "class", "allrounder", "sprinter", "climber", "unclassed", "value"]
    @test all(col in names(df) for col in expected_cols)

    # Test that the cost and rank columns are Int64
    for col in [:cost, :rank]
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
        @test all(df.class .== lowercase.(replace.(df.class_raw, " " => "")))
    end
end