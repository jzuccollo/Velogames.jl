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
            filter(c -> startswith(string(c), "shift_"), propertynames(predictions))
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
