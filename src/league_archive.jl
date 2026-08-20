# ---------------------------------------------------------------------------
# The league tier of the archive (Phase 1b)
# ---------------------------------------------------------------------------
#
# Until August 2026 the league lived in `~/code/vgleague-deploy/data/*.json`:
# gitignored, machine-local, overwritten in place on every scrape and backed up
# by nothing — while `league_winners.toml` sat in the archive as a five-field
# summary of it, existing only because the source of truth was unreliable.
#
# Three tiers replace that, all under `archive_dir()`:
#
#   league/raw/{game_slug}_{year}_{league_id}/{YYYY-MM-DD}.json
#   league/rosters/{game_slug}_{league_id}/{year}.arrow
#   league/meta/{game_slug}_{league_id}/{year}.arrow
#   league/winners/{game_slug}_{league_id}/{year}.arrow
#
# The raw tier is dated and never overwritten because **names mutate at
# source**: the Paris-Roubaix 2026 winner has been called three different things
# in the three copies of the league that survive, so the only honest record is
# what the site said on a given date. The derived tiers are a current-best view
# rebuilt from the newest snapshot on every ingest; winners are the exception
# and are append-only, because a winner is a fact about a particular Sunday.

"""
    league_key(game_slug, league_id) -> String

`{game_slug}_{league_id}`: the slug position of a league's derived archive
files. The year is the filename, as it is for every race type.
"""
league_key(
    game_slug::AbstractString,
    league_id::AbstractString,
) = "$(game_slug)_$(league_id)"

"""
    league_raw_dir(game_slug, year, league_id; archive_dir) -> String

Directory of dated raw snapshots for one league-season. Named for the vgleague
data file it mirrors (`{game_slug}_{year}_{league_id}`), so the two are
recognisably the same thing.
"""
league_raw_dir(
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString;
    archive_dir::String = archive_dir(),
) = joinpath(archive_dir, "league", "raw", "$(game_slug)_$(year)_$(league_id)")

"""
    league_snapshot_dates(game_slug, year, league_id; archive_dir) -> Vector{Date}

Every dated snapshot held for one league-season, ascending.
"""
function league_snapshot_dates(
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString;
    archive_dir::String = archive_dir(),
)
    dir = league_raw_dir(game_slug, year, league_id; archive_dir = archive_dir)
    isdir(dir) || return Date[]
    dates = Date[]
    for f in readdir(dir)
        m = match(r"^(\d{4}-\d{2}-\d{2})\.json$", f)
        m === nothing || push!(dates, Date(m[1]))
    end
    return sort!(dates)
end

"""
    league_snapshot_path(game_slug, year, league_id, date; archive_dir) -> String
"""
league_snapshot_path(
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString,
    date::Date;
    archive_dir::String = archive_dir(),
) = joinpath(
    league_raw_dir(game_slug, year, league_id; archive_dir = archive_dir),
    "$(date).json",
)

"""
    archived_leagues(; archive_dir) -> Vector{@NamedTuple{game_slug::String, year::Int, league_id::String}}

Every league-season with raw snapshots, sorted. The ingest walks the vgleague
data directory; everything downstream walks this instead, so a league added
later needs no code change on either side.
"""
function archived_leagues(; archive_dir::String = archive_dir())
    dir = joinpath(archive_dir, "league", "raw")
    isdir(dir) || return NamedTuple[]
    out = NamedTuple[]
    for e in sort(readdir(dir))
        isdir(joinpath(dir, e)) || continue
        m = match(r"^(.+)_(\d{4})_(.+)$", e)
        m === nothing && continue
        push!(
            out,
            (game_slug = String(m[1]), year = parse(Int, m[2]), league_id = String(m[3])),
        )
    end
    return out
end

"""
    save_league_snapshot(json_text, game_slug, year, league_id; date, dry_run, archive_dir) -> Union{Date, Nothing}

Write one raw league snapshot, dated, and return the date written — or
`nothing` when the content matches the newest snapshot already held.

Deduping on content rather than on the calendar is what keeps this tier to
roughly one file per genuine state change (~40 a year) rather than one per
scrape (~700), and means every file present marks something actually
happening. A second write on the same day overwrites that day's file, so an
intra-day revision replaces rather than accumulates.

`dry_run` returns what a real call would return and writes nothing.
"""
function save_league_snapshot(
    json_text::AbstractString,
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString;
    date::Date = Dates.today(),
    dry_run::Bool = false,
    archive_dir::String = archive_dir(),
)
    dates = league_snapshot_dates(game_slug, year, league_id; archive_dir = archive_dir)
    if !isempty(dates)
        newest = league_snapshot_path(
            game_slug,
            year,
            league_id,
            dates[end];
            archive_dir = archive_dir,
        )
        bytes2hex(sha256(read(newest))) == bytes2hex(sha256(json_text)) && return nothing
    end
    # `dry_run` forks here and nowhere else, so the date it reports is the date
    # a real run would write: the dedupe decision above is the part that could
    # drift, and it is shared.
    dry_run && return date
    path = league_snapshot_path(game_slug, year, league_id, date; archive_dir = archive_dir)
    mkpath(dirname(path))
    atomic_write(p -> write(p, json_text), path)
    return date
