module Velogames

using HTTP, DataFrames, TableScraper, Cascadia, Gumbo, CategoricalArrays, Unicode, HiGHS, JuMP
export solve_race, getvgriders, getpcsriderpts, getpcsriderhistory, getpcsranking

include("build_model.jl")
include("get_data.jl")
include("race_solver.jl")

end