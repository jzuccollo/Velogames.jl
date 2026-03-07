module Velogames

using HTTP, DataFrames, Cascadia, Gumbo, Unicode, HiGHS, JuMP, Feather, Dates, JSON3, SHA
using Random, Statistics, PlotlyBase

# Core data retrieval
export getvgriders,
    getvgracepoints,
    getpcsriderpts,
    getpcsriderpts_batch,
    getpcsraceranking,
    getodds,
    parse_oddschecker_odds,
    get_cycling_oracle,
    getvgracelist,
    getvgraceresults,
    match_vg_race_number,
    getpcsraceresults,
    getpcsracestartlist,
    getpcsraceform,
    getpcsracehistory,
    getpcsriderseasons,
    getpcsriderseasons_batch

# Betfair API
export betfair_login, betfair_get_market_odds

# Qualitative intelligence
export get_qualitative_auto,
    get_qualitative_article,
    load_qualitative_file,
    build_qualitative_prompt,
    parse_qualitative_response,
    fetch_transcript,
    fetch_article_text,
    QUALITATIVE_ADJUSTMENTS,
    QUALITATIVE_CONFIDENCES

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
    archive_race_results,
    ProspectiveResult,
    evaluate_prospective,
    prospective_season_summary,
    signal_value_analysis,
    build_model_oneday,
    build_model_stage,
    minimise_cost_stage,
    resample_optimise

# Simulation and prediction (public API)
export BayesianConfig,
    DEFAULT_BAYESIAN_CONFIG,
    pcs_variance,
    vg_variance,
    form_variance,
    trajectory_variance,
    hist_base_variance,
    vg_hist_base_variance,
    odds_variance,
    oracle_variance,
    qualitative_base_variance,
    estimate_strengths,
    predict_expected_points,
    BayesianPosterior,
    bayesian_update,
    estimate_rider_strength,
    position_to_strength,
    simulate_race,
    position_probabilities,
    expected_vg_points,
    simulate_vg_points,
    compute_stage_race_pcs_score,
    breakaway_sectors_from_km

# Prior predictive checks and calibration
export StylisedFacts,
    DEFAULT_STYLISED_FACTS,
    PriorCheckResult,
    SBCResult,
    prior_predictive_check,
    check_stylised_facts,
    sensitivity_sweep,
    simulation_based_calibration

# Backtesting
export BacktestRace,
    BacktestResult,
    RaceData,
    backtest_race,
    backtest_season,
    summarise_backtest,
    ablation_study,
    tune_hyperparameters,
    tune_domestique_discount,
    tune_risk_aversion,
    build_race_catalogue,
    prefetch_race_data,
    prefetch_all_races

# Utilities
export createkey,
    unpipe,
    round_numeric_columns!,
    clean_team_names!,
    suppress_output,
    format_signal_waterfall

# Race report helpers
export list_completed_races,
    load_report_data,
    compute_optimal_team,
    compute_cheapest_winning_team,
    plotly_html,
    precision_budget

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
include("qualitative.jl")
include("simulation.jl")
include("prior_checks.jl")
include("backtest.jl")
include("race_solver.jl")
include("prospective_eval.jl")
include("report_helpers.jl")

end
