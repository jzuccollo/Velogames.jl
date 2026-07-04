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

# ---------------------------------------------------------------------------
# Near-optimal team set: switcher + explicit filler pool + structural forks
# ---------------------------------------------------------------------------

"""Normalise a raw VG class string ("All Rounder") to a badge slug ("allrounder")."""
_class_slug(c) = lowercase(replace(string(c), " " => ""))

"""Serialise one near-optimal team to the dict shape the switcher JS consumes."""
function _team_switcher_dict(team::DataFrame, rank::Int)
    has_class = :classraw in propertynames(team)
    ordered = sort(team, :expected_vg_points, rev = true)
    riders = [
        Dict(
            "name" => string(r.rider),
            "team" => string(r.team),
            "class" => has_class ? string(r.classraw) : "",
            "cost" => r.cost,
            "evg" => round(Float64(r.expected_vg_points), digits = 1),
        ) for r in eachrow(ordered)
    ]
    return Dict(
        "rank" => rank,
        "evg" => round(sum(Float64.(team.expected_vg_points)), digits = 1),
        "cost" => sum(team.cost),
        "riders" => riders,
    )
end

"""HTML for the no-JS `<details>` fallback: a static table per near-optimal team."""
function _switcher_fallback(top_teams::Vector{DataFrame})
    io = IOBuffer()
    write(io, "<details><summary>All near-optimal teams (no-JavaScript view)</summary>\n")
    for (i, team) in enumerate(top_teams)
        evg = round(sum(Float64.(team.expected_vg_points)), digits = 1)
        write(io, "<p><strong>Team $i</strong> — cost $(sum(team.cost))/100, EVG $evg</p>\n")
        cols = intersect(
            [:rider, :team, :classraw, :cost, :expected_vg_points],
            propertynames(team),
        )
        write(io, html_table(sort(team[:, cols], :expected_vg_points, rev = true)))
    end
    write(io, "</details>\n")
    return String(take!(io))
end

