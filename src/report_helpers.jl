# ---------------------------------------------------------------------------
# HTML page generation (replaces Quarto)
# ---------------------------------------------------------------------------

"""Slugify text for use as an HTML id attribute."""
function _slugify(text::String)
    s = lowercase(text)
    s = replace(s, r"[^a-z0-9\s-]" => "")
    s = replace(s, r"\s+" => "-")
    return String(strip(s, '-'))
end

"""
    html_heading(text, level; id) -> String

Return an HTML heading tag with an auto-slugified id for ToC linking.
"""
function html_heading(text::String, level::Int = 2; id::String = _slugify(text))
    return "<h$level id=\"$id\">$text</h$level>\n"
end

"""
    html_table(df; caption, team_cols) -> String

Convert a DataFrame to a Bootstrap-styled HTML table. Rounds numeric columns
and cleans team name pipe characters automatically.
"""
function html_table(
    df::DataFrame;
    caption::String = "",
    team_cols::Vector{Symbol} = [:team, :Team],
)
    display = copy(df)
    round_numeric_columns!(display)
    clean_team_names!(display, intersect(team_cols, propertynames(display)))

    io = IOBuffer()
    write(io, "<table class=\"table table-striped table-sm\">\n")
    !isempty(caption) && write(io, "<caption>$caption</caption>\n")

    # Header
    write(io, "<thead><tr>")
    for col in names(display)
        write(io, "<th>$col</th>")
    end
    write(io, "</tr></thead>\n<tbody>\n")

    # Rows
    for row in eachrow(display)
        write(io, "<tr>")
        for col in names(display)
            val = row[col]
            cell = ismissing(val) ? "" : string(val)
            write(io, "<td>$cell</td>")
        end
        write(io, "</tr>\n")
    end
    write(io, "</tbody></table>\n")
    return String(take!(io))
end

"""
    html_callout(content; type, title, collapsed) -> String

Generate a Bootstrap-styled callout. Types: "note" (blue), "warning" (yellow),
"tip" (green). When `collapsed=true`, uses a `<details>` element.
"""
function html_callout(
    content::String;
    type::String = "note",
    title::String = "",
    collapsed::Bool = false,
)
    colour = type == "warning" ? "#856404" : type == "tip" ? "#155724" : "#004085"
    bg = type == "warning" ? "#fff3cd" : type == "tip" ? "#d4edda" : "#cce5ff"
    border = type == "warning" ? "#ffc107" : type == "tip" ? "#28a745" : "#007bff"

    if collapsed
        summary = isempty(title) ? titlecase(type) : title
        return """<details style="margin:1em 0; border-left:4px solid $border; padding:0.5em 1em; background:$bg;">
<summary style="color:$colour; font-weight:bold; cursor:pointer;">$summary</summary>
$content
</details>\n"""
    end

    header = isempty(title) ? "" : "<strong style=\"color:$colour;\">$title</strong><br>"
    return """<div style="margin:1em 0; border-left:4px solid $border; padding:0.75em 1em; background:$bg;">
$header$content
</div>\n"""
end

const _HTML_PAGE_CSS = """
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
       max-width: 960px; margin: 2em auto; padding: 0 1em; color: #333; line-height: 1.6; }
h1, h2, h3, h4 { margin-top: 1.5em; }
h1 { border-bottom: 1px solid #ddd; padding-bottom: 0.3em; }
table { border-collapse: collapse; width: 100%; margin: 1em 0; font-size: 0.9em; }
th, td { padding: 0.4em 0.8em; text-align: left; border-bottom: 1px solid #ddd; }
th { background: #f8f9fa; font-weight: 600; }
tr:hover { background: #f5f5f5; }
.table-striped tbody tr:nth-child(odd) { background: #fafafa; }
details { margin: 1em 0; }
summary { cursor: pointer; font-weight: bold; }
nav#toc { position: fixed; top: 2em; right: 2em; width: 220px; max-height: 80vh;
          overflow-y: auto; font-size: 0.85em; border-left: 2px solid #ddd; padding-left: 1em; }
nav#toc a { display: block; padding: 0.2em 0; color: #555; text-decoration: none; }
nav#toc a:hover { color: #007bff; }
nav#toc .toc-h3 { padding-left: 1em; font-size: 0.9em; }
@media (max-width: 1200px) { nav#toc { display: none; } body { max-width: 800px; } }
.subtitle { color: #666; font-size: 1.1em; margin-top: -0.8em; margin-bottom: 1.5em; }
"""

