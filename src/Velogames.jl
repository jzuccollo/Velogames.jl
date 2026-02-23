module Velogames

using HTTP,
    DataFrames,
    TableScraper,
    Cascadia,
    Gumbo,
    Unicode,
    HiGHS,
    JuMP,
    Feather,
    Downloads,
    Dates,
    JSON3,
    SHA
using Random, Statistics

# Export core functions
export solve_oneday,
    solve_stage,
    getvgriders,
    getvgracepoints,
    getpcsriderpts,
    getpcsriderpts_batch,
    getpcsriderhistory,
    getpcsranking,
    getpcsraceranking,
    getodds,
    build_model_oneday,
    build_model_stage,
    minimise_cost_stage,
    createkey,
    CacheConfig,
    clear_cache,
    DEFAULT_CACHE,
    cache_key,
    add_pcs_speciality_points!,
    unpipe,
    format_display_table,
    round_numeric_columns!,
    clean_team_names!,
    class_availability_summary,
    describe_class_availability,
    DEFAULT_CLASS_REQUIREMENTS

# Export classification helpers
export ensure_classification_columns!, validate_classification_constraints, STAGE_CLASS_MINIMUMS

# Export race helper functions
export setup_race, get_url_pattern, get_historical_url, print_race_info, RaceConfig, SIMILAR_RACES

# Export extended PCS scraping functions
export getpcsraceresults, getpcsracestartlist, getpcsracehistory

# Export Betfair API functions
export betfair_login, betfair_get_market_odds

# Export Cycling Oracle function
export get_cycling_oracle

# Export PCS scraper infrastructure
export find_column,
    scrape_pcs_table,
    scrape_html_tables,
    PCS_RIDER_ALIASES,
    PCS_POINTS_ALIASES,
    PCS_RANK_ALIASES,
    PCS_TEAM_ALIASES

# Export scoring system
export ScoringTable,
    RaceInfo,
    SCORING_CAT1,
    SCORING_CAT2,
    SCORING_CAT3,
    SCORING_STAGE,
    get_scoring,
    find_race,
    SUPERCLASICO_RACES_2025,
    expected_finish_points,
    expected_assist_points,
    expected_breakaway_points,
    finish_points_for_position

# Export backtesting framework
export BacktestRace,
    BacktestResult,
    backtest_race,
    backtest_season,
    summarise_backtest,
    ablation_study,
    tune_hyperparameters,
    build_race_catalogue,
    ABLATION_SETS,
    PARAM_BOUNDS

# Export simulation and prediction
export BayesianPosterior,
    StrengthEstimate,
    BayesianConfig,
    DEFAULT_BAYESIAN_CONFIG,
    bayesian_update,
    estimate_rider_strength,
    position_to_strength,
    simulate_race,
    position_probabilities,
    expected_vg_points,
    estimate_breakaway_points,
    predict_expected_points,
    STAGE_RACE_PCS_WEIGHTS,
    compute_stage_race_pcs_score

# Include all modules (order matters for dependencies)
include("cache_utils.jl")
include("utilities.jl")
include("betfair.jl")
include("classification_utils.jl")
include("scoring.jl")
include("race_helpers.jl")
include("build_model.jl")
include("get_data.jl")
include("pcs_scraper.jl")
include("pcs_extended.jl")
include("simulation.jl")
include("race_solver.jl")
include("report_helpers.jl")
include("backtest.jl")

end
