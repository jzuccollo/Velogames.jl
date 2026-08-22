"""
Race setup and configuration helpers.

This module provides utilities to quickly set up race analysis with
standard URL patterns and configurations for common races.
"""

# ---------------------------------------------------------------------------
# Race metadata (single source of truth)
# ---------------------------------------------------------------------------

"""
    RaceInfo

Metadata for a one-day classics race: name, template date, scoring category,
PCS slug, terrain-similar races, and total race distance in km.
"""
struct RaceInfo
    name::String
    date::String
    category::Int
    pcs_slug::String
    similar_races::Vector{String}
    total_distance_km::Float64
end

# Convenience constructors
RaceInfo(name, date, category, pcs_slug, similar_races) =
    RaceInfo(name, date, category, pcs_slug, similar_races, 0.0)
RaceInfo(name, date, category, pcs_slug) =
    RaceInfo(name, date, category, pcs_slug, String[], 0.0)

"""Complete 2026 Sixes Classics race schedule with categories, PCS slugs, terrain similarity, and distances."""
const CLASSICS_RACES_2026 = [
    # Flemish hilly (bergs + short cobbled sections)
    RaceInfo(
        "Omloop Nieuwsblad",
        "2026-02-28",
        2,
        "omloop-het-nieuwsblad",
        [
            "e3-harelbeke",
            "gent-wevelgem",
            "dwars-door-vlaanderen",
            "classic-brugge-de-panne",
        ],
        200.0,
    ),
    RaceInfo(
        "Kuurne - Brussel - Kuurne",
        "2026-03-01",
        3,
        "kuurne-brussel-kuurne",
        ["scheldeprijs", "classic-brugge-de-panne", "paris-tours"],
        197.0,
    ),
    RaceInfo(
        "Trofeo Laigueglia",
        "2026-03-04",
        3,
        "trofeo-laigueglia",
        ["gran-piemonte", "coppa-sabatini"],
        204.0,
    ),
    RaceInfo(
        "Strade Bianche",
        "2026-03-07",
        2,
        "strade-bianche",
        [
            "il-lombardia",
            "liege-bastogne-liege",
            "amstel-gold-race",
            "dwars-door-het-hageland",
        ],
        215.0,
    ),
    RaceInfo(
        "Danilith Nokere Koerse",
        "2026-03-18",
        3,
        "nokere-koerse",
        ["kuurne-brussel-kuurne", "classic-brugge-de-panne", "scheldeprijs"],
        192.0,
    ),
    RaceInfo(
        "Milano-Sanremo",
        "2026-03-21",
        1,
        "milano-sanremo",
        ["san-sebastian", "gp-quebec", "bretagne-classic"],
        294.0,
    ),
    RaceInfo(
        "Ronde Van Brugge",
        "2026-03-25",
        2,
        "classic-brugge-de-panne",
        ["gent-wevelgem", "scheldeprijs", "kuurne-brussel-kuurne"],
        201.0,
    ),
    RaceInfo(
        "E3 Saxo Classic",
        "2026-03-27",
        2,
        "e3-harelbeke",
        [
            "omloop-het-nieuwsblad",
            "ronde-van-vlaanderen",
            "dwars-door-vlaanderen",
            "gent-wevelgem",
        ],
        204.0,
    ),
    RaceInfo(
        # VG's name for Gent-Wevelgem 2026 (races.php and league pages agree;
        # there is no "From" — the previous name here never matched either).
        "In Flanders Fields - Middelkerke to Wevelgem",
        "2026-03-29",
        2,
        "gent-wevelgem",
        [
            "omloop-het-nieuwsblad",
            "e3-harelbeke",
            "classic-brugge-de-panne",
            "dwars-door-vlaanderen",
        ],
        253.0,
    ),
    RaceInfo(
        "Dwars door Vlaanderen",
        "2026-04-01",
        2,
        "dwars-door-vlaanderen",
        ["e3-harelbeke", "omloop-het-nieuwsblad", "ronde-van-vlaanderen", "gent-wevelgem"],
        183.0,
    ),
    RaceInfo(
        "Ronde van Vlaanderen",
        "2026-04-05",
        1,
        "ronde-van-vlaanderen",
        ["e3-harelbeke", "dwars-door-vlaanderen", "omloop-het-nieuwsblad"],
        273.0,
    ),
    RaceInfo(
        "Scheldeprijs",
        "2026-04-08",
        3,
        "scheldeprijs",
        ["kuurne-brussel-kuurne", "classic-brugge-de-panne", "cyclassics-hamburg"],
        198.0,
    ),
    RaceInfo(
        "Paris-Roubaix",
        "2026-04-12",
        1,
        "paris-roubaix",
        ["e3-harelbeke", "ronde-van-vlaanderen", "dwars-door-vlaanderen"],
        257.0,
    ),
    # Ardennes hilly (steep punchy climbs)
    RaceInfo(
        "De Brabantse Pijl",
        "2026-04-17",
        3,
        "brabantse-pijl",
        ["la-fleche-wallonne", "amstel-gold-race", "liege-bastogne-liege"],
        203.0,
    ),
    RaceInfo(
        "Amstel Gold Race",
        "2026-04-19",
        1,
        "amstel-gold-race",
        ["la-fleche-wallonne", "liege-bastogne-liege", "brabantse-pijl"],
        253.0,
    ),
    RaceInfo(
        "La Fleche Wallonne",
        "2026-04-22",
        2,
        "la-fleche-wallonne",
        ["amstel-gold-race", "brabantse-pijl"],
        202.0,
    ),
    RaceInfo(
        "Liege-Bastogne-Liege",
        "2026-04-26",
        1,
        "liege-bastogne-liege",
        ["la-fleche-wallonne", "amstel-gold-race", "brabantse-pijl"],
        257.0,
    ),
    RaceInfo(
        "Eschborn-Frankfurt",
        "2026-05-01",
        2,
        "eschborn-frankfurt",
        ["cyclassics-hamburg", "gp-quebec", "bretagne-classic", "brabantse-pijl"],
        238.0,
    ),
    # French regional
    RaceInfo(
        "Grand Prix du Morbihan",
        "2026-05-09",
        3,
        "gp-de-plumelec",
        ["bretagne-classic", "la-fleche-wallonne", "brabantse-pijl"],
        190.0,
    ),
    RaceInfo(
        "Tro-Bro Leon",
        "2026-05-10",
        3,
        "tro-bro-leon",
        ["dwars-door-het-hageland", "paris-tours", "kuurne-brussel-kuurne"],
        197.0,
    ),
    RaceInfo(
        "Classique Dunkerque",
        "2026-05-19",
        3,
        "classique-dunkerque",
        ["scheldeprijs", "kuurne-brussel-kuurne", "circuit-franco-belge", "paris-tours"],
        200.0,
    ),
    # Belgian hilly
    RaceInfo(
        "Brussels Cycling Classic",
        "2026-06-07",
        3,
        "brussels-cycling-classic",
        ["scheldeprijs", "kuurne-brussel-kuurne", "cyclassics-hamburg", "paris-tours"],
        201.0,
    ),
    RaceInfo(
        "Circuit Franco-Belge",
        "2026-06-10",
        3,
        "circuit-franco-belge",
        ["kuurne-brussel-kuurne", "gp-de-wallonie", "super-8-classic"],
        185.0,
    ),
    RaceInfo(
        "Duracell Dwars door het Hageland",
        "2026-06-13",
        3,
        "dwars-door-het-hageland",
        ["strade-bianche", "tro-bro-leon", "dwars-door-vlaanderen"],
        205.0,
    ),
    # Flat sprint
    RaceInfo(
        "Copenhagen Sprint",
        "2026-06-14",
        2,
        "copenhagen-sprint",
        [
            "scheldeprijs",
            "classic-brugge-de-panne",
            "brussels-cycling-classic",
            "paris-tours",
        ],
        178.0,
    ),
    # Punchy hilly (mixed terrain, moderate climbs)
    RaceInfo(
        "Donostia San Sebastian Klasikoa",
        "2026-08-01",
        2,
        "san-sebastian",
        ["bretagne-classic", "gp-quebec", "gp-montreal"],
        218.0,
    ),
    RaceInfo(
        "ADAC Cyclassics Hamburg",
        "2026-08-16",
        2,
        "cyclassics-hamburg",
        ["eschborn-frankfurt", "scheldeprijs", "paris-tours"],
        231.0,
    ),
    RaceInfo(
        "Bretagne Classic - CIC",
        "2026-08-30",
        2,
        "bretagne-classic",
        ["san-sebastian", "gp-quebec"],
        249.0,
    ),
    RaceInfo(
        "GP Industria & Artigianato",
        "2026-09-06",
        3,
        "gp-industria-e-artigianato-di-larciano",
        ["coppa-sabatini", "coppa-bernocchi"],
        185.0,
    ),
    RaceInfo(
        "Coppa Sabatini",
        "2026-09-10",
        3,
        "coppa-sabatini",
        ["giro-dell-emilia", "trofeo-laigueglia"],
        197.0,
    ),
    RaceInfo(
        "Grand Prix Cycliste de Quebec",
        "2026-09-11",
        2,
        "gp-quebec",
        ["gp-montreal", "san-sebastian", "bretagne-classic"],
        203.0,
    ),
    RaceInfo(
        "Grand Prix Cycliste de Montreal",
        "2026-09-13",
        2,
        "gp-montreal",
        ["gp-quebec", "san-sebastian", "amstel-gold-race"],
        224.0,
    ),
    RaceInfo(
        "Lotto Grand Prix de Wallonie",
        "2026-09-16",
        3,
        "gp-de-wallonie",
        ["la-fleche-wallonne", "brabantse-pijl"],
        199.0,
    ),
    RaceInfo(
        "SUPER 8 Classic",
        "2026-09-19",
        3,
        "super-8-classic",
        ["brussels-cycling-classic", "dwars-door-het-hageland"],
        181.0,
    ),
    RaceInfo(
        "World Championships - Elite Road Race",
        "2026-09-27",
        1,
        "world-championship",
        String[],
        270.0,
    ),
    # Italian/European autumn classics
    RaceInfo(
        "Giro dell'Emilia",
        "2026-10-03",
        3,
        "giro-dell-emilia",
        ["il-lombardia", "tre-valli-varesine", "coppa-sabatini"],
        197.0,
    ),
    RaceInfo(
        "European Championships - Elite Road Race",
        "2026-10-04",
        2,
        "uec-road-european-championships-me",
        ["world-championship", "gp-quebec", "gp-montreal"],
        230.0,
    ),
    RaceInfo(
        "Coppa Bernocchi",
        "2026-10-05",
        3,
        "coppa-bernocchi",
        ["tre-valli-varesine", "gran-piemonte"],
        180.0,
    ),
    RaceInfo(
        "Tre Valli Varesine",
        "2026-10-06",
        3,
        "tre-valli-varesine",
        ["giro-dell-emilia", "il-lombardia", "gran-piemonte"],
        193.0,
    ),
    RaceInfo(
        "Gran Piemonte",
        "2026-10-08",
        3,
        "gran-piemonte",
        ["tre-valli-varesine", "giro-dell-emilia"],
        197.0,
    ),
    RaceInfo(
        "Il Lombardia",
        "2026-10-10",
        1,
        "il-lombardia",
        ["giro-dell-emilia", "tre-valli-varesine", "gran-piemonte"],
        247.0,
    ),
    RaceInfo(
        "Paris - Tours Elite",
        "2026-10-11",
        3,
        "paris-tours",
        ["kuurne-brussel-kuurne", "eschborn-frankfurt", "scheldeprijs"],
        234.0,
    ),
    RaceInfo(
        "Giro del Veneto",
        "2026-10-14",
        3,
        "giro-del-veneto",
        ["veneto-classic", "gran-piemonte"],
        183.0,
    ),
    RaceInfo(
        "Veneto Classic",
        "2026-10-18",
        3,
        "veneto-classic",
        ["giro-del-veneto", "gran-piemonte"],
        174.0,
    ),
]

