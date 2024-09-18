module Velogames

using HTTP, DataFrames, TableScraper, Cascadia, Gumbo, CategoricalArrays, Unicode, HiGHS, JuMP, Feather
export solverace, getvgriders, getvgracepoints, getpcsriderpts, getpcsriderhistory, getpcsranking, getpcsraceranking, getodds, buildmodeloneday, buildmodelstage, createkey

include("build_model.jl")
include("get_data.jl")
include("race_solver.jl")
include("utilities.jl")

end