const _HTML_PAGE_TOC_JS = """
document.addEventListener('DOMContentLoaded', function() {
  var toc = document.getElementById('toc');
  if (!toc) return;
  var headings = document.querySelectorAll('h2[id], h3[id]');
  headings.forEach(function(h) {
    var a = document.createElement('a');
    a.href = '#' + h.id;
    a.textContent = h.textContent;
    if (h.tagName === 'H3') a.className = 'toc-h3';
    toc.appendChild(a);
  });
});
"""

"""
    html_page(; title, subtitle, body, include_plotly) -> String

Wrap body content in a complete, standalone HTML page with CSS and ToC.
"""
function html_page(;
    title::String,
    subtitle::String = "",
    body::String,
    include_plotly::Bool = false,
)
    plotly_script = include_plotly ? "\n<script src=\"https://cdn.plot.ly/plotly-2.35.2.min.js\"></script>" : ""
    subtitle_html = isempty(subtitle) ? "" : "<p class=\"subtitle\">$subtitle</p>\n"

    return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>$(_HTML_PAGE_CSS)</style>$plotly_script
</head>
<body>
<h1>$title</h1>
$subtitle_html$body
<nav id="toc"></nav>
<script>$(_HTML_PAGE_TOC_JS)</script>
</body>
</html>
"""
end

# ---------------------------------------------------------------------------
# Plotly chart helpers
# ---------------------------------------------------------------------------

"""
    plotly_html(traces, layout; id, width, height) -> String

Serialise PlotlyBase traces and layout to an HTML block with a div and script tag.
"""
function plotly_html(
    traces,
    layout;
    id::String = "plot-" * string(rand(UInt32), base = 16),
    width::String = "100%",
    height::String = "500px",
)
    spec = Dict(
        "data" => [JSON3.read(JSON3.write(t)) for t in traces],
        "layout" => JSON3.read(JSON3.write(layout)),
    )
    json_str = JSON3.write(spec)
    return """<div id="$id" style="width:$(width); height:$(height);"></div>
<script>Plotly.newPlot('$id', $json_str.data, $json_str.layout, {responsive: true})</script>"""
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
    # (name, base_variance, is_market_signal)
    signals = [
        ("Odds", odds_variance(config), true),
        ("Oracle", oracle_variance(config), true),
        ("Form", form_variance(config), false),
        ("PCS race history ($(n_history_years)y)", hist_base_variance(config), false),
        ("VG race history ($(n_history_years)y)", vg_hist_base_variance(config), false),
        ("PCS seasons", pcs_variance(config), false),
        ("VG season points", vg_variance(config), false),
        ("Prior", config.prior_variance, false),
    ]

    md = config.market_discount
    hist_names = Set([
        "PCS race history ($(n_history_years)y)",
        "VG race history ($(n_history_years)y)",
    ])

    precisions = [
        (
            name, var, is_market,
            name in hist_names ? n_history_years / var : 1.0 / var,
            # With market discount: market signals unchanged, others inflated
            is_market ?
                (name in hist_names ? n_history_years / var : 1.0 / var) :
                (name in hist_names ? n_history_years / (var * md) : 1.0 / (var * md)),
        ) for (name, var, is_market) in signals
    ]
    total = sum(p for (_, _, _, p, _) in precisions)
    total_md = sum(p for (_, _, _, _, p) in precisions)

    DataFrame(
        signal = [name for (name, _, _, _, _) in precisions],
        variance = [round(var, digits = 3) for (_, var, _, _, _) in precisions],
        precision = [round(p, digits = 3) for (_, _, _, p, _) in precisions],
        share = [string(round(Int, 100 * p / total), "%") for (_, _, _, p, _) in precisions],
        precision_with_market = [round(p, digits = 3) for (_, _, _, _, p) in precisions],
        share_with_market = [string(round(Int, 100 * p / total_md), "%") for (_, _, _, _, p) in precisions],
    )
end

const _SIGNAL_NAMES =
    ["PCS", "VG", "Form", "Hist", "VG hist", "Oracle", "Qual", "Odds"]
const _SHIFT_COLS = [
    :shift_pcs,
    :shift_vg,
    :shift_form,
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

"""
    compute_pit_values(predicted, sim_vg_points, actual_results) -> DataFrame

Compute probability integral transform (PIT) values for calibration checking.
For each rider with actual results, compute the empirical CDF value of their
actual VG points within the simulated distribution.