"""Terrain-similar race mapping, derived from `CLASSICS_RACES_2026`."""
const SIMILAR_RACES = Dict{String,Vector{String}}(
    ri.pcs_slug => ri.similar_races for
    ri in CLASSICS_RACES_2026 if !isempty(ri.similar_races)
)

"""
    find_race(name::String) -> Union{RaceInfo, Nothing}

Find a race in the classics schedule by partial name match (case-insensitive).
Returns the first matching RaceInfo or nothing.
"""
function find_race(name::String)
    ri = _find_race_by_slug(name)
    ri !== nothing && return ri
    name_norm = replace(lowercase(name), r"[-\s]" => "")
    for race in CLASSICS_RACES_2026
        # `startswith`, not `occursin`: a substring match resolved "Tour" to
        # Paris-Tours Elite, since "tour" appears mid-name.
        if startswith(replace(lowercase(race.name), r"[-\s]" => ""), name_norm)
            return race
        end
    end
    return nothing
end


# ---------------------------------------------------------------------------
# Race configuration
# ---------------------------------------------------------------------------

"""
Race configuration data structure.

Fields:
- `name`: Race identifier used for setup
- `year`: Race year
- `type`: `:stage` or `:oneday`
- `slug`: VG URL slug
- `current_url`: Full VG riders page URL
- `team_size`: Number of riders to select (6 for one-day, 9 for stage)
- `cache`: Cache configuration
- `category`: VG scoring category (1, 2, or 3). 0 = unknown/not applicable.
- `pcs_slug`: PCS race identifier for historical lookups. Empty string if unknown.
- `total_distance_km`: Total race distance in km (used for breakaway sector calculation). 0.0 if unknown.
"""
struct RaceConfig
    name::String
    year::Int
    type::Symbol
    slug::String
    current_url::String
    team_size::Int
    cache::CacheConfig
    category::Int
    pcs_slug::String
    total_distance_km::Float64
