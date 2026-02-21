"""
`normalisename` takes a rider's name and returns a normalised version of it.

The normalisation process involves:
    * expanding ligatures (æ→ae, ø→oe, ð→d, þ→th, ß→ss)
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
`unpipe` takes a vector of strings and replaces all instances of `|` with `-`.
"""
function unpipe(str::String)
    return replace(str, "|" => "-")
end

"""
    add_pcs_speciality_points!(allriderdata, pcsriderpts, vg_class_to_pcs_col)

Integrates PCS speciality points into the `allriderdata` DataFrame.

This function reshapes the wide-format `pcsriderpts` data into a long format,
then performs a left join with `allriderdata` on both `riderkey` and `class`.
A new `pcs_points` column is added to `allriderdata`.

# Arguments
- `allriderdata`: DataFrame with rider data, must include `riderkey` and `class` columns.
- `pcsriderpts`: DataFrame with PCS points, must include `riderkey` and columns for each speciality.
- `vg_class_to_pcs_col`: Dictionary mapping Velogames class (e.g., "allrounder") to PCS point column names (e.g., "gc").
"""
function add_pcs_speciality_points!(
    allriderdata::DataFrame,
    pcsriderpts::DataFrame,
    vg_class_to_pcs_col::Dict,
)
    # Invert the mapping to go from PCS column to VG class
    pcs_col_to_vg_class = Dict(v => k for (k, v) in vg_class_to_pcs_col)

    # Filter pcsriderpts to only include columns that are in the mapping, plus riderkey
    pcs_cols_to_keep = push!(collect(keys(pcs_col_to_vg_class)), "riderkey")
    pcs_speciality_data = pcsriderpts[:, pcs_cols_to_keep]

    # Reshape the data from wide to long format
    pcs_long = stack(
        pcs_speciality_data,
        Not(:riderkey),
        variable_name = :pcs_col,
        value_name = :pcs_speciality_points,
    )

    # Map the PCS column names to Velogames class names
    pcs_long.class = [get(pcs_col_to_vg_class, col, "unknown") for col in pcs_long.pcs_col]
    select!(pcs_long, Not(:pcs_col)) # Remove the temporary pcs_col

    # Join with allriderdata
    leftjoin!(allriderdata, pcs_long, on = [:riderkey, :class])
end