Returns a DataFrame with columns: riderkey, rider, actual_vg_points, pit_value, scored.
"""
function compute_pit_values(
    predicted::DataFrame,
    sim_vg_points::Matrix{Float64},
    actual_results::DataFrame,
)
    key_to_idx = Dict(predicted.riderkey[i] => i for i in 1:nrow(predicted))

    rows = NamedTuple{
        (:riderkey, :rider, :actual_vg_points, :pit_value, :scored),
        Tuple{String,String,Float64,Float64,Bool},
    }[]

    actual_col = :actual_vg_points in propertynames(actual_results) ? :actual_vg_points :
                 :score in propertynames(actual_results) ? :score : nothing
    actual_col === nothing && return DataFrame(rows)

    for row in eachrow(actual_results)
        idx = get(key_to_idx, row.riderkey, nothing)
        idx === nothing && continue
        actual_pts = Float64(coalesce(row[actual_col], 0))
        draws = @view sim_vg_points[idx, :]
        n_draws = length(draws)
        # Empirical CDF: fraction of draws <= actual
        pit = count(<=(actual_pts), draws) / n_draws
        rider_name = :rider in propertynames(actual_results) ? string(row.rider) :
                     idx <= nrow(predicted) ? string(predicted.rider[idx]) : ""
        push!(rows, (
            riderkey = string(row.riderkey),
            rider = rider_name,
            actual_vg_points = actual_pts,
            pit_value = pit,
            scored = actual_pts > 0.0,
        ))
    end

    DataFrame(rows)
end

"""
    pit_histogram_chart(pit_values; title, scored_only, compact) -> String

Generate an inline SVG histogram of PIT values for calibration checking.
Well-calibrated predictions produce a uniform histogram. Skewed right (many
values near 1) means the model underestimates; skewed left means it overestimates.

By default shows only riders who scored (positions 1-30). Set `scored_only=false`
to include all riders.
"""
function pit_histogram_chart(
    pit_values::DataFrame;
    title::String = "PIT calibration histogram",
    scored_only::Bool = true,
    compact::Bool = false,
)
    subset = scored_only ? filter(:scored => identity, pit_values) : pit_values
    nrow(subset) == 0 && return ""

    # Bin into 10 equal-width bins [0,0.1), [0.1,0.2), ... [0.9,1.0]
    counts = zeros(Int, 10)
    for v in subset.pit_value
        bin = clamp(floor(Int, v * 10) + 1, 1, 10)
        counts[bin] += 1
    end

    n = nrow(subset)
    expected = n / 10
    max_count = max(maximum(counts), expected) * 1.1

    # SVG dimensions
    w = compact ? 240 : 400
    h = compact ? 140 : 250
    pad_l = compact ? 30 : 45
    pad_r = 10
    pad_t = compact ? 20 : 30
    pad_b = compact ? 25 : 40
    plot_w = w - pad_l - pad_r
    plot_h = h - pad_t - pad_b
    bar_gap = 2

    subtitle = scored_only ? " ($(n) scoring)" : " ($(n) riders)"
    font_size = compact ? 10 : 12
    title_size = compact ? 11 : 13

    io = IOBuffer()
    write(io, "<svg width=\"$(w)\" height=\"$(h)\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family:sans-serif;\">")

    # Title
    write(io, "<text x=\"$(w÷2)\" y=\"$(pad_t - 6)\" text-anchor=\"middle\" font-size=\"$(title_size)\" fill=\"#333\">$(title)$(subtitle)</text>")

    # Bars
    bar_w = plot_w / 10 - bar_gap
    for i in 1:10
        bh = plot_h * counts[i] / max_count
        x = pad_l + (i - 1) * (plot_w / 10) + bar_gap / 2
        y = pad_t + plot_h - bh
        write(io, "<rect x=\"$(round(x,digits=1))\" y=\"$(round(y,digits=1))\" width=\"$(round(bar_w,digits=1))\" height=\"$(round(bh,digits=1))\" fill=\"steelblue\" stroke=\"white\" stroke-width=\"1\"/>")
    end

    # Uniform reference line (dashed red)
    ref_y = pad_t + plot_h - plot_h * expected / max_count
    write(io, "<line x1=\"$(pad_l)\" y1=\"$(round(ref_y,digits=1))\" x2=\"$(w - pad_r)\" y2=\"$(round(ref_y,digits=1))\" stroke=\"red\" stroke-width=\"1.5\" stroke-dasharray=\"6,3\"/>")

    # X-axis labels
    for i in 0:2:10
        x = pad_l + i * (plot_w / 10)
        write(io, "<text x=\"$(round(x,digits=1))\" y=\"$(pad_t + plot_h + font_size + 4)\" text-anchor=\"middle\" font-size=\"$(font_size - 1)\" fill=\"#666\">$(round(i/10, digits=1))</text>")
    end

    # Y-axis: just max and zero
    if !compact
        write(io, "<text x=\"$(pad_l - 5)\" y=\"$(pad_t + 4)\" text-anchor=\"end\" font-size=\"$(font_size - 1)\" fill=\"#666\">$(round(Int, max_count))</text>")
        write(io, "<text x=\"$(pad_l - 5)\" y=\"$(pad_t + plot_h + 4)\" text-anchor=\"end\" font-size=\"$(font_size - 1)\" fill=\"#666\">0</text>")
    end

    write(io, "</svg>")
    return String(take!(io))
end

"""
    scatter_chart(x, y; title, xlabel, ylabel, colours, reference_line) -> String

