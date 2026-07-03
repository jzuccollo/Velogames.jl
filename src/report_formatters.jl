# report_formatters.jl — signal/classification/podium table formatters,
# the precision budget, and per-dimension signal-impact helpers.

const _CLASS_LABELS = Dict(
    "allrounder" => "All-rounder",
    "climber" => "Climber",
    "sprinter" => "Sprinter",
    "unclassed" => "Unclassed",
)
_class_label(slug::AbstractString) = get(_CLASS_LABELS, slug, uppercasefirst(slug))

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
            name,
            var,
            is_market,
            name in hist_names ? n_history_years / var : 1.0 / var,
            # With market discount: market signals unchanged, others inflated
            is_market ? (name in hist_names ? n_history_years / var : 1.0 / var) :
            (name in hist_names ? n_history_years / (var * md) : 1.0 / (var * md)),
        ) for (name, var, is_market) in signals
    ]
    total = sum(p for (_, _, _, p, _) in precisions)
    total_md = sum(p for (_, _, _, _, p) in precisions)

    DataFrame(
        signal = [name for (name, _, _, _, _) in precisions],
        variance = [round(var, digits = 3) for (_, var, _, _, _) in precisions],
        precision = [round(p, digits = 3) for (_, _, _, p, _) in precisions],
        share = [
            string(round(Int, 100 * p / total), "%") for (_, _, _, p, _) in precisions
        ],
        precision_with_market = [round(p, digits = 3) for (_, _, _, _, p) in precisions],
        share_with_market = [
            string(round(Int, 100 * p / total_md), "%") for (_, _, _, _, p) in precisions
        ],
    )
end

# One-day production display: only the signals active after the April 2026
# ablation (PCS form, VG race history and qualitative are disabled, so their
# always-zero columns are omitted). The backtesting report renders the full set,
# where those signals still vary.
const _SIGNAL_NAMES = ["PCS", "VG", "Hist", "Oracle", "Odds"]
# Parallel info-share columns. Order-invariant precision-share metric:
# `signal_precision / total_observed_precision`, computed in
# `_estimate_strengths_multidim` / scalar `estimate_strengths`. Replaces the
# L2-norm shift display in `format_signal_waterfall` so the magnitude
# comparison across signals is fair (PCS routes to all 5 dims; odds routes
# mostly to gc — L2 norm structurally inflates PCS).
const _INFO_SHARE_COLS = [
    :info_share_pcs,
    :info_share_vg,
    :info_share_history,
    :info_share_oracle,
    :info_share_odds,
]