end

"""
    setup_race(race_name::String, year::Int, race_type::Symbol=:auto; cache_config::CacheConfig=DEFAULT_CACHE)

Quick setup for a new race prediction or historical analysis.

Returns a RaceConfig with standard URLs and settings for common races.

# Arguments
- `race_name::String`: Race identifier (e.g., "tdf", "vuelta", "giro", "liege", "roubaix")
- `year::Int`: Year of the race
- `race_type::Symbol`: `:stage`, `:oneday`, or `:auto` (default). `:auto` infers the
  type from the race pattern — classics races (category > 0) are one-day, others are stage.
- `cache_config::CacheConfig`: Cache configuration (default: `DEFAULT_CACHE`)

# Returns
- `RaceConfig`: Configuration object with URLs, cache settings, and team size

# Examples
```julia
# Set up Vuelta 2025 stage race
race = setup_race("vuelta", 2025, :stage)
riders = getvg_riders(race.current_url, cache_config=race.cache)

# Set up Paris-Roubaix 2025 — auto-detected as one-day
race = setup_race("roubaix", 2025)
```

# Supported Races
Stage races: tdf, vuelta, giro
One-day races: liege, roubaix, flanders, lombardia, sanremo, amstel, fleche
"""
function setup_race(
    race_name::String,
    year::Int,
    race_type::Symbol = :auto;
    cache_config::CacheConfig = DEFAULT_CACHE,
)
    # Get URL pattern for this race (includes schedule fallback)
    pattern = get_url_pattern(race_name; year = year)

    # Build the current URL
    current_url = replace(pattern.template, "{year}" => string(year))

    category = pattern.category
    pcs_slug = pattern.pcs_slug

    # Auto-detect race type: classics races (category > 0) are one-day
    if race_type == :auto
        race_type = category > 0 ? :oneday : :stage
    end
    team_size = race_type == :stage ? 9 : 6

    total_distance_km = pattern.total_distance_km

    # Create and display config
    config = RaceConfig(
        race_name,
        year,
        race_type,
        pattern.slug,
        current_url,
        team_size,
        cache_config,
        category,
        pcs_slug,
        total_distance_km,
    )

    type_str = race_type == :stage ? "Stage Race" : "One-Day Race"
    scoring_str = category > 0 ? "Cat $category" : "unclassed"
    @info "Race setup" race = titlecase(race_name) year type = type_str team_size scoring =
        scoring_str pcs_slug url = current_url cache_ttl = "$(cache_config.max_age_hours)h"

    return config
end


# ---------------------------------------------------------------------------
# Render configuration (data/race_config.toml)
# ---------------------------------------------------------------------------

"""
Everything a render script needs that `RaceConfig` does not already derive from
the race itself: the tuning knobs, the parsed bookmaker markets, and the output
location.

Built once by `load_render_config`, so every renderer and the local server hand
the solvers an identical argument set. The bookmaker markets are stored parsed
rather than as filenames — assembling them at each call site is what previously
let `render_assessor.jl` run without the odds the other renderers used.
"""
struct RenderConfig
    race::RaceConfig
    racehash::String
    output_dir::String
    oracle_url::String
    points_oracle_url::String
    kom_oracle_url::String
    odds_df::Union{DataFrame,Nothing}
    points_odds_df::Union{DataFrame,Nothing}
    kom_odds_df::Union{DataFrame,Nothing}
    stagewin_odds_df::Union{DataFrame,Nothing}
    season_round_slugs::Vector{String}
    n_resamples::Int
    history_years::Int
    domestique_discount::Float64
    risk_aversion::Float64
    max_per_team::Int
    simulation_df::Union{Int,Nothing}
    excluded_riders::Vector{String}
    market_blend_weight::Float64
    n_alternatives::Int
    cross_stage_alpha::Float64
    pcs_stage_scrape::Bool
    use_gt_vg_history::Bool
    use_gt_vg_propensity::Bool
    gt_vg_propensity_mode::Symbol
    vg_race_number::Int
    my_team::Vector{String}
    breakaway_dir::String
    fresh::Bool
end

function _parse_paste_file(path::String)
    isfile(path) || return nothing
    try
        return parse_oddschecker_odds(read(path, String))
    catch e
        @warn "Failed to parse $(basename(path)): $e"
        return nothing
    end
end

"""
The team the assessor treats as "yours". Normally the hand-entered
`[team_assessor] my_team`, but with `use_league_team` set it is pulled from the
archived roster of the `[league]` you play in, so the roster does not have to
be retyped after entry. Velogames publishes team rosters only once the entry
deadline has passed, so the pull comes back empty before the race — the
hand-entered list stands in, with a warning saying why.
"""
function _resolve_my_team(cfg::AbstractDict, ta::AbstractDict, race::RaceConfig)
    my_team = String[x for x in get(ta, "my_team", String[])]
    get(ta, "use_league_team", false) || return my_team

    league = get(cfg, "league", Dict{String,Any}())
    if isempty(league)
        @warn "use_league_team is set but there is no [league] section — using [team_assessor] my_team."
        return my_team
    end

    league_team = load_league_team(;
        game_slug = league["game_slug"],
        year = league["year"],
        league_id = string(league["league_id"]),
        username = league["user_name"],
        pcs_slug = race.pcs_slug,
    )
    if isempty(league_team)
        @warn "No archived roster for $(league["user_name"]) in $(race.name) — using [team_assessor] my_team. Velogames hides teams until the entry deadline, so this is expected before the race (and scripts/ingest_league.jl has to have run since it passed)."
        return my_team
    end
    @info "Entered team pulled from the league archive" user = league["user_name"] riders =
        length(league_team)
    return league_team
