"""Sentinel position for riders who did not finish (DNF/DNS/DSQ/OTL)."""
const DNF_POSITION = 999

"""Sentinel position/rank for unranked riders."""
const UNRANKED_POSITION = 9999


"""
`normalisename` takes a rider's name and returns a normalised version of it.

The normalisation process involves:
    * expanding ligatures (æ→ae, ø→oe, ð→d, þ→th, ß→ss)
    * replacing apostrophes/quotes with word separators
    * removing accents/diacritics
    * removing case
    * replacing spaces with hyphens (or removing them for keys)
"""
function normalisename(ridername::String, iskey::Bool = false)
    spacechar = iskey ? "" : "-"
    # Expand common ligatures that Unicode.normalize(stripmark=true) doesn't handle.
    # These are single codepoints (not base + combining mark), so stripmark leaves them.
    expanded = replace(
        ridername,
        "æ" => "ae",
        "Æ" => "Ae",
        "ø" => "oe",
        "Ø" => "Oe",
        "ð" => "d",
        "Ð" => "D",
        "þ" => "th",
        "Þ" => "Th",
        "ß" => "ss",
        "đ" => "d",
        "Đ" => "D",
        "ł" => "l",
        "Ł" => "L",
    )
    # Replace apostrophes/quotes with spaces — PCS treats them as word separators
    # (e.g. "Ben O'Connor" → "ben-o-connor", not "ben-oconnor")
    # Covers ASCII ' (U+0027), modifier ʼ (U+02BC), grave ` (U+0060),
    # and smart quotes ' (U+2018) and ' (U+2019)
    expanded = replace(expanded, r"['ʼ`''\u2018\u2019]" => " ")
    newname = replace(
        Unicode.normalize(expanded, stripmark = true, stripcc = true, casefold = true),
        " " => spacechar,
    )
    return newname
end

"""
`createkey` creates a unique key for each rider based on their name.
"""
function createkey(ridername::String)
    newkey = join(sort(collect(normalisename(ridername, true))))
    return newkey
end

"""
    rematch_riderkeys!(external_df, reference_df)

For riders in `external_df` whose `riderkey` doesn't match any in `reference_df`,
try the punctuation-stripped key first, then fall back to surname-only matching.
Either way the match must be unique to be applied. Handles common name
variations like "Tom Pidcock" (Oddschecker) vs "Thomas Pidcock" (VG), and
compound surnames hyphenated in one source and spaced in the other
("Ferrand-Prévot" vs "Ferrand Prevot").
"""
function rematch_riderkeys!(external_df::DataFrame, reference_df::DataFrame)
    # Materialise riderkey column so Arrow/Feather read-only backing doesn't block mutation
    if !(external_df.riderkey isa Vector)
        external_df.riderkey = Vector{String}(external_df.riderkey)
    end
    ref_keys = Set(reference_df.riderkey)
    # Compound surnames get hyphenated in one source and spaced in the other
    # ("Ferrand-Prévot" on VG, "Ferrand Prevot" from the bookmaker). That shifts
    # both the riderkey (which keeps the hyphen) and the whitespace-split
    # surname ("prevot" vs "ferrandprevot"), so surname matching alone misses
    # them. Try the punctuation-stripped key first. `normalisename` already
    # eats apostrophes, so hyphens and stops are what survive into a key.
    #
    # Stripping these in `createkey` instead would be the cleaner layer, but the
    # permanent archives hold ~112 hyphenated riderkeys that readers join against
    # freshly computed ones, and prediction archives cannot be re-created — so
    # the fix has to live at match time.
    depunct(k) = replace(k, r"[-.]" => "")
    ref_depunct = Dict{String,Vector{String}}()
    ref_surname = Dict{String,Vector{String}}()
    for row in eachrow(reference_df)
        push!(get!(ref_depunct, depunct(row.riderkey), String[]), row.riderkey)
        parts = split(strip(row.rider))
        isempty(parts) && continue
        surname = normalisename(String(last(parts)), true)
        push!(get!(ref_surname, surname, String[]), row.riderkey)
    end

    n_fixed = 0
    for row in eachrow(external_df)
        row.riderkey in ref_keys && continue
        candidates = get(ref_depunct, depunct(row.riderkey), String[])
        if length(candidates) != 1
            parts = split(strip(row.rider))
            isempty(parts) && continue
            surname = normalisename(String(last(parts)), true)
            candidates = get(ref_surname, surname, String[])
        end
        if length(candidates) == 1
            row.riderkey = candidates[1]
            n_fixed += 1
        end
    end
    n_fixed > 0 && @info "Re-matched $n_fixed riders by punctuation-stripped key or surname"
    return external_df
end

"""
`unpipe` takes a vector of strings and replaces all instances of `|` with `-`.
"""
function unpipe(str::String)
    return replace(str, "|" => "-")
end

# ---------------------------------------------------------------------------
# Report/display utilities
# ---------------------------------------------------------------------------

"""
    suppress_output(f)

Suppress stdout and info-level logging while executing `f()`.
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
            rounded = round.(df[!, col]; digits = digits)
            # Integer-valued columns render without a trailing ".0".
            if all(x -> ismissing(x) || x == round(x), rounded)
                df[!, col] = [ismissing(x) ? missing : Int(round(x)) for x in rounded]
            else
                df[!, col] = rounded
            end
        end
    end
    return df
end
