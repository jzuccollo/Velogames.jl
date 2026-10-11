"""Sentinel position for riders who did not finish (DNF/DNS/DSQ/OTL)."""
const DNF_POSITION = 999

"""Sentinel position/rank for unranked riders."""
const UNRANKED_POSITION = 9999

"""
A desktop-browser User-Agent for scraping requests. PCS and Velogames both
block requests that self-identify as a bot.
"""
const SCRAPE_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

"""
    ScrapeBlockedError

Raised when a scrape is turned away by Cloudflare bot protection (a challenge
page, or a 403/429), as distinct from a response that means "no data".

Both procyclingstats.com and velogames.com raise it; the URL in the message
says which.

Its own type, mirroring `BlockedError` in vgleague's `scraper.py`. A challenge
page parses as valid HTML with none of the elements a scraper looks for, so an
undifferentiated failure reads as a site redesign or a rider with no profile
and gets folded into a missing-data row. See `docs/pcs-fetch-architecture.md`.
"""
struct ScrapeBlockedError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ScrapeBlockedError) = print(io, "ScrapeBlockedError: ", e.msg)

"""
    looks_blocked(response) -> Bool

Whether an HTTP response is Cloudflare bot protection rather than the page
requested: the `cf-mitigated` header, a 403/429 status, or the challenge
page's own body markers ("Just a moment...", "Sorry, you have been
blocked"). Mirrors `looks_blocked` in vgleague's `scraper.py`, which checks
the same header for the same site's WAF.

`response` is anything with `.status`, `.headers` (an iterable of
name/value pairs) and `.body` — an `HTTP.Response`, or the `.response` field
of an `HTTP.Exceptions.StatusError`.
"""
function looks_blocked(response)::Bool
    response.status in (403, 429) && return true
    headers = Dict(lowercase(String(k)) => String(v) for (k, v) in response.headers)
    haskey(headers, "cf-mitigated") && return true
    # `String(v::Vector{UInt8})` takes ownership of the buffer and empties it.
    # Callers go on to do `String(response.body)` after `scrape_get` returns,
    # so decode a copy.
    body = String(copy(response.body))
    occursin("Just a moment...", body) && return true
    occursin("Sorry, you have been blocked", body) && return true
    return false
end

# Response bodies held for `scrape_get(...; reuse = true)`, keyed by URL.
#
# For two parsers wanting the same page: `getpcs_rider_pts` reads the specialty
# `.xvalue` elements off `/rider/{slug}` and `getpcs_rider_seasons` reads the
# season table off the same page. `cached_fetch` keys on the parsed frame, so
# they hold two entries and would otherwise fetch every profile twice.
#
# Opt-in because race results go from empty to partial to final on race day,
# are read through a zero-TTL `CacheConfig`, and must never be served stale;
# they do not pass `reuse`. Rider profiles are stable across a run.
#
# Only consulted after `cached_fetch` has missed both its tiers, since
# `scrape_get` runs inside the fetch closure. `clear_memory_cache!` empties it.
const _PAGE_CACHE = Dict{String,Vector{UInt8}}()

# Pages fetched ahead of time by `prefetch!`, keyed by URL, consumed once.
#
# Kept apart from `_PAGE_CACHE` because a prefetched page is not a cache entry:
# it is that fetch, made a few seconds earlier through a transport the site
# accepts. So it is served to every caller, `reuse` or not, and popped on the
# way out; a second request for the same URL goes back to the network, as a
# zero-TTL caller expects. A `reuse` caller keeps a copy, so the specialty and
# season parsers still share one profile page.
const _PREFETCHED = Dict{String,Vector{UInt8}}()

# Whether `scrape_get` may fall back to the browser transport.
#
# Off during reconstruction (backtests and prospective evaluation). There a
# browser fetch would reconstruct a 2024 race from *today's* page, the leak
# `pcs_specialty`'s `refetchable = false` exists to prevent, and would turn
# every archive miss into a browser launch. Reconstruction reads the archive
# only, so it gets a `ScrapeBlockedError` and degrades.
const _TRANSPORT_ENABLED = Ref(true)

"""
    with_browser_transport(f, enabled::Bool)

Run `f()` with the browser transport forced on or off, restoring the previous
setting afterwards. See `_TRANSPORT_ENABLED`.
"""
function with_browser_transport(f, enabled::Bool)
    old = _TRANSPORT_ENABLED[]
    _TRANSPORT_ENABLED[] = enabled
    try
        return f()
    finally
        _TRANSPORT_ENABLED[] = old
    end
