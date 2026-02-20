const DEFAULT_CLASS_REQUIREMENTS =
    Dict("All rounder" => 2, "Climber" => 2, "Sprinter" => 1, "Unclassed" => 4)

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
    format_display_table(df; columns, rename_map, round_to_int, round_digits, team_columns, sort_by)

Return a DataFrame tailored for report display. The function selects `columns`,
optionally rounds numeric fields, cleans team names, renames columns, and
applies an optional sort.

# Keyword Arguments
- `columns::Vector{Symbol}`: Columns to keep in the resulting DataFrame.
- `rename_map::Dict{Symbol,Symbol}`: Optional mapping of old column names to new names.
- `round_to_int::Vector{Symbol}`: Columns to round to integers.
- `round_digits::Dict{Symbol,Int}`: Columns to round to a given number of digits.
- `team_columns::Vector{Symbol}`: Columns whose values should have `|` replaced with `-`.
- `sort_by::Union{Nothing,Tuple{Symbol,Bool}}`: Optional tuple `(column, rev)` controlling sort order.
"""
function format_display_table(
    df::DataFrame;
    columns::Vector{Symbol},
    rename_map::Dict{Symbol,Symbol} = Dict{Symbol,Symbol}(),
    round_to_int::Vector{Symbol} = Symbol[],
    round_digits::Dict{Symbol,Int} = Dict{Symbol,Int}(),
    team_columns::Vector{Symbol} = Symbol[:team],
    sort_by::Union{Nothing,Tuple{Symbol,Bool}} = nothing,
)
    table = select(df, columns)

    for col in round_to_int
        if col in propertynames(table)
            table[!, col] = round.(Int, table[!, col])
        end
    end

    for (col, digits) in round_digits
        if col in propertynames(table)
            table[!, col] = round.(table[!, col]; digits = digits)
        end
    end

    clean_team_names!(table, team_columns)

    if !isempty(rename_map)
        rename!(table, rename_map)
    end

    if sort_by !== nothing
        column, rev = sort_by
        if column in propertynames(table)
            table = sort(table, column; rev = rev)
        end
    end

    return table
end

"""
    class_availability_summary(df; requirements, class_col, cost_col)

Summarise the availability of rider classes against required counts and compute
the minimum cost of assembling a valid squad if feasible.

# Keyword Arguments
- `requirements::Dict{String,Int}`: Required rider counts per class.
- `class_col::Symbol`: Column containing class labels.
- `cost_col::Symbol`: Column containing rider costs.

# Returns
A named tuple with keys `requirements`, `counts`, `cheapest`, `feasible`, and
`minimum_cost`.
"""
function class_availability_summary(
    df::DataFrame;
    requirements::Dict{String,Int} = DEFAULT_CLASS_REQUIREMENTS,
    class_col::Symbol = :class,
    cost_col::Symbol = :cost,
)
    counts = Dict{String,Int}()
    cheapest = Dict{String,Vector{Float64}}()
    feasible = true

    for (class, needed) in requirements
        matches = subset(df, class_col => ByRow(x -> x == class))
        counts[class] = nrow(matches)

        if needed <= 0
            cheapest[class] = Float64[]
            continue
        end

        if nrow(matches) < needed
            feasible = false
            cheapest[class] = Float64[]
            continue
        end

        costs = collect(skipmissing(matches[!, cost_col]))
        if length(costs) < needed
            feasible = false
            cheapest[class] = Float64[]
            continue
        end

        sorted_costs = sort(costs)[1:needed]
        cheapest[class] = Float64[sorted_costs...]
    end

    minimum_cost = feasible ? sum(sum(values) for values in values(cheapest)) : missing

    return (
        requirements = requirements,
        counts = counts,
        cheapest = cheapest,
        feasible = feasible,
        minimum_cost = minimum_cost,
    )
end

"""
    describe_class_availability(summary)

Create human-readable lines describing class availability based on the output
of `class_availability_summary`.
"""
function describe_class_availability(summary)
    lines = String[]
    for (class, needed) in summary.requirements
        count = summary.counts[class]
        push!(lines, "- $(class): $(count) riders (need $(needed))")
        cheapest = summary.cheapest[class]
        if !isempty(cheapest)
            push!(lines, "  Cheapest $(needed): $(join(round.(cheapest; digits=1), ", "))")
        end
    end

    if summary.feasible && summary.minimum_cost !== missing
        push!(
            lines,
            "Minimum cost for a valid roster: $(round(summary.minimum_cost; digits=1)) credits",
        )
    else
        push!(lines, "❌ Insufficient riders in one or more classes")
    end

    return lines
end
