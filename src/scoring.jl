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

VG uses one scoring table across stage types, with the sole exception of team
time trials, which score off `ttt_team_points` (every rider shares the squad's
placing). Flat/mountain/ITT stages share the same finish/GC/bonus tables.
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
    stage_assist_points::Vector{Int}         # teammate in stage top N (length varies by scraped scoring)
    gc_assist_points::Vector{Int}            # teammate in GC top N (length varies by scraped scoring)
    team_class_assist_points::Vector{Int}    # team in team class top N (length varies by scraped scoring)

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
score 3000-4000 points, top 10 score 1000-2000, with a long tail. The per-stage
simulator scores with `SCORING_GRAND_TOUR` instead.

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
    [
        600,
        500,
        400,
        350,
        300,
        260,
        220,
        200,
        180,
        160,
        140,
        130,
        120,
        110,
        100,
        90,
        80,
        70,
        60,
        55,
        50,
        45,
        40,
        35,
        30,
        25,
        20,
        15,
        10,
        5,
    ],
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
    1 <= position <= length(scoring.stage_finish_points) ?
    scoring.stage_finish_points[position] : 0
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
    history_years::Int = 3,
    max_rate::Float64 = 0.35,
    mean_sectors::Float64 = 2.0,
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

# ---------------------------------------------------------------------------
# Breakaway rates from the per-race archive
# ---------------------------------------------------------------------------

"""
One `(rider, race)` breakaway observation per row, built once per archive dir.

Reading 131 `pcs_results` files costs about a second, and every backtest race
wants the same table filtered to a different date, so it is built once and
filtered per call. Keyed by `archive_dir` because the tests use a scratch one.
"""
const _BREAKAWAY_OBS = Dict{String,DataFrame}()

"""
    breakaway_observations(; archive_dir, force_rebuild = false) -> DataFrame

Every archived one-day result as `(riderkey, slug, year, date, in_break, km,
sectors)`.

`sectors` is what VG actually pays on: it awards `breakaway_points` at four
checkpoints (half distance, then 50/20/10 km to go), so a rider's km in the
break converts to a sector count via `breakaway_sectors_from_km` against that
race's distance.

Rows for riders who were not in the break are kept: they are the denominator,
since a rate is breaks over starts.
"""
function breakaway_observations(;
    archive_dir::String = archive_dir(),
    force_rebuild::Bool = false,
)
    if !force_rebuild && haskey(_BREAKAWAY_OBS, archive_dir)
        return _BREAKAWAY_OBS[archive_dir]
    end
    rows = DataFrame(
        riderkey = String[],
        slug = String[],
        year = Int[],
        date = Date[],
        in_break = Bool[],
        km = Union{Float64,Missing}[],
        sectors = Int[],
    )
    for slug in archive_races("pcs_results"; archive_dir = archive_dir)
        race_format(slug) == :stage && continue
        pattern = try
            get_url_pattern(slug)
        catch
            nothing
        end
        distance = pattern === nothing ? 0.0 : pattern.total_distance_km
        for year in archive_years("pcs_results", slug; archive_dir = archive_dir)
            df = load_race_snapshot("pcs_results", slug, year; archive_dir = archive_dir)
            (df === nothing || !hasproperty(df, :in_breakaway)) && continue
            date = something(resolve_race_date(slug, year), Date(year, 12, 31))
            for r in eachrow(df)
                km = hasproperty(df, :breakaway_km) ? r.breakaway_km : missing
                sectors =
                    (r.in_breakaway && !ismissing(km)) ?
                    breakaway_sectors_from_km(Float64(km), distance) : 0
                push!(rows, (r.riderkey, slug, year, date, r.in_breakaway, km, sectors))
            end
        end
    end
    _BREAKAWAY_OBS[archive_dir] = rows
    return rows
end