end

"""
    load_league_snapshot(game_slug, year, league_id; date, archive_dir) -> Union{JSON3.Object, Nothing}

One raw snapshot, parsed. `date` selects a specific snapshot; omit it for the
newest. `nothing` when the league-season has none.
"""
function load_league_snapshot(
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString;
    date::Union{Date,Nothing} = nothing,
    archive_dir::String = archive_dir(),
)
    if date === nothing
        dates = league_snapshot_dates(game_slug, year, league_id; archive_dir = archive_dir)
        isempty(dates) && return nothing
        date = dates[end]
    end
    path = league_snapshot_path(game_slug, year, league_id, date; archive_dir = archive_dir)
    isfile(path) || return nothing
    return JSON3.read(read(path, String))
end


# ---------------------------------------------------------------------------
# Deriving the tabular tiers from one snapshot
# ---------------------------------------------------------------------------

"""
    league_rosters_frame(snapshot) -> DataFrame

The entrant × race × rider panel: `username, teamname, teamid, race_number,
race_name, rider, cost, score, race_score`.

One row per rider actually picked, so `race_score` (the entrant's total for
that race) repeats down the rider rows — the join key every league stat starts
from, and the thing the old five-field winners record was a summary of.
"""
function league_rosters_frame(snapshot)
    rows = NamedTuple[]
    for (username, team) in pairs(snapshot.teams)
        teamname = String(team.teamname)
        teamid = String(get(team, :teamid, ""))
        for (race_name, race) in pairs(team.races)
            costs = get(race, :rider_costs, nothing)
            scores = get(race, :rider_scores, nothing)
            for rider in get(race, :riders, String[])
                r = String(rider)
                push!(
                    rows,
                    (;
                        username = String(username),
                        teamname = teamname,
                        teamid = teamid,
                        race_number = Int(race.race_number),
                        race_name = String(race_name),
                        rider = r,
                        cost = costs === nothing ? missing :
                               (haskey(costs, Symbol(r)) ? Int(costs[Symbol(r)]) : missing),
                        score = scores === nothing ? missing :
                                (
                            haskey(scores, Symbol(r)) ? Float64(scores[Symbol(r)]) :
                            missing
                        ),
                        race_score = Float64(race.score),
                    ),
                )
            end
        end
    end
    isempty(rows) && return DataFrame(
        username = String[],
        teamname = String[],
        teamid = String[],
        race_number = Int[],
        race_name = String[],
        rider = String[],
        cost = Union{Int,Missing}[],
        score = Union{Float64,Missing}[],
        race_score = Float64[],
    )
    return DataFrame(rows)
end

"""
    league_meta_frame(snapshot) -> DataFrame

The race catalogue: `race_number, race_name, deadline, category, distance`,
plus the league-level `game_slug`, `league_id`, `series_type` and `game_id`
repeated down the rows.

Repeating four constants beats putting them in Arrow metadata because this
table exists to be read from Python, and a reader that has the table has the
league without a second lookup. `deadline` and `category` are strings: a grand
tour has no deadlines at all and calls its categories `road`/`itt`, where the
classics number theirs 1–3.
"""
function league_meta_frame(snapshot)
    meta = snapshot.meta
    game_slug = String(meta.game_slug)
    league_id = String(meta.league_id)
    series_type = String(get(meta, :series_type, ""))
    game_id = string(something(get(meta, :game_id, nothing), ""))

    rows = NamedTuple[]
    for (k, v) in pairs(get(meta, :race_catalogue, Dict()))
        push!(
            rows,
            (;
                race_number = parse(Int, String(k)),
                race_name = String(v["name"]),
                deadline = string(something(get(v, "deadline", nothing), "")),
                category = string(something(get(v, "category", nothing), "")),
                distance = string(something(get(v, "distance", nothing), "")),
                game_slug = game_slug,
                league_id = league_id,
                series_type = series_type,
                game_id = game_id,
            ),
        )
    end
    isempty(rows) && return DataFrame(
        race_number = Int[],
        race_name = String[],
        deadline = String[],
        category = String[],
        distance = String[],
        game_slug = String[],
        league_id = String[],
        series_type = String[],
        game_id = String[],
    )
    return sort!(DataFrame(rows), :race_number)
