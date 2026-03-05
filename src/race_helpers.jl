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
PCS slug, and terrain-similar races.
"""
struct RaceInfo
    name::String
    date::String
    category::Int
    pcs_slug::String
    similar_races::Vector{String}
end

# Convenience constructor without similar_races (defaults to empty)
RaceInfo(name, date, category, pcs_slug) =
    RaceInfo(name, date, category, pcs_slug, String[])

"""Complete 2026 Sixes Classics race schedule with categories, PCS slugs, and terrain similarity."""
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
    ),
    RaceInfo(
        "Kuurne - Brussel - Kuurne",
        "2026-03-01",
        3,
        "kuurne-brussel-kuurne",
        ["scheldeprijs", "classic-brugge-de-panne", "paris-tours", "eschborn-frankfurt"],
    ),
    RaceInfo(
        "Trofeo Laigueglia",
        "2026-03-04",
        3,
        "trofeo-laigueglia",
        ["gran-piemonte", "coppa-sabatini"],
    ),
    RaceInfo(
        "Strade Bianche",
        "2026-03-07",
        2,
        "strade-bianche",
        ["il-lombardia", "liege-bastogne-liege", "amstel-gold-race"],
    ),
    RaceInfo(
        "Danilith Nokere Koerse",
        "2026-03-18",
        3,
        "nokere-koerse",
        ["kuurne-brussel-kuurne", "classic-brugge-de-panne", "scheldeprijs"],
    ),
    RaceInfo("Milano-Sanremo", "2026-03-21", 1, "milano-sanremo", ["strade-bianche"]),
    RaceInfo(
        "Ronde Van Brugge",
        "2026-03-25",
        2,
        "classic-brugge-de-panne",
        ["gent-wevelgem", "omloop-het-nieuwsblad", "kuurne-brussel-kuurne"],
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
    ),
    RaceInfo(
        "In Flanders Fields - From Middelkerke to Wevelgem",
        "2026-03-29",
        2,
        "gent-wevelgem",
        [
            "omloop-het-nieuwsblad",
            "e3-harelbeke",
            "classic-brugge-de-panne",
            "dwars-door-vlaanderen",
        ],
    ),
    RaceInfo(
        "Dwars door Vlaanderen",
        "2026-04-01",
        2,
        "dwars-door-vlaanderen",
        ["e3-harelbeke", "omloop-het-nieuwsblad", "ronde-van-vlaanderen", "gent-wevelgem"],
    ),
    RaceInfo(
        "Ronde van Vlaanderen",
        "2026-04-05",
        1,
        "ronde-van-vlaanderen",
        ["e3-harelbeke", "dwars-door-vlaanderen", "omloop-het-nieuwsblad"],
    ),
    RaceInfo(
        "Scheldeprijs",
        "2026-04-08",
        3,
        "scheldeprijs",
        ["kuurne-brussel-kuurne", "classic-brugge-de-panne", "eschborn-frankfurt"],
    ),
    RaceInfo(
        "Paris-Roubaix",
        "2026-04-12",
        1,
        "paris-roubaix",
        ["e3-harelbeke", "ronde-van-vlaanderen", "dwars-door-vlaanderen"],
    ),
    # Ardennes hilly (steep punchy climbs)
    RaceInfo(
        "De Brabantse Pijl",
        "2026-04-17",
        3,
        "brabantse-pijl",
        ["la-fleche-wallonne", "amstel-gold-race", "liege-bastogne-liege"],
    ),
    RaceInfo(
        "Amstel Gold Race",
        "2026-04-19",
        1,
        "amstel-gold-race",
        ["la-fleche-wallonne", "liege-bastogne-liege", "brabantse-pijl"],
    ),
    RaceInfo(
        "La Fleche Wallonne",
        "2026-04-22",
        2,
        "la-fleche-wallonne",
        ["liege-bastogne-liege", "amstel-gold-race", "brabantse-pijl"],
    ),
    RaceInfo(
        "Liege-Bastogne-Liege",
        "2026-04-26",
        1,
        "liege-bastogne-liege",
        ["la-fleche-wallonne", "amstel-gold-race", "brabantse-pijl"],
    ),
    RaceInfo(
        "Eschborn-Frankfurt",
        "2026-05-01",
        2,
        "eschborn-frankfurt",
        ["kuurne-brussel-kuurne", "scheldeprijs", "cyclassics-hamburg"],
    ),
    # French regional
    RaceInfo(
        "Grand Prix du Morbihan",
        "2026-05-09",
        3,
        "gp-de-plumelec",
        ["tro-bro-leon", "quatre-jours-de-dunkerque"],
    ),
    RaceInfo(
        "Tro-Bro Leon",
        "2026-05-10",
        3,
        "tro-bro-leon",
        ["gp-de-plumelec", "quatre-jours-de-dunkerque"],
    ),
    RaceInfo(
        "Classique Dunkerque",
        "2026-05-19",
        3,
        "quatre-jours-de-dunkerque",
        ["gp-de-plumelec", "circuit-franco-belge"],
    ),
    # Belgian hilly
    RaceInfo(
        "Brussels Cycling Classic",
        "2026-06-07",
        3,
        "brussels-cycling-classic",
        ["dwars-door-het-hageland", "omloop-het-nieuwsblad"],
    ),
    RaceInfo(
        "Circuit Franco-Belge",
        "2026-06-10",
        3,
        "circuit-franco-belge",
        ["quatre-jours-de-dunkerque", "kuurne-brussel-kuurne"],
    ),
    RaceInfo(
        "Duracell Dwars door het Hageland",
        "2026-06-13",
        3,
        "dwars-door-het-hageland",
        ["brussels-cycling-classic", "classic-brugge-de-panne"],
    ),
    # Flat sprint
    RaceInfo(
        "Copenhagen Sprint",
        "2026-06-14",
        2,
        "copenhagen-sprint",
        ["scheldeprijs", "kuurne-brussel-kuurne"],
    ),
    # Punchy hilly (mixed terrain, moderate climbs)
    RaceInfo(
        "Donostia San Sebastian Klasikoa",
        "2026-08-01",
        2,
        "san-sebastian",
        ["bretagne-classic", "gp-quebec", "gp-montreal"],
    ),
    RaceInfo(
        "ADAC Cyclassics Hamburg",
        "2026-08-16",
        2,
        "cyclassics-hamburg",
        ["eschborn-frankfurt", "gp-montreal"],
    ),
    RaceInfo(
        "Bretagne Classic - CIC",
        "2026-08-30",
        2,
        "bretagne-classic",
        ["san-sebastian", "gp-quebec"],
    ),
    RaceInfo(
        "GP Industria & Artigianato",
        "2026-09-06",
        3,
        "gp-industria-e-artigianato-di-larciano",
        ["coppa-sabatini", "coppa-bernocchi"],
    ),
    RaceInfo(
        "Coppa Sabatini",
        "2026-09-10",
        3,
        "coppa-sabatini",
        ["giro-dell-emilia", "trofeo-laigueglia"],
    ),
    RaceInfo(
        "Grand Prix Cycliste de Quebec",
        "2026-09-11",
        2,
        "gp-quebec",
        ["gp-montreal", "san-sebastian", "bretagne-classic"],
    ),
    RaceInfo(
        "Grand Prix Cycliste de Montreal",
        "2026-09-13",
        2,
        "gp-montreal",
        ["gp-quebec", "san-sebastian", "cyclassics-hamburg"],
    ),
    RaceInfo(
        "Lotto Grand Prix de Wallonie",
        "2026-09-16",
        3,
        "gp-de-wallonie",
        ["la-fleche-wallonne", "brabantse-pijl"],
    ),
    RaceInfo(
        "SUPER 8 Classic",
        "2026-09-19",
        3,
        "super-8-classic",
        ["brussels-cycling-classic", "dwars-door-het-hageland"],
    ),
    RaceInfo(
        "World Championships - Elite Road Race",
        "2026-09-27",
        1,
        "world-championship",
    ),
    # Italian/European autumn classics
    RaceInfo(
        "Giro dell'Emilia",
        "2026-10-03",
        3,
        "giro-dell-emilia",
        ["il-lombardia", "tre-valli-varesine", "coppa-sabatini"],
    ),
    RaceInfo(
        "European Championships - Elite Road Race",
        "2026-10-04",
        2,
        "uec-road-european-championships-me",
        ["world-championship", "gp-quebec", "gp-montreal"],
    ),
    RaceInfo(
        "Coppa Bernocchi",
        "2026-10-05",
        3,
        "coppa-bernocchi",
        ["tre-valli-varesine", "gran-piemonte"],
    ),
    RaceInfo(
        "Tre Valli Varesine",
        "2026-10-06",
        3,
        "tre-valli-varesine",
        ["giro-dell-emilia", "il-lombardia", "gran-piemonte"],
    ),
    RaceInfo(
        "Gran Piemonte",
        "2026-10-08",
        3,
        "gran-piemonte",
        ["tre-valli-varesine", "giro-dell-emilia"],
    ),
    RaceInfo(
        "Il Lombardia",
        "2026-10-10",
        1,
        "il-lombardia",
        ["giro-dell-emilia", "tre-valli-varesine", "gran-piemonte"],
    ),
    RaceInfo(
        "Paris - Tours Elite",
        "2026-10-11",
        3,
        "paris-tours",
        ["kuurne-brussel-kuurne", "eschborn-frankfurt", "scheldeprijs"],
    ),
    RaceInfo(
        "Giro del Veneto",
        "2026-10-14",
        3,
        "giro-del-veneto",
        ["veneto-classic", "gran-piemonte"],
    ),
    RaceInfo(
        "Veneto Classic",
        "2026-10-18",
        3,
        "veneto-classic",
        ["giro-del-veneto", "gran-piemonte"],
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
    name_lower = lowercase(name)
    for race in CLASSICS_RACES_2026
        if occursin(name_lower, lowercase(race.name))
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
riders = getvgriders(race.current_url, cache_config=race.cache)

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
    )

    println("Race Setup: $(titlecase(race_name)) $year")
    println("Type: $(race_type == :stage ? "Stage Race" : "One-Day Race")")
    println("Team size: $team_size riders")
    println("Riders URL: $current_url")
    if category > 0
        println("Scoring: Category $category | PCS: $pcs_slug")
    end
    println("Cache: $(cache_config.cache_dir) ($(cache_config.max_age_hours)h TTL)")
    println()

    return config
end


"""Earliest year VG ran the one-day classics competition (Superclasico)."""
const VG_CLASSICS_FIRST_YEAR = 2023

"""VG URL slug for one-day classics, year-aware (renamed from Superclasico to Classics in 2026)."""
vg_classics_slug(year::Int) = year >= 2026 ? "sixes-classics" : "sixes-superclasico"

"""Full VG riders page URL for a given year's one-day classics competition."""
vg_classics_url(
    year::Int,
) = "https://www.velogames.com/$(vg_classics_slug(year))/$year/riders.php"

