"""
Race setup and configuration helpers.

This module provides utilities to quickly set up race analysis with
standard URL patterns and configurations for common races.
"""

"""
Race configuration data structure
"""
struct RaceConfig
    name::String
    year::Int
    type::Symbol
    slug::String
    current_url::String
    team_size::Int
    cache::CacheConfig
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

    # Create and display config
    config = RaceConfig(race_name, year, race_type, pattern.slug, current_url, team_size, cache)

    println("📋 Race Setup: $(titlecase(race_name)) $year")
    println("🏁 Type: $(race_type == :stage ? "Stage Race" : "One-Day Race")")
    println("👥 Team size: $team_size riders")
    println("🔗 Riders URL: $current_url")
    println("💾 Cache: $cache_dir ($(cache_hours)h TTL)")
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

    # Known race patterns
    patterns = Dict(
        # Grand Tours
        "tdf" => (slug="velogame", template="https://www.velogames.com/velogame/{year}/riders.php"),
        "tour" => (slug="velogame", template="https://www.velogames.com/velogame/{year}/riders.php"),
        "tourdefrance" => (slug="velogame", template="https://www.velogames.com/velogame/{year}/riders.php"),

        "vuelta" => (slug="spain", template="https://www.velogames.com/spain/{year}/riders.php"),
        "spain" => (slug="spain", template="https://www.velogames.com/spain/{year}/riders.php"),

        "giro" => (slug="giro", template="https://www.velogames.com/giro/{year}/riders.php"),
        "giroditalia" => (slug="giro", template="https://www.velogames.com/giro/{year}/riders.php"),

        # Monuments / Classics
        "liege" => (slug="sixes-liege", template="https://www.velogames.com/sixes-liege/{year}/riders.php"),
        "liegebastogneliege" => (slug="sixes-liege", template="https://www.velogames.com/sixes-liege/{year}/riders.php"),

        "roubaix" => (slug="sixes-roubaix", template="https://www.velogames.com/sixes-roubaix/{year}/riders.php"),
        "parisroubaix" => (slug="sixes-roubaix", template="https://www.velogames.com/sixes-roubaix/{year}/riders.php"),

        "flanders" => (slug="sixes-flanders", template="https://www.velogames.com/sixes-flanders/{year}/riders.php"),
        "ronde" => (slug="sixes-flanders", template="https://www.velogames.com/sixes-flanders/{year}/riders.php"),

        "lombardia" => (slug="sixes-lombardia", template="https://www.velogames.com/sixes-lombardia/{year}/riders.php"),
        "ilombardia" => (slug="sixes-lombardia", template="https://www.velogames.com/sixes-lombardia/{year}/riders.php"),

        "sanremo" => (slug="sixes-sanremo", template="https://www.velogames.com/sixes-sanremo/{year}/riders.php"),
        "milansanremo" => (slug="sixes-sanremo", template="https://www.velogames.com/sixes-sanremo/{year}/riders.php"),

        # Ardennes Classics
        "amstel" => (slug="sixes-amstel", template="https://www.velogames.com/sixes-amstel/{year}/riders.php"),
        "amstelgoldrace" => (slug="sixes-amstel", template="https://www.velogames.com/sixes-amstel/{year}/riders.php"),

        "fleche" => (slug="sixes-fleche", template="https://www.velogames.com/sixes-fleche/{year}/riders.php"),
        "flechewallonne" => (slug="sixes-fleche", template="https://www.velogames.com/sixes-fleche/{year}/riders.php"),
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
        return (slug=sanitized, template="https://www.velogames.com/$sanitized/{year}/riders.php")
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
