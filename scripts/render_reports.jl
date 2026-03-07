#!/usr/bin/env julia
"""
Render all race report pages for the Velogames retrospective site.

Usage:
    julia --project scripts/render_reports.jl [--years=2025,2026]

Scans the archive for completed races, generates a .qmd file per race
with hardcoded parameters, then you render with `cd site && quarto render`.
"""

using Velogames, DataFrames, Dates

# League winners by (pcs_slug, year). Add entries here after each race.
# Format: (pcs_slug, year) => (name = "Name", score = 1234)
const LEAGUE_WINNERS =
    Dict{Tuple{String,Int},NamedTuple{(:name, :score),Tuple{String,Int}}}(
        ("omloop-het-nieuwsblad", 2026) => (name = "Cobbles & Wobbles", score = 1027),
        ("kuurne-brussel-kuurne", 2026) => (name = "6 month write off", score = 488),
        ("trofeo-laigueglia", 2026) =>
            (name = "Supper Lino & Sausage Superstars!", score = 1126),
    )

function report_qmd(;
    pcs_slug,
    year,
    race_name,
    race_date,
    winner_name = "",
    winner_score = 0,
)
    return """
---
title: "$race_name $year"
subtitle: "Fantasy retrospective — $race_date"
format:
  html:
    code-fold: false
    toc: true
    include-in-header:
      text: '<script src="https://cdn.plot.ly/plotly-2.35.2.min.js"></script>'
---

```{julia}
#| echo: false
#| output: false

using Velogames, DataFrames, MarkdownTables, Printf, Statistics
using PlotlyBase

pcs_slug = "$pcs_slug"
race_year = $year
winner_name = "$winner_name"
winner_score = $winner_score

allriders = load_report_data(pcs_slug, race_year)
if allriders === nothing
    error("No archived results found for \$pcs_slug \$race_year")
end

# Compute optimal team
optimal_team = compute_optimal_team(allriders)
optimal_score = optimal_team !== nothing ? sum(optimal_team.score) : 0
optimal_cost = optimal_team !== nothing ? sum(optimal_team.cost) : 0

# Compute cheapest winning team if benchmark provided
cheapest_team = if winner_score > 0
    compute_cheapest_winning_team(allriders, winner_score)
else
    nothing
end

# Scoring riders and precomputed fields
scorers = filter(row -> row.score > 0, allriders)
sort!(scorers, :score, rev = true)
optimal_keys = optimal_team !== nothing ? Set(optimal_team.riderkey) : Set{String}()

# Precompute chart data on allriders (includes zero-scorers)
allriders[!, :in_optimal] = [k in optimal_keys for k in allriders.riderkey]
jitter = (rand(nrow(allriders)) .- 0.5) .* 0.3
```

```{julia}
#| echo: false
#| output: asis

if !isempty(winner_name) && winner_score > 0
    println("**\$(winner_name)** won our fantasy league with **\$(winner_score)** points. ",
        "But could they have done better? Read on to find out.")
end
```

## Race roundup

```{julia}
#| echo: false
#| output: asis

println("- **Riders who scored**: \$(nrow(scorers)) out of \$(nrow(allriders)) starters")
if nrow(scorers) > 0
    println("- **Top scorer**: \$(first(scorers).rider) with \$(first(scorers).score) points")
    best_val = first(sort(scorers, :value, rev=true))
    println("- **Best value**: \$(best_val.rider) at \$(best_val.value) pts/credit")
    println("- **Average value** (all starters): \$(round(mean(allriders.value), digits=1)) points per credit")
end
if optimal_team !== nothing
    println("- **Perfect team score**: \$(optimal_score) points for \$(optimal_cost) credits")
end
if !isempty(winner_name) && winner_score > 0
    println("- **League winner**: \$(winner_name) with \$(winner_score) points")
end
```

## The perfect team

With the benefit of hindsight, this is the highest-scoring team that fits within the budget.

```{julia}
#| echo: false
#| output: asis

if optimal_team !== nothing
    println("The perfect team scores **\$(optimal_score)** points, ",
        "costing **\$(optimal_cost)** out of 100 credits.")
    if winner_score > 0
        diff = optimal_score - winner_score
        println(" That's **\$(diff)** points more than our league winner.")
    end
else
    println("Optimisation failed — no feasible solution found.")
end
```

```{julia}
#| echo: false

if optimal_team !== nothing
    display_df = sort(optimal_team[:, [:rider, :team, :cost, :score, :value]], :score, rev = true)
    rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost,
        :score => :Points, :value => :Value)
    markdown_table(display_df)
end
```

```{julia}
#| echo: false
#| output: asis

if cheapest_team !== nothing && winner_score > 0
    cheapest_score = sum(cheapest_team.score)
    cheapest_cost = sum(cheapest_team.cost)

    println()
    println("## The cheapest winning team")
    println()
    println("What's the minimum investment that could have beaten **\$(winner_name)**? ",
        "This team scores **\$(cheapest_score)** points for just **\$(cheapest_cost)** credits, ",
        "leaving **\$(100 - cheapest_cost)** credits on the table.")
end
```

```{julia}
#| echo: false

if cheapest_team !== nothing && winner_score > 0
    display_df = sort(cheapest_team[:, [:rider, :team, :cost, :score, :value]], :score, rev = true)
    rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost,
        :score => :Points, :value => :Value)
    markdown_table(display_df)
end
```

## Performance analysis

### Points vs cost

How many points did each rider score relative to their cost? Hover over any point to see the rider details.

```{julia}
#| echo: false
#| output: asis

if nrow(allriders) > 0
    traces = GenericTrace[]

    # Zero-scorers as a distinct muted group
    zeroes_mask = allriders.score .== 0
    zeroes = allriders[zeroes_mask, :]
    if nrow(zeroes) > 0
        push!(traces, PlotlyBase.scatter(
            x = zeroes.cost .+ jitter[zeroes_mask],
            y = zeroes.score,
            mode = "markers",
            name = "Did not score",
            marker = attr(size = 5, opacity = 0.35, color = "#aaaaaa", symbol = "x"),
            text = ["\$(r.rider) (\$(r.team))<br>Cost: \$(r.cost), Points: 0" for r in eachrow(zeroes)],
            hoverinfo = "text",
        ))
    end

    for (label, is_opt) in [("Other riders", false), ("Optimal team", true)]
        mask = (allriders.score .> 0) .& (allriders.in_optimal .== is_opt)
        sub = allriders[mask, :]
        nrow(sub) == 0 && continue
        push!(traces, PlotlyBase.scatter(
            x = sub.cost .+ jitter[mask],
            y = sub.score,
            mode = "markers",
            name = label,
            marker = attr(size = is_opt ? 10 : 6, opacity = is_opt ? 0.9 : 0.5),
            text = ["\$(r.rider) (\$(r.team))<br>Cost: \$(r.cost), Points: \$(r.score), Value: \$(r.value)" for r in eachrow(sub)],
            hoverinfo = "text",
        ))
    end

    # Through-origin OLS fit line: β = Σ(cost * score) / Σ(cost²)
    costs_f = Float64.(allriders.cost)
    scores_f = Float64.(allriders.score)
    β = sum(costs_f .* scores_f) / sum(costs_f .^ 2)
    x_min, x_max = minimum(allriders.cost), maximum(allriders.cost)
    push!(traces, PlotlyBase.scatter(
        x = [x_min, x_max],
        y = [β * x_min, β * x_max],
        mode = "lines",
        name = "Average (\$(round(β, digits=1)) pts/credit)",
        line = attr(color = "#666666", dash = "dash", width = 1.5),
        hoverinfo = "skip",
    ))

    print(plotly_html(traces, Layout(
        xaxis_title = "Cost (credits)", yaxis_title = "Points scored",
        hovermode = "closest", template = "plotly_white",
    ); id = "plot-pts"))
end
```

### Top scorers

```{julia}
#| echo: false

top_n = min(15, nrow(scorers))
top = scorers[1:top_n, [:rider, :team, :cost, :score, :value]]
rename!(top, :rider => :Rider, :team => :Team, :cost => :Cost,
    :score => :Points, :value => :Value)
markdown_table(top)
```

### Value vs cost

Points per credit shows which riders delivered the best bang for their budget.

```{julia}
#| echo: false
#| output: asis

if nrow(allriders) > 0
    traces2 = GenericTrace[]

    # Zero-scorers
    zeroes_mask = allriders.score .== 0
    zeroes = allriders[zeroes_mask, :]
    if nrow(zeroes) > 0
        push!(traces2, PlotlyBase.scatter(
            x = zeroes.cost .+ jitter[zeroes_mask],
            y = zeroes.value,
            mode = "markers",
            name = "Did not score",
            marker = attr(size = 5, opacity = 0.35, color = "#aaaaaa", symbol = "x"),
            text = ["\$(r.rider) (\$(r.team))<br>Cost: \$(r.cost), Points: 0, Value: 0" for r in eachrow(zeroes)],
            hoverinfo = "text",
        ))
    end

    for (label, is_opt) in [("Other riders", false), ("Optimal team", true)]
        mask = (allriders.score .> 0) .& (allriders.in_optimal .== is_opt)
        sub = allriders[mask, :]
        nrow(sub) == 0 && continue
        push!(traces2, PlotlyBase.scatter(
            x = sub.cost .+ jitter[mask],
            y = sub.value,
            mode = "markers",
            name = label,
            marker = attr(size = is_opt ? 10 : 6, opacity = is_opt ? 0.9 : 0.5),
            text = ["\$(r.rider) (\$(r.team))<br>Cost: \$(r.cost), Points: \$(r.score), Value: \$(r.value)" for r in eachrow(sub)],
            hoverinfo = "text",
        ))
    end

    # Horizontal reference line: mean value across all starters (including zeros)
    avg_val = mean(allriders.value)
    x_min2, x_max2 = minimum(allriders.cost), maximum(allriders.cost)
    push!(traces2, PlotlyBase.scatter(
        x = [x_min2, x_max2],
        y = [avg_val, avg_val],
        mode = "lines",
        name = "Avg value (\$(round(avg_val, digits=1)) pts/credit)",
        line = attr(color = "#666666", dash = "dash", width = 1.5),
        hoverinfo = "skip",
    ))

    print(plotly_html(traces2, Layout(
        xaxis_title = "Cost (credits)", yaxis_title = "Value (points per credit)",
        hovermode = "closest", template = "plotly_white",
    ); id = "plot-val"))
end
```

### Best value riders

The top 10 riders by points per credit of cost.

```{julia}
#| echo: false

best_value = sort(scorers, :value, rev = true)
top_val = best_value[1:min(10, nrow(best_value)), [:rider, :team, :cost, :score, :value]]
rename!(top_val, :rider => :Rider, :team => :Team, :cost => :Cost,
    :score => :Points, :value => :Value)
markdown_table(top_val)
```

## Expensive disappointments

### Most expensive zeroes

The priciest riders who failed to score a single point.

```{julia}
#| echo: false

zeroes = filter(row -> row.cost >= 8 && row.score == 0, allriders)
if nrow(zeroes) > 0
    sort!(zeroes, :cost, rev = true)
    display_df = zeroes[1:min(5, nrow(zeroes)), [:rider, :team, :cost, :score]]
    rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost,
        :score => :Points)
    markdown_table(display_df)
end
```

### Worst value premium riders

The five lowest value riders who cost at least 8 credits.

```{julia}
#| echo: false

premium = filter(row -> row.cost >= 8 && row.score > 0, allriders)
if nrow(premium) > 0
    sort!(premium, :value)
    display_df = premium[1:min(5, nrow(premium)), [:rider, :team, :cost, :score, :value]]
    rename!(display_df, :rider => :Rider, :team => :Team, :cost => :Cost,
        :score => :Points, :value => :Value)
    markdown_table(display_df)
end
```

## Team analysis

Which teams provided the best value overall?

```{julia}
#| echo: false

team_stats = combine(
    groupby(allriders, :team),
    :score => sum => :total_points,
    :cost => sum => :total_cost,
    :score => (s -> count(>(0), s)) => :scorers,
    nrow => :riders,
)
team_stats[!, :avg_value] = round.(team_stats.total_points ./ max.(team_stats.total_cost, 1), digits = 1)
sort!(team_stats, :total_points, rev = true)
top_teams = team_stats[1:min(10, nrow(team_stats)), :]
rename!(top_teams, :team => :Team, :total_points => :Points, :total_cost => :Cost,
    :scorers => :Scorers, :riders => :Starters, :avg_value => :Value)
markdown_table(top_teams)
```
"""
end

