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
    Dates,
    JSON3,
    SHA
using Random, Statistics

# Core data retrieval
export getvgriders,
    getvgracepoints,
    getpcsriderpts,
    getpcsriderpts_batch,
    getpcsraceranking,
    getodds,
    get_cycling_oracle,
    getvgracelist,
    getvgraceresults,
    match_vg_race_number,
    getpcsraceresults,
    getpcsracestartlist,
    getpcsracehistory

# Betfair API
export betfair_login, betfair_get_market_odds

# Caching and archival
export CacheConfig,
    DEFAULT_CACHE,
    clear_cache,
    clear_memory_cache!,
    save_race_snapshot,
    load_race_snapshot,
    archive_path,
    DEFAULT_ARCHIVE_DIR

# Race setup and metadata
export setup_race,
    get_url_pattern,
    get_historical_url,
    print_race_info,
    RaceConfig,
    RaceInfo,
    find_race,
    CLASSICS_RACES_2026,
    SIMILAR_RACES,
    vg_classics_slug,
    vg_classics_url,
    vg_classics_game_id

# Scoring
export ScoringTable,
    SCORING_CAT1,
    SCORING_CAT2,
    SCORING_CAT3,
    SCORING_STAGE,
    get_scoring,
    expected_finish_points,
    finish_points_for_position

# Solvers and optimisation
export solve_oneday,
    solve_stage,
    build_model_oneday,
    build_model_stage,
    minimise_cost_stage

# Simulation and prediction (public API)
export BayesianConfig,
    DEFAULT_BAYESIAN_CONFIG,
    predict_expected_points,
    BayesianPosterior,
    bayesian_update,
    estimate_rider_strength,
    position_to_strength,
    simulate_race,
    position_probabilities,
    expected_vg_points,
    estimate_breakaway_points,
    compute_stage_race_pcs_score

# Backtesting
export BacktestRace,
    BacktestResult,
    RaceData,
    backtest_race,
    backtest_season,
    summarise_backtest,
    ablation_study,
    tune_hyperparameters,
    build_race_catalogue,
    prefetch_race_data,
    prefetch_all_races

# Utilities
export createkey, unpipe, round_numeric_columns!, clean_team_names!

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
include("data_assembly.jl")
include("simulation.jl")
include("backtest.jl")
include("race_solver.jl")
include("report_helpers.jl")

end
