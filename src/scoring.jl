"""
Velogames Superclassico Sixes scoring system.

Encodes the scoring rules (finish position points, assist points, breakaway points)
by race category, and provides functions to compute expected VG points from
probability distributions over finishing positions.
"""

# ---------------------------------------------------------------------------
# Scoring table data structure
# ---------------------------------------------------------------------------

"""
    ScoringTable

Holds the Velogames scoring rules for a single race category.

Fields:
- `finish_points::Vector{Int}` – points for positions 1st through 30th (length 30)
- `assist_points::Vector{Int}` – points for being a teammate of 1st, 2nd, 3rd place (length 3)
- `breakaway_points::Int` – points per breakaway sector (4 sectors per race)
"""
struct ScoringTable
    finish_points::Vector{Int}
    assist_points::Vector{Int}
    breakaway_points::Int
end

# ---------------------------------------------------------------------------
# Scoring tables by category (from velogames.com/sixes-superclasico/2025/scores.php)
# ---------------------------------------------------------------------------

const SCORING_CAT1 = ScoringTable(
    [
        600,
        540,
        480,
        420,
        360,
        330,
        300,
        285,
        270,
        255,
        240,
        228,
        216,
        204,
        192,
        180,
        168,
        156,
        144,
        132,
        120,
        108,
        96,
        84,
        72,
        60,
        48,
        36,
        24,
        12,
    ],
    [90, 60, 30],
    60,
)

const SCORING_CAT2 = ScoringTable(
    [
        450,
        405,
        360,
        315,
        270,
        246,
        228,
        216,
        204,
        192,
        180,
        171,
        162,
        153,
        144,
        135,
        126,
        117,
        108,
        99,
        90,
        81,
        72,
        63,
        54,
        45,
        36,
        27,
        18,
        9,
    ],
    [60, 40, 20],
    45,
)

const SCORING_CAT3 = ScoringTable(
    [
        300,
        270,
        240,
        210,
        180,
        165,
        156,
        147,
        138,
        129,
        120,
        114,
        108,
        102,
        96,
        90,
        84,
        78,
        72,
        66,
        60,
        54,
        48,
        42,
        36,
        30,
        24,
        18,
        12,
        6,
    ],
    [45, 30, 15],
    30,
)

"""
Approximate stage race scoring table.

Maps overall GC finishing position to expected total VG points accumulated across
the whole race. Calibrated from historical VG grand tour results: winners typically
score 3000-4000 points, top 10 score 1000-2000, with a long tail.

This is a placeholder for the aggregate prediction approach. Proper stage-by-stage
simulation (see roadmap) would replace this with per-stage scoring.

The assist and breakaway fields are set to zero because stage race VG points
already include these components implicitly in the aggregate totals.
"""
const SCORING_STAGE = ScoringTable(
    [
        3500,
        3100,
        2800,
        2500,
        2200,
        2000,
        1850,
        1700,
        1550,
        1400,
        1280,
        1170,
        1070,
        980,
        900,
        830,
        760,
        700,
        650,
        600,
        555,
        515,
        480,
        445,
        415,
        385,
        360,
        335,
        315,
        295,
    ],
    [0, 0, 0],
    0,
)

"""
    get_scoring(category::Union{Int, Symbol}) -> ScoringTable

Return the scoring table for the given race category.

One-day categories: 1 (monuments), 2 (WT classics), 3 (semi-classics).
Stage races: `:stage`.
"""
function get_scoring(category::Int)
    if category == 1
        return SCORING_CAT1
    elseif category == 2
        return SCORING_CAT2
    elseif category == 3
        return SCORING_CAT3
    else
        throw(ArgumentError("Invalid scoring category: $category. Must be 1, 2, or 3."))
    end
end

function get_scoring(category::Symbol)
    if category == :stage
        return SCORING_STAGE
    else
        throw(ArgumentError("Invalid scoring category: $category. Must be :stage."))
    end
end

# ---------------------------------------------------------------------------
# Race schedule with categories and PCS slugs
# ---------------------------------------------------------------------------