Generate an inline SVG scatter plot. `colours` is an optional vector of hex colour
strings (one per point). When `reference_line=true`, a 45-degree y=x line is drawn.
"""
function scatter_chart(
    x::AbstractVector{<:Real},
    y::AbstractVector{<:Real};
    title::String = "",
    xlabel::String = "x",
    ylabel::String = "y",
    colours::Union{Vector{String},Nothing} = nothing,
    reference_line::Bool = false,
)
    length(x) == 0 && return ""
    w, h = 420, 320
    pad_l, pad_r, pad_t, pad_b = 55, 15, 30, 40
    plot_w = w - pad_l - pad_r
    plot_h = h - pad_t - pad_b

    xmin, xmax = extrema(x)
    ymin, ymax = extrema(y)
    # Add 5% padding to ranges
    xrange = max(xmax - xmin, 1e-6)
    yrange = max(ymax - ymin, 1e-6)
    xmin -= 0.05 * xrange; xmax += 0.05 * xrange
    ymin -= 0.05 * yrange; ymax += 0.05 * yrange

    sx(v) = pad_l + plot_w * (v - xmin) / (xmax - xmin)
    sy(v) = pad_t + plot_h * (1.0 - (v - ymin) / (ymax - ymin))

    io = IOBuffer()
    write(io, "<svg width=\"$(w)\" height=\"$(h)\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family:sans-serif;\">")

    # Title
    !isempty(title) && write(io, "<text x=\"$(w÷2)\" y=\"16\" text-anchor=\"middle\" font-size=\"13\" fill=\"#333\">$(title)</text>")

    # Axes
    write(io, "<line x1=\"$(pad_l)\" y1=\"$(pad_t)\" x2=\"$(pad_l)\" y2=\"$(pad_t+plot_h)\" stroke=\"#ccc\" stroke-width=\"1\"/>")
    write(io, "<line x1=\"$(pad_l)\" y1=\"$(pad_t+plot_h)\" x2=\"$(pad_l+plot_w)\" y2=\"$(pad_t+plot_h)\" stroke=\"#ccc\" stroke-width=\"1\"/>")

    # Reference line (y=x)
    if reference_line
        lo = max(xmin, ymin)
        hi = min(xmax, ymax)
        if hi > lo
            write(io, "<line x1=\"$(round(sx(lo),digits=1))\" y1=\"$(round(sy(lo),digits=1))\" x2=\"$(round(sx(hi),digits=1))\" y2=\"$(round(sy(hi),digits=1))\" stroke=\"red\" stroke-width=\"1\" stroke-dasharray=\"6,3\" opacity=\"0.6\"/>")
        end
    end

    # Points
    for i in eachindex(x)
        cx = round(sx(x[i]), digits=1)
        cy = round(sy(y[i]), digits=1)
        col = colours !== nothing ? colours[i] : "steelblue"
        write(io, "<circle cx=\"$(cx)\" cy=\"$(cy)\" r=\"3\" fill=\"$(col)\" opacity=\"0.6\"/>")
    end

    # Axis labels
    write(io, "<text x=\"$(pad_l + plot_w÷2)\" y=\"$(h - 5)\" text-anchor=\"middle\" font-size=\"11\" fill=\"#666\">$(xlabel)</text>")
    write(io, "<text x=\"14\" y=\"$(pad_t + plot_h÷2)\" text-anchor=\"middle\" font-size=\"11\" fill=\"#666\" transform=\"rotate(-90, 14, $(pad_t + plot_h÷2))\">$(ylabel)</text>")

    # Tick labels (5 ticks each axis)
    for i in 0:4
        # X
        v = xmin + i * (xmax - xmin) / 4
        px = round(sx(v), digits=1)
        write(io, "<text x=\"$(px)\" y=\"$(pad_t + plot_h + 14)\" text-anchor=\"middle\" font-size=\"9\" fill=\"#999\">$(round(v, digits=0))</text>")
        # Y
        v = ymin + i * (ymax - ymin) / 4
        py = round(sy(v), digits=1)
        write(io, "<text x=\"$(pad_l - 5)\" y=\"$(py + 3)\" text-anchor=\"end\" font-size=\"9\" fill=\"#999\">$(round(v, digits=0))</text>")
    end

    write(io, "</svg>")
    return String(take!(io))
end

"""
    rank_histogram_chart(counts; title, expected) -> String

