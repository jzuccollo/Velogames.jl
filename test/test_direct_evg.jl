# Direct-EVG challenger (WP2.2) — synthetic-only tests, no network/archive.
using Velogames: _rank_curve_log, _evg_from_inputs, _fit_rank_curve

# Hand-built params so tests pin behaviour, not the fitted values.
const TEST_EVG_PARAMS = DirectEVGParams(8.0, 1.0, 2.0, 30.0, 0.8, 2.0, 2.0, 2.0)

_inputs(; riderkeys, ability_rank, market_rank = zeros(Int, length(riderkeys)),
    hist = [Tuple{Float64,Int}[] for _ in riderkeys]) =
    (; riderkeys, ability_rank, market_rank, hist)

@testset "rank curve is monotone decreasing" begin
    p = TEST_EVG_PARAMS
    @test _rank_curve_log(1, p) > _rank_curve_log(5, p) > _rank_curve_log(50, p)

    # The fit recovers a monotone curve from realistic decreasing totals.
    fake_totals = [3000.0 * r^-1.2 for r = 1:150]
    a, k, s = _fit_rank_curve([fake_totals, fake_totals], 30.0)
    @test k > 0
    @test s >= 0
    fitted = DirectEVGParams(a, k, s, 30.0, 0.8, 2.0, 2.0, 2.0)
    curve = [_rank_curve_log(r, fitted) for r = 1:150]
    @test issorted(curve; rev = true)

    # DEFAULT_DIRECT_EVG_PARAMS (the committed fit) is monotone too.
    dcurve = [_rank_curve_log(r, DEFAULT_DIRECT_EVG_PARAMS) for r = 1:200]
    @test issorted(dcurve; rev = true)
    @test DEFAULT_DIRECT_EVG_PARAMS.market_weight == 2.0  # fixed prior, never fitted
end

@testset "per-rider component availability" begin
    p = TEST_EVG_PARAMS

    # Debutant + unpriced → ability component only, exactly the curve value.
    inputs = _inputs(riderkeys = ["debutant"], ability_rank = [50])
    evg = _evg_from_inputs(inputs, p)
    @test evg[1] ≈ exp(_rank_curve_log(50, p)) - p.floor

    # A priced rider shifts toward the market ordering, in both directions.
    inputs = _inputs(
        riderkeys = ["unpriced", "market_likes", "market_dislikes", "top_unpriced"],
        ability_rank = [50, 51, 5, 4],
        market_rank = [0, 1, 60, 0],
    )
    evg = _evg_from_inputs(inputs, p)
    @test evg[2] > evg[1]   # market rank 1 lifts a mid-ability rider
    @test evg[3] < evg[4]   # market rank 60 drags a top-ability rider
end

@testset "history shrinkage grows with edition count" begin
    p = TEST_EVG_PARAMS
    # Same ability, same per-edition score: 3 consistent editions move the
    # blend further from ability-only than 1 edition does.
    inputs = _inputs(
        riderkeys = ["debutant", "one_edition", "three_editions"],
        ability_rank = [50, 50, 50],
        hist = [
            Tuple{Float64,Int}[],
            [(500.0, 1)],
            [(500.0, 1), (500.0, 2), (500.0, 3)],
        ],
    )
    evg = _evg_from_inputs(inputs, p)
    @test evg[1] < evg[2] < evg[3]   # history 500 ≫ ability-implied points here

    # Two-sided: a big-ability rider with a small history is pulled down more
    # by 3 consistent low editions than by 1.
    inputs = _inputs(
        riderkeys = ["fresh", "one_low", "three_low"],
        ability_rank = [3, 3, 3],
        hist = [
            Tuple{Float64,Int}[],
            [(40.0, 1)],
            [(40.0, 1), (40.0, 2), (40.0, 3)],
        ],
    )
    evg = _evg_from_inputs(inputs, p)
    @test evg[1] > evg[2] > evg[3]
end

@testset "floor regularises near-zero components" begin
    p = TEST_EVG_PARAMS
    inputs = _inputs(
        riderkeys = ["zero_hist", "worst_rank"],
        ability_rank = [10, 200],
        hist = [[(0.0, 1), (0.0, 2), (0.0, 3)], Tuple{Float64,Int}[]],
    )
    evg = _evg_from_inputs(inputs, p)
    @test all(isfinite, evg)
    @test all(>=(0.0), evg)
end

@testset "direct_evg returns the full riderkey set with finite values" begin
    n = 10
    riders = DataFrame(
        rider = ["Rider $i" for i = 1:n],
        riderkey = ["rider$i" for i = 1:n],
        team = ["Team $(1 + i % 3)" for i = 1:n],
        cost = [24, 18, 14, 12, 10, 8, 6, 6, 4, 4],
        classraw = ["All Rounder", "All Rounder", "Climber", "Sprinter", "Climber",
                    "Sprinter", "Unclassed", "Unclassed", "Unclassed", "Unclassed"],
        points = [1500.0, 1200.0, 900.0, 800.0, 600.0, 400.0, 200.0, 150.0, 100.0, 50.0],
        gc = [2000.0, 1500.0, 900.0, 200.0, 700.0, 100.0, 300.0, 250.0, 200.0, 150.0],
        tt = [1500.0, 900.0, 400.0, 300.0, 350.0, 200.0, 250.0, 200.0, 150.0, 100.0],
        sprint = [300.0, 200.0, 100.0, 2000.0, 150.0, 1500.0, 200.0, 180.0, 160.0, 140.0],
        climber = [1200.0, 1000.0, 1800.0, 100.0, 1400.0, 80.0, 300.0, 250.0, 200.0, 150.0],
        oneday = [1800.0, 1200.0, 700.0, 800.0, 500.0, 600.0, 300.0, 250.0, 200.0, 150.0],
        has_pcs_data = fill(true, n),
    )
    # rider9 (cheap) has two big prior GT totals; rider10 is its debutant twin
    # in every signal. rider5 is priced as a market favourite; rider3 is its
    # closest unpriced comparator.
    gt_hist = DataFrame(
        riderkey = ["rider9", "rider9"],
        score = [5000.0, 5000.0],
        year = [2024, 2025],
        gt_slug = ["giro-d-italia", "tour-de-france"],
    )
    odds_df = DataFrame(
        rider = ["Rider 5", "Rider 1"],
        odds = [3.0, 1.5],
        riderkey = ["rider5", "rider1"],
    )
    data = StageRaceBacktestData(
        "giro-d-italia",
        "giro",
        2026,
        nothing,
        riders,
        RaceData(rider_df = riders, odds_df = odds_df),
        StageProfile[],
        SCORING_GRAND_TOUR,
        gt_hist,
        nothing,
        nothing,
        nothing,
    )

    result = direct_evg(data)
    @test names(result) == ["riderkey", "expected_vg_points"]
    @test sort(result.riderkey) == sort(riders.riderkey)
    @test all(isfinite, result.expected_vg_points)
    @test all(>=(0.0), result.expected_vg_points)

    evg = Dict(zip(result.riderkey, result.expected_vg_points))
    @test evg["rider9"] > evg["rider10"]   # big prior GT totals lift the cheap rider
    @test evg["rider5"] > evg["rider3"]    # market favourite beats unpriced comparator
end
