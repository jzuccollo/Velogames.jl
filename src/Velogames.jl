module Velogames

using HTTP, DataFrames, Cascadia, Gumbo, Unicode, HiGHS, JuMP, Feather, Dates, JSON3, SHA
using Random, Statistics, PlotlyBase

# Core data retrieval
export getvg_riders,
    getvg_race_points,
    getpcs_rider_pts,
    getpcs_rider_pts_batch,
    getpcs_race_ranking,
    parse_oddschecker_odds,
    get_cycling_oracle,
    getvg_race_list,
    getvg_race_results,
    match_vg_race_number,
    getpcs_race_results,
    getpcs_race_startlist,
    getpcs_race_form,
    getpcs_race_history,
    getpcs_rider_seasons,
    getpcs_rider_seasons_batch,
    getpcs_specialty_by_season,
    load_pcs_breakaway_stats,
    getpcs_stage_profiles,
    getpcs_stage_results,
    getpcs_all_stage_results,
    getvg_stage_results,
    getvg_stage_race_totals,
    getvg_scoring

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
    DEFAULT_CACHE_DIR,
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
    vg_classics_game_id,
    StageProfile,
    StageRaceConfig,
    StageSimConfig,
    DEFAULT_STAGE_SIM_CONFIG,
    setup_stage_race,
    flat_stage,
    mountain_stage,
    hilly_stage,
    itt_stage,
    ttt_stage

# Scoring
export ScoringTable,
    StageRaceScoringTable,
    SCORING_CAT1,
    SCORING_CAT2,
    SCORING_CAT3,
    SCORING_STAGE,
    SCORING_GRAND_TOUR,
    get_scoring,
    get_stage_race_scoring,
    expected_finish_points,
    finish_points_for_position,
    stage_finish_points_for_position,
    daily_gc_points_for_position,
    final_gc_points_for_position,
    compute_breakaway_rates,
    STAGE_BREAKAWAY_MAX_RATE

# Solvers and optimisation
export solve_oneday,
    solve_stage,
    StageResult,
    archive_race_results,
    ProspectiveResult,
    evaluate_prospective,
    prospective_season_summary,
    prospective_pit_values,
    prospective_pit_summary,
    signal_value_analysis,
    ORACLE_2026_BASELINE,
    oracle_2026_comparison,
    build_model_oneday,
    build_model_stage,
    minimise_cost_stage,
    resample_optimise!,
    resample_optimise_stage!,
    gt_propensity_factors

# Simulation and strength estimation
export BayesianConfig,
    DEFAULT_BAYESIAN_CONFIG,
    pcs_variance,
    hist_base_variance,
    estimate_strengths,
    predict_expected_points,
    BayesianPosterior,
    bayesian_update,
    estimate_rider_strength,
    position_to_strength,
    simulate_race,
    position_probabilities,
    expected_vg_points,
    STRENGTH_DIMENSIONS,
    STAGE_TYPES,
    SIGNAL_DIMENSION_WEIGHTS,
    MultiDimStrengthEstimate,
    estimate_rider_strength_multidim,
    compute_stage_strengths,
    stage_dimension_weights,
    simulate_stage_race,
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
    build_race_catalogue,
    prefetch_race_data,
    prefetch_all_races,
    spearman_correlation

# Utilities
export createkey,
    unpipe,
    round_numeric_columns!,
    clean_team_names!,
    suppress_output,
    format_signal_waterfall

# HTML generation and report helpers
export html_page,
    html_table,
    html_callout,
    html_heading,
    format_classification_table,
    format_team_classification,
    format_stage_podium_picks,
    format_signal_impact_per_dim,
    format_info_share_per_dim,
    list_completed_races,
    load_report_data,
    compute_optimal_team,
    compute_cheapest_winning_team,
    load_stage_race_report_data,
    load_stage_race_per_stage_data,
    compute_optimal_stage_team,
    compute_cheapest_winning_stage_team,
    compute_filler_pool,
    compute_structural_forks,
    format_near_optimal_section,
    compute_cumulative_scores,
    compute_stage_type_scores,
    archive_stage_race_results,
    load_stage_profiles,
    plotly_html,
    precision_budget,
    sim_distribution_chart,
    simulate_vg_draws,
    compute_pit_values,
    pit_histogram_chart,
    team_total_distribution_chart,
    scatter_chart,
    rank_histogram_chart,
    line_chart

# Includes. Julia resolves function calls at runtime, so most ordering is free.
# The real constraints are eval-time: a file's structs/consts must be defined
# before another file references them at load time (hence bayesian_core precedes
# the strength pipeline, and scoring/race_helpers precede everything using them).
# pcs_scraper precedes get_data because get_data calls into it.
include("cache_utils.jl")
include("utilities.jl")
include("scoring.jl")
include("race_helpers.jl")
include("build_model.jl")
include("pcs_scraper.jl")
include("get_data.jl")
include("pcs_extended.jl")
include("data_assembly.jl")
include("qualitative.jl")
include("bayesian_core.jl")
include("simulate_oneday.jl")
include("simulate_stage.jl")
include("strength_pipeline.jl")
include("prior_checks.jl")
include("backtest.jl")
include("race_solver.jl")
include("prospective_eval.jl")
include("report_html.jl")
include("report_charts.jl")
include("report_formatters.jl")

end
