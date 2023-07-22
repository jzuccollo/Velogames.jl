module Velogames

using HTTP, DataFrames, TableScraper, Cascadia, Gumbo, CategoricalArrays, Unicode, HiGHS, JuMP
export solve_race, getvgriders, getpcsriderpts, getpcsriderhistory, getpcsranking, build_model_oneday, build_model_stage

include("build_model.jl")
include("get_data.jl")
include("race_solver.jl")
include("utilities.jl")

end