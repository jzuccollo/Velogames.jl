"""
Race setup and configuration helpers.

This module provides utilities to quickly set up race analysis with
standard URL patterns and configurations for common races.
"""

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
    setup_race(race_name::String, year::Int, race_type::Symbol=:stage; cache_hours::Int=12)

Quick setup for a new race prediction or historical analysis.

Returns a RaceConfig with standard URLs and settings for common races.

# Arguments
- `race_name::String`: Race identifier (e.g., "tdf", "vuelta", "giro", "liege", "roubaix")
- `year::Int`: Year of the race
- `race_type::Symbol`: Either :stage or :oneday (default: :stage)
- `cache_hours::Int`: How many hours to cache data (default: 12)

# Returns
- `RaceConfig`: Configuration object with URLs, cache settings, and team size

# Examples
```julia
# Set up Vuelta 2025 stage race
race = setup_race("vuelta", 2025, :stage)
riders = getvgriders(race.current_url, cache_config=race.cache)

# Set up Paris-Roubaix 2025 one-day race
race = setup_race("roubaix", 2025, :oneday)
```

# Supported Races
Stage races: tdf, vuelta, giro
One-day races: liege, roubaix, flanders, lombardia, sanremo, amstel, fleche
"""
function setup_race(race_name::String, year::Int, race_type::Symbol=:stage; cache_hours::Int=12)
    # Get URL pattern for this race
    pattern = get_url_pattern(race_name)

    # Build the current URL
    current_url = replace(pattern.template, "{year}" => string(year))

    # Team size based on race type
    team_size = race_type == :stage ? 9 : 6

    # Create cache config
    cache_dir = joinpath(tempdir(), "vg_$(pattern.slug)_$year")
    cache = CacheConfig(cache_dir, cache_hours, true)

    # Look up scoring category and PCS slug from the Superclassico schedule
    category = get(pattern, :category, 0)
    pcs_slug = get(pattern, :pcs_slug, "")

    # Also try to find in the race schedule if not in the pattern
    if category == 0
        race_info = find_race(race_name; year=year)
        if race_info !== nothing
            category = race_info.category
            pcs_slug = race_info.pcs_slug
        end
    end

    # Create and display config
    config = RaceConfig(race_name, year, race_type, pattern.slug, current_url, team_size, cache, category, pcs_slug)

    println("Race Setup: $(titlecase(race_name)) $year")
    println("Type: $(race_type == :stage ? "Stage Race" : "One-Day Race")")
    println("Team size: $team_size riders")
    println("Riders URL: $current_url")
    if category > 0
        println("Scoring: Category $category | PCS: $pcs_slug")
    end
    println("Cache: $cache_dir ($(cache_hours)h TTL)")
    println()

    return config
end


"""
    get_url_pattern(race_name::String)

Get the URL pattern for a given race name.