end

"""
    prefetch!(urls; headless = false) -> NamedTuple

Fetch `urls` through `vgleague fetch` and hold their HTML for `scrape_get`.

Both procyclingstats.com and velogames.com check the client's TLS and
client-hint fingerprint, which `HTTP.jl` cannot pass, so the pages are fetched
by a headed browser in Python and parsed here unchanged. See
`docs/pcs-fetch-architecture.md`.

One browser session covers the whole list: a launch costs seconds and a page
about a quarter of one, so a 160-rider field takes under three minutes where
160 separate launches would spend eight minutes launching alone. Call it once
with everything a batch needs.

Returns `(requested, fetched, blocked)`. A URL that could not be fetched is
absent from the store and `scrape_get` falls through to its usual behaviour
for it, so a partial prefetch degrades instead of failing.

Headed by default: PCS challenges headless Chromium even with a full
desktop-Chrome context, so this needs a GUI session rather than a bare launchd
job. Velogames tolerates headless, hence the keyword.
"""
function prefetch!(urls::Vector{String}; headless::Bool = false)
    _TRANSPORT_ENABLED[] || return (
        requested = length(urls),
        fetched = 0,
        blocked = length(urls),
    )
    # Drop what this process already holds. `_PAGE_CACHE` is why a seasons batch
    # costs nothing after a specialty batch has been over the same profiles.
    urls = unique(
        url for url in urls if
        !isempty(url) && !haskey(_PREFETCHED, url) && !haskey(_PAGE_CACHE, url)
    )
    isempty(urls) && return (requested = 0, fetched = 0, blocked = 0)

    dir = mktempdir()
    try
        listfile = joinpath(dir, "urls.txt")
        write(listfile, join(urls, "\n"))
        pages = joinpath(dir, "pages")

        cmd = `$(vgleague_executable()) fetch --urls-from $listfile --out $pages`
        headless && (cmd = `$cmd --headless`)
        try
            run(pipeline(cmd; stdout = devnull, stderr = stderr))
        catch e
            @warn "vgleague fetch failed; leaving these URLs to the usual path" exception =
                e count = length(urls)
            return (requested = length(urls), fetched = 0, blocked = length(urls))
        end

        fetched = 0
        for url in urls
            path = joinpath(pages, bytes2hex(sha256(url)) * ".html")
            isfile(path) || continue
            _PREFETCHED[url] = read(path)
            fetched += 1
        end
        return (
            requested = length(urls),
            fetched = fetched,
            blocked = length(urls) - fetched,
        )
    finally
        rm(dir; recursive = true, force = true)
    end
end

"""
    vgleague_executable() -> String

Where the `vgleague` CLI lives. `VGLEAGUE_BIN` overrides it; otherwise take
whatever is on `PATH`, which is how it is installed on this machine.
"""
vgleague_executable() = get(ENV, "VGLEAGUE_BIN", "vgleague")

