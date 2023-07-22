using Velogames
using Test

@testset "Velogames.jl" begin
    # test that functions are defined
    @test isdefined(Velogames, :getvgriders)
    @test isdefined(Velogames, :getpcsriderpts)
    @test isdefined(Velogames, :getpcsriderhistory)
    @test isdefined(Velogames, :getpcsranking)
    @test isdefined(Velogames, :build_model_oneday)
    @test isdefined(Velogames, :build_model_stage)
end