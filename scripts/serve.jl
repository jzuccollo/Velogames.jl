#!/usr/bin/env julia
"""
Local web frontend for the race predictors.

Serves a race-configuration form, writes the answers back to
`data/race_config.toml`, runs the chosen renderer in-process, and serves the
resulting report. Because the process is long-lived it pays the package load and
JIT cost once rather than per render — but the resampled optimisation is not
cached at any layer, so a re-render still costs a full solve.

The TOML stays the source of truth: the CLI render scripts read exactly the same
file and are unaffected by anything here.

Usage:
    julia --project scripts/serve.jl [--port 8080]
"""

using Velogames, DataFrames, HTTP, TOML, Logging, Dates

const REPO = dirname(@__DIR__)
const CONFIG_PATH = joinpath(REPO, "data", "race_config.toml")

# One render at a time: concurrent renders would race on race_config.toml, the
# paste files, the prediction archive and the global RNG.
const RENDER_LOCK = ReentrantLock()

const REPORTS = Dict(
    "predictor" => "predictor.html",
    "stagerace" => "stagerace.html",
    "assessor" => "assessor.html",
)

include(joinpath(@__DIR__, "render_predictor.jl"))
include(joinpath(@__DIR__, "render_stagerace.jl"))
include(joinpath(@__DIR__, "render_assessor.jl"))

# ---------------------------------------------------------------------------
# Bookmaker paste files
# ---------------------------------------------------------------------------

# name => (filename, TOML key that points at it). The win market's filename is
# hardcoded in the renderers, so it has no config key.
const PASTES = [
    ("odds_win", "oddschecker_paste.txt", ""),
    ("odds_points", "points_odds_paste.txt", "points_odds_paste_file"),
    ("odds_kom", "kom_odds_paste.txt", "kom_odds_paste_file"),
    ("odds_stagewin", "stagewin_odds_paste.txt", "stagewin_odds_paste_file"),
]

# ---------------------------------------------------------------------------
# Form fields
# ---------------------------------------------------------------------------