Generate an inline SVG bar chart for SBC rank histograms or similar uniform-calibration
checks. `counts` is a vector of bin counts; `expected` is the expected count per bin
under uniformity.
"""
function rank_histogram_chart(
    counts::Vector{<:Real};
    title::String = "Rank histogram",
    expected::Union{Float64,Nothing} = nothing,
)
    n_bins = length(counts)
    n_bins == 0 && return ""
    exp_val = expected !== nothing ? expected : sum(counts) / n_bins
    max_count = max(maximum(counts), exp_val) * 1.1

    w, h = 400, 220
    pad_l, pad_r, pad_t, pad_b = 45, 10, 30, 35
    plot_w = w - pad_l - pad_r
    plot_h = h - pad_t - pad_b
    bar_gap = 1

    io = IOBuffer()
    write(io, "<svg width=\"$(w)\" height=\"$(h)\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family:sans-serif;\">")
    write(io, "<text x=\"$(w÷2)\" y=\"16\" text-anchor=\"middle\" font-size=\"13\" fill=\"#333\">$(title)</text>")

    bar_w = plot_w / n_bins - bar_gap
    for i in 1:n_bins
        bh = plot_h * counts[i] / max_count
        x = pad_l + (i - 1) * (plot_w / n_bins) + bar_gap / 2
        y = pad_t + plot_h - bh
        write(io, "<rect x=\"$(round(x,digits=1))\" y=\"$(round(y,digits=1))\" width=\"$(round(bar_w,digits=1))\" height=\"$(round(bh,digits=1))\" fill=\"steelblue\" stroke=\"white\" stroke-width=\"1\"/>")
    end

    # Expected reference line
    ref_y = pad_t + plot_h - plot_h * exp_val / max_count
    write(io, "<line x1=\"$(pad_l)\" y1=\"$(round(ref_y,digits=1))\" x2=\"$(w - pad_r)\" y2=\"$(round(ref_y,digits=1))\" stroke=\"red\" stroke-width=\"1.5\" stroke-dasharray=\"6,3\"/>")

    # X-axis labels (every other bin)
    step = max(1, n_bins ÷ 10)
    for i in 1:step:n_bins
        x = pad_l + (i - 0.5) * (plot_w / n_bins)
        write(io, "<text x=\"$(round(x,digits=1))\" y=\"$(pad_t + plot_h + 14)\" text-anchor=\"middle\" font-size=\"9\" fill=\"#666\">$(i)</text>")
    end

    # Y-axis
    write(io, "<text x=\"$(pad_l - 5)\" y=\"$(pad_t + 4)\" text-anchor=\"end\" font-size=\"9\" fill=\"#666\">$(round(Int, max_count))</text>")
    write(io, "<text x=\"$(pad_l - 5)\" y=\"$(pad_t + plot_h + 4)\" text-anchor=\"end\" font-size=\"9\" fill=\"#666\">0</text>")

    write(io, "</svg>")
    return String(take!(io))
end

"""
    line_chart(x_labels, series; title, ylabel) -> String

