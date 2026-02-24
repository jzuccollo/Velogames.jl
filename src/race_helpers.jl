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

Metadata for a Superclasico race: name, template date, scoring category,
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

"""Complete 2025 Superclasico race schedule with categories, PCS slugs, and terrain similarity."""
const SUPERCLASICO_RACES_2025 = [
    # Flemish hilly (bergs + short cobbled sections)
    RaceInfo(
        "Omloop Nieuwsblad",
        "2025-03-01",
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
        "Kuurne-Brussel-Kuurne",
        "2025-03-02",
        3,
        "kuurne-brussel-kuurne",
        ["scheldeprijs", "classic-brugge-de-panne", "paris-tours", "eschborn-frankfurt"],
    ),
    RaceInfo(
        "Trofeo Laigueglia",
        "2025-03-05",
        3,
        "trofeo-laigueglia",
        ["milano-torino", "gran-piemonte", "coppa-sabatini"],
    ),
    RaceInfo("Strade Bianche", "2025-03-08", 2, "strade-bianche", ["milano-sanremo"]),
    RaceInfo(
        "Milano-Torino",
        "2025-03-19",
        3,
        "milano-torino",
        ["gran-piemonte", "trofeo-laigueglia", "giro-dell-emilia"],
    ),
    RaceInfo("Milano-Sanremo", "2025-03-22", 1, "milano-sanremo", ["strade-bianche"]),
    RaceInfo(
        "Classic Brugge-De Panne",
        "2025-03-26",
        2,
        "classic-brugge-de-panne",
        ["gent-wevelgem", "omloop-het-nieuwsblad", "kuurne-brussel-kuurne"],
    ),
    RaceInfo(
        "E3 Saxo Classic",
        "2025-03-28",
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
        "Gent-Wevelgem",
        "2025-03-30",
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
        "2025-04-02",
        2,
        "dwars-door-vlaanderen",
        ["e3-harelbeke", "omloop-het-nieuwsblad", "ronde-van-vlaanderen", "gent-wevelgem"],
    ),
    RaceInfo(
        "Ronde van Vlaanderen",
        "2025-04-06",
        1,
        "ronde-van-vlaanderen",
        ["e3-harelbeke", "dwars-door-vlaanderen", "omloop-het-nieuwsblad"],
    ),
    RaceInfo(
        "Scheldeprijs",
        "2025-04-09",
        3,
        "scheldeprijs",
        ["kuurne-brussel-kuurne", "classic-brugge-de-panne", "eschborn-frankfurt"],
    ),
    RaceInfo(
        "Paris-Roubaix",
        "2025-04-13",
        1,
        "paris-roubaix",
        ["e3-harelbeke", "ronde-van-vlaanderen", "dwars-door-vlaanderen"],
    ),
    # Ardennes hilly (steep punchy climbs)
    RaceInfo(
        "De Brabantse Pijl",
        "2025-04-18",
        3,
        "brabantse-pijl",
        ["la-fleche-wallonne", "amstel-gold-race", "liege-bastogne-liege"],
    ),
    RaceInfo(
        "Amstel Gold Race",
        "2025-04-20",
        2,
        "amstel-gold-race",
        ["la-fleche-wallonne", "liege-bastogne-liege", "brabantse-pijl"],
    ),
    RaceInfo(
        "La Fleche Wallonne",
        "2025-04-23",
        2,
        "la-fleche-wallonne",
        ["liege-bastogne-liege", "amstel-gold-race", "brabantse-pijl"],
    ),
    RaceInfo(
        "Liege-Bastogne-Liege",
        "2025-04-27",
        1,
        "liege-bastogne-liege",
        ["la-fleche-wallonne", "amstel-gold-race", "brabantse-pijl"],
    ),
    RaceInfo(
        "Eschborn-Frankfurt",
        "2025-05-01",
        2,
        "eschborn-frankfurt",
        ["kuurne-brussel-kuurne", "scheldeprijs", "cyclassics-hamburg"],
    ),
    # French regional
    RaceInfo(
        "Grand Prix du Morbihan",
        "2025-05-10",
        3,
        "gp-de-plumelec",
        ["quatre-jours-de-dunkerque", "tro-bro-leon"],
    ),
    RaceInfo(
        "Tro-Bro Leon",
        "2025-05-11",
        3,
        "tro-bro-leon",
        ["gp-de-plumelec", "quatre-jours-de-dunkerque"],
    ),
    RaceInfo(
        "Classique Dunkerque",
        "2025-05-13",
        3,
        "quatre-jours-de-dunkerque",
        ["gp-de-plumelec", "circuit-franco-belge"],
    ),
    # Belgian hilly
    RaceInfo(
        "Brussels Cycling Classic",
        "2025-06-08",
        2,
        "brussels-cycling-classic",
        ["dwars-door-het-hageland", "omloop-het-nieuwsblad"],
    ),
    RaceInfo(
        "Dwars door het Hageland",
        "2025-06-14",
        3,
        "dwars-door-het-hageland",
        ["brussels-cycling-classic", "classic-brugge-de-panne"],
    ),
    # Flat sprint
    RaceInfo(
        "Copenhagen Sprint",
        "2025-06-22",
        2,
        "copenhagen-sprint",
        ["scheldeprijs", "kuurne-brussel-kuurne"],
    ),
    # Punchy hilly (mixed terrain, moderate climbs)
    RaceInfo(
        "Donostia San Sebastian Klasikoa",
        "2025-08-02",
        2,
        "san-sebastian",
        ["bretagne-classic", "gp-quebec", "gp-montreal"],
    ),
    RaceInfo(
        "Circuit Franco-Belge",
        "2025-08-15",
        3,
        "circuit-franco-belge",
        ["quatre-jours-de-dunkerque", "kuurne-brussel-kuurne"],
    ),
    RaceInfo(
        "ADAC Cyclassics Hamburg",
        "2025-08-17",
        2,
        "cyclassics-hamburg",
        ["eschborn-frankfurt", "gp-montreal"],
    ),
    RaceInfo(
        "Bretagne Classic",
        "2025-08-31",
        2,
        "bretagne-classic",
        ["san-sebastian", "gp-quebec"],
    ),
    RaceInfo(
        "GP Industria & Artigianato",
        "2025-09-07",
        3,
        "gp-industria-e-artigianato-di-larciano",
        ["coppa-sabatini", "coppa-bernocchi"],
    ),
    RaceInfo(
        "Coppa Sabatini",
        "2025-09-11",
        3,
        "coppa-sabatini",
        ["giro-dell-emilia", "trofeo-laigueglia"],
    ),
    RaceInfo(
        "Grand Prix Cycliste de Quebec",
        "2025-09-12",
        2,
        "gp-quebec",
        ["gp-montreal", "san-sebastian", "bretagne-classic"],
    ),
    RaceInfo(
        "Grand Prix Cycliste de Montreal",
        "2025-09-14",
        2,
        "gp-montreal",
        ["gp-quebec", "san-sebastian", "cyclassics-hamburg"],
    ),
    RaceInfo(
        "Grand Prix de Wallonie",
        "2025-09-17",
        3,
        "gp-de-wallonie",
        ["la-fleche-wallonne", "brabantse-pijl"],
    ),
    RaceInfo(
        "SUPER 8 Classic",
        "2025-09-20",
        3,
        "super-8-classic",
        ["brussels-cycling-classic", "dwars-door-het-hageland"],
    ),
    RaceInfo("Worlds Elite Road Race", "2025-09-28", 1, "world-championship"),
    # Italian autumn classics
    RaceInfo(
        "Sparkassen Munsterland Giro",
        "2025-10-03",
        3,
        "sparkassen-muensterland-giro",
        ["eschborn-frankfurt", "cyclassics-hamburg"],
    ),
    RaceInfo(
        "Giro dell'Emilia",
        "2025-10-04",
        3,
        "giro-dell-emilia",
        ["il-lombardia", "tre-valli-varesine", "coppa-sabatini"],
    ),
    RaceInfo(
        "Coppa Bernocchi",
        "2025-10-06",
        3,
        "coppa-bernocchi",
        ["tre-valli-varesine", "gran-piemonte"],
    ),
    RaceInfo(
        "Tre Valli Varesine",
        "2025-10-07",
        3,
        "tre-valli-varesine",
        ["giro-dell-emilia", "il-lombardia", "gran-piemonte"],
    ),
    RaceInfo(
        "Gran Piemonte",
        "2025-10-09",
        3,
        "gran-piemonte",
        ["tre-valli-varesine", "giro-dell-emilia", "milano-torino"],
    ),
    RaceInfo(
        "Il Lombardia",
        "2025-10-11",
        1,
        "il-lombardia",
        ["giro-dell-emilia", "tre-valli-varesine", "gran-piemonte"],
    ),
    RaceInfo(
        "Paris-Tours",
        "2025-10-12",
        3,
        "paris-tours",
        ["kuurne-brussel-kuurne", "eschborn-frankfurt", "scheldeprijs"],
    ),
    RaceInfo(
        "Giro del Veneto",
        "2025-10-15",
        3,
        "giro-del-veneto",
        ["veneto-classic", "gran-piemonte"],
    ),
    RaceInfo(
        "Veneto Classic",
        "2025-10-19",
        3,
        "veneto-classic",
        ["giro-del-veneto", "gran-piemonte"],
    ),
]