end

function RenderConfig(cfg::AbstractDict; repo_root::String, fresh::Bool = false)
    race_tbl = cfg["race"]
    ds = cfg["data_sources"]
    opt = cfg["optimisation"]
    ta = get(cfg, "team_assessor", Dict{String,Any}())

    cache = CacheConfig(DEFAULT_CACHE_DIR, fresh ? 0 : 6)
    race = setup_race(race_tbl["name"], race_tbl["year"]; cache_config = cache)

    odds_df = if get(ds, "use_oddschecker", false)
        _parse_paste_file(joinpath(repo_root, "oddschecker_paste.txt"))
    else
        nothing
    end
    paste(key) =
        let f = get(ds, key, "")
            isempty(f) ? nothing : _parse_paste_file(joinpath(repo_root, f))
        end

    sim_df = let v = opt["simulation_df"]
        v isa Integer ? v : nothing
    end

    mode = Symbol(get(opt, "gt_vg_propensity_mode", "posthoc"))
    mode in (:posthoc, :sim) ||
        error("gt_vg_propensity_mode must be \"posthoc\" or \"sim\", got \"$mode\"")

    my_team = _resolve_my_team(cfg, ta, race)

    return RenderConfig(
        race,
        race_tbl["racehash"],
        joinpath(repo_root, get(get(cfg, "output", Dict()), "dir", "prediction_docs")),
        ds["oracle_url"],
        get(ds, "points_oracle_url", ""),
        get(ds, "kom_oracle_url", ""),
        odds_df,
        paste("points_odds_paste_file"),
        paste("kom_odds_paste_file"),
        paste("stagewin_odds_paste_file"),
        String[x for x in get(ds, "season_round_slugs", String[])],
        opt["n_resamples"],
        opt["history_years"],
        opt["domestique_discount"],
        opt["risk_aversion"],
        # A diversification preference, not a game rule, so it does NOT derive from
        # race format — both formats race under the same cap, and the backtest
        # harness defaults to the same 2 so its metric matches production.
        get(opt, "max_per_team", 2),
        sim_df,
        String[x for x in opt["excluded_riders"]],
        Float64(get(opt, "market_blend_weight", DEFAULT_MARKET_BLEND_WEIGHT)),
        get(opt, "n_alternatives", 20),
        get(opt, "cross_stage_alpha", 0.7),
        get(opt, "pcs_stage_scrape", true),
        get(opt, "gt_vg_history", true),
        get(opt, "gt_vg_propensity", true),
        mode,
        get(ta, "vg_race_number", 0),
        my_team,
        joinpath(archive_dir(), "_inputs", "pcs_breakaways"),
        fresh,
    )
end

"""
    load_render_config(path=<repo>/data/race_config.toml; fresh=false)

Parse `race_config.toml` into a `RenderConfig`. The single TOML-to-config
mapping in the codebase; the local server writes this same file and reloads
through here rather than building a config of its own.
"""
function load_render_config(
    path::String = joinpath(dirname(@__DIR__), "data", "race_config.toml");
    fresh::Bool = false,
)
    return RenderConfig(
        TOML.parsefile(path);
        repo_root = dirname(dirname(path)),
        fresh = fresh,
    )
end

"""
    all_races()

Every selectable race as `(name, slug, type)`. Joins the one-day catalogue
`CLASSICS_RACES_2026` with the stage-race slug tables, which are otherwise
unexported and have no combined view.
"""
all_races() = vcat(
    [(name = r.name, slug = r.pcs_slug, type = :oneday) for r in CLASSICS_RACES_2026],
    [
        (name = titlecase(replace(s, "-" => " ")), slug = s, type = :stage) for
        s in sort(collect(keys(_STAGE_RACE_VG_SLUGS)))
    ],
)

"""
    race_squash(name) -> String

A race name reduced to the letters and digits it shares with any other spelling
of itself: ligatures expanded, accents decomposed and dropped, everything else
removed, casefolded.

**This must agree with vgleague's `_squash_tag` character for character**, which
is why it is not `normalise_race_name` — that one strips only `-'`\``.` and leaves
commas and parentheses, so the two would disagree on exactly the races with
awkward names. `vgleague verify-races` checks the two implementations against
the exported catalogue, the way `verify-keys` checks `riderkey`: a divergence
here files a race's results under the wrong slug, or under none, and raises
nothing.
"""
race_squash(name::AbstractString) =
    replace(normalisename(String(name), true), r"[^a-z0-9]" => "")

