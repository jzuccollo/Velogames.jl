# ---------------------------------------------------------------------------
# HTML page generation (replaces Quarto)
# ---------------------------------------------------------------------------

"""Slugify text for use as an HTML id attribute."""
function _slugify(text::String)
    s = lowercase(text)
    s = replace(s, r"[^a-z0-9\s-]" => "")
    s = replace(s, r"\s+" => "-")
    return String(strip(s, '-'))
end

"""
    html_heading(text, level; id) -> String

Return an HTML heading tag with an auto-slugified id for ToC linking.
"""
function html_heading(text::String, level::Int = 2; id::String = _slugify(text))
    return "<h$level id=\"$id\">$text</h$level>\n"
end

"""Format an integer with thousands separators, e.g. 2876 → "2,876"."""
function commafmt(n::Integer)
    neg = n < 0
    s = string(abs(n))
    out = ""
    while length(s) > 3
        out = "," * s[(end-2):end] * out
        s = s[1:(end-3)]
    end
    return (neg ? "-" : "") * s * out
end

"""
    html_table(df; caption, team_cols) -> String

Convert a DataFrame to a Bootstrap-styled HTML table. Rounds numeric columns
and cleans team name pipe characters automatically.
"""
function html_table(
    df::DataFrame;
    caption::String = "",
    team_cols::Vector{Symbol} = [:team, :Team],
    rider_link_base::String = "",
)
    display = copy(df)
    round_numeric_columns!(display)
    clean_team_names!(display, intersect(team_cols, propertynames(display)))

    cols = names(display)
    # Optional rider-name hyperlinks: when a base is given and the frame carries both a
    # rider-name column and a riderkey column, link each name to its dossier and hide the key.
    keycol = findfirst(c -> lowercase(c) == "riderkey", cols)
    ridercol = findfirst(c -> lowercase(c) in ("rider", "name"), cols)
    linking = !isempty(rider_link_base) && keycol !== nothing && ridercol !== nothing
    keyname = keycol === nothing ? "" : cols[keycol]
    ridername = ridercol === nothing ? "" : cols[ridercol]
    render_cols = linking ? filter(!=(keyname), cols) : cols

    # Numeric columns are right-aligned with tabular figures for clean place-value alignment.
    numeric =
        Dict(col => (eltype(display[!, col]) <: Union{Missing,Number}) for col in cols)

    io = IOBuffer()
    # Wrap in a scroll container so wide tables (e.g. the 11-column stage profile)
    # scroll horizontally rather than squeezing cell text onto multiple lines.
    write(io, "<div class=\"table-wrap\">\n")
    write(io, "<table class=\"table table-striped table-sm\">\n")
    !isempty(caption) && write(io, "<caption>$caption</caption>\n")

    # Header
    write(io, "<thead><tr>")
    for col in render_cols
        cls = numeric[col] ? " class=\"num\"" : ""
        write(io, "<th$cls>$col</th>")
    end
    write(io, "</tr></thead>\n<tbody>\n")

    # Rows
    for row in eachrow(display)
        write(io, "<tr>")
        for col in render_cols
            val = row[col]
            if col == "Class" && !ismissing(val)
                slug = lowercase(string(val))
                cell = "<span class=\"badge badge-$slug\">$(_class_label(slug))</span>"
            elseif linking && col == ridername && !ismissing(val)
                cell = "<a href=\"$(rider_link_base)$(row[keyname])\">$(string(val))</a>"
            elseif numeric[col] &&
                   val isa Integer &&
                   abs(val) >= 1000 &&
                   !occursin("year", lowercase(col))
                cell = commafmt(val)
            else
                cell = ismissing(val) ? "" : string(val)
            end
            cls = numeric[col] ? " class=\"num\"" : ""
            write(io, "<td$cls>$cell</td>")
        end
        write(io, "</tr>\n")
    end
    write(io, "</tbody></table>\n")
    write(io, "</div>\n")
    return String(take!(io))
end