"""
    scrape_get(url; headers, reuse) -> HTTP.Response

Get `url`, by whatever means the site will accept, and hand back a response
the caller's parser can read. Every PCS and Velogames scrape goes through
here. Resolution order:

1. a page `prefetch!` already fetched for this URL, consumed on the way out;
2. a page held from an earlier `reuse` fetch in this process;
3. `HTTP.get`, which is cheap and works on any host that is not behind a
   challenge;
4. `vgleague fetch`, when 3 comes back blocked.

A non-2xx status that is not a block (e.g. 400, 404) raises
`HTTP.Exceptions.StatusError`, so callers keep their "missing data" handling
for those. `ScrapeBlockedError` is raised only when the browser transport is
turned away too.

Step 3 comes first because it costs one request to find out and keeps
unblocked hosts, such as the Cycling Oracle, on the fast path with no host list
to maintain. That request is made once per host per process: a refusal puts the
host in `_BLOCKED_HOSTS` and later URLs on it skip straight to step 4, throttle
included. Batches should use `prefetch!`.

The jittered 0.2-0.4s pause covers every request that reaches step 3, some
800 on a grand-tour field. It is politeness towards velogames.com, which
rate-limits under burst; no delay gets `HTTP.jl` past the fingerprint check
(see `docs/pcs-fetch-architecture.md`). It is short because a longer one would
add a quarter of an hour to a grand-tour render.

Every call site is inside a `cached_fetch` fetch closure, so a cache hit costs
nothing.
"""
function scrape_get(
    url::String;
    headers = ["User-Agent" => SCRAPE_USER_AGENT],
    reuse::Bool = false,
)
    if haskey(_PREFETCHED, url)
        body = pop!(_PREFETCHED, url)
        reuse && (_PAGE_CACHE[url] = copy(body))
        return _page_response(body)
    end
    reuse && haskey(_PAGE_CACHE, url) && return _page_response(_PAGE_CACHE[url])

    # The check is on the TLS fingerprint, which does not vary between
    # requests, so a host that refused once goes straight to the transport.
    if _host(url) in _BLOCKED_HOSTS
        return _scrape_get_via_browser(url; reuse = reuse)
    end

    sleep(0.2 + 0.2 * rand())
    response = try
        HTTP.get(url, headers)
    catch e
        if e isa HTTP.Exceptions.StatusError && looks_blocked(e.response)
            push!(_BLOCKED_HOSTS, _host(url))
            return _scrape_get_via_browser(url; reuse = reuse)
        end
        rethrow()
    end
    if looks_blocked(response)
        push!(_BLOCKED_HOSTS, _host(url))
        return _scrape_get_via_browser(url; reuse = reuse)
    end
    reuse && (_PAGE_CACHE[url] = copy(response.body))
    return response
end

_page_response(body::Vector{UInt8}) =
    HTTP.Response(200, Pair{String,String}[]; body = copy(body))

# Hosts that have refused `HTTP.jl` in this process. Per host because the
# fingerprint check ignores the path; per process, not persisted, because a
# site's posture changes. `clear_memory_cache!` empties it, so a long-lived
# `serve.jl` notices when a site relents.
const _BLOCKED_HOSTS = Set{String}()

"""
    _host(url) -> String

The host part of `url`, for `_BLOCKED_HOSTS`. Falls back to the whole string
when there is no `//`, which only happens for a malformed URL — those go on to
fail at `HTTP.get` and say so properly.
"""
function _host(url::AbstractString)
    stripped = replace(String(url), r"^[a-zA-Z][a-zA-Z0-9+.-]*://" => "")
    return String(first(split(stripped, '/'; limit = 2)))
end

"""
    _scrape_get_via_browser(url; reuse) -> HTTP.Response

The fallback `scrape_get` takes when `HTTP.jl` is turned away: fetch the one
page through `vgleague fetch` and carry on as though the request had worked.

One page means one browser launch, which takes seconds. That suits a one-off
such as `getpcs_race_startlist` loading a single startlist; a field of riders
goes through `prefetch!`.
"""
function _scrape_get_via_browser(url::String; reuse::Bool = false)
    _TRANSPORT_ENABLED[] || throw(
        ScrapeBlockedError(
            "Blocked fetching $url, and the browser transport is disabled for " *
            "this call (see `with_browser_transport`). Reconstruction reads the " *
            "archive and nothing else.",
        ),
    )
    prefetch!([url])
    haskey(_PREFETCHED, url) || throw(
        ScrapeBlockedError(
            "Blocked fetching $url, and the browser transport could not get it either",
        ),
    )
    body = pop!(_PREFETCHED, url)
    reuse && (_PAGE_CACHE[url] = copy(body))
    return _page_response(body)
end


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

const NAME_PARTICLES = Set([
    "van", "der", "den", "de", "da", "di", "du", "del", "della", "von",
    "ten", "ter", "la", "le", "dos", "das", "do", "vanden", "vander", "st",
])