Generate an inline SVG line chart. `series` is a vector of (label, values) pairs.
"""
function line_chart(
    x_labels::Vector{String},
    series::Vector{Tuple{String,Vector{Float64}}};
    title::String = "",
    ylabel::String = "",
)
    n = length(x_labels)
    n == 0 && return ""
    w, h = 500, 280
    pad_l, pad_r, pad_t, pad_b = 55, 120, 30, 40
    plot_w = w - pad_l - pad_r
    plot_h = h - pad_t - pad_b

    all_vals = vcat([v for (_, v) in series]...)
    ymin = minimum(all_vals) * 0.95
    ymax = maximum(all_vals) * 1.05
    yrange = max(ymax - ymin, 1e-6)

    sx(i) = pad_l + (i - 1) * plot_w / max(n - 1, 1)
    sy(v) = pad_t + plot_h * (1.0 - (v - ymin) / yrange)

    colours = ["#4e79a7", "#e15759", "#76b7b2", "#59a14f", "#edc949"]

    io = IOBuffer()
    write(io, "<svg width=\"$(w)\" height=\"$(h)\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family:sans-serif;\">")
    !isempty(title) && write(io, "<text x=\"$(pad_l + plot_w÷2)\" y=\"16\" text-anchor=\"middle\" font-size=\"13\" fill=\"#333\">$(title)</text>")

    # Axes
    write(io, "<line x1=\"$(pad_l)\" y1=\"$(pad_t)\" x2=\"$(pad_l)\" y2=\"$(pad_t+plot_h)\" stroke=\"#ccc\"/>")
    write(io, "<line x1=\"$(pad_l)\" y1=\"$(pad_t+plot_h)\" x2=\"$(pad_l+plot_w)\" y2=\"$(pad_t+plot_h)\" stroke=\"#ccc\"/>")

    for (si, (label, vals)) in enumerate(series)
        col = colours[mod1(si, length(colours))]
        points = join(["$(round(sx(i),digits=1)),$(round(sy(vals[i]),digits=1))" for i in 1:min(n, length(vals))], " ")
        write(io, "<polyline points=\"$(points)\" fill=\"none\" stroke=\"$(col)\" stroke-width=\"2\"/>")
        # Legend
        ly = pad_t + 10 + (si - 1) * 16
        write(io, "<line x1=\"$(w - pad_r + 10)\" y1=\"$(ly)\" x2=\"$(w - pad_r + 25)\" y2=\"$(ly)\" stroke=\"$(col)\" stroke-width=\"2\"/>")
        write(io, "<text x=\"$(w - pad_r + 28)\" y=\"$(ly + 4)\" font-size=\"10\" fill=\"#333\">$(label)</text>")
    end

    # X-axis labels (show subset to avoid crowding)
    step = max(1, n ÷ 8)
    for i in 1:step:n
        x = round(sx(i), digits=1)
        write(io, "<text x=\"$(x)\" y=\"$(pad_t + plot_h + 14)\" text-anchor=\"middle\" font-size=\"9\" fill=\"#666\" transform=\"rotate(-30, $(x), $(pad_t + plot_h + 14))\">$(x_labels[i])</text>")
    end

    # Y-axis label
    !isempty(ylabel) && write(io, "<text x=\"14\" y=\"$(pad_t + plot_h÷2)\" text-anchor=\"middle\" font-size=\"11\" fill=\"#666\" transform=\"rotate(-90, 14, $(pad_t + plot_h÷2))\">$(ylabel)</text>")

    write(io, "</svg>")
    return String(take!(io))
end

"""
    team_total_distribution_chart(team_keys, predicted, sim_vg_points; actual_total, title) -> String

Generate an inline SVG histogram of simulated team total VG points, with the actual
total marked as a vertical line when provided.
"""
function team_total_distribution_chart(
    team_keys::Vector{String},
    predicted::DataFrame,
    sim_vg_points::Matrix{Float64};
    actual_total::Union{Float64,Nothing} = nothing,
    title::String = "Simulated team total VG points",
)
    key_to_idx = Dict(predicted.riderkey[i] => i for i in 1:nrow(predicted))
    idxs = [key_to_idx[k] for k in team_keys if haskey(key_to_idx, k)]
    isempty(idxs) && return ""

    n_draws = size(sim_vg_points, 2)
    team_totals = [sum(sim_vg_points[i, r] for i in idxs) for r in 1:n_draws]

    # Bin into 30 equal-width bins
    lo, hi = extrema(team_totals)
    hi == lo && (hi = lo + 1)
    nbins = 30
    bin_width = (hi - lo) / nbins
    counts = zeros(Int, nbins)
    for v in team_totals
        bin = clamp(floor(Int, (v - lo) / bin_width) + 1, 1, nbins)
        counts[bin] += 1
    end
    max_count = maximum(counts) * 1.1

    # SVG dimensions
    w, h = 400, 250
    pad_l, pad_r, pad_t, pad_b = 45, 15, 30, 40
    plot_w = w - pad_l - pad_r
    plot_h = h - pad_t - pad_b
    bar_gap = 1

    io = IOBuffer()
    write(io, "<svg width=\"$(w)\" height=\"$(h)\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family:sans-serif;\">")
    write(io, "<text x=\"$(w÷2)\" y=\"$(pad_t - 8)\" text-anchor=\"middle\" font-size=\"13\" fill=\"#333\">$(title)</text>")

    # Bars
    bw = plot_w / nbins - bar_gap
    for i in 1:nbins
        bh = plot_h * counts[i] / max_count
        x = pad_l + (i - 1) * (plot_w / nbins) + bar_gap / 2
        y = pad_t + plot_h - bh
        write(io, "<rect x=\"$(round(x,digits=1))\" y=\"$(round(y,digits=1))\" width=\"$(round(bw,digits=1))\" height=\"$(round(bh,digits=1))\" fill=\"steelblue\" stroke=\"white\" stroke-width=\"0.5\"/>")
    end

    # Actual total vertical line
    if actual_total !== nothing
        percentile = round(Int, 100 * count(<=(actual_total), team_totals) / n_draws)
        frac = clamp((actual_total - lo) / (hi - lo), 0, 1)
        lx = pad_l + frac * plot_w
        write(io, "<line x1=\"$(round(lx,digits=1))\" y1=\"$(pad_t)\" x2=\"$(round(lx,digits=1))\" y2=\"$(pad_t + plot_h)\" stroke=\"red\" stroke-width=\"2\" stroke-dasharray=\"6,3\"/>")
        write(io, "<text x=\"$(round(lx,digits=1))\" y=\"$(pad_t - 1)\" text-anchor=\"middle\" font-size=\"10\" fill=\"red\">$(Int(round(actual_total)))pts ($(percentile)th pctl)</text>")
    end

    # X-axis labels (5 ticks)
    for i in 0:4
        val = lo + i * (hi - lo) / 4
        x = pad_l + i * plot_w / 4
        write(io, "<text x=\"$(round(x,digits=1))\" y=\"$(pad_t + plot_h + 16)\" text-anchor=\"middle\" font-size=\"11\" fill=\"#666\">$(Int(round(val)))</text>")
    end
    write(io, "<text x=\"$(w÷2)\" y=\"$(h - 2)\" text-anchor=\"middle\" font-size=\"11\" fill=\"#666\">Total VG points</text>")

    write(io, "</svg>")
    return String(take!(io))
end

"""
    simulate_vg_draws(predicted, scoring; n_draws, rng, simulation_df) -> Matrix{Float64}

