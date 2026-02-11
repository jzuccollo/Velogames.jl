module Velogames

using HTTP, DataFrames, TableScraper, Cascadia, Gumbo, CategoricalArrays, Unicode, HiGHS, JuMP, Feather, Downloads, Dates, JSON3, SHA
# Export core functions
export solverace, getvgriders, getvgracepoints, getpcsriderpts, getpcsriderpts_batch, getpcsriderhistory, getpcsranking, getpcsraceranking, getodds, buildmodeloneday, buildmodelstage, buildmodelhistorical, minimizecostforstage, createkey, CacheConfig, clear_cache, DEFAULT_CACHE, cache_key, add_pcs_speciality_points!, minimisecostforteam,
    unpipe, format_display_table, clean_team_names!, class_availability_summary, describe_class_availability, DEFAULT_CLASS_REQUIREMENTS

# Export new utility functions (classification helpers)
export ensure_classification_columns!, validate_classification_constraints

# Export new race helper functions
export setup_race, get_url_pattern, get_historical_url, print_race_info, RaceConfig

# Include all modules
include("cache_utils.jl")
include("classification_utils.jl")
include("race_helpers.jl")
include("build_model.jl")
include("get_data.jl")
include("race_solver.jl")
include("utilities.jl")
include("report_helpers.jl")

end