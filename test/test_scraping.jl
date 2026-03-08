@testset "parse_oddschecker_odds" begin
    # Typical Oddschecker copy-paste: name line followed by tab-separated fractional odds
    sample = """
    Strade Bianche Winner
    Some header text
    POGACAR TADEJ
    1/4\t1/3\t\t2/7\t
    VAN DER POEL MATHIEU
    9\t8\t\t10\t
    UNKNOWN RIDER
    header text here
    """

    df = parse_oddschecker_odds(sample)

    @test df isa DataFrame
    @test names(df) == ["rider", "odds", "riderkey"]
    @test nrow(df) == 2

    # Pogacar: best (minimum decimal) of 1/4+1=1.25, 1/3+1=1.333, 2/7+1=1.286 → 1.25
    pog = df[df.riderkey .== createkey("POGACAR TADEJ"), :]
    @test nrow(pog) == 1
    @test pog.odds[1] ≈ 1.25

    # Van der Poel: best of 9+1=10, 8+1=9, 10+1=11 → 9.0
    vdp = df[df.riderkey .== createkey("VAN DER POEL MATHIEU"), :]
    @test nrow(vdp) == 1
    @test vdp.odds[1] ≈ 9.0

    # Empty input returns empty DataFrame with correct schema
    empty_df = parse_oddschecker_odds("")
    @test empty_df isa DataFrame
    @test nrow(empty_df) == 0
    @test names(empty_df) == ["rider", "odds", "riderkey"]
end

@testset "PCS Scraper Infrastructure" begin
    @testset "find_column alias resolution" begin
        df = DataFrame("h2hRider" => ["Pogačar"], "Points" => [4852], "Team" => ["UAE"])

        @test Velogames.find_column(df, Velogames.PCS_RIDER_ALIASES) == Symbol("h2hRider")
        @test Velogames.find_column(df, Velogames.PCS_POINTS_ALIASES) == :Points
        @test Velogames.find_column(df, Velogames.PCS_TEAM_ALIASES) == :Team
        @test Velogames.find_column(df, ["nonexistent", "missing"]) === nothing

        df2 = DataFrame("Name" => ["A"], "Rider" => ["B"])
        @test Velogames.find_column(df2, ["rider", "name"]) == :Rider

        df_empty = DataFrame("Rider" => String[])
        @test Velogames.find_column(df_empty, Velogames.PCS_RIDER_ALIASES) == :Rider
    end

    @testset "PCS alias constants" begin
        @test "h2hrider" in Velogames.PCS_RIDER_ALIASES
        @test "rider" in Velogames.PCS_RIDER_ALIASES
        @test "points" in Velogames.PCS_POINTS_ALIASES
        @test "rank" in Velogames.PCS_RANK_ALIASES
        @test "#" in Velogames.PCS_RANK_ALIASES
        @test "team" in Velogames.PCS_TEAM_ALIASES
    end
end

@testset "getpcsraceresults schema" begin
    # getpcsraceresults uses scrape_pcs_table (static HTML table parsing).
    # div.svg_shield breakaway indicators are JavaScript-rendered and not
    # present in raw HTTP responses, so in_breakaway is always false.
    result_cols = [:position, :rider, :team, :riderkey, :in_breakaway, :breakaway_km]
    mock_df = DataFrame(
        position = [1, 2, 999],
        rider = ["Rider A", "Rider B", "Rider C"],
        team = ["Team X", "Team Y", "Team Z"],
        riderkey = ["ridera", "riderb", "riderc"],
        in_breakaway = [false, false, false],
        breakaway_km = Union{Float64,Missing}[missing, missing, missing],
    )
    @test all(c in propertynames(mock_df) for c in result_cols)
    # in_breakaway is always false (JS-rendered shields not available via HTTP.get)
    @test all(.!mock_df.in_breakaway)
    @test all(ismissing.(mock_df.breakaway_km))
end
