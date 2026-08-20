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
                rider = ["A", "B"],
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
    @test endswith(p, joinpath("oracle", "milano-sanremo", "2024.arrow"))
end

@testset "Archive enumeration API (WP1a)" begin
    tree = mktempdir()

    for (slug, years) in ("milano-sanremo" => [2024, 2025], "paris-roubaix" => [2025])
        for yr in years
            save_race_snapshot(
                DataFrame(riderkey = ["a"], rider = ["A"], odds = [2.5]),
                "odds",
                slug,
                yr;
                archive_dir = tree,
            )
        end
    end

    # Salt the tree with everything the live archive actually carries: Finder
    # droppings, a loose non-tabular input at type level, and a retired subtree.
    touch(joinpath(tree, "odds", ".DS_Store"))
    touch(joinpath(tree, "odds", "milano-sanremo", ".DS_Store"))
    touch(joinpath(tree, "odds", "milano-sanremo", "notes.txt"))
    touch(joinpath(tree, "odds", "breakaways-2025.mhtml"))
    mkpath(joinpath(tree, "_retired", "pcs_form", "e3-harelbeke"))
    touch(joinpath(tree, "_retired", "pcs_form", "e3-harelbeke", "2025.arrow"))

    @test archive_races("odds"; archive_dir = tree) ==
          ["milano-sanremo", "paris-roubaix"]
    @test archive_races("oracle"; archive_dir = tree) == String[]

    @test archive_years("odds", "milano-sanremo"; archive_dir = tree) == [2024, 2025]
    @test archive_years("odds", "paris-roubaix"; archive_dir = tree) == [2025]
    @test archive_years("odds", "nonexistent"; archive_dir = tree) == Int[]

    @test has_race_snapshot("odds", "milano-sanremo", 2024; archive_dir = tree)
    @test !has_race_snapshot("odds", "milano-sanremo", 2026; archive_dir = tree)
    @test !has_race_snapshot("oracle", "milano-sanremo", 2024; archive_dir = tree)

    # `_retired/` is a sibling of the types, so it never shows up as one.
    @test !("_retired" in archive_races("odds"; archive_dir = tree))
    @test archive_races("_retired"; archive_dir = tree) == ["pcs_form"]

    # The env var is read per call, not baked in at precompile time.
    withenv("VELOGAMES_ARCHIVE" => tree) do
        @test archive_dir() == tree
        @test archive_races("odds") == ["milano-sanremo", "paris-roubaix"]
    end
end

@testset "VG pages are read from the archive (WP1d)" begin
    tree = mktempdir()
    year = 2099              # no live page exists, so a scrape would fail loudly
    slug = Velogames.vg_classics_slug(year)

    pool = DataFrame(
        rider = ["A Rider", "B Rider"],
        team = ["T1", "T2"],
        riderkey = ["aderri", "bderri"],
        cost = [10, 6],
        points = [500, 120],
    )
    save_race_snapshot(pool, "vg_riders", slug, year; archive_dir = tree)

    # Archive-first: this must not touch the network. Velogames retires a
    # season's riders.php, so a scrape here would 404 rather than fall back.
    loaded = load_vg_classics_riders(year; archive_dir = tree)
    @test nrow(loaded) == 2
    @test Set(loaded.riderkey) == Set(pool.riderkey)
    @test loaded.cost == pool.cost

    # The race catalogue takes the same route.
    racelist = DataFrame(
        race_number = [1, 2],
        deadline = ["2099-03-01 11:00:00", "2099-03-02 12:00:00"],
        name = ["Race One", "Race Two"],
        category = [2, 3],
        namekey = ["raceone", "racetwo"],
    )
    save_race_snapshot(racelist, "vg_racelist", slug, year; archive_dir = tree)
    back = getvg_race_list(year; archive_dir = tree)
    @test nrow(back) == 2
    @test back.race_number == [1, 2]
    @test match_vg_race_number("Race Two", back) == 2
end

