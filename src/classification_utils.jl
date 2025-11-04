"""
Classification handling utilities for rider data.

This module centralizes all classification-related logic to eliminate code duplication
across the various model building functions.
"""

"""
    ensure_classification_columns!(df::DataFrame; required_classes::Vector{String}=["allrounder", "sprinter", "climber", "unclassed"])

Ensures that the DataFrame has binary classification columns for each required class.

If the columns don't exist, attempts to create them from the :class or :classraw column.

# Arguments
- `df::DataFrame`: The DataFrame to modify
- `required_classes::Vector{String}`: List of required classification columns (default: ["allrounder", "sprinter", "climber", "unclassed"])

# Returns
- `Bool`: true if all required columns exist or were successfully created, false otherwise

# Examples
```julia
df = DataFrame(rider=["A", "B"], class=["allrounder", "sprinter"])
ensure_classification_columns!(df)
# df now has columns: :allrounder, :sprinter, :climber, :unclassed
```
"""
function ensure_classification_columns!(df::DataFrame; required_classes::Vector{String}=["allrounder", "sprinter", "climber", "unclassed"])
    for class_name in required_classes
        col_name = Symbol(class_name)

        # Skip if column already exists
        if string(col_name) in names(df)
            continue
        end

        # Try to create from :class column
        if hasproperty(df, :class)
            df[!, col_name] = lowercase.(replace.(df.class, " " => "")) .== lowercase(class_name)
        # Try to create from :classraw column
        elseif hasproperty(df, :classraw)
            # Handle both "All Rounder" and "allrounder" formats
            df[!, col_name] = lowercase.(replace.(df.classraw, " " => "")) .== lowercase(class_name)
        else
            @warn "Cannot create classification column '$col_name' - no :class or :classraw column found"
            return false
        end
    end

    return true
end


"""
    validate_classification_constraints(df::DataFrame; min_allrounder::Int=2, min_sprinter::Int=1, min_climber::Int=2, min_unclassed::Int=3)

Validates that there are enough riders in each classification to satisfy the constraints.

# Arguments
- `df::DataFrame`: DataFrame with classification columns
- `min_allrounder::Int`: Minimum number of all-rounders required (default: 2)
- `min_sprinter::Int`: Minimum number of sprinters required (default: 1)
- `min_climber::Int`: Minimum number of climbers required (default: 2)
- `min_unclassed::Int`: Minimum number of unclassed riders required (default: 3)

# Returns
- `Bool`: true if all constraints can be satisfied, false otherwise

# Examples
```julia
df = DataFrame(
    allrounder=[true, true, false],
    sprinter=[false, false, true],
    climber=[false, true, true],
    unclassed=[true, true, true]
)
validate_classification_constraints(df)  # returns true
```
"""
function validate_classification_constraints(df::DataFrame;
                                            min_allrounder::Int=2,
                                            min_sprinter::Int=1,
                                            min_climber::Int=2,
                                            min_unclassed::Int=3)::Bool
    # Check each required column exists
    required_cols = [:allrounder, :sprinter, :climber, :unclassed]
    for col in required_cols
        if !hasproperty(df, col)
            @warn "Missing classification column: $col"
            return false
        end
    end

    # Count riders in each class
    checks = [
        (sum(df.allrounder) >= min_allrounder, "all-rounders", sum(df.allrounder), min_allrounder),
        (sum(df.sprinter) >= min_sprinter, "sprinters", sum(df.sprinter), min_sprinter),
        (sum(df.climber) >= min_climber, "climbers", sum(df.climber), min_climber),
        (sum(df.unclassed) >= min_unclassed, "unclassed", sum(df.unclassed), min_unclassed)
    ]

    all_satisfied = true
    for (satisfied, class_name, actual, required) in checks
        if !satisfied
            @warn "Insufficient $class_name: found $actual, need at least $required"
            all_satisfied = false
        end
    end

    return all_satisfied
end