"""
    race_catalogue_text() -> String

`_races.toml`: which Velogames race name is which PCS slug, for readers that
cannot see Julia.

The mapping lives in `CLASSICS_RACES_2026` and the stage-race slug tables and
exists nowhere else, so Python could not key a `vg_results` file — which is
keyed by `pcs_slug` across every one of its files — without it. Exported rather
than duplicated, for the reason `_manifest.toml` is: a race added on this side is
known on the other at the next export, with nothing to keep in step by hand.

Derived, like the manifest, so `--check` is a string comparison. Written by a
command rather than on every save: a file rewritten in the archive root during a
run is how Dropbox produces a conflicted copy.
"""
function race_catalogue_text()
    io = IOBuffer()
    write(io, """
    # Which Velogames race name is which PCS slug. DO NOT EDIT.
    #
    # Derived from CLASSICS_RACES_2026 and _STAGE_RACE_VG_SLUGS in
    # Velogames.jl's src/race_helpers.jl. Regenerate with
    # `julia --project scripts/archive_audit.jl --write-races`.
    #
    # `squash` is the name reduced to letters and digits with accents stripped;
    # match a scraped name by squashing it the same way. vgleague's `_squash_tag`
    # is the Python half, and `vgleague verify-races` checks the two agree.
    #
    # `[classics]` is the one-day game's own slug by season, which keys
    # `vg_riders`, `vg_racelist` and `vg_startlist`. Take the last `from_year`
    # that is not after the season you want.

    """)
    write(io, "[classics]\n")
    write(io, "first_year = $(VG_CLASSICS_FIRST_YEAR)\n")
    write(io, "slugs = [\n")
    for (from_year, slug) in VG_CLASSICS_SLUGS
        write(io, "    { from_year = $from_year, slug = $(repr(slug)) },\n")
    end
    write(io, "]\n\n")
    for r in CLASSICS_RACES_2026
        write(io, "[races.\"$(r.pcs_slug)\"]\n")
        write(io, "name = $(repr(r.name))\n")
        write(io, "squash = $(repr(race_squash(r.name)))\n")
        write(io, "category = $(r.category)\n")
        write(io, "format = \"oneday\"\n")
        write(io, "date = $(repr(r.date))\n\n")
    end
    for slug in sort(collect(keys(_STAGE_RACE_VG_SLUGS)))
        # A grand tour's proper name and month come from `GRAND_TOUR_RACES`
        # where it has them: "Giro d'Italia" rather than the titlecased slug,
        # and the month a three-week race is dated by. The dossier needs both,
        # and a reader that cannot see Julia has nowhere else to get them. The
        # squash is unchanged either way — apostrophes and spaces are stripped.
        gt_index = findfirst(gt -> gt.pcs_slug == slug, GRAND_TOUR_RACES)
        gt = gt_index === nothing ? nothing : GRAND_TOUR_RACES[gt_index]
        name = gt === nothing ? titlecase(replace(slug, "-" => " ")) : gt.name
        write(io, "[races.\"$slug\"]\n")
        write(io, "name = $(repr(name))\n")
        write(io, "squash = $(repr(race_squash(name)))\n")
        write(io, "format = \"stage\"\n")
        write(io, "vg_game_slug = $(repr(_STAGE_RACE_VG_SLUGS[slug]))\n")
        write(io, "n_stages = $(grand_tour_stages(slug))\n")
        gt === nothing || write(io, "month = $(gt.month)\n")
        write(io, "\n")
    end
    return String(take!(io))
end

"""`<archive_dir>/_races.toml`, beside `_manifest.toml`."""
race_catalogue_path(; archive_dir::String = archive_dir()) =
    joinpath(archive_dir, "_races.toml")

"""Write `_races.toml` and return its path."""
function write_race_catalogue(; archive_dir::String = archive_dir())
    path = race_catalogue_path(; archive_dir = archive_dir)
    return atomic_write(p -> write(p, race_catalogue_text()), path)
end

"""Whether the exported `_races.toml` is what this code would write."""
function race_catalogue_matches(; archive_dir::String = archive_dir())
    path = race_catalogue_path(; archive_dir = archive_dir)
    isfile(path) || return false
    return read(path, String) == race_catalogue_text()
end

"""
The one-day classics game's VG slug by season, as `(first year, slug)` in order.

Velogames renamed the game from Superclasico to Classics for 2026, and the slug
keys `vg_riders`, `vg_racelist` and `vg_startlist` — so a reader that cannot see
this table cannot open a season's rider pool at all. A table rather than a
conditional because `race_catalogue_text` exports it: the rename boundary then
lives in one place across both languages instead of being a `>= 2026` on each
side.
"""
const VG_CLASSICS_SLUGS = [(2023, "sixes-superclasico"), (2026, "sixes-classics")]

"""Earliest year VG ran the one-day classics competition (Superclasico)."""
const VG_CLASSICS_FIRST_YEAR = VG_CLASSICS_SLUGS[1][1]

"""VG URL slug for one-day classics, year-aware. Years before the first fall to its slug."""
function vg_classics_slug(year::Int)
    slug = VG_CLASSICS_SLUGS[1][2]
    for (from_year, s) in VG_CLASSICS_SLUGS
        year >= from_year && (slug = s)
    end
    return slug
end

"""Full VG riders page URL for a given year's one-day classics competition."""
vg_classics_url(
    year::Int,
) = "https://www.velogames.com/$(vg_classics_slug(year))/$year/riders.php"

"""VG game ID for one-day classics ridescore URLs."""
vg_classics_game_id() = 13

"""Human-friendly aliases mapping to PCS slugs for one-day classics races."""
const _CLASSICS_ALIASES = Dict{String,String}(
    # Monuments
    "liege" => "liege-bastogne-liege",
    "liegebastogneliege" => "liege-bastogne-liege",
    "roubaix" => "paris-roubaix",
    "parisroubaix" => "paris-roubaix",
    "flanders" => "ronde-van-vlaanderen",
    "ronde" => "ronde-van-vlaanderen",
    "lombardia" => "il-lombardia",
    "ilombardia" => "il-lombardia",
    "sanremo" => "milano-sanremo",
    "milansanremo" => "milano-sanremo",
    "worlds" => "world-championship",
    # Belgian opening weekend
    "omloop" => "omloop-het-nieuwsblad",
    "omloopnieuwsblad" => "omloop-het-nieuwsblad",
    "kuurne" => "kuurne-brussel-kuurne",
    "kuurnebrussels" => "kuurne-brussel-kuurne",
    # Cobbled classics
    "stradebianche" => "strade-bianche",
    "strade" => "strade-bianche",
    "bruggepanne" => "classic-brugge-de-panne",
    "brugge" => "classic-brugge-de-panne",
    "rondevanbrugge" => "classic-brugge-de-panne",
    "e3" => "e3-harelbeke",
    "e3harelbeke" => "e3-harelbeke",
    "gentwevelgem" => "gent-wevelgem",
    "inflanders" => "gent-wevelgem",
    "wevelgem" => "gent-wevelgem",
    "dwars" => "dwars-door-vlaanderen",
    "scheldeprijs" => "scheldeprijs",
    # Ardennes classics
    "amstel" => "amstel-gold-race",
    "amstelgoldrace" => "amstel-gold-race",
    "fleche" => "la-fleche-wallonne",
    "flechewallonne" => "la-fleche-wallonne",
    "brabantse" => "brabantse-pijl",
    # Other
    "eschborn" => "eschborn-frankfurt",
    "brussels" => "brussels-cycling-classic",
    "sansebastian" => "san-sebastian",
    "hamburg" => "cyclassics-hamburg",
    "bretagne" => "bretagne-classic",
    "quebec" => "gp-quebec",
    "montreal" => "gp-montreal",
    "laigueglia" => "trofeo-laigueglia",
    "paristours" => "paris-tours",
    "euros" => "european-championship",
    "european" => "european-championship",
    "copenhagen" => "copenhagen-sprint",
    "nokere" => "danilith-nokere-koerse",
)