end

"""
    ingest_league_file(json_path; date, force, dry_run, archive_dir) -> NamedTuple

Take one vgleague JSON file into the archive: date and content-dedupe the raw
snapshot, then rebuild the derived roster and meta tables from the newest
snapshot held.

Returns `(; game_slug, year, league_id, snapshot_date, rebuilt, source_date,
rows)` — `snapshot_date` is `nothing` when the content was already held, which
is the ordinary case on a tick where nothing changed; `rebuilt` says whether the
derived tables were written, and `source_date` which snapshot they came from.

The derived tables are rebuilt from the **newest** snapshot rather than
accumulated across snapshots: they are the current view (latest revised scores,
complete race set) and the dated raw tier is where history lives. Winner
derivation is the one thing that must not read the newest snapshot, and it
reads the raw tier directly — see `derive_league_winners`.

**A tick that changes nothing writes nothing.** The derived tables are a pure
function of the newest snapshot, so an unchanged snapshot cannot change them,
and rewriting an identical file in a Dropbox folder several times a day is how
you get a conflicted copy.

`force` rebuilds them anyway. They are a function of the newest snapshot *and*
of `league_rosters_frame`/`league_meta_frame`, and only the snapshot half is
checked — so changing either function leaves a finished season's table stale for
ever, still present, still readable, and no longer what the code says it is.

`dry_run` reports what a real call would do and writes nothing.
"""
function ingest_league_file(
    json_path::AbstractString;
    date::Date = Dates.today(),
    force::Bool = false,
    dry_run::Bool = false,
    archive_dir::String = archive_dir(),
)
    text = read(json_path, String)
    snapshot = JSON3.read(text)
    meta = snapshot.meta
    game_slug = String(meta.game_slug)
    year = Int(meta.year)
    league_id = String(meta.league_id)

    written = save_league_snapshot(
        text,
        game_slug,
        year,
        league_id;
        date = date,
        dry_run = dry_run,
        archive_dir = archive_dir,
    )

    key = league_key(game_slug, league_id)
    stale =
        force ||
        written !== nothing ||
        !has_race_snapshot("league/rosters", key, year; archive_dir = archive_dir) ||
        !has_race_snapshot("league/meta", key, year; archive_dir = archive_dir)

    # On a dry run the raw snapshot was not written, so the newest one on disk
    # is the previous state; build the frames from the file in hand instead, or
    # the row count reported would be the old one.
    newest =
        dry_run ? snapshot :
        load_league_snapshot(game_slug, year, league_id; archive_dir = archive_dir)
    # Named in the result because `--force` rebuilds from whatever the newest
    # snapshot is: against a pruned raw tier that is a table which looks freshly
    # built and is missing every race after it.
    held = league_snapshot_dates(game_slug, year, league_id; archive_dir = archive_dir)
    source_date = dry_run ? date : (isempty(held) ? nothing : held[end])
    rosters = league_rosters_frame(newest)
    if stale && !dry_run
        save_race_snapshot(rosters, "league/rosters", key, year; archive_dir = archive_dir)
        save_race_snapshot(
            league_meta_frame(newest),
            "league/meta",
            key,
            year;
            archive_dir = archive_dir,
        )
    end

    return (;
        game_slug,
        year,
        league_id,
        snapshot_date = written,
        rebuilt = stale,
        source_date,
        rows = nrow(rosters),
    )
end

"""
    ingest_league_dir(data_dir; date, force, dry_run, archive_dir) -> Vector{NamedTuple}

Ingest every `*.json` in a vgleague data directory. The one place in this
package that reads the vgleague repo; everything else reads the archive.
"""
function ingest_league_dir(
    data_dir::AbstractString;
    date::Date = Dates.today(),
    force::Bool = false,
    dry_run::Bool = false,
    archive_dir::String = archive_dir(),
)
    dir = expanduser(String(data_dir))
    isdir(dir) || error("No vgleague data directory at $dir (has the scrape run?)")
    files = sort(filter(p -> endswith(p, ".json"), readdir(dir; join = true)))
    return [
        ingest_league_file(
            f;
            date = date,
            force = force,
            dry_run = dry_run,
            archive_dir = archive_dir,
        ) for f in files
    ]
end


# ---------------------------------------------------------------------------
# Reading the derived tiers
# ---------------------------------------------------------------------------