@testset "Arrow archive round-trip (WP1b)" begin
    tree = mktempdir()

    # Mixed types and `missing` both survive the write.
    mixed = DataFrame(
        riderkey = ["a", "b", "c"],
        rider = ["A", "B", "C"],
        odds = [2.5, 8.0, 21.0],
        cost = [10, 14, 6],
        points = [1.5, 2.25, 0.0],
        chosen = [true, false, true],
        team = ["T1", "T2", "T3"],
        note = [missing, "x", missing],
    )
    save_race_snapshot(mixed, "odds", "mixed-race", 2026; archive_dir = tree)
    loaded = load_race_snapshot("odds", "mixed-race", 2026; archive_dir = tree)

    @test names(loaded) == names(mixed)
    for c in names(mixed)
        @test isequal(loaded[!, c], mixed[!, c])
    end

    # `copycols = true` materialises the mmapped columns. Without it a loaded
    # frame is read-only backing: `sort!` and element assignment throw, which is
    # what the `rematch_riderkeys!` workaround in utilities.jl existed to dodge.
    @test loaded.riderkey isa Vector{String}
    @test sort!(loaded, :cost) isa DataFrame
    loaded.riderkey[1] = "z"
    @test loaded.riderkey[1] == "z"

    # Load, overwrite the same path, load again. A file left mmapped would keep
    # a handle open and the second write would fail or read back stale.
    save_race_snapshot(mixed, "odds", "mixed-race", 2026; archive_dir = tree)
    again = load_race_snapshot("odds", "mixed-race", 2026; archive_dir = tree)
    @test nrow(again) == nrow(mixed)

    # A planted Feather V1 file is not an archive file any more.
    planted = joinpath(tree, "odds", "mixed-race", "2019.feather")
    touch(planted)
    @test load_race_snapshot("odds", "mixed-race", 2019; archive_dir = tree) === nothing
    @test 2019 ∉ archive_years("odds", "mixed-race"; archive_dir = tree)
    @test 2026 ∈ archive_years("odds", "mixed-race"; archive_dir = tree)
end