"""
    get_url_pattern(race_name::String; year::Int=Dates.year(Dates.today()))

Get the URL pattern for a given race name.

Returns a NamedTuple with (slug, template, category, pcs_slug, total_distance_km) where
template uses {year} placeholder. Looks up classics aliases against the canonical
race schedule; grand tours have their own URL patterns.
"""
function get_url_pattern(race_name::String; year::Int = Dates.year(Dates.today()))
    race_lower = replace(lowercase(strip(race_name)), r"[-\s]" => "")

    # Stage races run their own VG competitions, one per race, each on the same
    # URL shape — so alias → PCS slug → VG slug is the whole mapping.
    if haskey(_STAGE_RACE_PCS_SLUGS, race_lower)
        pcs_slug = _STAGE_RACE_PCS_SLUGS[race_lower]
        vg_slug = _STAGE_RACE_VG_SLUGS[pcs_slug]
        return (
            slug = vg_slug,
            template = "https://www.velogames.com/$vg_slug/{year}/riders.php",
            category = 0,
            pcs_slug = pcs_slug,
            total_distance_km = 0.0,
        )
    end

    # Stage races addressed by their PCS slug rather than an alias. `all_races()`
    # emits PCS slugs, so without this arm the race picker cannot resolve its own
    # entries — hyphen-stripping turns "vuelta-a-espana" into a non-key.
    pcs_direct = replace(lowercase(strip(race_name)), r"\s+" => "-")
    if haskey(_STAGE_RACE_VG_SLUGS, pcs_direct)
        vg_slug = _STAGE_RACE_VG_SLUGS[pcs_direct]
        return (
            slug = vg_slug,
            template = "https://www.velogames.com/$vg_slug/{year}/riders.php",
            category = 0,
            pcs_slug = pcs_direct,
            total_distance_km = 0.0,
        )
    end

    slug = vg_classics_slug(year)
    template = "https://www.velogames.com/$slug/{year}/riders.php"

    # Classics alias lookup
    if haskey(_CLASSICS_ALIASES, race_lower)
        pcs_slug = _CLASSICS_ALIASES[race_lower]
        ri = _find_race_by_slug(pcs_slug)
        if ri !== nothing
            return (
                slug = slug,
                template = template,
                category = ri.category,
                pcs_slug = ri.pcs_slug,
                total_distance_km = ri.total_distance_km,
            )
        end
    end

    # Try direct PCS slug match (handles users passing PCS slugs as race names)
    ri = _find_race_by_slug(race_name)
    if ri !== nothing
        return (
            slug = slug,
            template = template,
            category = ri.category,
            pcs_slug = ri.pcs_slug,
            total_distance_km = ri.total_distance_km,
        )
    end

    # Fallback: try partial name match against the race schedule
    ri = find_race(race_name)
    if ri !== nothing
        return (
            slug = slug,
            template = template,
            category = ri.category,
            pcs_slug = ri.pcs_slug,
            total_distance_km = ri.total_distance_km,
        )
    end

    # No fabricated fallback: an unresolved name used to become a 9-rider stage
    # race on a made-up URL, because `category = 0` is what `setup_race` reads as
    # "stage race". Failing here is the difference between a typo costing a
    # second and a typo costing a whole plausible-looking report.
    near =
        [r.slug for r in all_races() if startswith(r.slug, first(lowercase(race_name), 3))]
    error(
        "Unknown race: '$race_name'. Not a stage-race alias or PCS slug, and no " *
        "match in CLASSICS_RACES_2026." *
        (isempty(near) ? "" : " Did you mean: $(join(near, ", "))?") *
        " Check [race] name in data/race_config.toml, or list options with all_races().",
    )
end


"""
    get_historical_url(config::RaceConfig, years_back::Int=1)

Get the Velogames URL for historical data from a previous year.

# Arguments
- `config::RaceConfig`: Current race configuration
- `years_back::Int`: How many years back to look (default: 1)

# Returns
- `String`: URL for the historical race data

# Examples
```julia
race = setup_race("vuelta", 2025)
last_year_url = get_historical_url(race, 1)  # 2024 Vuelta
two_years_url = get_historical_url(race, 2)  # 2023 Vuelta
```
"""
function get_historical_url(config::RaceConfig, years_back::Int = 1)
    historical_year = config.year - years_back
    # For one-day classics, reconstruct with the correct slug for that year
    # (slug changed from sixes-superclasico to sixes-classics in 2026).
    # For grand tours, the slug is stable so just replace the year.
    if config.category > 0
        slug = vg_classics_slug(historical_year)
        return "https://www.velogames.com/$slug/$historical_year/riders.php"
    else
        return replace(config.current_url, string(config.year) => string(historical_year))
    end
end


"""
    print_race_info(config::RaceConfig)

Print detailed information about the race configuration.
"""
function print_race_info(config::RaceConfig)
    println("="^60)
    println("RACE CONFIGURATION")
    println("="^60)
    println("Name:       $(titlecase(config.name))")
    println("Year:       $(config.year)")
    println("Type:       $(config.type)")
    println("Team Size:  $(config.team_size) riders")
    println("Slug:       $(config.slug)")
    if config.category > 0
        println("Category:   $(config.category)")
        println("PCS Slug:   $(config.pcs_slug)")
    end
    println()
    println("URLs:")
    println("  Current:  $(config.current_url)")
    println("  Previous: $(get_historical_url(config, 1))")
    println()
    println("Cache:")
    println("  Directory: $(config.cache.cache_dir)")
    println("  Max Age:   $(config.cache.max_age_hours) hours")
    println("="^60)
end


# ---------------------------------------------------------------------------
# Stage race metadata
# ---------------------------------------------------------------------------

"""
    StageProfile

Metadata for a single stage in a grand tour: type, terrain, distance, climbs.
"""
struct StageProfile
    stage_number::Int
    stage_type::Symbol          # :flat, :hilly, :mountain, :itt, :ttt
    distance_km::Float64
    profile_score::Int          # PCS ProfileScore (0-400+)
    vertical_meters::Int
    gradient_final_km::Float64
    n_hc_climbs::Int
    n_cat1_climbs::Int
    n_intermediate_sprints::Int
    is_summit_finish::Bool