"""
    load_league_standings(; game_slug, year, league_id, toml_path=nothing, archive_dir) -> DataFrame

Full league standings from the archive: one row per
`(username, teamname, race_name, race_number, score)`, every entrant's score in
every race the league has scored.

Aggregated from `league/rosters`, so the per-rider panel and the standings can
no longer disagree — they were two readings of the same JSON before, and the
scores that decide the league now come from the same rows the rider stats do.
That has one cost: an entrant who picked nobody for a race has no rows in the
panel and so no standings row, where reading the JSON gave them one on zero. It
has not happened in any snapshot held (0 of 2,077 entrant-races).

If `toml_path` is given and exists, manually-recorded standings
(`data/league_standings.toml`) override any race whose name matches one in the
file (compared via `normalise_race_name`, so a hand-typed variant still wins).
TOML rows record the team display name; where that matches a `teamname` in the
archive, the row takes that entrant's `username` so one entrant keeps a single
identity across sources.
"""
function load_league_standings(;
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString,
    toml_path::Union{AbstractString,Nothing} = nothing,
    archive_dir::String = archive_dir(),
)
    rosters = load_race_snapshot(
        "league/rosters",
        league_key(game_slug, league_id),
        Int(year);
        archive_dir = archive_dir,
    )
    archived =
        rosters === nothing ? DataFrame() :
        combine(
            groupby(rosters, [:username, :teamname, :race_name, :race_number]),
            :race_score => first => :score,
        )

    toml_df =
        (toml_path === nothing || !isfile(toml_path)) ? DataFrame() :
        load_league_standings_toml(toml_path)

    isempty(toml_df) && return archived
    isempty(archived) && return toml_df

    override_races = Set(normalise_race_name.(String.(toml_df.race_name)))
    kept = filter(
        :race_name => (r -> !(normalise_race_name(String(r)) in override_races)),
        archived,
    )
    username_of_team =
        Dict(String(t) => String(u) for (t, u) in zip(archived.teamname, archived.username))
    toml_df.username =
        [get(username_of_team, String(t), String(t)) for t in toml_df.teamname]
    return vcat(kept, toml_df; cols = :union)
end

"""
    load_league_team(; game_slug, year, league_id, username, pcs_slug, archive_dir) -> Vector{String}

The riders `username` actually entered for the race identified by `pcs_slug`.
Returns `String[]` when the league, the entrant or that race is absent —
Velogames hides every team roster until the entry deadline passes, so a lookup
run before the race legitimately comes back empty and the caller should fall
back to a hand-entered team.

League race names are matched to `pcs_slug` through `CLASSICS_RACES_2026`,
which carries the Velogames display names, so the league's own spelling
("Ronde van Brugge", "In Flanders Fields - Middelkerke to Wevelgem") resolves.
Grand tour rosters are locked for the whole tour and recorded against every
stage, so `pcs_slug` is ignored there and the latest stage's roster is
returned.
"""
function load_league_team(;
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString,
    username::AbstractString,
    pcs_slug::AbstractString,
    archive_dir::String = archive_dir(),
)
    rosters = load_race_snapshot(
        "league/rosters",
        league_key(game_slug, league_id),
        Int(year);
        archive_dir = archive_dir,
    )
    rosters === nothing && return String[]
    mine = filter(:username => ==(String(username)), rosters)
    isempty(mine) && return String[]

    if _is_grand_tour_league(game_slug, year, league_id; archive_dir = archive_dir)
        latest = maximum(mine.race_number)
        return String.(filter(:race_number => ==(latest), mine).rider)
    end

    for g in groupby(mine, :race_name)
        league_race_slug(String(g.race_name[1])) == pcs_slug || continue
        return String.(g.rider)
    end
    return String[]
end

function _is_grand_tour_league(
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString;
    archive_dir::String = archive_dir(),
)
    meta = load_race_snapshot(
        "league/meta",
        league_key(game_slug, league_id),
        Int(year);
        archive_dir = archive_dir,
    )
    meta === nothing && return false
    return !isempty(meta) && String(meta.series_type[1]) == "grand_tour"
end

"""PCS slug for a league standings race name, or `""` if it isn't a known classic."""
function league_race_slug(race_name::AbstractString)
    key = normalise_race_name(String(race_name))
    i = findfirst(r -> normalise_race_name(r.name) == key, CLASSICS_RACES_2026)
    return i === nothing ? "" : CLASSICS_RACES_2026[i].pcs_slug
end