"""
    compute_breakaway_rates_archive(startlist_keys; as_of, ...) -> (rates, sectors)

Per-rider breakaway probability and expected sector count, from the per-race
archive rather than a season leaderboard.

Unlike `compute_breakaway_rates`, which scales by season kilometres, the rate is
breaks over starts: a rider with six 100 km breaks rates twice one with three
200 km breaks, being twice as likely to be in tomorrow's move. Every row is
dated by its race, so `as_of` gives an as-of-race-day view that a season total
cannot.

# Keyword arguments
- `as_of`: ignore races on or after this date. Required for temporal integrity;
  pass the race date being predicted.
- `history_years`: how far back to look.
- `prior_strength`: Beta prior pseudo-starts. Rates are sparse — the field mean
  is about 0.035 over ~23 starts a rider — so an unshrunk 2-in-8 reads as 0.25
  on almost no evidence. The prior mean is the field rate over the same window,
  so this shrinks toward what a typical rider does. Team-points-captured rose
  monotonically over 10 → 29 → 60 → 120 (+0.007, +0.0146, +0.0158, +0.0168
  against breakaway-off), so 120 is the largest value tested, not an optimum.
- `km_weighted`: weight each break by its sector count rather than counting it
  as one. Distance is informative beyond the binary flag (ρ(km, VG score) ≈
  0.41); off by default because it makes the "rate" no longer a probability.
- `decay_rate`: exponential recency decay in years, 0.0 for flat.
- `max_rate`: hard cap, a guard against a rider with two starts and two breaks
  reading as certain.
"""
function compute_breakaway_rates_archive(
    startlist_keys::AbstractVector{<:AbstractString};
    as_of::Date,
    history_years::Int = 3,
    prior_strength::Float64 = 120.0,
    km_weighted::Bool = false,
    decay_rate::Float64 = 0.0,
    max_rate::Float64 = 0.5,
    archive_dir::String = archive_dir(),
)
    obs = breakaway_observations(; archive_dir = archive_dir)
    cutoff = as_of - Year(history_years)
    window = filter(r -> cutoff <= r.date < as_of, obs)

    n = length(startlist_keys)
    isempty(window) && return zeros(n), zeros(n)

    weight(date) =
        decay_rate <= 0.0 ? 1.0 :
        exp(-decay_rate * (Dates.value(as_of - date) / 365.25))
    credit(row) = km_weighted ? Float64(row.sectors) : 1.0

    starts = Dict{String,Float64}()
    breaks = Dict{String,Float64}()
    sector_sum = Dict{String,Float64}()
    sector_n = Dict{String,Float64}()
    for r in eachrow(window)
        w = weight(r.date)
        starts[r.riderkey] = get(starts, r.riderkey, 0.0) + w
        r.in_break || continue
        breaks[r.riderkey] = get(breaks, r.riderkey, 0.0) + w * credit(r)
        sector_sum[r.riderkey] = get(sector_sum, r.riderkey, 0.0) + w * r.sectors
        sector_n[r.riderkey] = get(sector_n, r.riderkey, 0.0) + w
    end

    # Field rates, used as the shrinkage target so a rider with no history lands
    # on the field rate, not zero.
    total_starts = sum(values(starts); init = 0.0)
    total_breaks = sum(values(breaks); init = 0.0)
    field_rate = total_starts > 0 ? total_breaks / total_starts : 0.0
    total_sectors = sum(values(sector_sum); init = 0.0)
    total_sector_n = sum(values(sector_n); init = 0.0)
    field_sectors = total_sector_n > 0 ? total_sectors / total_sector_n : 2.0

    rates = Float64[]
    sectors = Float64[]
    for key in startlist_keys
        s = get(starts, key, 0.0)
        b = get(breaks, key, 0.0)
        # Beta-binomial posterior mean, with the prior centred on the field rate.
        rate = (b + prior_strength * field_rate) / (s + prior_strength)
        push!(rates, min(rate, max_rate))
        sn = get(sector_n, key, 0.0)
        # Sector counts shrink too, on a weaker prior: a rider with three breaks
        # has three real observations of how far he goes, which is more than he
        # has about whether he goes at all.
        push!(
            sectors,
            (get(sector_sum, key, 0.0) + 2.0 * field_sectors) / (sn + 2.0),
        )
    end
    return rates, sectors
end
