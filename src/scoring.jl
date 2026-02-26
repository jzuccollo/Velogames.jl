"""
Velogames Sixes Classics scoring system.

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
# Scoring tables by category (from velogames.com/sixes-classics/2026/scores.php)
# ---------------------------------------------------------------------------

const SCORING_CAT1 = ScoringTable(
    [
        640,
        560,
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
        480,
        420,
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
        320,
        280,
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