@testset "Stage profile frame round-trip (WP3)" begin
    tree = mktempdir()
    stages = [
        StageProfile(1, :flat, 182.5, 24, 850, 0.4, 0, 0, 2, false),
        StageProfile(2, :mountain, 165.0, 310, 4200, 7.8, 2, 1, 1, true),
        StageProfile(3, :itt, 33.0, 12, 180, 0.2, 0, 0, 0, false),
    ]

    save_race_snapshot(
        stage_profiles_frame(stages),
        "pcs_stage_profiles",
        "test-tour",
        2026;
        archive_dir = tree,
    )
    loaded = load_stage_profiles("test-tour", 2026; archive_dir = tree)

    @test length(loaded) == length(stages)
    for (a, b) in zip(stages, loaded), f in fieldnames(StageProfile)
        @test getfield(a, f) == getfield(b, f)
    end

    # The narrow `stage_profiles` type is gone, not merely unused: nothing
    # writes it, so nothing should find it.
    @test load_race_snapshot("stage_profiles", "test-tour", 2026; archive_dir = tree) ===
          nothing
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

    # Synthetic archive round-trip: every mandatory column survives, and the
    # version rides in the file metadata rather than in a column of its own.
    test_archive = mktempdir()
    complete = DataFrame(
        riderkey = ["a", "b"],
        rider = ["A", "B"],
        team = ["T1", "T2"],
        cost = [10.0, 20.0],
        chosen = [true, false],
        selection_frequency = [0.5, 0.3],
        expected_vg_points = [100.0, 80.0],
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
    @test isempty(missing_mandatory_columns("predictions", loaded))
    @test :schema_version ∉ propertynames(loaded)
    prov = archive_provenance(
        "predictions",
        "test-archival-wp03",
        2025;
        archive_dir = test_archive,
    )
    @test prov["schema_version"] == string(ARCHIVE_TYPES["predictions"].version)

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
    # Planted with Arrow directly: `save_race_snapshot` would refuse both frames
    # now, which is the point — these are what the archive holds from before the
    # guard, not what anything is allowed to write today.
    for (df, data_type) in
        ((legacy_predictions, "predictions"), (legacy_pcs_results, "pcs_results"))
        path = archive_path(data_type, "legacy-test-race", 2024; archive_dir = test_archive)
        mkpath(dirname(path))
        Velogames.Arrow.write(path, df)
    end
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

@testset "Archive type guard (WP5)" begin
    tree = mktempdir()

    # An unknown type errors, and — the property actually being bought — leaves
    # no directory behind. An empty `prediction/` sitting beside `predictions/`
    # is what made a typo look like a data type for four months.
    @test_throws ErrorException save_race_snapshot(
        DataFrame(riderkey = ["a"]),
        "predicton",
        "test-race",
        2026;
        archive_dir = tree,
    )
    @test !isdir(joinpath(tree, "predicton"))

    # The narrow `stage_profiles` and every retired tree are unknown names now.
    for name in ["stage_profiles"; [r.name for r in RETIRED_ARCHIVE_TYPES]]
        @test_throws ErrorException save_race_snapshot(
            DataFrame(riderkey = ["a"]),
            name,
            "test-race",
            2026;
            archive_dir = tree,
        )
        @test !isdir(joinpath(tree, name))
    end

    # Table-driven over every entry: a frame of exactly its mandatory columns
    # writes, and dropping any one of them throws. The first half pins that
    # every entry is satisfiable, so no type is impossible to archive.
    for (data_type, spec) in ARCHIVE_TYPES
        full = DataFrame([c => ["x"] for c in spec.mandatory])
        save_race_snapshot(full, data_type, "guard-race", 2026; archive_dir = tree)
        @test has_race_snapshot(data_type, "guard-race", 2026; archive_dir = tree)

        for col in spec.mandatory
            short = select(full, Not(col))
            @test missing_mandatory_columns(data_type, short) == [col]
            @test_throws ErrorException save_race_snapshot(
                short,
                data_type,
                "guard-race",
                2027;
                archive_dir = tree,
            )
        end
    end
end

@testset "Archive provenance metadata (WP5)" begin
    tree = mktempdir()
    df = DataFrame(riderkey = ["a"], rider = ["A"], odds = [3.5])
    url = "https://www.velogames.com/sixes-classics/2026/riders.php"
    save_race_snapshot(df, "odds", "prov-race", 2026; archive_dir = tree, source_url = url)

    prov = archive_provenance("odds", "prov-race", 2026; archive_dir = tree)
    @test prov !== nothing
    @test issubset(Velogames.ARCHIVE_PROVENANCE_KEYS, collect(keys(prov)))
    @test prov["data_type"] == "odds"
    @test prov["source_url"] == url
    @test prov["schema_version"] == "1"
    @test !isempty(prov["machine"])

    # Provenance is metadata, not columns: nothing joins against it, and the
    # allowlist in `_archive_predictions` cannot drop it.
    loaded = load_race_snapshot("odds", "prov-race", 2026; archive_dir = tree)
    @test names(loaded) == names(df)

    # A file written before WP5 has none, and that is not an error on read.
    path = archive_path("odds", "legacy-race", 2026; archive_dir = tree)
    mkpath(dirname(path))
    Velogames.Arrow.write(path, df)
    @test archive_provenance("odds", "legacy-race", 2026; archive_dir = tree) === nothing
    @test nrow(load_race_snapshot("odds", "legacy-race", 2026; archive_dir = tree)) == 1
end

@testset "Archive manifest is derived, not maintained (WP5)" begin
    tree = mktempdir()
    @test !archive_manifest_matches(; archive_dir = tree)

    path = write_archive_manifest(; archive_dir = tree)
    @test archive_manifest_matches(; archive_dir = tree)

    manifest = TOML.parsefile(path)
    @test Set(keys(manifest["types"])) == Set(keys(ARCHIVE_TYPES))
    @test Set(keys(manifest["retired"])) == Set(r.name for r in RETIRED_ARCHIVE_TYPES)
    @test Set(keys(manifest["raw"])) == Set(t.name for t in RAW_ARCHIVE_TREES)
    for (name, spec) in ARCHIVE_TYPES
        entry = manifest["types"][name]
        @test entry["version"] == spec.version
        @test entry["mandatory"] == String.(spec.mandatory)
        @test entry["refetchable"] == spec.refetchable
    end

    # Hand-edited, so it no longer describes the archive: `--check` says so.
    write(path, replace(read(path, String), "[types.\"odds\"]" => "[types.\"oddz\"]"))
    @test !archive_manifest_matches(; archive_dir = tree)
end

@testset "Archive audit finds the legacy defects (WP5)" begin
    tree = mktempdir()
    good = DataFrame(riderkey = ["a"], rider = ["A"], odds = [3.5])
    save_race_snapshot(good, "odds", "clean-race", 2026; archive_dir = tree)

    # One planted defect of each kind, all of them things the write guard would
    # now refuse — which is exactly why the audit has to look for them on disk.
    mkpath(joinpath(tree, "oddz", "typo-race"))
    Velogames.Arrow.write(
        joinpath(tree, "oddz", "typo-race", "2026.arrow"),
        DataFrame(riderkey = ["a"]),
    )
    short_path = archive_path("odds", "short-race", 2026; archive_dir = tree)
    mkpath(dirname(short_path))
    Velogames.Arrow.write(short_path, DataFrame(riderkey = ["a"], rider = ["A"]))
    touch(joinpath(tree, "odds", "clean-race", "notes.txt"))
    mkpath(joinpath(tree, "odds", "hollow-race"))
    mkpath(joinpath(tree, "_retired", "pcs_form", "e3-harelbeke"))
    touch(joinpath(tree, "_retired", "pcs_form", "e3-harelbeke", "2025.arrow"))

    a = audit_archive(; archive_dir = tree)

    @test a.unknown_types == ["oddz"]
    @test a.stray_files == [joinpath(tree, "odds", "clean-race", "notes.txt")]
    @test a.empty_races == [joinpath("odds", "hollow-race")]
    @test [x.path for x in a.missing_columns] == [short_path]
    @test a.missing_columns[1].missing == [:odds]
    # The clean file was stamped on write; the two planted ones were not.
    @test Set(a.missing_provenance) ==
          Set([short_path, joinpath(tree, "oddz", "typo-race", "2026.arrow")])
    @test isempty(a.unreadable)
    odds_count = only(c for c in a.counts if c.data_type == "odds")
    @test odds_count.files == 2
    @test odds_count.races == 3
end

@testset "Per-race startlist is the field (Phase 1c)" begin
    tree = mktempdir()
    year = 2099              # no live page exists, so a scrape would fail loudly
    slug = Velogames.vg_classics_slug(year)

    save_race_snapshot(
        DataFrame(
            rider = ["A Rider", "B Rider", "C Rider", "D Rider"],
            team = ["T1", "T2", "T3", "T4"],
            riderkey = createkey.(["A Rider", "B Rider", "C Rider", "D Rider"]),
            cost = [20, 10, 8, 6],
            points = [900, 400, 120, 60],
        ),
        "vg_riders",
        slug,
        year;
        archive_dir = tree,
    )
    save_race_snapshot(
        DataFrame(
            race_number = [7],
            deadline = ["2099-03-21 11:00:00"],
            name = ["Milano-Sanremo"],
            category = [1],
            namekey = ["milanosanremo"],
        ),
        "vg_racelist",
        slug,
        year;
        archive_dir = tree,
    )
    # A and D scored; C started and didn't.
    save_race_snapshot(
        DataFrame(
            rider = ["A Rider", "D Rider"],
            team = ["T1", "T4"],
            riderkey = createkey.(["A Rider", "D Rider"]),
            score = [500, 200],
        ),
        "vg_results",
        "milano-sanremo",
        year;
        archive_dir = tree,
    )
    # PCS saw only the two finishers, so the old filter would lose C entirely.
    save_race_snapshot(
        DataFrame(
            riderkey = createkey.(["A Rider", "C Rider"]),
            rider = ["A Rider", "C Rider"],
            team = ["T1", "T3"],
            position = [1, 40],
            in_breakaway = [false, false],
            breakaway_km = [0.0, 0.0],
        ),
        "pcs_results",
        "milano-sanremo",
        year;
        archive_dir = tree,
    )

    withenv("VELOGAMES_ARCHIVE" => tree) do
        # No startlist yet: the field is the season pool filtered through PCS.
        @test load_vg_startlist("milano-sanremo", year) === nothing
        pcs_filtered = load_report_data("milano-sanremo", year)
        @test Set(pcs_filtered.rider) == Set(["A Rider", "C Rider"])

        # With one, the field is Velogames' own — D, who scored but never
        # reached PCS, comes back, and the whole race's points are on the page.
        save_race_snapshot(
            DataFrame(
                race_number = [7, 7, 7],
                race_name = ["Milano-Sanremo", "Milano-Sanremo", "Milano-Sanremo"],
                rider = ["A Rider", "B Rider", "C Rider"],
                riderkey = createkey.(["A Rider", "B Rider", "C Rider"]),
                team = ["T1", "T2", "T3"],
                cost = [20, 10, 8],
                points = [900, 400, 120],
                class = ["", "", ""],
                start_list = ["#MilanoSanremo", "#MilanoSanremo", "#MilanoSanremo"],
            ),
            "vg_startlist",
            slug,
            year;
            archive_dir = tree,
        )
        @test nrow(load_vg_startlist("milano-sanremo", year)) == 3

        df = load_report_data("milano-sanremo", year)
        # A startlist captured after the race is not a superset of the results:
        # anyone in vg_results is in the field whatever the startlist says.
        @test Set(df.rider) == Set(["A Rider", "B Rider", "C Rider", "D Rider"])
        @test sum(df.score) == 700
        @test nrow(df) == length(unique(df.riderkey))
        @test only(filter(:rider => ==("D Rider"), df).cost) == 6
    end
end