"""
    format_near_optimal_section(top_teams, predicted, build_model_fn;
                                team_size, max_per_team, n_forks=5) -> String

Render the full "near-optimal team set" section: an interactive team switcher
(tabs repopulating one table, swing riders highlighted, EVG + %-gap-vs-best), the
explicit core/filler decomposition (`compute_filler_pool`), and the ranked
structural forks (`compute_structural_forks`). Degrades to a static `<details>`
list when JavaScript is disabled. `predicted` (the live frame, which carries the
class columns) and `build_model_fn` drive the fork re-solves.
"""
function format_near_optimal_section(
    top_teams::Vector{DataFrame},
    predicted::DataFrame,
    build_model_fn::Function;
    team_size::Integer,
    max_per_team::Integer,
    n_forks::Integer = 5,
)
    isempty(top_teams) && return ""
    n_teams = length(top_teams)
    evgs = [sum(Float64.(t.expected_vg_points)) for t in top_teams]
    best_evg = maximum(evgs)
    worst_gap =
        best_evg > 0 ? round(100 * (best_evg - minimum(evgs)) / best_evg, digits = 2) : 0.0

    io = IOBuffer()
    write(io, html_heading("Your optimal team and its near-equals", 2))

    # --- Intro callout ---
    intro =
        "<p>The single \"best\" team is the top of a cluster of near-identical rosters. " *
        "Below are the <strong>$(n_teams)</strong> best distinct teams; the worst shown is only " *
        "<strong>$(worst_gap)%</strong> below the best in expected VG points (EVG). They " *
        "share a fixed <em>core</em> and differ only in the interchangeable " *
        "<span style=\"background:#fff3cd;border-left:3px solid #ffc107;padding:0 .3em;\">swing</span> slots.</p>"
    write(io, html_callout(intro; title = "Why a switcher?", type = "note"))

    # --- Interactive switcher (JS) + no-JS fallback ---
    teams_json =
        JSON3.write([_team_switcher_dict(t, i) for (i, t) in enumerate(top_teams)])
    css = """<style>
#near-optimal .no-tabbar { display:flex; flex-wrap:wrap; gap:.4em; margin:1em 0; }
#near-optimal .no-tab { border:1px solid #ccc; background:#f7f7f7; border-radius:6px; padding:.35em .7em; cursor:pointer; font-size:.9em; font-family:inherit; }
#near-optimal .no-tab.active { background:#d4a843; color:#fff; border-color:#d4a843; font-weight:600; }
#near-optimal .no-tab .gap { opacity:.75; font-size:.85em; margin-left:.3em; }
#near-optimal .no-meta { margin:.4em 0 1em; }
#near-optimal tr.no-swing td { background:#fff3cd; }
#near-optimal tr.no-swing td:first-child { border-left:3px solid #ffc107; }
#near-optimal .no-badge { font-size:.7em; background:#ffc107; color:#5a4600; border-radius:4px; padding:.05em .4em; }
</style>"""
    switcher = """<div id="near-optimal">
$css
<div class="no-tabbar" id="no-tabbar"></div>
<p class="no-meta" id="no-meta"></p>
<div class="table-wrap"><table class="table table-striped table-sm">
<thead><tr><th>Rider</th><th>Team</th><th class="num">Cost</th><th class="num">EVG</th></tr></thead>
<tbody id="no-body"></tbody></table></div>
<noscript><p><em>Enable JavaScript to switch between teams interactively; the full list is below.</em></p></noscript>
$(_switcher_fallback(top_teams))
</div>
<script>
(function(){
  var TEAMS = $(teams_json);
  var nameSets = TEAMS.map(function(t){ return new Set(t.riders.map(function(r){return r.name;})); });
  var core = TEAMS.length ? TEAMS[0].riders.map(function(r){return r.name;})
      .filter(function(n){ return nameSets.every(function(s){ return s.has(n); }); }) : [];
  var coreSet = new Set(core);
  var best = TEAMS.length ? Math.max.apply(null, TEAMS.map(function(t){ return t.evg; })) : 0;
  var tabbar = document.getElementById("no-tabbar");
  var body = document.getElementById("no-body");
  var meta = document.getElementById("no-meta");
  function render(i){
    var t = TEAMS[i];
    Array.prototype.forEach.call(tabbar.children, function(b, j){ b.className = "no-tab" + (j===i ? " active" : ""); });
    var gapPct = ((best - t.evg) / best * 100).toFixed(2);
    meta.innerHTML = "<strong>Team " + t.rank + "</strong> \\u2014 cost " + t.cost + "/100 \\u00b7 EVG " + t.evg.toFixed(1) +
      (i === 0 ? " \\u00b7 <em>best</em>" : " \\u00b7 " + gapPct + "% below best");
    body.innerHTML = "";
    t.riders.forEach(function(r){
      var swing = !coreSet.has(r.name);
      var tr = document.createElement("tr");
      if (swing) tr.className = "no-swing";
      tr.innerHTML = "<td>" + r.name + (swing ? " <span class='no-badge'>swing</span>" : "") + "</td>" +
        "<td>" + r.team + "</td><td class='num'>" + r.cost + "</td><td class='num'>" + r.evg.toFixed(1) + "</td>";
      body.appendChild(tr);
    });
  }
  TEAMS.forEach(function(t, i){
    var b = document.createElement("button");
    b.className = "no-tab";
    var gapPct = ((best - t.evg) / best * 100).toFixed(2);
    b.innerHTML = "Team " + t.rank + (i === 0 ? "" : " <span class='gap'>-" + gapPct + "%</span>");
    b.onclick = function(){ render(i); };
    tabbar.appendChild(b);
  });
  if (TEAMS.length) render(0);
})();
</script>
"""
    write(io, switcher)

    # --- Explicit core + filler pool (Refinement A) ---
    core_df, filler_df, _ = compute_filler_pool(top_teams)
    write(io, html_heading("Locked core and the filler menu", 3))
    core_cost = nrow(core_df) > 0 ? sum(core_df.cost) : 0
    core_evg =
        nrow(core_df) > 0 ? round(sum(Float64.(core_df.expected_vg_points)), digits = 1) :
        0.0
    write(
        io,
        "<p><strong>$(nrow(core_df)) core riders</strong> appear in every near-optimal team " *
        "($(core_cost)/100 credits, $(core_evg) EVG) — treat these as locked. The remaining " *
        "$(100 - core_cost) credits buy the interchangeable filler slots below.</p>\n",
    )
    if nrow(core_df) > 0
        core_cols = intersect(
            [:rider, :team, :classraw, :cost, :expected_vg_points, :strength_gc],
            propertynames(core_df),
        )
        write(io, html_table(sort(core_df[:, core_cols], :expected_vg_points, rev = true)))
    end

    if nrow(filler_df) > 0
        has_class = :classraw in propertynames(filler_df)
        filler_display = DataFrame(
            Rider = string.(filler_df.rider),
            Team = string.(filler_df.team),
            Cost = filler_df.cost,
            EVG = round.(Float64.(filler_df.expected_vg_points), digits = 1),
            In = ["$(f)/$(n_teams)" for f in filler_df.frequency],
        )
        if has_class
            insertcols!(filler_display, 3, :Class => _class_slug.(filler_df.classraw))
        end
        write(
            io,
            html_callout(
                "<p>Riders appearing in <em>some but not all</em> near-optimal teams — the " *
                "menu competing for the open slots. <strong>In</strong> shows how many of the " *
                "$(n_teams) near-optimal teams each appears in; a higher count is a safer filler.</p>\n" *
                html_table(filler_display);
                title = "Filler pool (interchangeable slots)",
                type = "tip",
                collapsed = false,
            ),
        )
    else
        write(
            io,
            "<p><em>The near-optimal teams are identical — no interchangeable slots.</em></p>\n",
        )
    end

    # --- Structural forks (Refinement B) ---
    forks_result = compute_structural_forks(
        predicted,
        build_model_fn;
        team_size = team_size,
        max_per_team = max_per_team,
        n_forks = n_forks,
    )
    write(io, html_heading("Key decisions (structural forks)", 3))

    shape = forks_result.shape
    fork_lines = String[]
    if shape !== nothing
        verdict =
            shape.winner == :both ?
            "carrying <strong>both</strong> $(shape.leader1) and $(shape.leader2) wins" :
            "<strong>one leader plus depth</strong> wins (dropping one of $(shape.leader1)/$(shape.leader2))"
        push!(
            fork_lines,
            "<li><strong>Two GC leaders vs one:</strong> $verdict by " *
            "<strong>$(round(shape.delta, digits=1)) EVG</strong> " *
            "(both-leaders team $(round(shape.both_evg, digits=1)) vs " *
            "best at-most-one $(round(shape.atmost_evg, digits=1))).</li>",
        )
    end
    for f in forks_result.forks
        f.delta < 0.05 && continue
        incoming =
            isempty(f.comes_in) ? "no replacement (roster shrinks)" :
            join(
                [
                    "$(c.rider) ($(c.cost)cr, $(round(c.evg, digits=1)) EVG)" for
                    c in f.comes_in
                ],
                ", ",
            )
        push!(
            fork_lines,
            "<li><strong>Drop $(f.rider)</strong> ($(f.cost)cr): costs " *
            "<strong>$(round(f.delta, digits=1)) EVG</strong>. Frees $(f.cost) credits, which buy " *
            "$incoming — no combination matches their points-per-slot.</li>",
        )
    end
    if isempty(fork_lines)
        write(
            io,
            "<p><em>No high-impact either/or decisions — the optimal team is robust.</em></p>\n",
        )
    else
        write(
            io,
            html_callout(
                "<p>The roster decisions that move the most EVG, best first. Each shows the EVG " *
                "at stake and which riders swing in to fill the freed budget.</p>\n<ul>\n" *
                join(fork_lines, "\n") *
                "\n</ul>\n";
                title = "Highest-impact roster decisions",
                type = "note",
                collapsed = false,
            ),
        )
    end

    return String(take!(io))
end