end

"""
    stage_profiles_frame(stages) -> DataFrame

The archive frame for `pcs_stage_profiles`: one row per stage, one column per
`StageProfile` field.

One builder rather than two. The pre-race write (`race_solver.jl`) and the
post-race one (`data_assembly.jl`) used to construct this by hand and differed
only in dropping `gradient_final_km` and `n_intermediate_sprints`, which made
the narrow result look like a second dataset — `stage_profiles` — rather than
the same one at an older schema. Retired in WP3.
"""
stage_profiles_frame(stages::Vector{StageProfile}) = DataFrame(
    stage_number = [s.stage_number for s in stages],
    stage_type = [String(s.stage_type) for s in stages],
    distance_km = [s.distance_km for s in stages],
    profile_score = [s.profile_score for s in stages],
    vertical_meters = [s.vertical_meters for s in stages],
    gradient_final_km = [s.gradient_final_km for s in stages],
    n_hc_climbs = [s.n_hc_climbs for s in stages],
    n_cat1_climbs = [s.n_cat1_climbs for s in stages],
    n_intermediate_sprints = [s.n_intermediate_sprints for s in stages],
    is_summit_finish = [s.is_summit_finish for s in stages],
)

"""
    StageSimConfig

Tuneable constants for the per-stage grand-tour simulator (`simulate_stage_race`).
Consolidates values that were previously module-level constants so they can be
threaded like `stage_scoring` and calibrated (see roadmap Phase 6 / C1).

Fields:
- `aleatoric_noise` — per-dimension race-day scatter scale (`a_type`). This is the
  coefficient on the independent per-stage Student-t(5) noise draw; the SD it
  contributes to a rider's stage performance is `a_type · √(5/3)`. A stage's
  scalar scale is blended across dimensions by the stage's `stage_dimension_weights`.
  Fitted by Plackett–Luce ranking-likelihood MLE on archived GT finishing orders
  (A1b, June 2026): hilly is the most stochastic, ITT the least.
- `breakaway_noise` — per-event, per-dimension breakaway σ (decoupled from GC).
- `points_jersey_allocation` — per-stage-type points-jersey allocation vectors.
- `intermediate_sprint_points` — intermediate-sprint banner allocation, awarded
  as-is per banner rank. The default halves the model's former hardcoded vector
  (20/12/8/6/4/2/1): a runtime 0.5× multiplier folded into the config (July
  2026, decision D3) — it damps the banner contribution because not every
  stage's sprint is contested by the strongest flat riders. NB the actual VG
  table pays 10 banner ranks ([20,16,12,8,6,5,4,3,2,1], see
  `SCORING_GRAND_TOUR.intermediate_sprint_points`); this vector is a
  deliberately damped modelling allocation, not the published table.
"""
struct StageSimConfig
    aleatoric_noise::NamedTuple
    breakaway_noise::NamedTuple
    points_jersey_allocation::NamedTuple
    intermediate_sprint_points::Vector{Float64}
    aleatoric_df::Int                   # Student-t df for the aleatoric race-day draw
end

function StageSimConfig(;
    aleatoric_noise = (flat = 0.8, hilly = 1.1, mountain = 0.7, itt = 0.5),
    breakaway_noise = (
        stage_finish = (flat = 0.0, hilly = 1.0, mountain = 1.5, itt = 0.0),
        points_jersey = (flat = 0.0, hilly = 1.5, mountain = 2.5, itt = 0.0),
    ),
    points_jersey_allocation = (
        flat = [
            50.0,
            35.0,
            25.0,
            18.0,
            14.0,
            12.0,
            10.0,
            8.0,
            7.0,
            6.0,
            5.0,
            4.0,
            3.0,
            2.0,
            1.0,
        ],
        hilly = [25.0, 18.0, 12.0, 8.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0],
        mountain = [15.0, 12.0, 9.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0],
        itt = [15.0, 10.0, 6.0, 3.0, 2.0, 1.0],
        ttt = [15.0, 10.0, 6.0, 3.0, 2.0, 1.0],
    ),
    intermediate_sprint_points = [10.0, 6.0, 4.0, 3.0, 2.0, 1.0, 0.5],
    # Student-t df for the aleatoric race-day scatter. This is a calibrated model
    # property, NOT the global `simulation_df`: the aleatoric term models fat-
    # tailed race-day chaos (crashes/echelons) and is distinct from the Gaussian
    # epistemic wobble, so it has its own tail. `aleatoric_noise` (a_type) is
    # calibrated against df=5; change them together.
    aleatoric_df = 5,
)
    StageSimConfig(
        aleatoric_noise,
        breakaway_noise,
        points_jersey_allocation,
        intermediate_sprint_points,
        aleatoric_df,
    )
end

const DEFAULT_STAGE_SIM_CONFIG = StageSimConfig()

# Convenience constructors for stage profiles
flat_stage(n; km = 180.0, ps = 15, vert = 1000, sprints = 1) =
    StageProfile(n, :flat, km, ps, vert, 0.2, 0, 0, sprints, false)

mountain_stage(
    n;
    km = 180.0,
    ps = 300,
    vert = 4000,
    gradient = 5.0,
    hc = 1,
    cat1 = 1,
    sprints = 0,
    summit = true,
) = StageProfile(n, :mountain, km, ps, vert, gradient, hc, cat1, sprints, summit)

hilly_stage(n; km = 180.0, ps = 100, vert = 2500, gradient = 1.0, cat1 = 1, sprints = 1) =
    StageProfile(n, :hilly, km, ps, vert, gradient, 0, cat1, sprints, false)

itt_stage(n; km = 40.0, ps = 15, vert = 300) =
    StageProfile(n, :itt, km, ps, vert, 0.2, 0, 0, 0, false)

ttt_stage(n; km = 30.0) = StageProfile(n, :ttt, km, 5, 200, 0.1, 0, 0, 0, false)