# scope: :both, :oneday, :stage, :assessor — drives which fieldset a control sits
# in, and so which controls are reachable for a given race format. This is what
# makes a stage-race value like max_per_team = 0 unreachable on a classic.
const FIELDS = [
    (
        sec = "race",
        key = "year",
        label = "Year",
        kind = :number,
        scope = :both,
        step = "1",
        help = "Edition year. Selects the Velogames rider list and PCS results URLs, and anchors the recency weighting on race history.",
    ),
    (
        sec = "race",
        key = "racehash",
        label = "VG startlist hash",
        kind = :text,
        scope = :both,
        step = "",
        help = "All one-day classics share a single Velogames rider page per year. This hash (e.g. #CyclassicsHamburg) picks this race's startlist out of it. Copy it from the tab link on the VG riders page.",
    ),
    (
        sec = "data_sources",
        key = "oracle_url",
        label = "Cycling Oracle URL",
        kind = :text,
        scope = :both,
        step = "",
        help = "Cycling Oracle prediction post for this race. Its win probabilities act as a market signal with broader coverage than bookmaker odds. Leave blank to skip.",
    ),
    (
        sec = "optimisation",
        key = "n_resamples",
        label = "Resamples",
        kind = :number,
        scope = :both,
        step = "50",
        help = "Monte Carlo draws. Each draw simulates the race and solves its own team optimisation, so runtime is roughly linear in this. 500 is the default; below ~200 the selection frequencies get noisy.",
    ),
    (
        sec = "optimisation",
        key = "history_years",
        label = "History years",
        kind = :number,
        scope = :both,
        step = "1",
        help = "How many past editions of this race (and similar races) feed the history signal. Older results are down-weighted hard — a three-year-old result already carries ~7x the variance of this year's — so beyond about four years adds little.",
    ),
    (
        sec = "optimisation",
        key = "domestique_discount",
        label = "Domestique discount",
        kind = :number,
        scope = :both,
        step = "0.1",
        help = "Shrinks the strength of riders who are not their own team's best on a given dimension, in proportion to the gap. Counteracts the model rating a strong helper as though they would be ridden for. 0 disables it.",
    ),
    (
        sec = "optimisation",
        key = "risk_aversion",
        label = "Risk aversion",
        kind = :number,
        scope = :both,
        step = "0.1",
        help = "Penalises riders whose expected points come from volatile outcomes (mostly zeroes, occasional big scores), using downside coefficient of variation. 0 optimises raw expected points.",
    ),
    (
        sec = "optimisation",
        key = "max_per_team",
        label = "Max riders per team (0 = uncapped)",
        kind = :number,
        scope = :both,
        step = "1",
        help = "Cap on riders drawn from a single professional team, matching the Velogames game rule. Set it to whatever this game states; 0 means no cap.",
    ),
    (
        sec = "optimisation",
        key = "simulation_df",
        label = "Student-t df (blank = Gaussian)",
        kind = :text,
        scope = :both,
        step = "",
        help = "Degrees of freedom for the simulation noise. Lower means fatter tails, i.e. more crashes, breakaways and surprise winners. 5 is the usual choice; blank gives Gaussian noise.",
    ),
    (
        sec = "optimisation",
        key = "excluded_riders",
        label = "Excluded riders (one per line)",
        kind = :lines,
        scope = :both,
        step = "",
        help = "Force riders out of the team — non-starters, injuries, or anything else the scraped data does not yet know. Names are matched loosely, so spelling need not be exact.",
    ),
    (
        sec = "optimisation",
        key = "market_blend_weight",
        label = "Market blend weight (1 = pure simulator)",
        kind = :number,
        scope = :oneday,
        step = "0.05",
        help = "Mixes the bookmaker market into the final pick: w x simulator points + (1-w) x implied win probability, both unit-normalised. 1 is the pure simulator; 0.5 is the shipped default and was worth about +0.08 team-points-captured across the 2026 classics.",
    ),
    (
        sec = "data_sources",
        key = "points_oracle_url",
        label = "Oracle URL — points jersey",
        kind = :text,
        scope = :stage,
        step = "",
        help = "Cycling Oracle post predicting the points classification. Feeds the sprint dimension.",
    ),
    (
        sec = "data_sources",
        key = "kom_oracle_url",
        label = "Oracle URL — KOM",
        kind = :text,
        scope = :stage,
        step = "",
        help = "Cycling Oracle post predicting the mountains classification. Feeds the climbing dimension.",
    ),
    (
        sec = "optimisation",
        key = "n_alternatives",
        label = "Near-optimal teams (k-best)",
        kind = :number,
        scope = :both,
        step = "1",
        help = "How many distinct near-best teams to enumerate. These drive the report's team switcher, the locked-core/filler split and the structural forks. More costs one extra optimisation each — cheap next to the resamples.",
    ),
    (
        sec = "optimisation",
        key = "cross_stage_alpha",
        label = "Cross-stage noise correlation",
        kind = :number,
        scope = :stage,
        step = "0.05",
        help = "The share of a rider's simulated noise that persists across the whole race rather than being redrawn each stage. Higher means good form and bad luck tend to run in streaks; 0.7 is the default.",
    ),
    (
        sec = "optimisation",
        key = "pcs_stage_scrape",
        label = "Scrape stage profiles from PCS",
        kind = :bool,
        scope = :stage,
        step = "",
        help = "Fetch each stage's profile (ProfileScore, vertical metres, gradient) from PCS to classify it as flat, hilly, mountain or time trial. Turn off to fall back on the built-in stage list.",
    ),
    (
        sec = "optimisation",
        key = "gt_vg_history",
        label = "GT VG-history signal (Option A)",
        kind = :bool,
        scope = :stage,
        step = "",
        help = "Feeds each rider's Velogames points from previous grand tours in as an extra, upward-only signal — it can lift a rider whose past GT scoring beats their ability estimate, but never drag one down. Aimed at breakaway raiders the ability signals under-rate.",
    ),
    (
        sec = "optimisation",
        key = "gt_vg_propensity",
        label = "GT VG-propensity layer (Option B)",
        kind = :bool,
        scope = :stage,
        step = "",
        help = "A two-sided correction applied to expected points rather than strength, learned from the gap between a rider's real past GT totals and what their ability implies. Unlike Option A it can also mark riders down. Stacks with Option A without double-counting.",
    ),
    (
        sec = "optimisation",
        key = "gt_vg_propensity_mode",
        label = "Propensity injection point",
        kind = :mode,
        scope = :stage,
        step = "",
        help = "Where Option B's correction lands. 'posthoc' scales the final expected points only, leaving selection frequencies on the unadjusted simulation. 'sim' scales every draw, so the mean, the downside risk and the selection frequencies all move together.",
    ),
    (
        sec = "data_sources",
        key = "season_round_slugs",
        label = "Season-round VG slugs (one per line)",
        kind = :lines,
        scope = :stage,
        step = "",
        help = "Velogames slugs for the other rounds of a season-long series. Single-race games open with every rider on zero points, which switches the VG season signal off; when that happens, mean points per scored round across these rounds stands in for it.",
    ),
    (
        sec = "team_assessor",
        key = "vg_race_number",
        label = "Retrospective scores against",
        kind = :vgrace,
        scope = :assessor,
        step = "1",
        help = "Which Velogames race to score your entered team against, once results are in. Auto matches the race by name, which is nearly always right; pick one by hand only when it doesn't. The list is the season set on this form — save the form after changing the year to refresh it. Stage races ignore everything but Skip.",
    ),
    (
        sec = "team_assessor",
        key = "use_league_team",
        label = "Pull my team from the league archive",
        kind = :bool,
        scope = :assessor,
        step = "",
        help = "Read the team you entered straight from the archived rosters of your league, instead of the list below. Velogames only publishes rosters once the entry deadline has passed, so before the race this finds nothing and the typed list is used instead — as it does until scripts/ingest_league.jl has run since the deadline.",
    ),
    (
        sec = "team_assessor",
        key = "my_team",
        label = "Your team (one rider per line)",
        kind = :lines,
        scope = :assessor,
        step = "",
        help = "The team you actually entered. The assessor sets it beside the model's pick and, after the race, beside the hindsight-optimal team.",
    ),
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

cfgval(cfg, sec, key, default = "") = get(get(cfg, sec, Dict{String,Any}()), key, default)

function read_paste(filename)
    path = joinpath(REPO, filename)
    return isfile(path) ? read(path, String) : ""
end

# The VG race list is a scrape, so it is memoised per year on top of the disk
# cache: the form is re-rendered on every page load and a dropdown is not worth
# a cache lookup each time. An empty list (offline, or a year VG has no page
# for) leaves the dropdown with just Auto and Skip rather than failing the form.
const VG_RACELIST_MEMO = Dict{Int,DataFrame}()

function vg_race_options(year::Int)
    return get!(VG_RACELIST_MEMO, year) do
        try
            suppress_output() do
                getvg_race_list(year)
            end
        catch e
            @warn "Could not fetch the $year VG race list for the retrospective dropdown: $e"
            DataFrame()
        end
    end
end

# `title` as well as the styled bubble: the bubble is the readable one, the title
# attribute is what a screen reader and a keyboard user actually get.
hint(text) =
    isempty(text) ? "" :
    "<span class=\"hint\" tabindex=\"0\" role=\"note\" title=\"$(esc(text))\">?" *
    "<span class=\"tip\">$(esc(text))</span></span>"

function field_html(f, cfg)
    v = cfgval(cfg, f.sec, f.key, "")
    id = "$(f.sec).$(f.key)"
    ctrl = if f.kind === :lines
        text = v isa AbstractVector ? join(string.(v), "\n") : string(v)
        "<textarea name=\"$id\" rows=\"4\">$(esc(text))</textarea>"
    elseif f.kind === :bool
        checked = v === true ? " checked" : ""
        "<input type=\"checkbox\" name=\"$id\" value=\"true\"$checked>"
    elseif f.kind === :mode
        sel(o) = string(v) == o ? " selected" : ""
        "<select name=\"$id\"><option value=\"posthoc\"$(sel("posthoc"))>posthoc</option>" *
        "<option value=\"sim\"$(sel("sim"))>sim</option></select>"
    elseif f.kind === :vgrace
        # Not named `sel`: the :mode branch already defines one in this scope,
        # and two same-named inner functions in one body collide.
        selrace(o) = string(v) == string(o) ? " selected" : ""
        year = something(
            tryparse(Int, string(cfgval(cfg, "race", "year", ""))),
            Dates.year(Dates.today()),
        )
        opts = IOBuffer()
        write(opts, "<option value=\"0\"$(selrace(0))>Auto — match by race name</option>")
        write(opts, "<option value=\"-1\"$(selrace(-1))>Skip the retrospective</option>")
        for row in eachrow(vg_race_options(year))
            write(
                opts,
                "<option value=\"$(row.race_number)\"$(selrace(row.race_number))>" *
                "$(row.race_number). $(esc(row.name))</option>",
            )
        end
        "<select name=\"$id\">$(String(take!(opts)))</select>"
    elseif f.kind === :number
        "<input type=\"number\" step=\"$(f.step)\" name=\"$id\" value=\"$(esc(v))\">"
    else
        "<input type=\"text\" name=\"$id\" value=\"$(esc(v))\">"
    end
    return "<div class=\"fld\"><label for=\"$id\">$(esc(f.label))$(hint(f.help))</label>$ctrl</div>\n"
end

function fieldset_html(title, scope, cfg)
    # `sec == "race"` fields are rendered inside the Race fieldset alongside the
    # picker. Emitting them here too would put two controls with the same name on
    # the page, and an edit to the wrong one would be silently discarded.
    fields = [f for f in FIELDS if f.scope === scope && f.sec != "race"]
    isempty(fields) && return ""
    cls = scope === :oneday ? " fmt-oneday" : scope === :stage ? " fmt-stage" : ""
    io = IOBuffer()
    write(io, "<fieldset class=\"grp$cls\"><legend>$(esc(title))</legend>\n")
    for f in fields
        write(io, field_html(f, cfg))
    end
    write(io, "</fieldset>\n")
    return String(take!(io))
end

const FORM_CSS = """
<style>
.grp{border:1px solid var(--rule,#ddd);border-radius:6px;padding:1rem 1.25rem;margin:0 0 1.25rem}
.grp legend{font-weight:600;padding:0 .5rem}
.fld{display:grid;grid-template-columns:minmax(0,18rem) minmax(0,1fr);gap:.75rem;align-items:center;margin:.5rem 0}
.fld label{font-size:.9rem}
.fld input[type=text],.fld input[type=number],.fld select,.fld textarea{
  width:100%;padding:.4rem .5rem;font:inherit;font-size:.9rem;
  border:1px solid #bbb;border-radius:4px;background:#fff;color:#111}
.fld textarea{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;resize:vertical}
.fld input[type=checkbox]{justify-self:start;width:1.1rem;height:1.1rem}
.hint{position:relative;display:inline-grid;place-items:center;width:1.05em;height:1.05em;
  margin-left:.4em;border:1px solid #999;border-radius:50%;font-size:.72rem;font-weight:700;
  color:#666;cursor:help;vertical-align:middle;user-select:none}
.hint:hover,.hint:focus{border-color:var(--accent,#4a7fb5);color:var(--accent,#4a7fb5);outline:none}
/* Left-anchored, not centred: hints sit in the narrow left-hand label column, so
   a centred bubble would hang off the edge of the viewport on a small screen. */
.hint .tip{position:absolute;left:0;bottom:calc(100% + .5em);
  width:24rem;max-width:min(24rem,70vw);padding:.6rem .75rem;border-radius:6px;
  background:#1c1c1c;color:#f0f0f0;font-size:.8rem;font-weight:400;line-height:1.45;
  text-align:left;white-space:normal;cursor:auto;
  box-shadow:0 3px 14px rgba(0,0,0,.3);opacity:0;visibility:hidden;transition:opacity .12s;z-index:50}
.hint:hover .tip,.hint:focus .tip{opacity:1;visibility:visible}
.actions{display:flex;gap:.75rem;flex-wrap:wrap;align-items:center;margin:1.5rem 0}
.actions button{padding:.6rem 1.1rem;font:inherit;font-weight:600;cursor:pointer;
  border:1px solid var(--accent,#d4a843);border-radius:5px;background:var(--accent,#d4a843);color:#1a1a1a}
.actions button.alt{background:transparent;color:inherit}
.pastes textarea{width:100%;min-height:7rem;font-family:ui-monospace,Menlo,monospace;font-size:.8rem;
  padding:.5rem;border:1px solid #bbb;border-radius:4px;background:#fff;color:#111}
#log{background:#111;color:#d8d8d8;padding:1rem;border-radius:6px;overflow-x:auto;
  font-family:ui-monospace,Menlo,monospace;font-size:.8rem;line-height:1.45}
.err{color:#b00020;font-weight:600}
</style>
"""

const TOGGLE_JS = """
<script>
(function(){
  var sel = document.getElementById('race-select');
  function sync(){
    var t = sel.options[sel.selectedIndex].getAttribute('data-type');
    document.querySelectorAll('.fmt-oneday').forEach(function(e){e.style.display = t==='oneday'?'':'none';});
    document.querySelectorAll('.fmt-stage').forEach(function(e){e.style.display = t==='stage'?'':'none';});
    document.querySelectorAll('[data-only]').forEach(function(e){e.style.display = e.getAttribute('data-only')===t?'':'none';});
  }
  sel.addEventListener('change', sync); sync();
})();
</script>
"""

function form_page()
    cfg = TOML.parsefile(CONFIG_PATH)
    current = string(cfgval(cfg, "race", "name", ""))

    io = IOBuffer()
    write(io, FORM_CSS)
    write(io, "<form method=\"post\" action=\"/render\">\n")
    # Marks a full form submission. Without it /render re-runs the config as it
    # already stands on disk, rather than reading absent fields as cleared ones.
    write(io, "<input type=\"hidden\" name=\"form\" value=\"1\">\n")

    write(io, html_heading("Race", 2))
    write(io, "<fieldset class=\"grp\"><legend>Race</legend>\n")
    write(
        io,
        "<div class=\"fld\"><label for=\"race-select\">Race" *
        hint(
            "Picking the race fixes its format, which decides both the report you can run and which controls below apply. One-day and stage races take different knobs, so the wrong ones are hidden rather than left to carry over.",
        ) *
        "</label><select id=\"race-select\" name=\"race.name\">\n",
    )
    for r in all_races()
        sel = r.slug == current ? " selected" : ""
        write(
            io,
            "<option value=\"$(esc(r.slug))\" data-type=\"$(r.type)\"$sel>$(esc(r.name))</option>\n",
        )
    end
    write(io, "</select></div>\n")
    for f in FIELDS
        f.scope === :both && f.sec == "race" && write(io, field_html(f, cfg))
    end
    write(io, "</fieldset>\n")

    write(io, html_heading("Optimisation", 2))
    write(io, fieldset_html("Shared", :both, cfg))
    write(io, fieldset_html("One-day only", :oneday, cfg))
    write(io, fieldset_html("Stage races only", :stage, cfg))

    write(io, html_heading("Bookmaker markets", 2))
    write(io, "<fieldset class=\"grp pastes\"><legend>Paste odds</legend>\n")
    write(
        io,
        "<p>Paste a bookmaker winner market straight from Oddschecker (or any " *
        "rider/price list). Odds are the single strongest signal for the favourites, " *
        "so they are worth the paste. Clearing a box removes that market.</p>\n",
    )
    labels = Dict(
        "odds_win" => (
            "Winner market",
            "",
            "Outright winner odds. The strongest predictor there is for top-quartile riders. Riders absent from the market get a floor estimate from the residual probability, so a partial list is fine.",
        ),
        "odds_points" => (
            "Points jersey",
            "stage",
            "Odds on the points classification. Feeds the sprint dimension of the stage-race model.",
        ),
        "odds_kom" => (
            "KOM",
            "stage",
            "Odds on the mountains classification. Feeds the climbing dimension.",
        ),
        "odds_stagewin" => (
            "Rider to win a stage",
            "stage",
            "Odds on winning any stage. Picks up stage hunters the GC market prices poorly.",
        ),
    )
    for (name, filename, _) in PASTES
        label, only, tip = labels[name]
        attr = isempty(only) ? "" : " data-only=\"$only\""
        write(io, "<div$attr><label for=\"$name\">$(esc(label))$(hint(tip))</label>\n")
        write(
            io,
            "<textarea id=\"$name\" name=\"$name\">$(esc(read_paste(filename)))</textarea></div>\n",
        )
    end
    write(io, "</fieldset>\n")

    write(io, html_heading("Team assessor", 2))
    write(io, fieldset_html("Your entered team", :assessor, cfg))

    write(io, "<div class=\"actions\">\n")
    write(
        io,
        "<button type=\"submit\" name=\"report\" value=\"predictor\" class=\"fmt-oneday\">Run predictor</button>\n",
    )
    write(
        io,
        "<button type=\"submit\" name=\"report\" value=\"stagerace\" class=\"fmt-stage\">Run stage race</button>\n",
    )
    write(
        io,
        "<button type=\"submit\" name=\"report\" value=\"assessor\" class=\"alt\">Run assessor</button>\n",
    )
    write(
        io,
        "<label><input type=\"checkbox\" name=\"fresh\" value=\"true\"> bypass cache (--fresh)" *
        hint(
            "Re-scrape everything from Velogames and PCS instead of reusing the local cache (which holds data for a week). Slower, and only worth it when a startlist or the rider costs have just changed.",
        ) *
        "</label>\n",
    )
    write(io, "</div>\n</form>\n")
    write(io, TOGGLE_JS)

    return html_page(;
        title = "Velogames race builder",
        subtitle = "Configure a race, run the model, read the report",
        body = String(take!(io)),
        accent = "#4a7fb5",
    )
end

# ---------------------------------------------------------------------------
# Saving the form back to TOML
# ---------------------------------------------------------------------------

function coerce(f, raw::AbstractString)
    f.kind === :lines &&
        return String[strip(l) for l in split(raw, '\n') if !isempty(strip(l))]
    f.kind === :bool && return raw == "true"
    f.kind === :vgrace && return something(tryparse(Int, strip(raw)), 0)
    if f.kind === :number
        v = tryparse(Float64, strip(raw))
        v === nothing && return 0
        # Integer steps mean the config wants an Int; TOML round-trips the type.
        return f.step in ("1", "50") && isinteger(v) ? Int(v) : v
    end
    # simulation_df is the one text field the config wants typed
    f.key == "simulation_df" && return something(tryparse(Int, strip(raw)), "")
    return String(raw)
end

function save_config(params)
    # TOML.print drops comments, so keep one copy of the hand-written file.
    backup = CONFIG_PATH * ".backup"
    isfile(backup) || cp(CONFIG_PATH, backup)

    cfg = TOML.parsefile(CONFIG_PATH)
    haskey(cfg, "race") || (cfg["race"] = Dict{String,Any}())
    cfg["race"]["name"] = get(params, "race.name", cfgval(cfg, "race", "name", ""))

    for f in FIELDS
        haskey(cfg, f.sec) || (cfg[f.sec] = Dict{String,Any}())
        id = "$(f.sec).$(f.key)"
        if f.kind === :bool
            cfg[f.sec][f.key] = haskey(params, id)   # unchecked boxes are not submitted
        elseif haskey(params, id)
            cfg[f.sec][f.key] = coerce(f, params[id])
        end
    end

    # Odds pastes go to the files the renderers already read, so the CLI path is
    # unchanged and the config keeps holding filenames rather than a wall of text.
    for (name, filename, key) in PASTES
        text = strip(get(params, name, ""))
        path = joinpath(REPO, filename)
        isempty(text) ? (isfile(path) && rm(path)) : write(path, text)
        if name == "odds_win"
            cfg["data_sources"]["use_oddschecker"] = !isempty(text)
        else
            cfg["data_sources"][key] = isempty(text) ? "" : filename
        end
    end

    open(CONFIG_PATH, "w") do io
        TOML.print(io, cfg)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Streaming render
# ---------------------------------------------------------------------------

struct StreamLogger <: AbstractLogger
    io::IO
end
Logging.min_enabled_level(::StreamLogger) = Logging.Info
Logging.shouldlog(::StreamLogger, _...) = true
Logging.catch_exceptions(::StreamLogger) = false
function Logging.handle_message(
    l::StreamLogger,
    level,
    message,
    _module,
    group,
    id,
    file,
    line;
    kwargs...,
)
    kv = isempty(kwargs) ? "" : "  " * join(("$k=$v" for (k, v) in kwargs), "  ")
    text = "[$level] $message$kv"
    println(stderr, text)          # terminal copy first, so it survives a dead client
    try
        println(l.io, esc(text))
        flush(l.io)
    catch
        # Browser tab closed mid-render. The report is written to disk regardless,
        # so finish the job rather than abandoning several minutes of solving.
    end
    return nothing
end

# Browsers withhold an incrementally-arriving document until roughly a kilobyte
# has landed, which makes a streaming render look hung. Pad the first chunk.
const PAD = "<!-- " * repeat("padding ", 150) * " -->\n"

function render_stream(stream::HTTP.Stream)
    params = HTTP.queryparams(String(read(stream)))
    which = get(params, "report", "predictor")

    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type" => "text/html; charset=utf-8")
    HTTP.setheader(stream, "Transfer-Encoding" => "chunked")
    HTTP.setheader(stream, "X-Content-Type-Options" => "nosniff")
    HTTP.startwrite(stream)

    write(stream, PAD)
    write(
        stream,
        "<!doctype html><meta charset=\"utf-8\"><title>Rendering…</title>" *
        FORM_CSS *
        "<body style=\"font-family:system-ui,sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem\">" *
        "<h1>Rendering $(esc(which))…</h1><p><a href=\"/\">← back to options</a></p><pre id=\"log\">\n",
    )
    flush(stream)

    lock(RENDER_LOCK) do
        try
            with_logger(StreamLogger(stream)) do
                haskey(params, "form") && save_config(params)
                rc = load_render_config(CONFIG_PATH; fresh = haskey(params, "fresh"))
                started = time()
                path = if which == "stagerace"
                    render_stagerace(rc)
                elseif which == "assessor"
                    render_assessor(rc)
                else
                    render_predictor(rc)
                end
                @info "Rendered in $(round(time() - started, digits = 1))s"
                file = basename(path)
                try
                    write(
                        stream,
                        "</pre><p><a href=\"/reports/$file\">Open the report →</a></p>" *
                        "<script>location.replace('/reports/$file')</script>\n",
                    )
                catch
                end
            end
        catch e
            @error "Render failed" exception = (e, catch_backtrace())
            msg = sprint(showerror, e)
            try
                write(
                    stream,
                    "</pre><p class=\"err\">Render failed: $(esc(msg))</p>" *
                    "<p><a href=\"/\">← back to options</a></p>\n",
                )
            catch
            end
        end
    end
    HTTP.closewrite(stream)
    return nothing
end

# Injected only on the way out of the server, never written to the report file:
# the link targets routes that exist solely while the frontend is running, so a
# report opened straight off disk or published to the site must not carry it.
const BACKLINK_BAR = """
<style>
#vg-bar{position:fixed;right:1rem;bottom:1rem;z-index:9999;display:flex;gap:.5rem;
  background:#1c1c1c;color:#eee;padding:.5rem .6rem;border-radius:8px;
  box-shadow:0 2px 12px rgba(0,0,0,.35);font:600 .85rem system-ui,sans-serif}
#vg-bar a,#vg-bar button{font:inherit;color:#eee;text-decoration:none;cursor:pointer;
  background:transparent;border:1px solid #555;border-radius:5px;padding:.35rem .7rem}
#vg-bar button{background:#4a7fb5;border-color:#4a7fb5;color:#fff}
@media print{#vg-bar{display:none}}
</style>
<div id="vg-bar">
  <a href="/">&larr; Change parameters</a>
  <form method="post" action="/render" style="margin:0">
    <input type="hidden" name="report" value="{{which}}">
    <button type="submit">Re-run</button>
  </form>
</div>
"""

function serve_report(req::HTTP.Request)
    segments = HTTP.URIs.splitpath(req.target)
    isempty(segments) && return HTTP.Response(404, "Unknown report")
    # Whitelist, not a path join: never build a filesystem path from user input.
    name = basename(segments[end])
    name in values(REPORTS) || return HTTP.Response(404, "Unknown report")
    cfg = TOML.parsefile(CONFIG_PATH)
    dir = joinpath(REPO, get(get(cfg, "output", Dict()), "dir", "prediction_docs"))
    path = joinpath(dir, name)
    isfile(path) || return HTTP.Response(404, "Not rendered yet: $name")

    which = first(k for (k, v) in REPORTS if v == name)
    html = replace(
        read(path, String),
        "</body>" => replace(BACKLINK_BAR, "{{which}}" => which) * "</body>",
    )
    return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], html)
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function serve_forms(; port::Int = 8080)
    # The default 404/405 handlers return a Response, which the router cannot use
    # in stream mode — every unmatched route would surface as a 500.
    notfound = HTTP.streamhandler(_ -> HTTP.Response(404, "Not found"))
    router = HTTP.Router(notfound, notfound)
    HTTP.register!(
        router,
        "GET",
        "/",
        HTTP.streamhandler(
            _ -> HTTP.Response(
                200,
                ["Content-Type" => "text/html; charset=utf-8"],
                form_page(),
            ),
        ),
    )
    HTTP.register!(router, "GET", "/reports/*", HTTP.streamhandler(serve_report))
    HTTP.register!(router, "POST", "/render", render_stream)

    @info "Velogames race builder on http://localhost:$port  (ctrl-c to stop)"
    HTTP.serve(router, "127.0.0.1", port; stream = true)
end

if abspath(PROGRAM_FILE) == @__FILE__
    i = findfirst(==("--port"), ARGS)
    serve_forms(; port = i === nothing ? 8080 : parse(Int, ARGS[i+1]))
end
