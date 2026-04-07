"""
Prospective evaluation: compare archived predictions against actual race results.

Loads predictions and results from `~/.velogames_archive/` and computes the same
metrics as the backtesting framework (Spearman rho, top-N overlap, signal shifts).
"""

struct ProspectiveResult
    pcs_slug::String
    year::Int
    n_matched::Int
    spearman_rho::Float64
    top5_overlap::Int
    top10_overlap::Int
    mean_abs_rank_error::Float64
    mean_signal_shifts::Dict{Symbol,Float64}
end

"""
    evaluate_prospective(pcs_slug, year; archive_dir) -> Union{ProspectiveResult, Nothing}

Load archived predictions and PCS results for a race, match riders,
and compute evaluation metrics. Returns `nothing` if either predictions
or results are missing.
"""
function evaluate_prospective(
    pcs_slug::String,
    year::Int;
    archive_dir::String = DEFAULT_ARCHIVE_DIR,
)
    predictions =
        load_race_snapshot("predictions", pcs_slug, year; archive_dir = archive_dir)
    pcs_results =
        load_race_snapshot("pcs_results", pcs_slug, year; archive_dir = archive_dir)

    if predictions === nothing || pcs_results === nothing
        return nothing
    end

    # Match on riderkey
    if !hasproperty(pcs_results, :riderkey)
        return nothing
    end

    matched = innerjoin(predictions, pcs_results; on = :riderkey, makeunique = true)
    n = nrow(matched)
    if n < 5
        @warn "Only $n matched riders for $pcs_slug $year — skipping"
        return nothing
    end

    # Compute actual positions (rank by PCS result position)
    pos_col =
        hasproperty(matched, :position) ? :position :
        hasproperty(matched, :rnk) ? :rnk : nothing
    if pos_col === nothing
        @warn "No position column found in PCS results for $pcs_slug $year"
        return nothing
    end

    actual_positions = matched[!, pos_col]
    predicted_strengths = matched.strength

    # Spearman correlation (higher strength should mean lower position)
    rho = spearman_correlation(-predicted_strengths, Float64.(actual_positions))

    # Top-N overlap
    pred_top5 = Set(partialsortperm(-predicted_strengths, 1:min(5, n)))
    pred_top10 = Set(partialsortperm(-predicted_strengths, 1:min(10, n)))
    actual_top5 = Set(partialsortperm(actual_positions, 1:min(5, n)))
    actual_top10 = Set(partialsortperm(actual_positions, 1:min(10, n)))
    top5_overlap = length(intersect(pred_top5, actual_top5))
    top10_overlap = length(intersect(pred_top10, actual_top10))

    # Mean absolute rank error
    pred_ranks = _average_ranks(-predicted_strengths)
    actual_ranks = _average_ranks(Float64.(actual_positions))
    mare = mean(abs.(pred_ranks .- actual_ranks))

    # Signal shift summaries
    shift_cols = filter(
        c -> startswith(string(c), "shift_") && hasproperty(matched, c),
        propertynames(predictions),
    )
    mean_shifts = Dict{Symbol,Float64}()
    for col in shift_cols
        vals = matched[!, col]
        signal_name = Symbol(replace(string(col), "shift_" => ""))
        mean_shifts[signal_name] = mean(abs.(vals))
    end

    ProspectiveResult(
        pcs_slug,
        year,
        n,
        rho,
        top5_overlap,
        top10_overlap,
        mare,
        mean_shifts,
    )
end