"""
    load_league_standings_toml(toml_path::AbstractString) -> DataFrame

Load manually-recorded league standings (fallback for races the `vgleague`
scraper hasn't picked up yet, or hand corrections). Schema:

```toml
[[races]]
name = "Omloop Nieuwsblad"
standings = [
    { team = "Cobbles & Wobbles", score = 1027 },
    { team = "Mud Springs Eternal", score = 965 },
]
```

Same long shape as the archived standings, except `username` is set equal to
`teamname` (manual entries only ever record team names, not VG logins) and
`race_number` is `missing`.
"""
function load_league_standings_toml(toml_path::AbstractString)
    isfile(toml_path) || return DataFrame()
    data = TOML.parsefile(toml_path)

    rows = NamedTuple[]
    for race in get(data, "races", [])
        race_name = race["name"]
        for standing in race["standings"]
            push!(
                rows,
                (;
                    username = standing["team"],
                    teamname = standing["team"],
                    race_name = race_name,
                    race_number = missing,
                    score = Float64(standing["score"]),
                ),
            )
        end
    end
    isempty(rows) && return DataFrame()
    return DataFrame(rows)
end


# ---------------------------------------------------------------------------
# Winners
# ---------------------------------------------------------------------------

"""
    load_league_winners(; archive_dir) -> Vector{@NamedTuple{pcs_slug::String, year::Int, name::String, score::Int}}

Every recorded league winner, across every archived league-season, sorted by
race then year. Empty when nothing has been recorded.

Replaces the hand-maintained `league_winners.toml`, which existed only because
the league snapshots lived somewhere nothing backed up. Same return shape, so
the renderers and `league_eval.jl` read it unchanged.
"""
function load_league_winners(; archive_dir::String = archive_dir())
    out = NamedTuple[]
    for key in archive_races("league/winners"; archive_dir = archive_dir)
        for year in archive_years("league/winners", key; archive_dir = archive_dir)
            df = load_race_snapshot("league/winners", key, year; archive_dir = archive_dir)
            df === nothing && continue
            for r in eachrow(df)
                push!(
                    out,
                    (
                        pcs_slug = String(r.pcs_slug),
                        year = Int(r.year),
                        name = String(r.teamname),
                        score = Int(round(r.score)),
                    ),
                )
            end
        end
    end

    # Readers key on `(pcs_slug, year)` — `render_reports.jl` builds a Dict
    # comprehension off it — so a race recorded by two league-seasons does not
    # collide, it silently keeps whichever was walked last. Nothing downstream
    # can notice, so say it here.
    counts = Dict{Tuple{String,Int},Int}()
    for w in out
        counts[(w.pcs_slug, w.year)] = get(counts, (w.pcs_slug, w.year), 0) + 1
    end
    dupes = sort([k for (k, n) in counts if n > 1])
    isempty(dupes) ||
        @warn "league/winners records more than one winner for $(length(dupes)) race-year(s); readers that key on (pcs_slug, year) will keep an arbitrary one" dupes

    return sort!(out; by = w -> (w.pcs_slug, w.year))
end

"""
    league_winners_frame(game_slug, year, league_id; archive_dir) -> DataFrame

The winners table for one league-season, empty-but-typed when absent.
"""
function league_winners_frame(
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString;
    archive_dir::String = archive_dir(),
)
    df = load_race_snapshot(
        "league/winners",
        league_key(game_slug, league_id),
        Int(year);
        archive_dir = archive_dir,
    )
    df === nothing || return df
    return DataFrame(
        pcs_slug = String[],
        year = Int[],
        race_number = Int[],
        username = String[],
        teamname = String[],
        score = Float64[],
        snapshot_date = String[],
    )
end

"""
    append_league_winners(df, game_slug, year, league_id; archive_dir) -> Nothing

Add rows to a league-season's winners table.

Append-only, and the reason is the same one that made the raw tier dated: a
winner is a fact about a particular Sunday, and entrants rename their teams.
Re-deriving Paris-Roubaix 2026 today gives a name the winner adopted months
later, and re-deriving it from the oldest snapshot still on disk gives a third
name; only the entry written the week of the race is right. Use
`remove_league_winner` to unpick one that went in wrong.

Read-modify-write, and `save_race_snapshot`'s atomic rename does not make it
safe against a concurrent writer: two runs that each read the same table and
append one row produce a file with whichever row was written last, and the
other winner is gone for good — silently, because a winner is never re-derived
and nothing will notice the gap. `.velogames-publish.lock` is what serialises
that, and it is per-clone, so a second machine publishing into the same Dropbox
archive is still unguarded.
"""
function append_league_winners(
    df::DataFrame,
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString;
    archive_dir::String = archive_dir(),
)
    isempty(df) && return nothing
    existing = league_winners_frame(game_slug, year, league_id; archive_dir = archive_dir)
    combined = vcat(existing, df; cols = :union)
    save_race_snapshot(
        combined,
        "league/winners",
        league_key(game_slug, league_id),
        Int(year);
        archive_dir = archive_dir,
    )
    return nothing