Lightweight simulation of VG points draws from archived strength estimates.
Draws noisy strengths, converts to positions, scores VG points (finish + assist).
Returns a Matrix{Float64} (n_riders × n_draws). No optimisation is performed.

Uses Student's t-distribution with `simulation_df` degrees of freedom for
heavy-tailed noise (set `simulation_df=nothing` for Gaussian).
"""
function simulate_vg_draws(
    predicted::DataFrame,
    scoring::ScoringTable;
    n_draws::Int = 500,
    rng::AbstractRNG = Random.MersenneTwister(42),
    breakaway_rates::Vector{Float64} = Float64[],
    breakaway_mean_sectors::Vector{Float64} = Float64[],
    simulation_df::Union{Int,Nothing} = nothing,
)
    n_riders = nrow(predicted)
    strengths = Float64.(predicted.strength)
    uncertainties = Float64.(predicted.uncertainty)
    teams = String.(predicted.team)

    sim_vg_points = Matrix{Float64}(undef, n_riders, n_draws)
    noisy_strengths = Vector{Float64}(undef, n_riders)

    for r = 1:n_draws
        for i = 1:n_riders
            noise = simulation_df === nothing ? randn(rng) : _rand_t(rng, simulation_df)
            noisy_strengths[i] = strengths[i] + uncertainties[i] * noise
        end

        order = sortperm(noisy_strengths, rev = true)
        positions = Vector{Int}(undef, n_riders)
        for (pos, rider_idx) in enumerate(order)
            positions[rider_idx] = pos
        end

        sim_pts = zeros(Float64, n_riders)
        for i = 1:n_riders
            sim_pts[i] = Float64(finish_points_for_position(positions[i], scoring))
        end
        for i = 1:n_riders
            if positions[i] <= 3
                top_team = teams[i]
                for j = 1:n_riders
                    if j != i && teams[j] == top_team
                        sim_pts[j] += scoring.assist_points[positions[i]]
                    end
                end
            end
        end

        # Breakaway sector points (Bernoulli draw per rider)
        if !isempty(breakaway_rates)
            for i = 1:n_riders
                if breakaway_rates[i] > 0.0 && rand(rng) < breakaway_rates[i]
                    sim_pts[i] += breakaway_mean_sectors[i] * scoring.breakaway_points
                end
            end
        end

        for i = 1:n_riders
            sim_vg_points[i, r] = sim_pts[i]
        end
    end

    return sim_vg_points
end

"""
    sim_distribution_chart(team_df, predicted, sim_vg_points; actual_results, title) -> String