"""
    prospective_season_summary(year; archive_dir) -> DataFrame

Load all archived predictions and results for a year. Returns per-race metrics.
Scans the predictions archive directory for available races.
"""
function prospective_season_summary(year::Int; archive_dir::String = DEFAULT_ARCHIVE_DIR)
    pred_dir = joinpath(archive_dir, "predictions")
    if !isdir(pred_dir)
        @info "No predictions archive found at $pred_dir"
        return DataFrame()
    end

    rows = []
    for race_dir in readdir(pred_dir; join = true)
        isdir(race_dir) || continue
        pcs_slug = basename(race_dir)
        feather_path = joinpath(race_dir, "$year.feather")
        isfile(feather_path) || continue

        # Auto-archive PCS results if predictions exist but results don't
        if load_race_snapshot("pcs_results", pcs_slug, year; archive_dir = archive_dir) === nothing
            try
                pcs_results = getpcsraceresults(pcs_slug, year)
                if nrow(pcs_results) > 0
                    save_race_snapshot(pcs_results, "pcs_results", pcs_slug, year; archive_dir = archive_dir)
                    @info "Auto-archived PCS results for $pcs_slug $year"
                end
            catch e
                @warn "Failed to auto-archive PCS results for $pcs_slug $year: $e"
            end
        end

        result = evaluate_prospective(pcs_slug, year; archive_dir = archive_dir)
        result === nothing && continue

        push!(
            rows,
            (;
                race = pcs_slug,
                year = year,
                n_matched = result.n_matched,
                spearman_rho = round(result.spearman_rho, digits = 3),
                top5_overlap = result.top5_overlap,
                top10_overlap = result.top10_overlap,
                mean_abs_rank_error = round(result.mean_abs_rank_error, digits = 1),
            ),
        )
    end

    isempty(rows) && return DataFrame()
    DataFrame(rows)
end

"""
    prospective_pit_values(year; archive_dir, n_draws) -> DataFrame

Compute PIT values for all riders across all archived races in a year.
For each race with archived predictions and VG results, regenerates simulation
draws and computes the PIT value of each rider's actual VG points.

Returns a DataFrame with columns: race, riderkey, rider, actual_vg_points,
pit_value, scored. Empty DataFrame if no data available.
"""
function prospective_pit_values(
    year::Int;
    archive_dir::String = DEFAULT_ARCHIVE_DIR,
    n_draws::Int = 500,
    breakaway_dir::String = "",
    simulation_df::Union{Int,Nothing} = nothing,
)
    pred_dir = joinpath(archive_dir, "predictions")
    if !isdir(pred_dir)
        return DataFrame()
    end

    all_pit = DataFrame[]

    for race_dir in readdir(pred_dir; join = true)
        isdir(race_dir) || continue
        pcs_slug = basename(race_dir)
        feather_path = joinpath(race_dir, "$year.feather")
        isfile(feather_path) || continue

        predictions =
            load_race_snapshot("predictions", pcs_slug, year; archive_dir = archive_dir)
        vg_results =
            load_race_snapshot("vg_results", pcs_slug, year; archive_dir = archive_dir)

        # Auto-archive VG results if missing
        if vg_results === nothing
            try
                race_info = _find_race_by_slug(pcs_slug)
                if race_info !== nothing
                    vg_racelist = getvgracelist(year)
                    race_num = match_vg_race_number(race_info.name, vg_racelist)
                    if race_num !== nothing
                        vg_results = getvgraceresults(year, race_num)
                        if vg_results !== nothing && nrow(vg_results) > 0
                            save_race_snapshot(vg_results, "vg_results", pcs_slug, year; archive_dir = archive_dir)
                            @info "Auto-archived VG results for $pcs_slug $year"
                        end
                    end
                end
            catch e
                @warn "Failed to auto-archive VG results for $pcs_slug $year: $e"
            end
        end

        predictions === nothing && continue
        vg_results === nothing && continue
        !hasproperty(predictions, :strength) && continue
        !hasproperty(predictions, :uncertainty) && continue

        # Need team column for assist computation in simulate_vg_draws.
        # Prefer predictions.team if archived; otherwise join from VG results
        # (only covers scoring riders — re-run oneday_predictor to fix).
        if !hasproperty(predictions, :team)
            if hasproperty(vg_results, :team)
                predictions = leftjoin(
                    predictions,
                    unique(vg_results[:, [:riderkey, :team]]);
                    on = :riderkey,
                )
                predictions[!, :team] = coalesce.(predictions.team, "Unknown")
                n_unknown = count(==("Unknown"), predictions.team)
                if n_unknown > 0
                    @warn "Team data missing for $n_unknown/$(nrow(predictions)) riders in $pcs_slug $year — " *
                          "assist simulation will be inaccurate. Re-run oneday_predictor to re-archive with team data."
                end
            else
                predictions[!, :team] .= "Unknown"
                @warn "No team data available for $pcs_slug $year — assist simulation disabled"
            end
        end

        # Determine scoring category from race metadata
        ri = _find_race_by_slug(pcs_slug)
        cat = ri !== nothing ? ri.category : 2
        scoring = get_scoring(cat > 0 ? cat : 2)

        # Compute breakaway rates for this race's riders
        b_rates, b_sectors = if !isempty(breakaway_dir) && isdir(breakaway_dir)
            try
                bdf = load_pcs_breakaway_stats(breakaway_dir)
                compute_breakaway_rates(bdf, String.(predictions.riderkey))
            catch
                Float64[], Float64[]
            end
        else
            Float64[], Float64[]
        end

        # Regenerate draws
        sim_vg_points = simulate_vg_draws(
            predictions, scoring;
            n_draws = n_draws,
            breakaway_rates = b_rates,
            breakaway_mean_sectors = b_sectors,
            simulation_df = simulation_df,
        )

        # Build actual results DataFrame with riderkey and actual VG points
        actual_df = leftjoin(
            predictions[:, [:riderkey, :rider]],
            vg_results[:, [:riderkey, :score]];
            on = :riderkey,
        )
        actual_df[!, :actual_vg_points] = Float64.(coalesce.(actual_df.score, 0))

        pit = compute_pit_values(predictions, sim_vg_points, actual_df)
        nrow(pit) == 0 && continue

        pit[!, :race] .= pcs_slug
        push!(all_pit, pit)
    end

    isempty(all_pit) && return DataFrame()
    vcat(all_pit...)