end

"""
    remove_league_winner(pcs_slug, game_slug, year, league_id; archive_dir) -> Int

Drop a race's recorded winner so it can be derived again. Returns how many rows
went.

A winner is recorded once and never re-derived, which is right — but it means
one that went in wrong is wrong for ever, and the alternative repair is editing
an Arrow file by hand, which no text editor does. Pair it with
`auto_publish.jl --redrive=<slug>`, which removes the row and re-derives it in
the same run.

**Seeded rows are refused.** The 29 winners carried across when the league moved
into the archive have an empty `snapshot_date` because no snapshot on disk
predates them; four of them are reproducible from nothing else at all. Removing
one destroys the only record there is, so the caller has to go and do that
deliberately.
"""
function remove_league_winner(
    pcs_slug::AbstractString,
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString;
    archive_dir::String = archive_dir(),
)
    existing = league_winners_frame(game_slug, year, league_id; archive_dir = archive_dir)
    isempty(existing) && return 0

    matches = r -> String(r.pcs_slug) == String(pcs_slug)
    hit = filter(matches, existing)
    isempty(hit) && return 0

    if any(isempty(String(d)) for d in hit.snapshot_date)
        error(
            "remove_league_winner: $pcs_slug $year in $game_slug/$league_id is a seeded row " *
            "(no snapshot_date). It was carried across when the league moved into the archive " *
            "and no raw snapshot on disk can re-derive it, so removing it would destroy the " *
            "only record. Edit the winners table by hand if that is really what you want.",
        )
    end

    kept = filter(!matches, existing)
    save_race_snapshot(
        kept,
        "league/winners",
        league_key(game_slug, league_id),
        Int(year);
        archive_dir = archive_dir,
    )
    return nrow(hit)
end

"""Winner row of a standings frame, ties broken by name so a re-run agrees with itself."""
_top_entrant(df, score_col) = sort(df, [order(score_col, rev = true), :teamname])[1, :]

"""
    derive_league_winners(game_slug, year, league_id; min_age_hours, now, archive_dir) -> DataFrame

Winners the archive can now record for one league-season but hasn't yet, each
read from **the earliest raw snapshot that satisfies the publishing gate** —
the snapshot a run on the day would have used, not the newest one. Deriving
from the newest would rewrite history every time an entrant renamed their team,
which is the whole reason the raw tier is dated.

The gates are the ones `auto_publish.jl` has always applied:

  * a classic waits `min_age_hours` (24 by default) past its pick deadline,
    because Velogames revises scores for about a day afterwards;
  * a grand tour is one entry for the whole tour and waits until **every** race
    in its catalogue is scored, End-of-Tour included — until then the
    cumulative totals are a partial sum and the leader is not the winner. Grand
    tour catalogues carry no deadlines, so that structural test replaces the
    age gate rather than adding to it;
  * a race whose top score is 0 is skipped: `ridescore.php` serves the full
    roster at zero for a race nobody has been scored in yet.
"""
function derive_league_winners(
    game_slug::AbstractString,
    year::Integer,
    league_id::AbstractString;
    min_age_hours::Real = 24,
    now::DateTime = Dates.now(),
    archive_dir::String = archive_dir(),
)
    dates = league_snapshot_dates(game_slug, year, league_id; archive_dir = archive_dir)
    isempty(dates) && return DataFrame()

    recorded = league_winners_frame(game_slug, year, league_id; archive_dir = archive_dir)
    have = Set(String.(recorded.pcs_slug))

    newest = load_league_snapshot(game_slug, year, league_id; archive_dir = archive_dir)
    series = String(get(newest.meta, :series_type, ""))

    if series == "classics"
        return _derive_classics_winners(
            game_slug,
            year,
            league_id,
            dates,
            have,
            min_age_hours,
            now,
            archive_dir,
        )
    elseif series == "grand_tour"
        return _derive_grand_tour_winner(
            game_slug,
            year,
            league_id,
            dates,
            have,
            newest,
            min_age_hours,
            now,
            archive_dir,
        )
    end
    @info "skip $game_slug $year: unknown series_type $(repr(series))"
    return DataFrame()
end