"""Terrain-similar race mapping, derived from `SUPERCLASICO_RACES_2025`."""
const SIMILAR_RACES = Dict{String,Vector{String}}(
    ri.pcs_slug => ri.similar_races for
    ri in SUPERCLASICO_RACES_2025 if !isempty(ri.similar_races)
)

"""
    find_race(name::String; year::Int=2025) -> Union{RaceInfo, Nothing}

Find a race in the Superclasico schedule by partial name match (case-insensitive).
Returns the first matching RaceInfo or nothing.
"""
function find_race(name::String; year::Int = 2025)
    name_lower = lowercase(name)
    if year != 2025
        @warn "Race schedule data is from 2025; using it as approximation for $year"
    end
    for race in SUPERCLASICO_RACES_2025
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
  type from the race pattern — Superclasico races (category > 0) are one-day, others are stage.
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
    pattern = get_url_pattern(race_name)

    # Build the current URL
    current_url = replace(pattern.template, "{year}" => string(year))

    category = pattern.category
    pcs_slug = pattern.pcs_slug

    # Auto-detect race type: Superclasico races (category > 0) are one-day
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


"""VG URL template for Superclasico races (shared with backtest.jl)."""
const VG_SUPERCLASICO_URL = "https://www.velogames.com/sixes-superclasico/{year}/riders.php"

