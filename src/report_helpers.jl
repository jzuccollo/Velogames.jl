# ---------------------------------------------------------------------------
# Plotly chart helpers (for Quarto HTML output without WebIO)
# ---------------------------------------------------------------------------

"""
    plotly_html(traces, layout; id) -> String

Serialise PlotlyBase traces and layout to a raw HTML block that Quarto
can embed directly via `output: asis`. Loads Plotly.js from CDN in the
page header (see `include-in-header` in the report template).
"""
function plotly_html(traces, layout; id::String = "plot-" * string(rand(UInt32), base = 16))
    spec = Dict(
        "data" => [JSON3.read(JSON3.write(t)) for t in traces],
        "layout" => JSON3.read(JSON3.write(layout)),
    )
    json_str = JSON3.write(spec)
    return """
    ```{=html}
    <div id="$id" style="width:100%; height:500px;"></div>
    <script>Plotly.newPlot('$id', $json_str.data, $json_str.layout, {responsive: true})</script>
    ```
    """
end

# ---------------------------------------------------------------------------
# Race report data assembly (used by site/race_report.qmd)
# ---------------------------------------------------------------------------

"""
    list_completed_races(years; archive_dir) -> DataFrame

Scan the VG results archive for completed races and cross-reference with
`CLASSICS_RACES_2026` for metadata. Returns a DataFrame with columns:
pcs_slug, year, name, date, category.
"""
function list_completed_races(
    years::Vector{Int} = [2025, 2026];
    archive_dir::String = DEFAULT_ARCHIVE_DIR,
)
    rows = NamedTuple{
        (:pcs_slug, :year, :name, :date, :category),
        Tuple{String,Int,String,String,Int},
    }[]
    vg_dir = joinpath(archive_dir, "vg_results")
    isdir(vg_dir) || return DataFrame(rows)

    for slug_dir in readdir(vg_dir; join = true)
        isdir(slug_dir) || continue
        pcs_slug = basename(slug_dir)
        ri = _find_race_by_slug(pcs_slug)
        for f in readdir(slug_dir)
            m = match(r"^(\d{4})\.feather$", f)
            m === nothing && continue
            yr = parse(Int, m[1])
            yr in years || continue
            name = ri !== nothing ? ri.name : replace(pcs_slug, "-" => " ") |> titlecase
            date = ri !== nothing ? replace(ri.date, r"^\d{4}" => string(yr)) : "$yr-01-01"
            cat = ri !== nothing ? ri.category : 0
            push!(
                rows,
                (pcs_slug = pcs_slug, year = yr, name = name, date = date, category = cat),
            )
        end
    end

    df = DataFrame(rows)
    sort!(df, [:date, :name])
    return df
end