"""
    html_callout(content; type, title, collapsed) -> String

Generate a Bootstrap-styled callout. Types: "note" (blue), "warning" (yellow),
"tip" (green). When `collapsed=true`, uses a `<details>` element.
"""
function html_callout(
    content::String;
    type::String = "note",
    title::String = "",
    collapsed::Bool = false,
)
    colour = type == "warning" ? "#856404" : type == "tip" ? "#155724" : "#004085"
    bg = type == "warning" ? "#fff3cd" : type == "tip" ? "#d4edda" : "#cce5ff"
    border = type == "warning" ? "#ffc107" : type == "tip" ? "#28a745" : "#007bff"

    if collapsed
        summary = isempty(title) ? titlecase(type) : title
        return """<details style="margin:1.25em 0; border-left:4px solid $border; padding:0.5em 1em; background:$bg; border-radius:6px;">
<summary style="color:$colour; font-weight:bold; cursor:pointer;">$summary</summary>
$content
</details>\n"""
    end

    header = isempty(title) ? "" : "<strong style=\"color:$colour;\">$title</strong><br>"
    return """<div style="margin:1.25em 0; border-left:4px solid $border; padding:0.75em 1em; background:$bg; border-radius:6px;">
$header$content
</div>\n"""
end

const _TEMPLATES_DIR = joinpath(@__DIR__, "templates")
# include_dependency so editing a template invalidates the precompiled cache.
include_dependency(joinpath(_TEMPLATES_DIR, "page.css"))
include_dependency(joinpath(_TEMPLATES_DIR, "toc.js"))
include_dependency(joinpath(_TEMPLATES_DIR, "rider-backlink.js"))
include_dependency(joinpath(_TEMPLATES_DIR, "page.html"))
const _HTML_PAGE_CSS = read(joinpath(_TEMPLATES_DIR, "page.css"), String)
const _HTML_PAGE_TOC_JS = read(joinpath(_TEMPLATES_DIR, "toc.js"), String)
const _HTML_PAGE_RIDER_BACKLINK_JS =
    read(joinpath(_TEMPLATES_DIR, "rider-backlink.js"), String)
const _HTML_PAGE_TEMPLATE = read(joinpath(_TEMPLATES_DIR, "page.html"), String)

"""
    html_page(; title, subtitle, body, include_plotly, home_url) -> String

Wrap body content in a complete, standalone HTML page with CSS and ToC.
"""
function html_page(;
    title::String,
    subtitle::String = "",
    body::String,
    include_plotly::Bool = false,
    home_url::String = "",
    accent::String = "#d4a843",
)
    plotly_script =
        include_plotly ?
        "\n<script src=\"https://cdn.plot.ly/plotly-2.35.2.min.js\"></script>" : ""
    subtitle_html = isempty(subtitle) ? "" : "<p class=\"subtitle\">$subtitle</p>\n"
    home_html =
        isempty(home_url) ? "" :
        "<a class=\"home-link\" href=\"$home_url\">&larr; All races</a>\n"

    page = _HTML_PAGE_TEMPLATE
    page = replace(page, "{{title}}" => title)
    page = replace(page, "{{css}}" => _HTML_PAGE_CSS)
    page = replace(page, "{{plotly_script}}" => plotly_script)
    page = replace(page, "{{home_link}}" => home_html)
    page = replace(page, "{{subtitle}}" => subtitle_html)
    page = replace(page, "{{body}}" => body)
    page = replace(page, "{{accent}}" => accent)
    page = replace(
        page,
        "{{toc_script}}" => "<script>\n$(_HTML_PAGE_TOC_JS)</script>\n<script>\n$(_HTML_PAGE_RIDER_BACKLINK_JS)</script>",
    )
    return page
end

# ---------------------------------------------------------------------------
# Plotly chart helpers
# ---------------------------------------------------------------------------

"""
    plotly_html(traces, layout; id, width, height) -> String

Serialise PlotlyBase traces and layout to an HTML block with a div and script tag.
"""
function plotly_html(
    traces,
    layout;
    id::String = "plot-" * string(rand(UInt32), base = 16),
    width::String = "100%",
    height::String = "500px",
)
    spec = Dict(
        "data" => [JSON3.read(JSON3.write(t)) for t in traces],
        "layout" => JSON3.read(JSON3.write(layout)),
    )
    json_str = JSON3.write(spec)
    return """<div id="$id" style="width:$(width); height:$(height);"></div>
<script>Plotly.newPlot('$id', $json_str.data, $json_str.layout, {responsive: true, displayModeBar: false, displaylogo: false})</script>"""
end

# ---------------------------------------------------------------------------
# Race report data assembly (used by site/race_report.qmd)
# ---------------------------------------------------------------------------

"""
    write_report(page, dir, filename) -> String

Write a rendered page to `dir/filename`, creating the directory if needed, and
log where it landed. Returns the path, which every renderer returns to its
caller (the CLI shim and the web frontend both use it).
"""
function write_report(page::AbstractString, dir::AbstractString, filename::AbstractString)
    mkpath(dir)
    path = joinpath(dir, filename)
    write(path, page)
    @info "Written to $path"
    return path
end
