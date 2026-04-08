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

Holds the Velogames scoring rules for a single one-day race category.

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

"""
    StageRaceScoringTable

Holds the Velogames scoring rules for grand tour stage races (TDF, Giro, Vuelta).
Scoring is identical across all three grand tours.

VG uses a single scoring table for ALL stage types — no variation by flat/mountain/ITT.
"""
struct StageRaceScoringTable
    # Per-stage scoring (applied every stage)
    stage_finish_points::Vector{Int}         # length 20: positions 1-20
    daily_gc_points::Vector{Int}             # length 20: GC positions 1-20
    daily_points_class::Vector{Int}          # length 6: points classification top 6
    daily_mountains_class::Vector{Int}       # length 6: mountains classification top 6

    # In-stage bonuses
    intermediate_sprint_points::Vector{Int}  # length 10: sprint positions 1-10
    hc_climb_points::Vector{Int}             # length 8: HC climb positions 1-8
    cat1_climb_points::Vector{Int}           # length 5: Cat 1 climb positions 1-5
    breakaway_points::Int                    # points per rider in break at 50%

    # Assist points (stage finish, GC, team classification)
    stage_assist_points::Vector{Int}         # length 3: teammate in stage top 3
    gc_assist_points::Vector{Int}            # length 3: teammate in GC top 3
    team_class_assist_points::Vector{Int}    # length 3: team in team class top 3

    # Final classification bonuses (end of race)
    final_gc_points::Vector{Int}             # length 30: final GC positions 1-30
    final_points_class::Vector{Int}          # length 10: final points classification
    final_mountains_class::Vector{Int}       # length 10: final mountains classification
    final_team_class::Vector{Int}            # length 5: final team classification

    # TTT stage scoring (if applicable)
    ttt_team_points::Vector{Int}             # length 8: TTT team positions 1-8
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

const SCORING_GRAND_TOUR = StageRaceScoringTable(
    # Stage finish (positions 1-20)
    [220, 180, 160, 140, 120, 110, 95, 80, 70, 60, 50, 40, 35, 30, 25, 20, 16, 12, 8, 4],
    # Daily GC (positions 1-20)
    [30, 26, 22, 18, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1],
    # Daily points classification (top 6)
    [12, 8, 6, 4, 2, 1],
    # Daily mountains classification (top 6)
    [12, 8, 6, 4, 2, 1],
    # Intermediate sprints (top 10)
    [20, 16, 12, 8, 6, 5, 4, 3, 2, 1],
    # HC climbs (top 8)
    [30, 25, 20, 15, 10, 6, 4, 2],
    # Cat 1 climbs (top 5)
    [15, 10, 6, 4, 2],
    # Breakaway at 50% distance
    20,
    # Stage assists (teammate in stage top 3)
    [8, 4, 2],
    # GC assists (teammate in GC top 3)
    [8, 4, 2],
    # Team classification assists (team in top 3)
    [8, 4, 2],
    # Final GC (positions 1-30)
    [600, 500, 400, 350, 300, 260, 220, 200, 180, 160, 140, 130, 120, 110, 100, 90, 80, 70, 60, 55, 50, 45, 40, 35, 30, 25, 20, 15, 10, 5],
    # Final points classification (top 10)
    [120, 100, 80, 60, 40, 30, 20, 15, 10, 5],
    # Final mountains classification (top 10)
    [120, 100, 80, 60, 40, 30, 20, 15, 10, 5],
    # Final team classification (top 5)
    [50, 40, 30, 20, 10],
    # TTT team (top 8)
    [50, 40, 30, 25, 20, 15, 10, 5],
)

get_stage_race_scoring() = SCORING_GRAND_TOUR

"""
    stage_finish_points_for_position(position, scoring) -> Int

Return stage finish points for a given position. Positions outside 1-20 score 0.
"""
function stage_finish_points_for_position(position::Int, scoring::StageRaceScoringTable)
    1 <= position <= length(scoring.stage_finish_points) ? scoring.stage_finish_points[position] : 0
end

"""
    daily_gc_points_for_position(position, scoring) -> Int

Return daily GC classification points for a given GC position. Positions outside 1-20 score 0.
"""
function daily_gc_points_for_position(position::Int, scoring::StageRaceScoringTable)
    1 <= position <= length(scoring.daily_gc_points) ? scoring.daily_gc_points[position] : 0
end

"""
    final_gc_points_for_position(position, scoring) -> Int

Return final GC classification bonus for a given position. Positions outside 1-30 score 0.
"""
function final_gc_points_for_position(position::Int, scoring::StageRaceScoringTable)
    1 <= position <= length(scoring.final_gc_points) ? scoring.final_gc_points[position] : 0
end

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

# ---------------------------------------------------------------------------
# Breakaway rate estimation
# ---------------------------------------------------------------------------

"""
    compute_breakaway_rates(breakaway_df, startlist_keys; history_years=3, max_rate=0.35, mean_sectors=2.0)
        -> (rates::Vector{Float64}, sectors::Vector{Float64})

Convert PCS season-total breakaway km into per-rider, per-race breakaway
probability and expected sector count for use in VG simulations.

Returns two vectors aligned to `startlist_keys`:
- `rates[i]`: probability that rider i is in a breakaway in any given race
- `sectors[i]`: expected number of sectors if they are in a breakaway

Riders not found in the breakaway data get rate 0.0.

The `max_rate` parameter caps the top breakaway rider's per-race probability.
Other riders' rates are proportional to their average annual breakaway km.
"""
function compute_breakaway_rates(
    breakaway_df::DataFrame,
    startlist_keys::AbstractVector{<:AbstractString};
    history_years::Int=3,
    max_rate::Float64=0.35,
    mean_sectors::Float64=2.0,
)
    # Filter to recent years and compute average annual km per rider
    max_year = maximum(breakaway_df.year)
    recent = filter(row -> row.year > max_year - history_years, breakaway_df)

    rider_avg_km = combine(groupby(recent, :riderkey), :breakaway_km => mean => :avg_km)

    # Normalise: top rider gets max_rate, others proportional
    max_km = nrow(rider_avg_km) > 0 ? maximum(rider_avg_km.avg_km) : 1.0
    km_lookup = Dict(row.riderkey => row.avg_km for row in eachrow(rider_avg_km))

    rates = Float64[]
    sectors = Float64[]
    for key in startlist_keys
        km = get(km_lookup, key, 0.0)
        rate = km > 0.0 ? max_rate * km / max_km : 0.0
        push!(rates, rate)
        push!(sectors, km > 0.0 ? mean_sectors : 0.0)
    end

    return rates, sectors
end