"""
    load_report_data(pcs_slug, year) -> Union{DataFrame, Nothing}

Load VG race results and rider costs, join them, and compute value.
Returns a DataFrame with columns: rider, team, cost, score, value, riderkey.
Returns `nothing` if no archived results exist.
"""
function load_report_data(
    pcs_slug::String,
    year::Int;
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    vg_results = load_race_snapshot("vg_results", pcs_slug, year)
    vg_results === nothing && return nothing
    pcs_results = load_race_snapshot("pcs_results", pcs_slug, year)

    # Load rider costs from the classics riders page
    riders_url = vg_classics_url(year)
    riders = getvgriders(riders_url; cache_config = cache_config)

    # Start from VG riders list and left-join results to get all riders with costs
    df = leftjoin(
        riders[:, [:rider, :team, :riderkey, :cost]],
        vg_results[:, [:riderkey, :score]];
        on = :riderkey,
    )
    # Fill missing scores (riders who didn't score) with 0
    df[!, :score] = coalesce.(df.score, 0)

    # Filter to race starters using PCS results if available
    if pcs_results !== nothing && :riderkey in propertynames(pcs_results)
        starter_keys = Set(pcs_results.riderkey)
        filter!(row -> row.riderkey in starter_keys, df)
    end

    df[!, :value] = round.(df.score ./ max.(df.cost, 1), digits = 1)
    clean_team_names!(df, [:team])
    return df
end

"""
    compute_optimal_team(df) -> Union{DataFrame, Nothing}

Find the hindsight-optimal one-day team (6 riders, cost <= 100) from actual results.
"""
function compute_optimal_team(df::DataFrame)
    result = build_model_oneday(df, 6, :score, :cost; totalcost = 100)
    result === nothing && return nothing
    chosen_keys = Set(k for k in df.riderkey if result[k] > 0.5)
    return filter(row -> row.riderkey in chosen_keys, df)
end

"""
    compute_cheapest_winning_team(df, target_score) -> Union{DataFrame, Nothing}

Find the minimum-cost one-day team that beats `target_score`.
"""
function compute_cheapest_winning_team(df::DataFrame, target_score::Real)
    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x[df.riderkey], Bin)
    JuMP.@objective(model, Min, df.cost' * x)
    JuMP.@constraint(model, df.score' * x >= target_score + 1)
    JuMP.@constraint(model, sum(x) == 6)
    JuMP.optimize!(model)
    if JuMP.termination_status(model) != JuMP.OPTIMAL
        return nothing
    end
    chosen_keys = Set(k for k in df.riderkey if JuMP.value(x[k]) > 0.5)
    return filter(row -> row.riderkey in chosen_keys, df)
end

"""
    suppress_output(f)

Suppress stdout and info-level logging whilst executing `f()`.
Useful in Quarto notebooks to keep rendered output clean.
"""
function suppress_output(f)
    redirect_stdout(devnull) do
        Base.CoreLogging.with_logger(
            Base.CoreLogging.SimpleLogger(stderr, Base.CoreLogging.Warn),
        ) do
            f()
        end
    end
end

"""
    clean_team_names!(df, team_columns)

Replace pipe characters with hyphens for each column listed in `team_columns`.
Returns the modified DataFrame so the function can be chained.
"""
function clean_team_names!(df::DataFrame, team_columns::Vector{Symbol})
    for col in team_columns
        if col in propertynames(df)
            df[!, col] = map(unpipe, df[!, col])
        end
    end
    return df
end

"""
    round_numeric_columns!(df; digits=1)

Round all numeric columns in the DataFrame to the given number of digits.
Returns the modified DataFrame for chaining.
"""
function round_numeric_columns!(df::DataFrame; digits::Int = 1)
    for col in names(df)
        if eltype(df[!, col]) <: Union{Missing,Number}
            df[!, col] = round.(df[!, col]; digits = digits)
        end
    end
    return df
end

"""
    precision_budget(config; n_history_years=3) -> DataFrame

Compute per-signal precision contributions for the Bayesian model at the given
config. Returns a DataFrame with columns: signal, variance, precision, share.
"""
function precision_budget(
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG;
    n_history_years::Int = 3,
)
    signals = [
        ("Odds", odds_variance(config)),
        ("Oracle", oracle_variance(config)),
        ("Form", form_variance(config)),
        ("PCS race history ($(n_history_years)y)", hist_base_variance(config)),
        ("VG race history ($(n_history_years)y)", vg_hist_base_variance(config)),
        ("PCS specialty", pcs_variance(config)),
        ("VG season points", vg_variance(config)),
        ("Trajectory", trajectory_variance(config)),
        ("Prior", config.prior_variance),
    ]

    precisions = [
        (
            name,
            var,
            name in (
                "PCS race history ($(n_history_years)y)",
                "VG race history ($(n_history_years)y)",
            ) ? n_history_years / var : 1.0 / var,
        ) for (name, var) in signals
    ]
    total = sum(p for (_, _, p) in precisions)

    DataFrame(
        signal = [name for (name, _, _) in precisions],
        variance = [round(var, digits = 3) for (_, var, _) in precisions],
        precision = [round(p, digits = 3) for (_, _, p) in precisions],
        share = [string(round(Int, 100 * p / total), "%") for (_, _, p) in precisions],
    )
end

const _SIGNAL_NAMES =
    ["PCS", "VG", "Form", "Traj", "Hist", "VG hist", "Oracle", "Qual", "Odds"]
const _SHIFT_COLS = [
    :shift_pcs,
    :shift_vg,
    :shift_form,
    :shift_trajectory,
    :shift_history,
    :shift_vg_history,
    :shift_oracle,
    :shift_qualitative,
    :shift_odds,
]

"""
    _shift_cell_style(value, max_abs)

Return an inline CSS style string for a shift cell, using a diverging
red-white-green colour scale. Positive = green, negative = red,
intensity proportional to |value| / max_abs.
"""
function _shift_cell_style(value::Float64, max_abs::Float64)
    if max_abs == 0.0 || value == 0.0
        return "text-align:right; color:#999"
    end
    intensity = clamp(abs(value) / max_abs, 0.0, 1.0)
    alpha = round(intensity * 0.45, digits = 2)  # max 0.45 opacity for readability
    colour = value > 0 ? "rgba(34,139,34,$alpha)" : "rgba(220,20,60,$alpha)"
    return "text-align:right; background:$colour"
end

"""
    format_signal_waterfall(df; max_riders=10)

Generate an HTML table showing per-rider signal shifts with heatmap colouring.
Positive shifts are green, negative are red, with intensity proportional to
magnitude. Flags riders with few active signals or single-signal dominance.
"""
function format_signal_waterfall(df::DataFrame; max_riders::Int = 10)
    subset = df[1:min(max_riders, nrow(df)), :]

    # Find max absolute shift across all riders for consistent colour scaling
    all_shifts = Float64[]
    for row in eachrow(subset)
        for c in _SHIFT_COLS
            push!(all_shifts, abs(Float64(row[c])))
        end
    end
    max_abs = maximum(all_shifts; init = 1.0)

    lines = String[]
    push!(lines, "<table style='border-collapse:collapse; font-size:0.85em; width:100%'>")
    push!(lines, "<thead><tr style='border-bottom:2px solid #666'>")
    push!(lines, "<th style='text-align:left; padding:4px'>Rider</th>")
    push!(lines, "<th style='text-align:right; padding:4px'>Cost</th>")
    for name in _SIGNAL_NAMES
        push!(lines, "<th style='text-align:right; padding:4px'>$name</th>")
    end
    push!(lines, "<th style='text-align:right; padding:4px'>Str</th>")
    push!(lines, "<th style='text-align:right; padding:4px'>Unc</th>")
    push!(lines, "<th style='text-align:left; padding:4px'>Flag</th>")
    push!(lines, "</tr></thead><tbody>")

    for row in eachrow(subset)
        shifts = [Float64(row[c]) for c in _SHIFT_COLS]
        n_active = count(!=(0.0), shifts)
        total_abs = sum(abs.(shifts))

        # Flag logic
        dominant_name, dominant_pct = if total_abs > 0
            idx = argmax(abs.(shifts))
            _SIGNAL_NAMES[idx], round(Int, 100 * abs(shifts[idx]) / total_abs)
        else
            "none", 0
        end
        flag = if n_active <= 2
            "⚠ few signals"
        elseif dominant_pct > 60
            "⚠ $(dominant_name) $(dominant_pct)%"
        else
            ""
        end

        team_str = hasproperty(row, :team) ? unpipe(string(row.team)) : ""
        push!(lines, "<tr style='border-bottom:1px solid #ddd'>")
        push!(
            lines,
            "<td style='padding:4px; white-space:nowrap'><strong>$(row.rider)</strong><br><span style='color:#888; font-size:0.85em'>$team_str</span></td>",
        )
        push!(lines, "<td style='text-align:right; padding:4px'>$(row.cost)</td>")

        for shift in shifts
            style = _shift_cell_style(shift, max_abs)
            display_val = shift == 0.0 ? "·" : string(round(shift, digits = 2))
            push!(lines, "<td style='$style; padding:4px'>$display_val</td>")
        end

        push!(
            lines,
            "<td style='text-align:right; padding:4px; font-weight:bold'>$(round(row.strength, digits=2))</td>",
        )
        push!(
            lines,
            "<td style='text-align:right; padding:4px'>$(round(row.uncertainty, digits=2))</td>",
        )
        flag_style = isempty(flag) ? "" : " color:#c44"
        push!(lines, "<td style='padding:4px; font-size:0.85em;$flag_style'>$flag</td>")
        push!(lines, "</tr>")
    end

    push!(lines, "</tbody></table>")
    return join(lines, "\n")
end