function main()
    years = [2025, 2026]
    for arg in ARGS
        if startswith(arg, "--years=")
            years_str = replace(arg, "--years=" => "")
            years = parse.(Int, split(years_str, ","))
        end
    end

    races = list_completed_races(years)
    println("Found $(nrow(races)) completed races")

    site_dir = joinpath(@__DIR__, "..", "site")
    reports_dir = joinpath(site_dir, "reports")
    mkpath(reports_dir)

    # Clean old generated files
    for f in readdir(reports_dir)
        endswith(f, ".qmd") && rm(joinpath(reports_dir, f))
    end

    for row in eachrow(races)
        filename = "$(row.pcs_slug)-$(row.year).qmd"
        filepath = joinpath(reports_dir, filename)

        # Format the date nicely
        d = Date(row.date)
        race_date = Dates.format(d, "d U yyyy")

        winner = get(LEAGUE_WINNERS, (row.pcs_slug, row.year), nothing)
        write(
            filepath,
            report_qmd(;
                pcs_slug = row.pcs_slug,
                year = row.year,
                race_name = row.name,
                race_date = race_date,
                winner_name = winner !== nothing ? winner.name : "",
                winner_score = winner !== nothing ? winner.score : 0,
            ),
        )
        println("  Generated reports/$filename")
    end

    println("\nGenerated $(nrow(races)) reports in site/reports/")
    println("Now run:  cd site && quarto render")
end

main()
