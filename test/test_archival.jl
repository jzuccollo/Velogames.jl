@testset "Archive round-trips for all data types" begin
    test_archive = mktempdir()

    # Parameterised round-trip tests
    archive_cases = [
        (
            "odds",
            DataFrame(rider = ["A", "B"], odds = [2.5, 5.0], riderkey = ["a", "b"]),
            :odds,
        ),
        (
            "oracle",
            DataFrame(rider = ["A", "B"], win_prob = [0.3, 0.1], riderkey = ["a", "b"]),
            :win_prob,
        ),
        (
            "vg_results",
            DataFrame(
                rider = ["A", "B"],
                team = ["T1", "T2"],
                score = [500, 200],
                riderkey = ["a", "b"],
            ),
            :score,
        ),
        (
            "pcs_specialty",
            DataFrame(
                riderkey = ["a", "b"],
                oneday = [1000, 500],
                gc = [800, 300],
                tt = [600, 200],
                sprint = [100, 400],
                climber = [700, 100],
            ),
            :oneday,
        ),
    ]

    for (data_type, df, check_col) in archive_cases
        year = data_type == "vg_results" ? 2024 : 2025
        save_race_snapshot(df, data_type, "test-race", year; archive_dir = test_archive)
        loaded = load_race_snapshot(data_type, "test-race", year; archive_dir = test_archive)
        @test loaded !== nothing
        @test nrow(loaded) == nrow(df)
        @test check_col in propertynames(loaded)
    end

    # Overwrite behaviour
    odds_df = DataFrame(rider = ["A"], odds = [2.5], riderkey = ["a"])
    save_race_snapshot(odds_df, "odds", "test-race", 2025; archive_dir = test_archive)
    loaded = load_race_snapshot("odds", "test-race", 2025; archive_dir = test_archive)
    @test nrow(loaded) == 1

    # Missing snapshot returns nothing
    @test load_race_snapshot("odds", "nonexistent", 2025; archive_dir = test_archive) ===
          nothing

    # archive_path produces expected structure
    p = archive_path("oracle", "milano-sanremo", 2024; archive_dir = test_archive)
    @test endswith(p, joinpath("oracle", "milano-sanremo", "2024.feather"))
end