# Stage-race (multidim) path splits several signals into per-market sub-channels
# (GC / points / KOM / stage-win odds & oracle, points/KOM history). The scalar
# 8-column view above collapses ORACLE→oracle_gc and ODDS→odds (GC) only, so its
# rows do NOT sum to 100% — the hidden sub-channels silently pad the denominator.
# When these columns are present, render the full set so the breakdown is
# genuine and sums to 100%.
const _SIGNAL_NAMES_STAGE = [
    "PCS",
    "VG",
    "Form",
    "Hist",
    "VG hist",
    "Pts hist",
    "KOM hist",
    "Oracle GC",
    "Oracle Pts",
    "Oracle KOM",
    "Odds GC",
    "Odds Pts",
    "Odds KOM",
    "Odds Stage",
    "Qual",
]
const _INFO_SHARE_COLS_STAGE = [
    :info_share_pcs,
    :info_share_vg,
    :info_share_form,
    :info_share_history,
    :info_share_vg_history,
    :info_share_points_history,
    :info_share_kom_history,
    :info_share_oracle_gc,
    :info_share_oracle_points,
    :info_share_oracle_kom,
    :info_share_odds,
    :info_share_odds_points,
    :info_share_odds_kom,
    :info_share_odds_stagewin,
    :info_share_qualitative,
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
    _info_share_cell_style(value)

Inline CSS for an info-share cell. Sequential green scale: deeper green =
higher share. `value` is in [0, 1].
"""
function _info_share_cell_style(value::Float64)
    if value <= 0.0
        return "text-align:right; color:#999"
    end
    intensity = clamp(value, 0.0, 1.0)
    alpha = round(intensity * 0.6, digits = 2)  # cap at 0.6 for readability
    return "text-align:right; background:rgba(34,139,34,$alpha)"
end

"""
    format_signal_waterfall(df; max_riders=10)

Generate an HTML table showing per-rider info-share contributions of each
signal to the rider's posterior. Info share is order-invariant precision
share (signal precision / total observed precision). Sequential green
heatmap; flags single-signal dominance > 60%.
"""
function format_signal_waterfall(df::DataFrame; max_riders::Int = 10)
    subset = df[1:min(max_riders, nrow(df)), :]

    # Stage-race path exposes per-market sub-channels; render the full set so the
    # shares genuinely sum to 100%. One-day path falls back to the 8-column view.
    is_stage = :info_share_odds_kom in propertynames(df)
    signal_names = is_stage ? _SIGNAL_NAMES_STAGE : _SIGNAL_NAMES
    info_share_cols = is_stage ? _INFO_SHARE_COLS_STAGE : _INFO_SHARE_COLS

    lines = String[]
    push!(lines, "<div class=\"table-wrap\">")
    push!(
        lines,
        "<table style='border-collapse:collapse; font-size:0.85em; min-width:100%; width:max-content'>",
    )
    push!(lines, "<thead><tr style='border-bottom:2px solid #666'>")
    push!(lines, "<th style='text-align:left; padding:4px'>Rider</th>")
    push!(lines, "<th style='text-align:right; padding:4px'>Cost</th>")
    for name in signal_names
        push!(lines, "<th style='text-align:right; padding:4px'>$name</th>")
    end
    push!(lines, "<th style='text-align:right; padding:4px'>Str</th>")
    push!(lines, "<th style='text-align:right; padding:4px'>Unc</th>")
    push!(lines, "<th style='text-align:left; padding:4px'>Flag</th>")
    push!(lines, "</tr></thead><tbody>")

    for row in eachrow(subset)
        shares = [Float64(row[c]) for c in info_share_cols]
        n_active = count(>(0.001), shares)

        dominant_name, dominant_pct = if any(>(0.0), shares)
            idx = argmax(shares)
            signal_names[idx], round(Int, 100 * shares[idx])
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

        for share in shares
            style = _info_share_cell_style(share)
            display_val = share <= 0.0 ? "·" : string(round(Int, 100 * share), "%")
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
    push!(lines, "</div>")
    return join(lines, "\n")
end

"""
    format_classification_table(diagnostics, classification, riders;
                                top_label=10, n_show=10) -> String

Render a top-N classification probability table for one of the rider-level
classifications produced by `simulate_stage_race` (`:gc`, `:points`,
`:mountains`). Returns the HTML table as a String, or a fallback `<p>` when
no rider has non-trivial probability mass.

Sorting: `:gc` sorts by P(win) descending (then top-`top_label`), because a GC
contender's top-N rate collapses onto their finish rate and would otherwise rank
by DNF hazard rather than GC quality. `:points`/`:mountains` sort by P(finishes
top-`top_label`) descending with P(win) breaking ties.
"""
function format_classification_table(
    diagnostics,
    classification::Symbol,
    riders::DataFrame;
    top_label::Int = 10,
    n_show::Int = 10,
)
    pos_counts = if classification == :gc
        diagnostics.final_gc_position_counts
    elseif classification == :points
        diagnostics.final_points_position_counts
    elseif classification == :mountains
        diagnostics.final_mountains_position_counts
    else
        error("Unknown classification $classification (expected :gc, :points, or :mountains)")
    end

    rider_names = String.(riders.rider)
    rider_teams = String.(riders.team)
    n_sims = diagnostics.n_sims
    top_k = size(pos_counts, 2)

    # No scoring depth for this classification (VG published no table, or the
    # scrape didn't match its heading) — nothing to rank.
    top_k == 0 && return "<p>No $classification classification scoring available.</p>\n"

    any_pos = vec(sum(pos_counts[:, 1:min(top_label, top_k)], dims = 2)) ./ n_sims
    win = pos_counts[:, 1] ./ n_sims
    # GC: sort by P(win) first, then top-N. For a genuine contender, top-N ≈ their
    # finish rate (they place top-N whenever they don't abandon), so sorting GC by
    # top-N would rank by DNF hazard rather than GC quality and push the actual
    # favourites below younger low-attrition riders. Win% is the true GC signal.
    # Points/mountains stay top-N-first (consistency is what those reward).
    order =
        classification == :gc ? sortperm(collect(zip(win, any_pos)); rev = true) :
        sortperm(collect(zip(any_pos, win)); rev = true)

    rows = Dict{String,Any}[]
    for rank = 1:min(n_show, length(order))
        i = order[rank]
        any_pos[i] < 0.005 && break
        push!(
            rows,
            Dict{String,Any}(
                "Rank" => rank,
                "Rider" => rider_names[i],
                "Team" => rider_teams[i],
                "Win %" => round(100 * win[i], digits = 1),
                "Top-$top_label %" => round(100 * any_pos[i], digits = 1),
            ),
        )
    end
    isempty(rows) &&
        return "<p>No riders with non-trivial top-$top_label probability.</p>\n"
    df = DataFrame(rows)
    return html_table(df[:, ["Rank", "Rider", "Team", "Win %", "Top-$top_label %"]])
end

"""
    format_team_classification(diagnostics; n_show=10) -> String

Render a top-N team-classification probability table. The number of prize
positions varies by VG game (e.g. 5 in `SCORING_GRAND_TOUR`), so the column
name is derived dynamically (`Top-5 %`, `Top-3 %`, etc.).
"""
function format_team_classification(diagnostics; n_show::Int = 10)
    isempty(diagnostics.final_team_position_counts) &&
        return "<p>No team predictions available.</p>\n"

    n_sims = diagnostics.n_sims
    rows = Dict{String,Any}[]
    top_k = 0
    for (team, pos_counts) in diagnostics.final_team_position_counts
        top_k = length(pos_counts)
        push!(
            rows,
            Dict{String,Any}(
                "Team" => team,
                "Win %" => round(100 * pos_counts[1] / n_sims, digits = 1),
                "Top-$top_k %" => round(100 * sum(pos_counts) / n_sims, digits = 1),
            ),
        )
    end
    df = DataFrame(rows)
    top_col = "Top-$top_k %"
    sort!(df, top_col, rev = true)
    df = first(df, min(n_show, nrow(df)))
    df.Rank = 1:nrow(df)
    return html_table(df[:, ["Rank", "Team", "Win %", top_col]])
end

"""
    format_stage_podium_picks(diagnostics, stages, riders) -> DataFrame

Build the per-stage details table including the most-likely podium finishers
(1st, 2nd, 3rd) for each stage. Each rider entry is rendered as
`"<Name> (xx%)"` where the percentage is the share of simulations in which
that rider finished in that exact position. Probabilities below 0.5% are
suppressed (empty cell).

Caller is expected to render via `html_table` with the desired column order.
"""
function format_stage_podium_picks(
    diagnostics,
    stages::Vector{StageProfile},
    riders::DataFrame,
)
    rider_names = String.(riders.rider)
    n_sims = diagnostics.n_sims

    # Pick the modal occupant of each podium position, but exclude riders
    # already shown in a higher column so the three cells name distinct riders
    # (a dominant favourite is otherwise the modal occupant of 1st, 2nd AND 3rd,
    # which just repeats one name). The percentage is still P(rider finishes in
    # exactly that position).
    function _picks(stage_idx::Int)
        used = Int[]
        out = String[]
        for rank = 1:3
            counts = copy(diagnostics.stage_finish_counts[stage_idx, :, rank])
            for u in used
                counts[u] = -1
            end
            i = argmax(counts)
            prob = counts[i] / n_sims
            if counts[i] <= 0 || prob < 0.005
                push!(out, "")
            else
                push!(used, i)
                push!(out, "$(rider_names[i]) ($(round(Int, 100 * prob))%)")
            end
        end
        return out
    end

    rows = Dict{String,Any}[]
    for (idx, s) in enumerate(stages)
        picks = _picks(idx)
        push!(
            rows,
            Dict{String,Any}(
                "Stage" => s.stage_number,
                "Type" => String(s.stage_type),
                "Distance" => "$(round(s.distance_km, digits=0)) km",
                "ProfileScore" => s.profile_score,
                "Vert" => "$(s.vertical_meters) m",
                "Summit" => s.is_summit_finish ? "Yes" : "",
                "HC" => s.n_hc_climbs > 0 ? string(s.n_hc_climbs) : "",
                "Cat1" => s.n_cat1_climbs > 0 ? string(s.n_cat1_climbs) : "",
                "Likely 1st" => picks[1],
                "Likely 2nd" => picks[2],
                "Likely 3rd" => picks[3],
            ),
        )
    end
    return DataFrame(rows)
end

"""
    format_signal_impact_per_dim(predicted; signal_specs, dim_labels, dim_syms) -> String

Render a per-dimension RMS-shift table summarising how much each signal
moved the posterior on each strength dimension. `signal_specs` is a vector
of `(human_label, signal_key)` tuples where `signal_key` matches the
`shift_<key>_<dim>` column convention produced by the multidim estimator.
Returns the HTML table.
"""
function format_signal_impact_per_dim(
    predicted::DataFrame;
    signal_specs::Vector{Tuple{String,Symbol}} = [
        ("PCS specialty", :pcs),
        ("VG season points", :vg),
        ("PCS race history", :history),
        ("VG race history", :vg_history),
        ("Points-class history", :points_history),
        ("KOM-class history", :kom_history),
        ("Oracle GC", :oracle_gc),
        ("Oracle Points", :oracle_points),
        ("Oracle KOM", :oracle_kom),
        ("Odds GC", :odds),
        ("Odds Points", :odds_points),
        ("Odds KOM", :odds_kom),
        ("Odds stage-win", :odds_stagewin),
    ],
    dim_labels::Vector{String} = ["Flat", "Hilly", "Mountain", "ITT", "GC", "KOM"],
    dim_syms::Vector{Symbol} = [:flat, :hilly, :mountain, :itt, :gc, :kom],
)
    rms(v) = sqrt(mean(v .^ 2))
    rows = Dict{String,Any}[]
    for (label, sig) in signal_specs
        row = Dict{String,Any}("Signal" => label)
        for (lab, dsym) in zip(dim_labels, dim_syms)
            col = Symbol("shift_$(sig)_$(dsym)")
            row[lab] =
                col in propertynames(predicted) ?
                round(rms(predicted[!, col]), digits = 3) : 0.0
        end
        push!(rows, row)
    end
    df = DataFrame(rows)
    return html_table(df[:, ["Signal", dim_labels...]])
end

"""
    format_info_share_per_dim(chosen_team_df; signal_specs, dim_labels, dim_syms) -> String

Render a per-rider × per-(signal, dim) info-share heatmap for the chosen team.
Each cell is `info_share_<signal>_<dim>` — the share of total observed
precision on that dimension contributed by that signal. Order-invariant
(unlike per-signal mean shifts) and direction-aware (unlike L2 norms).

Layout: one row per chosen rider; columns are (signal × dim) cells grouped
by signal with sub-headers for each dim.
"""
function format_info_share_per_dim(
    chosen_team_df::DataFrame;
    signal_specs::Vector{Tuple{String,Symbol}} = [
        ("PCS", :pcs),
        ("VG", :vg),
        ("Hist", :history),
        ("Oracle GC", :oracle_gc),
        ("Oracle Pts", :oracle_points),
        ("Oracle KOM", :oracle_kom),
        ("Odds GC", :odds),
        ("Odds Pts", :odds_points),
        ("Odds KOM", :odds_kom),
        ("Odds Stage", :odds_stagewin),
    ],
    dim_labels::Vector{String} = ["F", "H", "M", "I", "G", "K"],
    dim_syms::Vector{Symbol} = [:flat, :hilly, :mountain, :itt, :gc, :kom],
)
    lines = String[]
    push!(lines, "<div class=\"table-wrap\">")
    push!(
        lines,
        "<table style='border-collapse:collapse; font-size:0.78em; min-width:100%; width:max-content'>",
    )
    # Two-row header: signal labels (spanning per-dim columns) + dim sub-labels
    push!(lines, "<thead>")
    push!(lines, "<tr style='border-bottom:1px solid #999'>")
    push!(lines, "<th rowspan='2' style='text-align:left; padding:4px'>Rider</th>")
    for (label, _) in signal_specs
        push!(
            lines,
            "<th colspan='$(length(dim_syms))' style='text-align:center; padding:4px; border-left:1px solid #ddd'>$label</th>",
        )
    end
    push!(lines, "</tr>")
    push!(lines, "<tr style='border-bottom:2px solid #666'>")
    for _ in signal_specs, (j, lab) in enumerate(dim_labels)
        border = j == 1 ? "border-left:1px solid #ddd;" : ""
        push!(
            lines,
            "<th style='text-align:right; padding:2px 4px; $border font-size:0.85em; color:#666'>$lab</th>",
        )
    end
    push!(lines, "</tr></thead><tbody>")

    for row in eachrow(chosen_team_df)
        push!(lines, "<tr style='border-bottom:1px solid #ddd'>")
        push!(
            lines,
            "<td style='padding:4px; white-space:nowrap'><strong>$(row.rider)</strong></td>",
        )
        for (_, sig) in signal_specs, (j, dsym) in enumerate(dim_syms)
            col = Symbol("info_share_$(sig)_$(dsym)")
            v = col in propertynames(chosen_team_df) ? Float64(row[col]) : 0.0
            border = j == 1 ? "border-left:1px solid #ddd;" : ""
            style = _info_share_cell_style(v) * "; $border"
            display_val = v <= 0.0 ? "·" : string(round(Int, 100 * v))
            push!(lines, "<td style='$style padding:2px 4px'>$display_val</td>")
        end
        push!(lines, "</tr>")
    end

    push!(lines, "</tbody></table>")
    push!(lines, "</div>")
    return join(lines, "\n")
end