"""Stage race VG slug mapping (PCS slug → VG slug)."""
const _STAGE_RACE_VG_SLUGS = Dict(
    "tour-de-france" => "velogame",
    "tour-de-france-femmes" => "velogame-femmes",
    "giro-d-italia" => "italy",
    "vuelta-a-espana" => "spain",
    "paris-nice" => "pn",
    "tirreno-adriatico" => "tirreno-adriatico",
    "volta-a-catalunya" => "catalunya",
    "itzulia-basque-country" => "itzulia",
    "tour-de-romandie" => "romandie",
    "criterium-du-dauphine" => "criterium-du-dauphine",
    "tour-de-suisse" => "suisse",
)

"""Stage race PCS slug mapping from common aliases."""
const _STAGE_RACE_PCS_SLUGS = Dict(
    # Grand tours
    "tdf" => "tour-de-france",
    "tour" => "tour-de-france",
    "tourdefrance" => "tour-de-france",
    "giro" => "giro-d-italia",
    "giroditalia" => "giro-d-italia",
    "vuelta" => "vuelta-a-espana",
    "spain" => "vuelta-a-espana",
    # Women's grand tours
    "tourdefrancefemmes" => "tour-de-france-femmes",
    "femmes" => "tour-de-france-femmes",
    "tdff" => "tour-de-france-femmes",
    # Week-long stage races
    "parisnice" => "paris-nice",
    "tirrenoadriatico" => "tirreno-adriatico",
    "tirreno" => "tirreno-adriatico",
    "catalunya" => "volta-a-catalunya",
    "voltaacatalunya" => "volta-a-catalunya",
    "itzulia" => "itzulia-basque-country",
    "itzuliabasquecountry" => "itzulia-basque-country",
    "romandie" => "tour-de-romandie",
    "tourderomandie" => "tour-de-romandie",
    "dauphine" => "criterium-du-dauphine",
    "criteriumdudauphine" => "criterium-du-dauphine",
    "tourauvergne" => "criterium-du-dauphine",
    "suisse" => "tour-de-suisse",
    "tourdesuisse" => "tour-de-suisse",
)

# ---------------------------------------------------------------------------
# Race lookup helpers (used by data assembly and backtesting)
# ---------------------------------------------------------------------------

"""Find a RaceInfo by PCS slug from the race schedule."""
function _find_race_by_slug(pcs_slug::String)
    for ri in CLASSICS_RACES_2026
        if ri.pcs_slug == pcs_slug
            return ri
        end
    end
    return nothing
end

"""Compute a race date for a given year using the template date."""
function _race_date_for_year(ri::RaceInfo, year::Int)
    template = Date(ri.date)
    return Date(year, Dates.month(template), Dates.day(template))
end

# ---------------------------------------------------------------------------
# Grand-tour cross-history
# ---------------------------------------------------------------------------

"""
Grand-tour cross-history mapping. A rider's GC result in one grand tour is
weak-but-real evidence about another. Kept separate from the terrain-based
`SIMILAR_RACES` (classics) so it can carry a larger variance penalty: GT GC form
transfers more noisily than a terrain-matched classic, and the recency decay
already applied to race history downweights older editions automatically.

Membership in this dict is also what marks a slug as a grand tour for
`assemble_pcs_race_history`, which reads it to fetch `/gc` rather than
`/result` (the latter returns the final stage's sprint). A grand tour with no
cross-history partners therefore still belongs here, mapped to an empty vector.
"""
const GT_SIMILAR_RACES = Dict{String,Vector{String}}(
    "tour-de-france" => ["giro-d-italia", "vuelta-a-espana"],
    "giro-d-italia" => ["tour-de-france", "vuelta-a-espana"],
    "vuelta-a-espana" => ["tour-de-france", "giro-d-italia"],
    # Women's grand tours: present so `/gc` scraping is used, but with no
    # cross-history partners — the men's GTs share no riders with them.
    "tour-de-france-femmes" => String[],
)

"""
The grand tours the public site reports on, with the stage count the ingest and
report paths both need.

Lived in `scripts/render_reports.jl` until Phase 2, where it was reachable only
by rendering. `scripts/ingest.jl` needs the same stage counts to fetch a tour's
per-stage results, and race metadata belongs beside the rest of the catalogue.

`month` is the display month for the report subtitle, and is *not* the same fact
as `_GT_APPROX_DATE` below, which is the approximate start date the similar-race
gate orders races by. The Vuelta starts in August and finishes in September; the
two tables disagree by design.
"""
const GRAND_TOUR_RACES = [
    (pcs_slug = "giro-d-italia", name = "Giro d'Italia", month = 5, n_stages = 21),
    (pcs_slug = "tour-de-france", name = "Tour de France", month = 7, n_stages = 21),
    (pcs_slug = "vuelta-a-espana", name = "Vuelta a España", month = 9, n_stages = 21),
    (
        pcs_slug = "tour-de-france-femmes",
        name = "Tour de France Femmes",
        month = 7,
        n_stages = 9,
    ),
]

"""Stages in a grand tour, defaulting to 21 for a stage race that is not one."""
function grand_tour_stages(pcs_slug::AbstractString)
    i = findfirst(gt -> gt.pcs_slug == String(pcs_slug), GRAND_TOUR_RACES)
    return i === nothing ? 21 : GRAND_TOUR_RACES[i].n_stages
end

"""
Approximate grand-tour start dates `(month, day)`. Exact dates shift a little
year to year, but only the ordering relative to the target race matters for the
within-year similar-race gate (a May Giro precedes a July Tour; a late-August
Vuelta follows it). Also used to give grand tours a `race_date` at all — they
are absent from the classics schedule, so without this their within-year
similar-race channel never fires.
"""
const _GT_APPROX_DATE = Dict{String,Tuple{Int,Int}}(
    "giro-d-italia" => (5, 9),
    "tour-de-france" => (7, 1),
    "vuelta-a-espana" => (8, 23),
    "tour-de-france-femmes" => (7, 26),
)

"""
    resolve_race_date(pcs_slug, year) -> Union{Date,Nothing}

Resolve an approximate date for a race, covering both the classics schedule
(`CLASSICS_RACES_2026`) and grand tours (`_GT_APPROX_DATE`). Returns `nothing`
for unknown slugs.
"""
function resolve_race_date(pcs_slug::AbstractString, year::Int)
    ri = _find_race_by_slug(pcs_slug)
    ri !== nothing && return _race_date_for_year(ri, year)
    haskey(_GT_APPROX_DATE, pcs_slug) && return Date(year, _GT_APPROX_DATE[pcs_slug]...)
    return nothing
end