"""
    RaceInfo

Metadata for a Superclassico race: name, date, scoring category, PCS slug.
"""
struct RaceInfo
    name::String
    date::String
    category::Int
    pcs_slug::String
end

"""Complete 2025 Superclassico race schedule with categories and PCS slugs."""
const SUPERCLASICO_RACES_2025 = [
    RaceInfo("Omloop Nieuwsblad", "2025-03-01", 2, "omloop-het-nieuwsblad"),
    RaceInfo("Kuurne-Brussel-Kuurne", "2025-03-02", 3, "kuurne-brussel-kuurne"),
    RaceInfo("Trofeo Laigueglia", "2025-03-05", 3, "trofeo-laigueglia"),
    RaceInfo("Strade Bianche", "2025-03-08", 2, "strade-bianche"),
    RaceInfo("Milano-Torino", "2025-03-19", 3, "milano-torino"),
    RaceInfo("Milano-Sanremo", "2025-03-22", 1, "milano-sanremo"),
    RaceInfo("Classic Brugge-De Panne", "2025-03-26", 2, "classic-brugge-de-panne"),
    RaceInfo("E3 Saxo Classic", "2025-03-28", 2, "e3-harelbeke"),
    RaceInfo("Gent-Wevelgem", "2025-03-30", 2, "gent-wevelgem"),
    RaceInfo("Dwars door Vlaanderen", "2025-04-02", 2, "dwars-door-vlaanderen"),
    RaceInfo("Ronde van Vlaanderen", "2025-04-06", 1, "ronde-van-vlaanderen"),
    RaceInfo("Scheldeprijs", "2025-04-09", 3, "scheldeprijs"),
    RaceInfo("Paris-Roubaix", "2025-04-13", 1, "paris-roubaix"),
    RaceInfo("De Brabantse Pijl", "2025-04-18", 3, "de-brabantse-pijl"),
    RaceInfo("Amstel Gold Race", "2025-04-20", 2, "amstel-gold-race"),
    RaceInfo("La Fleche Wallonne", "2025-04-23", 2, "la-fleche-wallonne"),
    RaceInfo("Liege-Bastogne-Liege", "2025-04-27", 1, "liege-bastogne-liege"),
    RaceInfo("Eschborn-Frankfurt", "2025-05-01", 2, "eschborn-frankfurt"),
    RaceInfo("Grand Prix du Morbihan", "2025-05-10", 3, "grand-prix-du-morbihan"),
    RaceInfo("Tro-Bro Leon", "2025-05-11", 3, "tro-bro-leon"),
    RaceInfo("Classique Dunkerque", "2025-05-13", 3, "quatre-jours-de-dunkerque"),
    RaceInfo("Brussels Cycling Classic", "2025-06-08", 2, "brussels-cycling-classic"),
    RaceInfo("Dwars door het Hageland", "2025-06-14", 3, "dwars-door-het-hageland"),
    RaceInfo("Copenhagen Sprint", "2025-06-22", 2, "copenhagen-sprint"),
    RaceInfo(
        "Donostia San Sebastian Klasikoa",
        "2025-08-02",
        2,
        "donostia-san-sebastian-klasikoa",
    ),
    RaceInfo("Circuit Franco-Belge", "2025-08-15", 3, "circuit-franco-belge"),
    RaceInfo("ADAC Cyclassics Hamburg", "2025-08-17", 2, "cyclassics-hamburg"),
    RaceInfo("Bretagne Classic", "2025-08-31", 2, "bretagne-classic"),
    RaceInfo(
        "GP Industria & Artigianato",
        "2025-09-07",
        3,
        "gp-industria-e-artigianato-di-larciano",
    ),
    RaceInfo("Coppa Sabatini", "2025-09-11", 3, "coppa-sabatini"),
    RaceInfo("Grand Prix Cycliste de Quebec", "2025-09-12", 2, "gp-quebec"),
    RaceInfo("Grand Prix Cycliste de Montreal", "2025-09-14", 2, "gp-montreal"),
    RaceInfo("Grand Prix de Wallonie", "2025-09-17", 3, "gp-de-wallonie"),
    RaceInfo("SUPER 8 Classic", "2025-09-20", 3, "super-8-classic"),
    RaceInfo("Worlds Elite Road Race", "2025-09-28", 1, "world-championship"),
    RaceInfo(
        "Sparkassen Munsterland Giro",
        "2025-10-03",
        3,
        "sparkassen-muensterland-giro",
    ),
    RaceInfo("Giro dell'Emilia", "2025-10-04", 3, "giro-dell-emilia"),
    RaceInfo("Coppa Bernocchi", "2025-10-06", 3, "coppa-bernocchi"),
    RaceInfo("Tre Valli Varesine", "2025-10-07", 3, "tre-valli-varesine"),
    RaceInfo("Gran Piemonte", "2025-10-09", 3, "gran-piemonte"),
    RaceInfo("Il Lombardia", "2025-10-11", 1, "il-lombardia"),
    RaceInfo("Paris-Tours", "2025-10-12", 3, "paris-tours"),
    RaceInfo("Giro del Veneto", "2025-10-15", 3, "giro-del-veneto"),
    RaceInfo("Veneto Classic", "2025-10-19", 3, "veneto-classic"),
]