# Given names that are the same name. Keep in step with `NICKNAME_GROUPS` in
# vgleague's `src/vgleague/matching.py`; the golden corpus
# (test/fixtures/rider_matching.json) catches a drift where a measured name
# depends on it.
const NICKNAME_GROUPS = [
    ["tom", "thomas", "tommy"],
    ["fred", "frederick", "frederik", "freddy"],
    ["will", "william", "bill"],
    ["alex", "alexander", "aleksandr", "alexandre", "alexandr", "oleksandr", "sasha"],
    ["alexey", "aleksey", "alexei", "aleksei"],
    ["matt", "matthew", "mathew"],
    ["mike", "michael", "michal", "mikkel"],
    ["ben", "benjamin"],
    ["chris", "christopher"],
    ["nick", "nicholas", "nicolas", "niklas", "nikolas"],
    ["dan", "daniel", "danny"],
    ["sam", "samuel"],
    ["jon", "jonathan", "john", "johnny"],
    ["joe", "joseph", "josef"],
    ["rob", "robert", "bob", "robbie"],
    ["ed", "edward", "eddie"],
    ["jake", "jacob", "jakob"],
    ["max", "maximilian", "maxim"],
    ["andy", "andrew", "andreas"],
    ["pat", "patrick"],
    ["stan", "stanislaw"],
    ["steve", "steven", "stephen"],
    ["jim", "james", "jimmy"],
    ["magnus", "mangus"],
    ["juanpe", "juan", "pedro"],
    ["jan", "johannes", "johan"],
    ["oier", "oyer"],
    ["fran", "francisco", "francesco"],
    ["josh", "joshua"],
    ["harry", "harold"],
    ["tim", "timothy", "timo"],
    ["mads", "mats"],
    ["lenny", "leonard"],
    ["rich", "richard", "ricardo", "riccardo"],
    ["isaac", "isaak"],
    ["zak", "zachary"],
    ["kasia", "katarzyna"],
    ["luke", "lucas", "lukas"],
    ["kim", "kimberley", "kimberly"],
    ["dave", "davide", "david"],
]

const _NICKNAMES = let d = Dict{String,Set{String}}()
    for group in NICKNAME_GROUPS, name in group
        union!(get!(d, name, Set{String}()), group)
    end
    d
end

_depunct(key::AbstractString) = replace(key, r"[-.]" => "")

"""
    name_parts(name) -> Vector{String}

A printed name's parts in printed order: hyphens split, normalised as
`normalisename` does, anything but letters and digits dropped.
"""
function name_parts(name::AbstractString)
    s = normalisename(replace(String(name), "-" => " "))
    parts = (replace(p, r"[^a-z0-9]" => "") for p in split(s, "-"))
    return [String(p) for p in parts if !isempty(p)]
end

function levenshtein(a::AbstractString, b::AbstractString)
    a == b && return 0
    ca, cb = collect(a), collect(b)
    prev = collect(0:length(cb))
    for (i, x) in enumerate(ca)
        cur = [i]
        for (j, y) in enumerate(cb)
            push!(cur, min(prev[j+1] + 1, cur[j] + 1, prev[j] + (x != y)))
        end
        prev = cur
    end
    return prev[end]
end

"""
    given_compatible(a, b) -> Bool

Whether two normalised given names can be one rider's: equal, in one
`NICKNAME_GROUPS` group, an initial, a prefix of three letters or more, or one
edit apart (two when both are longer than five letters).
"""
function given_compatible(a::AbstractString, b::AbstractString)
    (a == b || b in get(_NICKNAMES, a, ())) && return true
    la, lb = length(a), length(b)
    (la == 1 || lb == 1) && return first(a) == first(b)
    min(la, lb) >= 3 && (startswith(a, b) || startswith(b, a)) && return true
    return levenshtein(a, b) <= (min(la, lb) <= 5 ? 1 : 2)
end

struct _RefRider
    key::String
    depunct::String
    core::Set{String}
    sorted_join::String
    join::String
    given::Union{String,Nothing}
    surname::Union{String,Nothing}
end

function _reference_riders(names, keys)
    refs = _RefRider[]
    seen = Set{String}()
    for (name, key) in zip(names, keys)
        key = String(key)
        key in seen && continue
        push!(seen, key)
        parts = name_parts(name)
        core = [p for p in parts if !(p in NAME_PARTICLES)]
        two = length(core) >= 2
        push!(
            refs,
            _RefRider(
                key,
                _depunct(key),
                Set(core),
                join(sort(parts)),
                join(parts),
                two ? first(core) : nothing,
                two ? last(core) : nothing,
            ),
        )
    end
    return refs, seen
end

