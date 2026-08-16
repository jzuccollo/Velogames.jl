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
        loaded =
            load_race_snapshot(data_type, "test-race", year; archive_dir = test_archive)
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

@testset "Prediction archive schema hardening (WP0.3)" begin
    # Future year so `_race_has_happened` short-circuits false and no I/O
    # against the real archive happens before the mandatory-column check.
    future_year = Dates.year(Dates.today()) + 1
    config = RaceConfig(
        "test-archival-wp03",
        future_year,
        :oneday,
        "",
        "",
        6,
        DEFAULT_CACHE,
        2,
        "test-archival-wp03",
        0.0,
    )

    # Missing a mandatory column (:chosen) errors loudly rather than silently
    # writing an incomplete archive.
    incomplete = DataFrame(
        riderkey = ["a", "b"],
        rider = ["A", "B"],
        team = ["T1", "T2"],
        cost = [10.0, 20.0],
        selection_frequency = [0.5, 0.3],
        expected_vg_points = [100.0, 80.0],
    )
    @test_throws ErrorException Velogames._archive_predictions(incomplete, config)

    # Synthetic archive round-trip: all mandatory columns + schema_version survive
    test_archive = mktempdir()
    complete = DataFrame(
        riderkey = ["a", "b"],
        rider = ["A", "B"],
        team = ["T1", "T2"],
        cost = [10.0, 20.0],
        chosen = [true, false],
        selection_frequency = [0.5, 0.3],
        expected_vg_points = [100.0, 80.0],
        schema_version = fill(Velogames.PREDICTION_ARCHIVE_SCHEMA_VERSION, 2),
    )
    save_race_snapshot(
        complete,
        "predictions",
        "test-archival-wp03",
        2025;
        archive_dir = test_archive,
    )
    loaded = load_race_snapshot(
        "predictions",
        "test-archival-wp03",
        2025;
        archive_dir = test_archive,
    )
    @test loaded !== nothing
    for col in Velogames.PREDICTION_MANDATORY_COLUMNS
        @test col in propertynames(loaded)
    end
    @test :schema_version in propertynames(loaded)
    @test all(loaded.schema_version .== Velogames.PREDICTION_ARCHIVE_SCHEMA_VERSION)

    # Legacy-shaped frame (missing chosen/cost/team/selection_frequency/
    # expected_vg_points — only riderkey/rider/strength survive) reads through
    # the tolerant reader path (evaluate_prospective) without throwing.
    legacy_predictions = DataFrame(
        riderkey = ["a", "b", "c", "d", "e"],
        rider = ["A", "B", "C", "D", "E"],
        strength = [5.0, 4.0, 3.0, 2.0, 1.0],
    )
    legacy_pcs_results =
        DataFrame(riderkey = ["a", "b", "c", "d", "e"], position = [1, 2, 3, 4, 5])
    save_race_snapshot(
        legacy_predictions,
        "predictions",
        "legacy-test-race",
        2024;
        archive_dir = test_archive,
    )
    save_race_snapshot(
        legacy_pcs_results,
        "pcs_results",
        "legacy-test-race",
        2024;
        archive_dir = test_archive,
    )
    result = evaluate_prospective("legacy-test-race", 2024; archive_dir = test_archive)
    @test result !== nothing
    @test result.n_matched == 5
end

@testset "Empty cache entries expire quickly" begin
    # A results page fetched before the race finishes caches as empty. Holding
    # that for the full TTL hides the real results for days afterwards, and the
    # failure is silent — the report just says results are unavailable.
    cache_dir = mktempdir()
    cache = Velogames.CacheConfig(cache_dir, 168)
    url = "https://example.invalid/ridescore.php?ga=13&st=26"

    n_fetches = Ref(0)
    fetch_func = function (_, _)
        n_fetches[] += 1
        n_fetches[] == 1 ? DataFrame() :
        DataFrame(rider = ["A"], score = [100], riderkey = ["a"])
    end

    empty_result = Velogames.cached_fetch(fetch_func, url; cache_config = cache)
    @test nrow(empty_result) == 0
    @test n_fetches[] == 1

    # Empty results stay out of the in-memory cache, so a long-lived process
    # rechecks rather than serving the miss forever.
    @test !haskey(Velogames._MEMORY_CACHE, Velogames.cache_key(url, Dict()))

    # Still within the empty-entry window → served from disk, no refetch.
    @test nrow(Velogames.cached_fetch(fetch_func, url; cache_config = cache)) == 0
    @test n_fetches[] == 1

    # Age the entry past the empty-entry window but well inside the 168h TTL.
    _, meta_file = Velogames.cache_paths(Velogames.cache_key(url, Dict()), cache_dir)
    meta = Velogames.JSON3.read(read(meta_file, String), Velogames.CacheMetadata)
    aged = Velogames.CacheMetadata(
        meta.url,
        meta.timestamp - Hour(Velogames.EMPTY_CACHE_MAX_AGE_HOURS + 1),
        meta.version,
        meta.params,
    )
    write(meta_file, Velogames.JSON3.write(aged))

    refetched = Velogames.cached_fetch(fetch_func, url; cache_config = cache)
    @test n_fetches[] == 2
    @test nrow(refetched) == 1

    # A non-empty entry keeps the full TTL.
    @test nrow(Velogames.cached_fetch(fetch_func, url; cache_config = cache)) == 1
    @test n_fetches[] == 2
end
