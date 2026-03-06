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

const _SIGNAL_NAMES = ["PCS", "VG", "Form", "Traj", "Hist", "VG hist", "Oracle", "Qual", "Odds"]
const _SHIFT_COLS = [:shift_pcs, :shift_vg, :shift_form, :shift_trajectory, :shift_history, :shift_vg_history, :shift_oracle, :shift_qualitative, :shift_odds]

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
    alpha = round(intensity * 0.45, digits=2)  # max 0.45 opacity for readability
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
    max_abs = maximum(all_shifts; init=1.0)

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
        push!(lines, "<td style='padding:4px; white-space:nowrap'><strong>$(row.rider)</strong><br><span style='color:#888; font-size:0.85em'>$team_str</span></td>")
        push!(lines, "<td style='text-align:right; padding:4px'>$(row.cost)</td>")

        for shift in shifts
            style = _shift_cell_style(shift, max_abs)
            display_val = shift == 0.0 ? "·" : string(round(shift, digits=2))
            push!(lines, "<td style='$style; padding:4px'>$display_val</td>")
        end

        push!(lines, "<td style='text-align:right; padding:4px; font-weight:bold'>$(round(row.strength, digits=2))</td>")
        push!(lines, "<td style='text-align:right; padding:4px'>$(round(row.uncertainty, digits=2))</td>")
        flag_style = isempty(flag) ? "" : " color:#c44"
        push!(lines, "<td style='padding:4px; font-size:0.85em;$flag_style'>$flag</td>")
        push!(lines, "</tr>")
    end

    push!(lines, "</tbody></table>")
    return join(lines, "\n")
end
