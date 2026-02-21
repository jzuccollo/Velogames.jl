"""
PCS (ProCyclingStats) scraping infrastructure.

Provides alias-based column resolution so that when PCS renames a column
(e.g. `Rider` → `h2hRider`), you add one string to the relevant alias
constant and everything works again.

This is deliberately separate from the VG scraping in get_data.jl —
the two sites have different table structures and shouldn't share
column-processing logic.
"""

# ---------------------------------------------------------------------------
# Column alias constants — edit these when PCS changes column names
# ---------------------------------------------------------------------------

"""Known PCS column names for the rider/name field (lowercase)."""
const PCS_RIDER_ALIASES = ["rider", "h2hrider", "name"]

"""Known PCS column names for points fields (lowercase)."""
const PCS_POINTS_ALIASES = ["points", "pts", "score"]

"""Known PCS column names for rank/position fields (lowercase)."""
const PCS_RANK_ALIASES = ["rank", "#", "rnk", "pos", "position"]

"""Known PCS column names for team fields (lowercase)."""
const PCS_TEAM_ALIASES = ["team", "squad"]

# ---------------------------------------------------------------------------
# Core utilities
# ---------------------------------------------------------------------------

"""
    find_column(df::DataFrame, aliases::Vector{String}) -> Union{Symbol, Nothing}

Find a column in a DataFrame by trying a list of name aliases (case-insensitive).
Returns the column Symbol (preserving original casing) or `nothing` if no alias matches.

# Example
```julia
df = DataFrame("h2hRider" => ["Pogačar"], "Points" => [4852])
find_column(df, PCS_RIDER_ALIASES)  # => Symbol("h2hRider")
find_column(df, ["nonexistent"])     # => nothing
```
"""
function find_column(df::DataFrame, aliases::Vector{String})::Union{Symbol,Nothing}
    cols_lower = Dict(lowercase(n) => Symbol(n) for n in names(df))
    for alias in aliases
        key = lowercase(alias)
        if haskey(cols_lower, key)
            return cols_lower[key]
        end
    end
    return nothing
end

"""
    scrape_html_tables(pageurl::String) -> Vector{DataFrame}

Download a web page and extract all HTML tables as DataFrames.
This is the lowest-level scraping function, shared by both VG and PCS paths.
"""
function scrape_html_tables(pageurl::String)::Vector{DataFrame}
    page = TableScraper.scrape_tables(pageurl)
    if isempty(page)
        error(
            "No tables found at: $pageurl. " *
            "Check the URL in your browser to verify it loads correctly.",
        )
    end
    return [DataFrame(tbl) for tbl in page]
end

"""
    scrape_pcs_table(url::String; min_rows=5, prefer_largest=true) -> DataFrame

Fetch HTML tables from a PCS URL and select the most likely data table.

Unlike VG scraping, this does NOT require rider/points/cost columns for table
selection, and does NOT transform column names or types — callers handle that
using `find_column()`.

Table selection strategy:
- If `prefer_largest=true` (default): picks the largest table with ≥ `min_rows` rows.
  PCS puts main data in the biggest table; summary/nav tables are small.
- Falls back to the first table if none meets the min_rows threshold.

# Arguments
- `url::String` — the PCS URL to scrape
- `min_rows::Int=5` — minimum rows for a table to be considered (use 20+ to skip summary tables)
- `prefer_largest::Bool=true` — prefer the largest table on the page
"""
function scrape_pcs_table(
    url::String;
    min_rows::Int = 5,
    prefer_largest::Bool = true,
)::DataFrame
    tables = scrape_html_tables(url)

    if prefer_largest
        sorted = sort(tables, by = nrow, rev = true)
        for tbl in sorted
            if nrow(tbl) >= min_rows
                return tbl
            end
        end
    end

    # Fallback: try first table that meets min_rows
    for tbl in tables
        if nrow(tbl) >= min_rows
            return tbl
        end
    end

    # Last resort: return the largest table regardless
    largest = sort(tables, by = nrow, rev = true)[1]
    table_sizes = join(string.(nrow.(tables)), ", ")
    @warn "No table with ≥ $min_rows rows found at $url. " *
          "Using largest table ($(nrow(largest)) rows). " *
          "Table sizes on page: [$table_sizes]"
    return largest
end
