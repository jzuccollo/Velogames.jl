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
try surname-only matching. If the normalised surname is unique in both datasets,
update the external rider's key to match. Handles common name variations like
"Tom Pidcock" (Oddschecker) vs "Thomas Pidcock" (VG).
"""
function rematch_riderkeys!(external_df::DataFrame, reference_df::DataFrame)
    # Materialise riderkey column so Arrow/Feather read-only backing doesn't block mutation
    if !(external_df.riderkey isa Vector)
        external_df.riderkey = Vector{String}(external_df.riderkey)
    end
    ref_keys = Set(reference_df.riderkey)
    # Build surname → riderkey lookup for reference riders (only unique surnames)
    ref_surname = Dict{String,Vector{String}}()
    for row in eachrow(reference_df)
        parts = split(strip(row.rider))
        isempty(parts) && continue
        surname = normalisename(String(last(parts)), true)
        keys = get!(ref_surname, surname, String[])
        push!(keys, row.riderkey)
    end

    n_fixed = 0
    for row in eachrow(external_df)
        row.riderkey in ref_keys && continue
        parts = split(strip(row.rider))
        isempty(parts) && continue
        surname = normalisename(String(last(parts)), true)
        candidates = get(ref_surname, surname, String[])
        if length(candidates) == 1
            row.riderkey = candidates[1]
            n_fixed += 1
        end
    end
    n_fixed > 0 && @info "Re-matched $n_fixed riders by surname"
    return external_df
end

"""
`unpipe` takes a vector of strings and replaces all instances of `|` with `-`.
"""
function unpipe(str::String)
    return replace(str, "|" => "-")
end
