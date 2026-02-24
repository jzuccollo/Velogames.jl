"""
Classification handling utilities for rider data.
"""

"""
    ensure_classification_columns!(df::DataFrame)

Ensures that the DataFrame has binary classification columns for each rider class
(allrounder, sprinter, climber, unclassed). Creates them from the :class or
:classraw column if they don't already exist.

Returns true if all columns exist or were successfully created, false otherwise.
"""
function ensure_classification_columns!(
    df::DataFrame;
    required_classes::Vector{String} = ["allrounder", "sprinter", "climber", "unclassed"],
)
    for class_name in required_classes
        col_name = Symbol(class_name)

        if string(col_name) in names(df)
            continue
        end

        if hasproperty(df, :class)
            df[!, col_name] =
                lowercase.(replace.(df.class, " " => "")) .== lowercase(class_name)
        elseif hasproperty(df, :classraw)
            df[!, col_name] =
                lowercase.(replace.(df.classraw, " " => "")) .== lowercase(class_name)
        else
            @warn "Cannot create classification column '$col_name' - no :class or :classraw column found"
            return false
        end
    end

    return true
end