end

"""
    prospective_pit_summary(pit_values; scored_only) -> NamedTuple

Summarise aggregate PIT values: mean, variance, KS statistic against uniform.
Well-calibrated predictions have mean ≈ 0.5 and variance ≈ 1/12 ≈ 0.0833.
"""
function prospective_pit_summary(pit_values::DataFrame; scored_only::Bool = true)
    subset = scored_only ? filter(:scored => identity, pit_values) : pit_values
    n = nrow(subset)
    n == 0 && return (; n = 0, mean_pit = NaN, var_pit = NaN, ks_statistic = NaN)

    pits = subset.pit_value
    m = mean(pits)
    v = var(pits)

    # Kolmogorov-Smirnov statistic against uniform(0,1)
    sorted = sort(pits)
    ks = maximum(
        max(abs(sorted[i] - (i - 1) / n), abs(sorted[i] - i / n)) for i in 1:n
    )

    (;
        n = n,
        mean_pit = round(m, digits = 3),
        var_pit = round(v, digits = 4),
        ks_statistic = round(ks, digits = 3),
    )
end

"""
    signal_value_analysis(year; archive_dir) -> DataFrame

For each signal, compute:
- Mean absolute shift (how much it moves predictions)
- Number of races where the signal was active

Requires archived predictions. Signal direction correctness requires
actual results (computed only for races with both).
"""
function signal_value_analysis(year::Int; archive_dir::String = DEFAULT_ARCHIVE_DIR)
    pred_dir = joinpath(archive_dir, "predictions")
    if !isdir(pred_dir)
        return DataFrame()
    end

    # Accumulate per-signal stats across races
    signal_totals = Dict{Symbol,Vector{Float64}}()

    for race_dir in readdir(pred_dir; join = true)
        isdir(race_dir) || continue
        pcs_slug = basename(race_dir)
        feather_path = joinpath(race_dir, "$year.feather")
        isfile(feather_path) || continue

        predictions =
            load_race_snapshot("predictions", pcs_slug, year; archive_dir = archive_dir)
        predictions === nothing && continue

        shift_cols =
            filter(c -> startswith(string(c), "shift_") && c != :shift_trajectory, propertynames(predictions))
        for col in shift_cols
            signal = Symbol(replace(string(col), "shift_" => ""))
            vals = abs.(predictions[!, col])
            active = filter(>(0.0), vals)
            if !isempty(active)
                if !haskey(signal_totals, signal)
                    signal_totals[signal] = Float64[]
                end
                append!(signal_totals[signal], active)
            end
        end
    end

    isempty(signal_totals) && return DataFrame()

    rows = [
        (;
            signal = k,
            mean_abs_shift = round(mean(v), digits = 3),
            n_observations = length(v),
        ) for (k, v) in sort(collect(signal_totals); by = x -> -mean(x[2]))
    ]

    DataFrame(rows)
end