"""VG game ID for one-day classics ridescore URLs (may change with 2026 rebrand)."""
vg_classics_game_id(year::Int) = 13  # Update if 2026 uses a different game ID

"""Grand tour URL patterns (separate competition from one-day classics)."""
const _GRAND_TOUR_PATTERNS =
    Dict{String,NamedTuple{(:slug, :template),Tuple{String,String}}}(
        "tdf" => (
            slug = "velogame",
            template = "https://www.velogames.com/velogame/{year}/riders.php",
        ),
        "tour" => (
            slug = "velogame",
            template = "https://www.velogames.com/velogame/{year}/riders.php",
        ),
        "tourdefrance" => (
            slug = "velogame",
            template = "https://www.velogames.com/velogame/{year}/riders.php",
        ),
        "vuelta" => (
            slug = "spain",
            template = "https://www.velogames.com/spain/{year}/riders.php",
        ),
        "spain" => (
            slug = "spain",
            template = "https://www.velogames.com/spain/{year}/riders.php",
        ),
        "giro" =>
            (slug = "giro", template = "https://www.velogames.com/giro/{year}/riders.php"),
        "giroditalia" =>
            (slug = "giro", template = "https://www.velogames.com/giro/{year}/riders.php"),
    )

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

Returns a NamedTuple with (slug, template, category, pcs_slug) where template
uses {year} placeholder. Looks up classics aliases against the canonical
race schedule; grand tours have their own URL patterns.
"""
function get_url_pattern(race_name::String; year::Int = Dates.year(Dates.today()))
    race_lower = lowercase(strip(race_name))

    # Grand tours have their own URL templates
    if haskey(_GRAND_TOUR_PATTERNS, race_lower)
        gt = _GRAND_TOUR_PATTERNS[race_lower]
        return (slug = gt.slug, template = gt.template, category = 0, pcs_slug = "")
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
            )
        end
    end

    # Fallback: try partial name match against the race schedule
    ri = find_race(race_name)
    if ri !== nothing
        return (
            slug = slug,
            template = template,
            category = ri.category,
            pcs_slug = ri.pcs_slug,
        )
    end

    @warn """Unknown race: '$race_name'

    Supported races:
      Grand Tours: tdf, vuelta, giro
      Monuments: roubaix, flanders, liege, lombardia, sanremo
      Classics: amstel, fleche

    Using generic pattern - you'll need to check the URL manually.
    """

    sanitized = replace(race_lower, r"[^a-z0-9]" => "-")
    return (
        slug = sanitized,
        template = "https://www.velogames.com/$sanitized/{year}/riders.php",
        category = 0,
        pcs_slug = "",
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
