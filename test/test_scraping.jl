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

    # Pogacar: median of 1/4+1=1.25, 1/3+1=1.333, 2/7+1=1.286 → 1.286
    pog = df[df.riderkey .== createkey("POGACAR TADEJ"), :]
    @test nrow(pog) == 1
    @test pog.odds[1] ≈ 2/7 + 1

    # Van der Poel: median of 9+1=10, 8+1=9, 10+1=11 → 10.0
    vdp = df[df.riderkey .== createkey("VAN DER POEL MATHIEU"), :]
    @test nrow(vdp) == 1
    @test vdp.odds[1] ≈ 10.0

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

@testset "_vg_scoring_field assist headings" begin
    # Every VG assist heading contains "Team" — either "Teammate" or "Overall
    # Team". A bare "team" test run ahead of the "stage" test swallows the
    # stage-assist table and silently zeroes stage assists in the simulator.
    @test Velogames._vg_scoring_field("Assists - Teammate stage positions") ==
          :stage_assist_points
    @test Velogames._vg_scoring_field(
        "Assists - Teammate General Classification positions",
    ) == :gc_assist_points
    @test Velogames._vg_scoring_field("Assists - Overall Team competition") ==
          :team_class_assist_points
    @test Velogames._vg_scoring_field("Assists - Overall Team Classification positions") ==
          :team_class_assist_points
    # "stage" is tested after "general classification", so a heading naming
    # both files as GC.
    @test Velogames._vg_scoring_field(
        "Assists - Teammate General Classification positions after each stage",
    ) == :gc_assist_points
end

@testset "_vg_scoring_field stage-result headings" begin
    # A plain stage-result heading, and the TTT bonus table beside it.
    @test Velogames._vg_scoring_field("Stage Result") == :stage_finish_points
    @test Velogames._vg_scoring_field("Stage Result (Stage 5 team time trial)") ==
          :ttt_team_points

    # The 2025 Vuelta names the TTT only to exclude it. Read as a TTT heading,
    # first-match-wins would file this table as TTT points, leaving
    # `stage_finish_points` empty and failing the whole scrape.
    @test Velogames._vg_scoring_field(
        "Stage Result (all stages, except for the Stage 5 team time trial)",
    ) == :stage_finish_points

    # A TTT heading that is not the stage-result table stays unmodelled.
    @test Velogames._vg_scoring_field("Team time trial overall leader bonus") === nothing
end