"""Grand tour URL patterns (separate competition from Superclasico)."""
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

"""Human-friendly aliases mapping to PCS slugs for Superclasico races."""
const _SUPERCLASICO_ALIASES = Dict{String,String}(
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
    "e3" => "e3-harelbeke",
    "gentwevelgem" => "gent-wevelgem",
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
    "milanotorino" => "milano-torino",
    "paristours" => "paris-tours",
)

"""
    get_url_pattern(race_name::String)

Get the URL pattern for a given race name.

Returns a NamedTuple with (slug, template, category, pcs_slug) where template
uses {year} placeholder. Looks up Superclasico aliases against the canonical
race schedule; grand tours have their own URL patterns.
"""
function get_url_pattern(race_name::String)
    race_lower = lowercase(strip(race_name))

    # Grand tours have their own URL templates
    if haskey(_GRAND_TOUR_PATTERNS, race_lower)
        gt = _GRAND_TOUR_PATTERNS[race_lower]
        return (slug = gt.slug, template = gt.template, category = 0, pcs_slug = "")
    end

    # Superclasico alias lookup
    if haskey(_SUPERCLASICO_ALIASES, race_lower)
        pcs_slug = _SUPERCLASICO_ALIASES[race_lower]
        ri = _find_race_by_slug(pcs_slug)
        if ri !== nothing
            return (
                slug = "sixes-superclasico",
                template = VG_SUPERCLASICO_URL,
                category = ri.category,
                pcs_slug = ri.pcs_slug,
            )
        end
    end

    # Fallback: try partial name match against the race schedule
    ri = find_race(race_name)
    if ri !== nothing
        return (
            slug = "sixes-superclasico",
            template = VG_SUPERCLASICO_URL,
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
    return replace(config.current_url, string(config.year) => string(historical_year))
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

"""Find a RaceInfo by PCS slug from the 2025 schedule template."""
function _find_race_by_slug(pcs_slug::String)
    for ri in SUPERCLASICO_RACES_2025
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