"""Deadlines by race number, from a snapshot's own catalogue — the only thing in it that dates a classic."""
function _league_deadlines(snapshot)
    return Dict{Int,DateTime}(
        parse(Int, String(k)) => DateTime(String(v["deadline"]), "yyyy-mm-dd HH:MM:SS") for
        (k, v) in pairs(get(snapshot.meta, :race_catalogue, Dict())) if
        get(v, "deadline", nothing) !== nothing
    )
end

"""One winner row from a race group in a dated snapshot, or `nothing` when nobody has scored.

A top score of 0 means the race has not been scored: `ridescore.php` serves the
full roster at zero both before a race and after one nobody has been scored in.
"""
function _winner_row(g, slug, year, date)
    top = _top_entrant(DataFrame(g), :score)
    top.score <= 0 && return nothing
    return (;
        pcs_slug = slug,
        year = Int(year),
        race_number = Int(g.race_number[1]),
        username = String(top.username),
        teamname = String(top.teamname),
        score = Float64(top.score),
        snapshot_date = string(date),
    )
end

"""Race groups of a standings frame, in race order."""
_race_groups(standings) =
    isempty(standings) ? [] :
    sort(collect(groupby(standings, :race_name)); by = g -> g.race_number[1])

function _derive_classics_winners(
    game_slug,
    year,
    league_id,
    dates,
    have,
    min_age_hours,
    now,
    archive_dir,
)
    rows = NamedTuple[]
    seen = copy(have)
    # Accumulated oldest-first so the diagnostic pass below can date a race the
    # newest catalogue has since dropped — the live classics catalogue has
    # already shrunk once, from 44 entries to 43.
    all_deadlines = Dict{Int,DateTime}()
    load(d) = load_league_snapshot(
        game_slug,
        year,
        league_id;
        date = d,
        archive_dir = archive_dir,
    )

    for date in dates
        snapshot = load(date)
        standings = _snapshot_standings(snapshot)
        isempty(standings) && continue
        deadlines = _league_deadlines(snapshot)
        merge!(all_deadlines, deadlines)

        for g in _race_groups(standings)
            slug = league_race_slug(String(g.race_name[1]))
            (isempty(slug) || slug in seen) && continue

            deadline = get(deadlines, g.race_number[1], nothing)
            deadline === nothing && continue
            (now - deadline) / Hour(1) < min_age_hours && continue
            # The snapshot itself must postdate the settling window too, or an
            # early capture would freeze a pre-revision score just because a
            # later run is the one doing the deriving. A snapshot dated D was
            # taken at some unrecorded time during D, so it is read as the start
            # of D: erring towards a later snapshot costs a fresher team name,
            # erring the other way costs a wrong score.
            (DateTime(date) - deadline) / Hour(1) < min_age_hours && continue

            row = _winner_row(g, slug, year, date)
            row === nothing && continue
            push!(rows, row)
            push!(seen, slug)
        end
    end

    _report_unsettled_classics(
        load(dates[end]),
        dates[end],
        seen,
        all_deadlines,
        min_age_hours,
        now,
    )

    isempty(rows) && return DataFrame()
    return DataFrame(rows)
end

"""Say, once per race, why a scored classic has no winner recorded.

Nothing here publishes anything — the gates above are deliberately strict, and a
race they hold back stays held back. What this closes is that they held it back
in silence.

The reporting lives outside the loop above because that loop runs once per
snapshot date: an `@info` in there prints one line per snapshot per race, which
for a permanent defect is forty identical lines a run and is how a real warning
stops being read.

The case worth knowing about is the season's last classic. `save_league_snapshot`
dedupes on content, so a snapshot exists only where something changed; once the
final race's scores settle nothing changes again, and no snapshot dated a full
settling window past its deadline is ever written. The gate can then never be
satisfied and `render_reports.jl` renders only a race that has a winner, so that
report would never appear. The remedy is a one-off run at a lower threshold, and
the message works out which threshold, because the obvious guess is wrong: a
snapshot dated the race day is *negative* hours from an 11:00 deadline, so
`--min-age-hours=0` does not rescue it.
"""
function _report_unsettled_classics(
    newest,
    newest_date,
    seen,
    all_deadlines,
    min_age_hours,
    now,
)
    for g in _race_groups(_snapshot_standings(newest))
        race_name = String(g.race_name[1])
        slug = league_race_slug(race_name)
        if isempty(slug)
            @info "skip $race_name: not a known classic (missing from CLASSICS_RACES_2026?)"
            continue
        end
        slug in seen && continue
        # An unscored race is not a blocked one.
        maximum(g.score) <= 0 && continue

        deadline = get(all_deadlines, g.race_number[1], nothing)
        if deadline === nothing
            @info "skip $slug: no deadline in any snapshot's race catalogue, so its age can't be checked"
            continue
        end
        (now - deadline) / Hour(1) < min_age_hours && continue

        gap = (DateTime(newest_date) - deadline) / Hour(1)
        if gap < min_age_hours
            @info "skip $slug: no snapshot postdates its deadline by $(min_age_hours)h — the newest ($newest_date) is $(round(Int, gap))h past it, and content dedupe means no later one is coming. Settle it by hand with: julia --project scripts/auto_publish.jl --min-age-hours=$(floor(Int, gap))"
        end
    end
    return nothing