Returns a NamedTuple with (slug, template) where template uses {year} placeholder.
"""
function get_url_pattern(race_name::String)
    # Normalize race name
    race_lower = lowercase(strip(race_name))

    # Known race patterns. NamedTuples include optional category and pcs_slug for Superclassico races.
    # All Superclassico races use the same VG URL: sixes-superclasico/{year}/riders.php
    superclasico_tpl = "https://www.velogames.com/sixes-superclasico/{year}/riders.php"

    patterns = Dict(
        # Grand Tours (no scoring category -- different competition)
        "tdf" => (slug="velogame", template="https://www.velogames.com/velogame/{year}/riders.php", category=0, pcs_slug=""),
        "tour" => (slug="velogame", template="https://www.velogames.com/velogame/{year}/riders.php", category=0, pcs_slug=""),
        "tourdefrance" => (slug="velogame", template="https://www.velogames.com/velogame/{year}/riders.php", category=0, pcs_slug=""),

        "vuelta" => (slug="spain", template="https://www.velogames.com/spain/{year}/riders.php", category=0, pcs_slug=""),
        "spain" => (slug="spain", template="https://www.velogames.com/spain/{year}/riders.php", category=0, pcs_slug=""),

        "giro" => (slug="giro", template="https://www.velogames.com/giro/{year}/riders.php", category=0, pcs_slug=""),
        "giroditalia" => (slug="giro", template="https://www.velogames.com/giro/{year}/riders.php", category=0, pcs_slug=""),

        # Monuments (Cat 1 in Superclassico)
        "liege" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="liege-bastogne-liege"),
        "liegebastogneliege" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="liege-bastogne-liege"),
        "roubaix" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="paris-roubaix"),
        "parisroubaix" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="paris-roubaix"),
        "flanders" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="ronde-van-vlaanderen"),
        "ronde" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="ronde-van-vlaanderen"),
        "lombardia" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="il-lombardia"),
        "ilombardia" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="il-lombardia"),
        "sanremo" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="milano-sanremo"),
        "milansanremo" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="milano-sanremo"),

        # Belgian Opening Weekend (Cat 2 + Cat 3)
        "omloop" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="omloop-het-nieuwsblad"),
        "omloopnieuwsblad" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="omloop-het-nieuwsblad"),
        "kuurne" => (slug="sixes-superclasico", template=superclasico_tpl, category=3, pcs_slug="kuurne-brussel-kuurne"),
        "kuurnebrussels" => (slug="sixes-superclasico", template=superclasico_tpl, category=3, pcs_slug="kuurne-brussel-kuurne"),

        # Cobbled Classics (Cat 2)
        "stradebianche" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="strade-bianche"),
        "strade" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="strade-bianche"),
        "bruggepanne" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="classic-brugge-de-panne"),
        "e3" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="e3-harelbeke"),
        "gentwevelgem" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="gent-wevelgem"),
        "dwars" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="dwars-door-vlaanderen"),
        "scheldeprijs" => (slug="sixes-superclasico", template=superclasico_tpl, category=3, pcs_slug="scheldeprijs"),

        # Ardennes Classics (Cat 2)
        "amstel" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="amstel-gold-race"),
        "amstelgoldrace" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="amstel-gold-race"),
        "fleche" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="la-fleche-wallonne"),
        "flechewallonne" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="la-fleche-wallonne"),

        # Other Cat 2 races
        "eschborn" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="eschborn-frankfurt"),
        "brussels" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="brussels-cycling-classic"),
        "sansebastian" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="donostia-san-sebastian-klasikoa"),
        "hamburg" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="cyclassics-hamburg"),
        "bretagne" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="bretagne-classic"),
        "quebec" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="gp-quebec"),
        "montreal" => (slug="sixes-superclasico", template=superclasico_tpl, category=2, pcs_slug="gp-montreal"),

        # Cat 3 races
        "laigueglia" => (slug="sixes-superclasico", template=superclasico_tpl, category=3, pcs_slug="trofeo-laigueglia"),
        "milanoTorino" => (slug="sixes-superclasico", template=superclasico_tpl, category=3, pcs_slug="milano-torino"),
        "brabantse" => (slug="sixes-superclasico", template=superclasico_tpl, category=3, pcs_slug="de-brabantse-pijl"),
        "paristours" => (slug="sixes-superclasico", template=superclasico_tpl, category=3, pcs_slug="paris-tours"),

        # Worlds (Cat 1)
        "worlds" => (slug="sixes-superclasico", template=superclasico_tpl, category=1, pcs_slug="world-championship"),
    )

    if haskey(patterns, race_lower)
        return patterns[race_lower]
    else
        @warn """Unknown race: '$race_name'

        Supported races:
          Grand Tours: tdf, vuelta, giro
          Monuments: roubaix, flanders, liege, lombardia, sanremo
          Classics: amstel, fleche

        Using generic pattern - you'll need to check the URL manually.
        """

        # Return a generic pattern with the race name as slug
        sanitized = replace(race_lower, r"[^a-z0-9]" => "-")
        return (slug=sanitized, template="https://www.velogames.com/$sanitized/{year}/riders.php", category=0, pcs_slug="")
    end
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
function get_historical_url(config::RaceConfig, years_back::Int=1)
    historical_year = config.year - years_back
    return replace(config.current_url, string(config.year) => string(historical_year))
end


"""
    print_race_info(config::RaceConfig)

Print detailed information about the race configuration.
"""
function print_race_info(config::RaceConfig)
    println("=" ^ 60)
    println("RACE CONFIGURATION")
    println("=" ^ 60)
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
    println("  Enabled:   $(config.cache.enabled)")
    println("=" ^ 60)
end