"""
    find_race(name::String; year::Int=2025) -> Union{RaceInfo, Nothing}

Find a race in the Superclassico schedule by partial name match (case-insensitive).
Returns the first matching RaceInfo or nothing.
"""
function find_race(name::String; year::Int = 2025)
    name_lower = lowercase(name)
    if year != 2025
        error("Race schedule data only available for 2025 (requested $year)")
    end
    races = SUPERCLASICO_RACES_2025
    for race in races
        if occursin(name_lower, lowercase(race.name))
            return race
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Expected points computation
# ---------------------------------------------------------------------------

"""
    expected_finish_points(position_probs::Vector{Float64}, scoring::ScoringTable) -> Float64

Compute expected finish points from a probability distribution over positions.

`position_probs[k]` = probability of finishing in position k, for k = 1..length(position_probs).
Only positions 1-30 score points. Probabilities beyond position 30 are ignored.
"""
function expected_finish_points(
    position_probs::AbstractVector{<:Real},
    scoring::ScoringTable,
)
    n = min(length(position_probs), 30)
    total = 0.0
    for k = 1:n
        total += position_probs[k] * scoring.finish_points[k]
    end
    return total
end

"""
    expected_assist_points(teammate_top3_probs::Vector{Float64}, scoring::ScoringTable) -> Float64

Compute expected assist points for a rider given the probabilities that their
teammates finish 1st, 2nd, or 3rd.

`teammate_top3_probs[k]` = probability that at least one teammate finishes in position k,
for k = 1, 2, 3.
"""
function expected_assist_points(
    teammate_top3_probs::AbstractVector{<:Real},
    scoring::ScoringTable,
)
    @assert length(teammate_top3_probs) >= 3 "Need probabilities for positions 1, 2, 3"
    total = 0.0
    for k = 1:3
        total += teammate_top3_probs[k] * scoring.assist_points[k]
    end
    return total
end

"""
    expected_breakaway_points(breakaway_sector_probs::AbstractVector{<:Real}, scoring::ScoringTable) -> Float64

Compute expected breakaway points. `breakaway_sector_probs[k]` = probability of being
in the leading group at sector k (k = 1..4: 50% distance, 50km, 20km, 10km to go).
"""
function expected_breakaway_points(
    breakaway_sector_probs::AbstractVector{<:Real},
    scoring::ScoringTable,
)
    n = min(length(breakaway_sector_probs), 4)
    total = 0.0
    for k = 1:n
        total += breakaway_sector_probs[k] * scoring.breakaway_points
    end
    return total
end

"""
    finish_points_for_position(position::Int, scoring::ScoringTable) -> Int

Return the finish points for a given position. Positions outside 1-30 score 0.
"""
function finish_points_for_position(position::Int, scoring::ScoringTable)
    if 1 <= position <= 30
        return scoring.finish_points[position]
    else
        return 0
    end
end