"""
    resolve_rider(name, key, refs, ref_keys) -> (method, key, candidates)

Resolve one printed name against a reference set prepared by
`_reference_riders`. `key` is `nothing` unless exactly one reference rider
fits. Steps, in order, each applied only when it finds exactly one rider:

1. `:exact` — the key itself.
2. `:depunct` — the key with hyphens and full stops stripped.
3. `:compound` — the same name parts run together differently.
4. `:subset` — one name's parts (particles aside) all among the other's, two
   parts at least.
5. `:surname_given` — the reference rider's surname among the printed parts
   and a `given_compatible` given name.
6. `:surname_typo` — the same given name, a surname of five letters or more
   within two edits.

Two or more candidates at steps 2, 4, 5 or 6 give `:ambiguous` with the
candidates listed; nothing is guessed. There is no step matching a first name
alone: it sent Tim Merlier to Tim Marsman and Jasper Philipsen's price to
Albert Withen Philipsen. vgleague's `matching.py` is a port, held to this by
the golden corpus in `test/fixtures/rider_matching.json`.
"""
function resolve_rider(name::AbstractString, key::AbstractString, refs, ref_keys)
    key in ref_keys && return (:exact, String(key), [String(key)])
    dk = _depunct(key)
    found = [r.key for r in refs if r.depunct == dk]
    length(found) == 1 && return (:depunct, found[1], found)
    length(found) > 1 && return (:ambiguous, nothing, found)

    parts = name_parts(name)
    core = Set(p for p in parts if !(p in NAME_PARTICLES))
    sj, jn = join(sort(parts)), join(parts)
    found = [r.key for r in refs if r.sorted_join == sj || r.join == jn]
    length(found) == 1 && return (:compound, found[1], found)

    found = [
        r.key for r in refs if min(length(r.core), length(core)) >= 2 &&
        (issubset(r.core, core) || issubset(core, r.core))
    ]
    length(found) == 1 && return (:subset, found[1], found)
    length(found) > 1 && return (:ambiguous, nothing, found)

    found = [
        r.key for r in refs if r.surname !== nothing && r.surname in core &&
        any(x -> given_compatible(r.given, x), setdiff(core, (r.surname,)))
    ]
    length(found) == 1 && return (:surname_given, found[1], found)
    length(found) > 1 && return (:ambiguous, nothing, found)

    found = [
        r.key for r in refs if r.given !== nothing && r.given in core &&
        length(r.surname) >= 5 &&
        any(x -> 0 < levenshtein(r.surname, x) <= 2, setdiff(core, (r.given,)))
    ]
    length(found) == 1 && return (:surname_typo, found[1], found)
    length(found) > 1 && return (:ambiguous, nothing, found)
    return (:none, nothing, String[])
end

"""
    resolve_riders(external_df, reference_df) -> Vector of (method, key, candidates)

`resolve_rider` for every row of `external_df` (columns `rider`, `riderkey`)
against `reference_df`, normally the race's field.
"""
function resolve_riders(external_df::DataFrame, reference_df::DataFrame)
    refs, ref_keys = _reference_riders(reference_df.rider, reference_df.riderkey)
    return [
        resolve_rider(String(row.rider), String(row.riderkey), refs, ref_keys) for
        row in eachrow(external_df)
    ]
end

"""
    rematch_riderkeys!(external_df, reference_df)

Rekey each row of `external_df` that `resolve_rider` resolves to one rider of
`reference_df`, normally the race's field. An unresolved or ambiguous row keeps
its printed key and so joins nothing. Handles "Tom Pidcock" (Oddschecker) and
"PIDCOCK Tom" (PCS) against "Thomas Pidcock" (VG), PCS's added middle names,
and compound surnames hyphenated in one source and spaced in the other.

Stripping hyphens in `createkey` instead would be the cleaner layer, but the
permanent archives hold ~112 hyphenated riderkeys that readers join against
freshly computed ones, and prediction archives cannot be re-created, so the
matching lives at read time.
"""
function rematch_riderkeys!(external_df::DataFrame, reference_df::DataFrame)
    results = resolve_riders(external_df, reference_df)
    n_fixed = 0
    n_ambiguous = 0
    for (i, (method, key, _)) in enumerate(results)
        if key !== nothing && method != :exact
            external_df.riderkey[i] = key
            n_fixed += 1
        end
        n_ambiguous += method == :ambiguous
    end
    n_fixed > 0 && @info "Re-matched $n_fixed riders by name"
    n_ambiguous > 0 && @info "$n_ambiguous riders matched more than one reference rider and were left unmatched"
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