Generate an inline SVG box plot showing the simulated VG points distribution
for each rider in `team_df`. Overlays actual results as diamond markers when provided.
"""
function sim_distribution_chart(
    team_df::DataFrame,
    predicted::DataFrame,
    sim_vg_points::Matrix{Float64};
    actual_results::Union{DataFrame,Nothing} = nothing,
    title::String = "Simulated VG points distribution",
)
    key_to_idx = Dict(predicted.riderkey[i] => i for i in 1:nrow(predicted))

    sort_col = :expected_vg_points in propertynames(team_df) ? :expected_vg_points : :rider
    team_sorted = sort(team_df, sort_col, rev = sort_col == :expected_vg_points)

    # Collect box plot stats for each rider
    riders = NamedTuple{(:name, :q0, :q25, :q50, :q75, :q100, :actual),
                         Tuple{String,Float64,Float64,Float64,Float64,Float64,Union{Float64,Nothing}}}[]
    for row in eachrow(team_sorted)
        idx = get(key_to_idx, row.riderkey, nothing)
        idx === nothing && continue
        draws = sim_vg_points[idx, :]
        actual_val = nothing
        if actual_results !== nothing
            match_rows = filter(r -> r.riderkey == row.riderkey, actual_results)
            if nrow(match_rows) > 0 && :actual_vg_points in propertynames(match_rows)
                actual_val = Float64(match_rows[1, :actual_vg_points])
            end
        end
        push!(riders, (name=string(row.rider),
            q0=minimum(draws), q25=quantile(draws, 0.25), q50=quantile(draws, 0.5),
            q75=quantile(draws, 0.75), q100=maximum(draws), actual=actual_val))
    end
    isempty(riders) && return ""

    n = length(riders)
    # SVG dimensions
    name_space = 120
    w = 500
    h = max(200, n * 28 + 60)
    pad_t, pad_b = 30, 20
    plot_h = h - pad_t - pad_b
    plot_w = w - name_space - 20
    bar_h = min(18, plot_h / n - 4)

    y_max = max(maximum(r.q100 for r in riders),
                maximum(something(r.actual, 0.0) for r in riders)) * 1.05
    y_max = max(y_max, 1.0)

    val_to_x(v) = name_space + v / y_max * plot_w

    io = IOBuffer()
    write(io, "<svg width=\"$(w)\" height=\"$(h)\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family:sans-serif;\">")
    write(io, "<text x=\"$(w÷2)\" y=\"$(pad_t - 10)\" text-anchor=\"middle\" font-size=\"13\" fill=\"#333\">$(title)</text>")

    for (i, r) in enumerate(riders)
        cy = pad_t + (i - 0.5) * (plot_h / n)
        # Whisker line (min to max)
        write(io, "<line x1=\"$(round(val_to_x(r.q0),digits=1))\" y1=\"$(round(cy,digits=1))\" x2=\"$(round(val_to_x(r.q100),digits=1))\" y2=\"$(round(cy,digits=1))\" stroke=\"steelblue\" stroke-width=\"1\"/>")
        # IQR box
        bx = val_to_x(r.q25)
        bw = val_to_x(r.q75) - bx
        write(io, "<rect x=\"$(round(bx,digits=1))\" y=\"$(round(cy - bar_h/2,digits=1))\" width=\"$(round(max(bw,0.5),digits=1))\" height=\"$(round(bar_h,digits=1))\" fill=\"steelblue\" fill-opacity=\"0.3\" stroke=\"steelblue\" stroke-width=\"1\"/>")
        # Median line
        mx = val_to_x(r.q50)
        write(io, "<line x1=\"$(round(mx,digits=1))\" y1=\"$(round(cy - bar_h/2,digits=1))\" x2=\"$(round(mx,digits=1))\" y2=\"$(round(cy + bar_h/2,digits=1))\" stroke=\"steelblue\" stroke-width=\"2\"/>")
        # Actual result diamond
        if r.actual !== nothing
            ax = val_to_x(r.actual)
            d = 5
            write(io, "<polygon points=\"$(round(ax,digits=1)),$(round(cy-d,digits=1)) $(round(ax+d,digits=1)),$(round(cy,digits=1)) $(round(ax,digits=1)),$(round(cy+d,digits=1)) $(round(ax-d,digits=1)),$(round(cy,digits=1))\" fill=\"red\" stroke=\"darkred\" stroke-width=\"1\"/>")
        end
        # Rider name
        write(io, "<text x=\"$(name_space - 5)\" y=\"$(round(cy + 4,digits=1))\" text-anchor=\"end\" font-size=\"10\" fill=\"#333\">$(r.name)</text>")
    end

    # X-axis ticks
    n_ticks = 5
    for i in 0:n_ticks
        val = y_max * i / n_ticks
        x = val_to_x(val)
        write(io, "<text x=\"$(round(x,digits=1))\" y=\"$(h - pad_b + 14)\" text-anchor=\"middle\" font-size=\"10\" fill=\"#666\">$(Int(round(val)))</text>")
    end

    # Legend if actual results shown
    if actual_results !== nothing
        lx = name_space + 10
        ly = h - 4
        write(io, "<polygon points=\"$(lx),$(ly-5) $(lx+5),$(ly) $(lx),$(ly+5) $(lx-5),$(ly)\" fill=\"red\" stroke=\"darkred\" stroke-width=\"1\"/>")
        write(io, "<text x=\"$(lx + 10)\" y=\"$(ly + 4)\" font-size=\"10\" fill=\"#666\">Actual</text>")
    end

    write(io, "</svg>")
    return String(take!(io))
end