end

"""Velogames games have their own slugs, unrelated to PCS's.

Only the games that exist are listed: an unmapped one warns and is skipped
rather than being guessed at, so a game nobody here has seen yet announces
itself in the log instead of publishing under a wrong race. The slugs are
Velogames' own and are not guessable — the Vuelta's is `spain`.
"""
const GT_PCS_SLUG = Dict(
    "velogame" => "tour-de-france",
    "italy" => "giro-d-italia",
    "velogame-femmes" => "tour-de-france-femmes",
    "spain" => "vuelta-a-espana",
)

"""Race numbers in a snapshot's own catalogue."""
_catalogue_numbers(snapshot) =
    Set(parse(Int, String(k)) for k in keys(get(snapshot.meta, :race_catalogue, Dict())))

function _derive_grand_tour_winner(
    game_slug,
    year,
    league_id,
    dates,
    have,
    newest,
    min_age_hours,
    now,
    archive_dir,
)
    slug = get(GT_PCS_SLUG, String(game_slug), "")
    if isempty(slug)
        @info "skip $game_slug $year: no PCS slug mapped for that Velogames game (add it to GT_PCS_SLUG)"
        return DataFrame()
    end
    slug in have && return DataFrame()

    # A tour is settled from a catalogue that has stopped growing, and neither
    # half of that is optional.
    #
    # The catalogue itself grows: End-of-Tour is added when the tour finishes,
    # so a snapshot taken between the last stage being scored and that entry
    # appearing lists every race it knows about as scored. Testing each snapshot
    # against its own catalogue therefore passes on a partial total. On the 2026
    # Giro that is 1,680 points, 20% of the winning total, on a race decided by
    # 33 — and it reorders second through fifth. So gate on the newest
    # catalogue. Newest rather than the union of every catalogue: a cancelled
    # stage dropped from the list would otherwise be required for ever and the
    # tour would never publish at all.
    #
    # And the newest catalogue is only trustworthy once it has settled. Publish
    # runs on every vgleague tick, so a run landing inside that window sees the
    # partial catalogue as the newest one and the first test cannot help. Content
    # dedupe means the newest snapshot's date is the last day anything moved, so
    # requiring a full settling window since then is what makes the window
    # unreachable rather than merely unlikely. Wall-clock age always grows, so
    # unlike the classics gate this one cannot deadlock.
    (now - DateTime(dates[end])) / Hour(1) < min_age_hours && return DataFrame()
    catalogue = _catalogue_numbers(newest)

    for date in dates
        snapshot = load_league_snapshot(
            game_slug,
            year,
            league_id;
            date = date,
            archive_dir = archive_dir,
        )
        standings = _snapshot_standings(snapshot)
        isempty(standings) && continue

        isempty(setdiff(catalogue, Set(Int.(standings.race_number)))) || continue

        totals =
            combine(groupby(standings, [:username, :teamname]), :score => sum => :score)
        top = _top_entrant(totals, :score)
        top.score <= 0 && continue
        return DataFrame([(;
            pcs_slug = slug,
            year = Int(year),
            race_number = 0,
            username = String(top.username),
            teamname = String(top.teamname),
            score = Float64(top.score),
            snapshot_date = string(date),
        )])
    end
    @info "skip $slug $year: no snapshot has all $(length(catalogue)) races of the current catalogue scored"
    return DataFrame()
end

"""Per-entrant, per-race scores straight out of one raw snapshot.

Winner derivation reads the JSON rather than `league/rosters` because the
derived table is rebuilt from the newest snapshot; the point of the exercise is
to read an old one.
"""
function _snapshot_standings(snapshot)
    rows = NamedTuple[]
    for (username, team) in pairs(snapshot.teams)
        teamname = String(team.teamname)
        for (race_name, race) in pairs(team.races)
            push!(
                rows,
                (;
                    username = String(username),
                    teamname = teamname,
                    race_name = String(race_name),
                    race_number = Int(race.race_number),
                    score = Float64(race.score),
                ),
            )
        end
    end
    isempty(rows) && return DataFrame()
    return DataFrame(rows)
end
