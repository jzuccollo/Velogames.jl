@testset "Archive round-trips for all data types" begin
    test_archive = mktempdir()

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

    @test load_race_snapshot("odds", "nonexistent", 2025; archive_dir = test_archive) ===
          nothing

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

    # Salt the tree with everything the live archive carries: Finder
    # droppings, a loose non-tabular input at type level, and a retired subtree.
    touch(joinpath(tree, "odds", ".DS_Store"))
    touch(joinpath(tree, "odds", "milano-sanremo", ".DS_Store"))
    touch(joinpath(tree, "odds", "milano-sanremo", "notes.txt"))
    touch(joinpath(tree, "odds", "breakaways-2025.mhtml"))
    mkpath(joinpath(tree, "_retired", "pcs_form", "e3-harelbeke"))
    touch(joinpath(tree, "_retired", "pcs_form", "e3-harelbeke", "2025.arrow"))

    @test archive_races("odds"; archive_dir = tree) == ["milano-sanremo", "paris-roubaix"]
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
    # frame is read-only backing: `sort!` and element assignment throw.
    @test loaded.riderkey isa Vector{String}
    @test sort!(loaded, :cost) isa DataFrame
    loaded.riderkey[1] = "z"
    @test loaded.riderkey[1] == "z"

    # Load, overwrite the same path, load again. A file left mmapped would keep
    # a handle open and the second write would fail or read back stale.
    save_race_snapshot(mixed, "odds", "mixed-race", 2026; archive_dir = tree)
    again = load_race_snapshot("odds", "mixed-race", 2026; archive_dir = tree)
    @test nrow(again) == nrow(mixed)

    # A planted Feather V1 file is not an archive file.
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

    # Nothing writes the narrow `stage_profiles` type, so nothing should find it.
    @test load_race_snapshot("stage_profiles", "test-tour", 2026; archive_dir = tree) ===
          nothing
end

@testset "Grand tours are dated like classics" begin
    # A stage race with no resolved date falls to `_race_has_happened`'s
    # "unknown date — protect by default" branch and reads as already run, which
    # makes a grand tour's prediction archive write-once: every pre-race re-run
    # after the first is declined.
    stage_cfg(name, year) =
        suppress_output(() -> setup_race(name, year, :stage))
    oneday_cfg(name, year) =
        suppress_output(() -> setup_race(name, year, :oneday))

    this_year = Dates.year(Dates.today())

    # Every grand tour resolves to a date.
    for name in ("giro", "tdf", "vuelta")
        cfg = stage_cfg(name, this_year)
        @test Velogames.resolve_race_date(cfg.pcs_slug, this_year) !== nothing
    end

    # A past year is protected and a future year is not, for both formats.
    @test Velogames._race_has_happened(stage_cfg("vuelta", this_year - 1))
    @test !Velogames._race_has_happened(stage_cfg("vuelta", this_year + 1))
    @test Velogames._race_has_happened(oneday_cfg("roubaix", this_year - 1))
    @test !Velogames._race_has_happened(oneday_cfg("roubaix", this_year + 1))

    # Within the current year the answer tracks the resolved date.
    for name in ("giro", "tdf", "vuelta")
        cfg = stage_cfg(name, this_year)
        date = Velogames.resolve_race_date(cfg.pcs_slug, this_year)
        @test Velogames._race_has_happened(cfg) == (date < Dates.today())
    end

    # An unknown slug keeps the protective default.
    unknown = RaceConfig(
        "no-such-race",
        this_year,
        :oneday,
        "",
        "",
        6,
        DEFAULT_CACHE,
        2,
        "no-such-race",
        0.0,
    )
    @test Velogames.resolve_race_date(unknown.pcs_slug, this_year) === nothing
    @test Velogames._race_has_happened(unknown)
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

    # Missing a mandatory column (:chosen) errors instead of writing an
    # incomplete archive.
    incomplete = DataFrame(
        riderkey = ["a", "b"],
        rider = ["A", "B"],
        team = ["T1", "T2"],
        cost = [10.0, 20.0],
        selection_frequency = [0.5, 0.3],
        expected_vg_points = [100.0, 80.0],
    )
    @test_throws ErrorException Velogames._archive_predictions(incomplete, config)

    # Every mandatory column survives the round-trip, and the schema version is
    # file metadata, not a column.
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
    # Planted with Arrow directly, since `save_race_snapshot` refuses both
    # frames: they stand for files written before the guard existed.
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
    # that for the full TTL silently hides the real results for days afterwards.
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
    # rechecks.
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

    # An unknown type errors and leaves no directory behind: an empty
    # `prediction/` beside `predictions/` makes a typo look like a data type.
    @test_throws ErrorException save_race_snapshot(
        DataFrame(riderkey = ["a"]),
        "predicton",
        "test-race",
        2026;
        archive_dir = tree,
    )
    @test !isdir(joinpath(tree, "predicton"))

    # The narrow `stage_profiles` and every retired tree are unknown names.
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

@testset "Archive hollow-column guard" begin
    tree = mktempdir()

    # A mandatory column present in every row but carrying nothing in any of
    # them: what a blocked fetch that does not error writes, with riderkey and
    # rider populated and a rating column all-`missing`.
    hollow = DataFrame(
        riderkey = ["a", "b"],
        rider = ["A", "B"],
        oneday = [missing, missing],
        gc = [800, 300],
        tt = [600, 200],
        sprint = [100, 400],
        climber = [700, 100],
    )
    @test hollow_mandatory_columns("pcs_specialty", hollow) == [:oneday]
    @test_throws ErrorException save_race_snapshot(
        hollow,
        "pcs_specialty",
        "hollow-guard-race",
        2026;
        archive_dir = tree,
    )
    @test !has_race_snapshot("pcs_specialty", "hollow-guard-race", 2026; archive_dir = tree)

    # Zero stays a value: a column that is all zeros is real data,
    # not a blocked fetch, so it writes.
    zeroed = DataFrame(
        riderkey = ["a", "b"],
        rider = ["A", "B"],
        oneday = [0, 0],
        gc = [800, 300],
        tt = [600, 200],
        sprint = [100, 400],
        climber = [700, 100],
    )
    @test isempty(hollow_mandatory_columns("pcs_specialty", zeroed))
    save_race_snapshot(zeroed, "pcs_specialty", "hollow-guard-race", 2026; archive_dir = tree)
    @test has_race_snapshot("pcs_specialty", "hollow-guard-race", 2026; archive_dir = tree)

    # An all-empty-string column is not hollow: Julia writers use `missing`
    # uniformly for "the fetch found nothing", so a real `""` is a real value,
    # as in `league/meta`'s `deadline`, which is blank in every row for every
    # grand tour because Velogames locks a stage race's roster for the whole
    # tour.
    blank_strings = DataFrame(riderkey = ["a", "b"], rider = ["A", "B"], odds = [2.5, 5.0])
    blank_deadline = DataFrame(
        race_number = [1, 2],
        race_name = ["Stage 1", "Stage 2"],
        deadline = ["", ""],
        category = ["road", "road"],
        series_type = ["grand_tour", "grand_tour"],
    )
    @test isempty(hollow_mandatory_columns("odds", blank_strings))
    @test isempty(hollow_mandatory_columns("league/meta", blank_deadline))
    save_race_snapshot(blank_deadline, "league/meta", "hollow-guard-gt", 2026; archive_dir = tree)
    @test has_race_snapshot("league/meta", "hollow-guard-gt", 2026; archive_dir = tree)
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

    # A file written before provenance stamping has none, and that is not an
    # error on read.
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

    # One planted defect of each kind. The write guard refuses all of them, so
    # the audit has to find them on disk.
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
    # PCS saw only two finishers, A and C.
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
        # No startlist yet: the field is the season pool filtered through PCS,
        # but a rider who scored is in the race whatever PCS says. D scored 200
        # and never reached PCS, so the filter must keep him. This is common:
        # the two sources order names differently, and "Thomas Pidcock" and
        # "Pidcock Tom" key differently.
        @test load_vg_startlist("milano-sanremo", year) === nothing
        pcs_filtered = load_report_data("milano-sanremo", year)
        @test Set(pcs_filtered.rider) == Set(["A Rider", "C Rider", "D Rider"])
        @test sum(pcs_filtered.score) == 700   # 500 when the filter drops D

        # With a startlist, the field is Velogames' own.
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

        # `vg_startlist` is written by the Python side, accumulates down the
        # season, and carries no uniqueness constraint the column guard can see.
        # A re-capture that appends rather than replaces would double the rider
        # through the leftjoin — a plausible page with the wrong totals on it.
        # The re-appended row is priced differently. The first occurrence has to
        # win, because the startlist arm comes first and that is the price
        # Velogames showed for the race.
        save_race_snapshot(
            DataFrame(
                race_number = [7, 7, 7, 7],
                race_name = fill("Milano-Sanremo", 4),
                rider = ["A Rider", "B Rider", "C Rider", "A Rider"],
                riderkey = createkey.(["A Rider", "B Rider", "C Rider", "A Rider"]),
                team = ["T1", "T2", "T3", "T1"],
                cost = [20, 10, 8, 22],
                points = [900, 400, 120, 900],
                class = ["", "", "", ""],
                start_list = fill("#MilanoSanremo", 4),
            ),
            "vg_startlist",
            slug,
            year;
            archive_dir = tree,
        )
        dup = load_report_data("milano-sanremo", year)
        @test sum(dup.score) == 700          # 1200 when the duplicate survives
        @test nrow(dup) == 4                 # 5 when the duplicate survives
        @test nrow(dup) == length(unique(dup.riderkey))
        @test only(filter(:rider => ==("A Rider"), dup).cost) == 20
    end
end

@testset "Archive writes are atomic (WP6)" begin
    # The archive is written by launchd and by serve.jl, read by a Python
    # package on its own schedule, and lives in Dropbox with no locking. A
    # writer interrupted mid-`Arrow.write` leaves a truncated file; a rename
    # cannot.
    tree = mktempdir()
    good = DataFrame(riderkey = ["a"], rider = ["A"], odds = [3.5])
    save_race_snapshot(good, "odds", "atomic-race", 2026; archive_dir = tree)
    path = Velogames.archive_path("odds", "atomic-race", 2026; archive_dir = tree)
    racedir = joinpath(tree, "odds", "atomic-race")

    # A rename replaces the inode, so a reader holding the old file keeps a
    # whole file. An in-place truncate cannot do this.
    ino = stat(path).inode
    save_race_snapshot(
        DataFrame(riderkey = ["a", "b"], rider = ["A", "B"], odds = [3.5, 9.0]),
        "odds",
        "atomic-race",
        2026;
        archive_dir = tree,
    )
    @test stat(path).inode != ino
    @test nrow(load_race_snapshot("odds", "atomic-race", 2026; archive_dir = tree)) == 2

    # A write that throws leaves the existing file alone and no temp behind.
    before = read(path)
    @test_throws ErrorException Velogames.atomic_write(path) do tmp
        write(tmp, "half a file")
        error("boom")
    end
    @test read(path) == before
    @test readdir(racedir) == ["2026.arrow"]

    # A temp orphaned by a kill is dot-prefixed, so it is neither a year nor a
    # stray file — the audit and the enumeration both skip it.
    touch(joinpath(racedir, ".2026.arrow.99999.tmp"))
    @test archive_years("odds", "atomic-race"; archive_dir = tree) == [2026]
    @test isempty(audit_archive(; archive_dir = tree).stray_files)
    @test nrow(load_race_snapshot("odds", "atomic-race", 2026; archive_dir = tree)) == 2

    # The manifest goes through it too, and leaves nothing behind.
    write_archive_manifest(; archive_dir = tree)
    @test Velogames.archive_manifest_matches(; archive_dir = tree)
    @test !any(startswith(f, ".") for f in readdir(tree))

    # And the raw league tier.
    @test Velogames.save_league_snapshot(
        "{\"x\": 1}",
        "g",
        2026,
        "1";
        date = Date(2026, 5, 1),
        archive_dir = tree,
    ) == Date(2026, 5, 1)
    rawdir = Velogames.league_raw_dir("g", 2026, "1"; archive_dir = tree)
    @test readdir(rawdir) == ["2026-05-01.json"]
end

@testset "Cache data lands before its metadata (WP6)" begin
    # `is_cache_valid` turns on the metadata alone, and `cached_fetch` reads
    # metadata-without-data as the deliberate "empty result" marker. Writing the
    # metadata first therefore opens a window in which a crash, or a reader in
    # another process, is served an empty frame nothing ever fetched.
    cache_dir = mktempdir()
    cache = Velogames.CacheConfig(cache_dir, 168)
    url = "https://example.invalid/wp6-ordering"
    key = Velogames.cache_key(url, Dict())
    data_file, meta_file = Velogames.cache_paths(key, cache_dir)
    df = DataFrame(rider = ["A"], score = [100], riderkey = ["a"])

    Velogames.save_to_cache(df, key, url, cache_dir)
    # The only assertion that tells the two orderings apart.
    @test mtime(data_file) <= mtime(meta_file)

    # The state a crash leaves: data on disk, metadata not yet written. A
    # reader must refetch rather than serve an empty result.
    rm(meta_file)
    n = Ref(0)
    fetched = Velogames.cached_fetch(
        (_, _) -> (n[] += 1; df),
        url;
        cache_config = cache,
        verbose = false,
    )
    @test n[] == 1
    @test nrow(fetched) == 1

    # The deliberate marker is untouched: an empty fetch still writes metadata
    # only, and still reads back as a valid empty entry.
    url2 = "https://example.invalid/wp6-ordering-empty"
    key2 = Velogames.cache_key(url2, Dict())
    data_file2, meta_file2 = Velogames.cache_paths(key2, cache_dir)
    Velogames.save_to_cache(DataFrame(), key2, url2, cache_dir)
    @test !isfile(data_file2)
    @test isfile(meta_file2)
    @test Velogames.is_cache_valid(key2, 168, cache_dir)
end

# ---------------------------------------------------------------------------
# Ingest, and completeness computed from the archive
# ---------------------------------------------------------------------------

"""A temp archive holding one classic, with whichever pieces the test asks for."""
function _phase2_tree(; startlist::Bool, pcs::Bool, unpriced::Bool)
    tree = mktempdir()
    year = 2099
    vg_slug = Velogames.vg_classics_slug(year)
    names = ["A Rider", "B Rider", "C Rider", "D Rider"]

    save_race_snapshot(
        DataFrame(
            rider = names,
            team = ["T1", "T2", "T3", "T4"],
            riderkey = createkey.(names),
            cost = [20, 10, 8, 6],
            points = [900, 400, 120, 60],
        ),
        "vg_riders",
        vg_slug,
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
        vg_slug,
        year;
        archive_dir = tree,
    )

    # "E Rider" is in no price list at all.
    scorers = unpriced ? ["A Rider", "D Rider", "E Rider"] : ["A Rider", "D Rider"]
    scores = unpriced ? [500, 200, 60] : [500, 200]
    save_race_snapshot(
        DataFrame(
            rider = scorers,
            team = fill("T1", length(scorers)),
            riderkey = createkey.(scorers),
            score = scores,
        ),
        "vg_results",
        "milano-sanremo",
        year;
        archive_dir = tree,
    )

    if startlist
        listed = ["A Rider", "C Rider", "D Rider"]
        save_race_snapshot(
            DataFrame(
                race_number = fill(7, 3),
                rider = listed,
                riderkey = createkey.(listed),
                team = ["T1", "T3", "T4"],
                cost = [20, 8, 6],
            ),
            "vg_startlist",
            vg_slug,
            year;
            archive_dir = tree,
        )
    end
    if pcs
        finishers = ["A Rider", "C Rider"]
        save_race_snapshot(
            DataFrame(
                riderkey = createkey.(finishers),
                rider = finishers,
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
    end
    return tree
end

@testset "Race completeness is computed from the archive (Phase 2)" begin
    @testset "types present, absent and required" begin
        tree = _phase2_tree(startlist = false, pcs = true, unpriced = false)
        c = race_completeness("milano-sanremo", 2099; archive_dir = tree)
        @test c.format == :oneday
        @test has_required_data(c)

        by_type = Dict(r.data_type => r for r in eachrow(c.types))
        @test by_type["vg_results"].present
        @test by_type["vg_results"].rows == 2
        @test by_type["vg_results"].required
        @test by_type["vg_riders"].present
        @test by_type["pcs_results"].present
        # Never written, so absent — and not required, so it holds nothing back.
        @test !by_type["vg_startlist"].present
        @test !by_type["vg_startlist"].required
        # Provenance is stamped on write, so a file written here carries it.
        @test !isempty(by_type["vg_results"].fetched_at)
    end

    @testset "a missing required type is reported, not worked around" begin
        tree = mktempdir()
        c = race_completeness("milano-sanremo", 2099; archive_dir = tree)
        @test !has_required_data(c)
        @test c.field_basis == :none
        @test c.field_riders == 0
    end

    @testset "field_basis says where the field came from" begin
        with_sl = _phase2_tree(startlist = true, pcs = true, unpriced = false)
        @test race_completeness("milano-sanremo", 2099; archive_dir = with_sl).field_basis ==
              :startlist

        pcs_only = _phase2_tree(startlist = false, pcs = true, unpriced = false)
        @test race_completeness("milano-sanremo", 2099; archive_dir = pcs_only).field_basis ==
              :pool_pcs_filtered

        neither = _phase2_tree(startlist = false, pcs = false, unpriced = false)
        c = race_completeness("milano-sanremo", 2099; archive_dir = neither)
        @test c.field_basis == :pool
        # The whole season pool, which is why the page withholds "N of M starters".
        @test c.field_riders == 4
    end

    @testset "a scorer nothing can price is counted, not dropped" begin
        tree = _phase2_tree(startlist = false, pcs = true, unpriced = true)
        c = race_completeness("milano-sanremo", 2099; archive_dir = tree)
        @test c.unpriced_scorers == 1
        @test c.unpriced_points == 60
        @test c.race_points == 760
        @test unpriced_share(c) ≈ 60 / 760
        @test !field_prices_every_scorer(c)
        # `load_report_data`'s leftjoin drops the rider silently; this is the
        # sentence the page carries instead.
        @test occursin("One rider who scored", field_basis_note(c))

        clean = _phase2_tree(startlist = false, pcs = true, unpriced = false)
        @test field_prices_every_scorer(race_completeness("milano-sanremo", 2099; archive_dir = clean))
    end

    @testset "a grand tour's rider list is its field" begin
        tree = mktempdir()
        names = ["A Rider", "B Rider"]
        for (t, df) in [
            (
                "vg_stage_totals",
                DataFrame(
                    rider = names,
                    team = ["T1", "T2"],
                    riderkey = createkey.(names),
                    score = [900, 400],
                ),
            ),
            (
                "vg_stage_riders",
                DataFrame(
                    rider = names,
                    team = ["T1", "T2"],
                    riderkey = createkey.(names),
                    cost = [20, 10],
                    points = [900, 400],
                ),
            ),
        ]
            save_race_snapshot(df, t, "giro-d-italia", 2099; archive_dir = tree)
        end
        c = race_completeness("giro-d-italia", 2099; archive_dir = tree)
        @test c.format == :stage
        @test has_required_data(c)
        # Not `:startlist` — riders.php carries no Start List column for a stage
        # race, and the rider pool *is* the field.
        @test c.field_basis == :vg_rider_list
        @test c.field_riders == 2
        @test field_prices_every_scorer(c)
        @test isempty(field_basis_note(c))
    end

    @testset "reading completeness writes nothing" begin
        tree = _phase2_tree(startlist = false, pcs = true, unpriced = false)
        before = sort(collect(walkdir(tree)))
        race_completeness("milano-sanremo", 2099; archive_dir = tree)
        race_completeness("giro-d-italia", 2099; archive_dir = tree)
        # `load_vg_classics_riders` scrapes and archives on a miss, so reaching
        # it would make asking the question change the answer, and an ingest's
        # before-and-after reading would be nonsense.
        @test sort(collect(walkdir(tree))) == before
    end
end

@testset "pending_races keys off the winners record (Phase 2)" begin
    tree = mktempdir()
    save_race_snapshot(
        DataFrame(
            pcs_slug = ["milano-sanremo", "paris-roubaix"],
            year = [2099, 2099],
            username = ["u1", "u2"],
            teamname = ["T One", "T Two"],
            score = [1000.0, 900.0],
            snapshot_date = ["2099-03-22", "2099-04-13"],
        ),
        "league/winners",
        "sixes-classics_1",
        2099;
        archive_dir = tree,
    )
    # Neither race has results, so both are pending.
    @test pending_races([2099]; archive_dir = tree) ==
          [("milano-sanremo", 2099), ("paris-roubaix", 2099)]

    save_race_snapshot(
        DataFrame(
            rider = ["A Rider"],
            team = ["T1"],
            riderkey = [createkey("A Rider")],
            score = [500],
        ),
        "vg_results",
        "milano-sanremo",
        2099;
        archive_dir = tree,
    )
    save_race_snapshot(
        DataFrame(
            rider = ["A Rider"],
            team = ["T1"],
            riderkey = [createkey("A Rider")],
            cost = [20],
            points = [900],
        ),
        "vg_riders",
        Velogames.vg_classics_slug(2099),
        2099;
        archive_dir = tree,
    )
    @test pending_races([2099]; archive_dir = tree) == [("paris-roubaix", 2099)]
    # A year the site does not publish is not pending work.
    @test isempty(pending_races([2098]; archive_dir = tree))
end

@testset "Run log (Phase 2)" begin
    @testset "a record round-trips" begin
        tree = mktempdir()
        out = record_run(
            "ingest-race";
            run_id = "testrun-1",
            items = ["milano-sanremo-2099"],
            archive_dir = tree,
        ) do
            ("ok", "2 files gained")
        end
        @test out == ("ok", "2 files gained")

        log = read_run_log(; archive_dir = tree)
        @test nrow(log) == 1
        @test log.run_id[1] == "testrun-1"
        @test log.phase[1] == "ingest-race"
        @test log.status[1] == "ok"
        @test log.detail[1] == "2 files gained"
        @test log.items[1] == "milano-sanremo-2099"
        @test log.host[1] == gethostname()
    end

    @testset "a failure is logged and rethrown" begin
        tree = mktempdir()
        # The log records what happened; it does not decide what happens.
        @test_throws ErrorException record_run(
            "render";
            run_id = "testrun-2",
            archive_dir = tree,
        ) do
            error("boom")
        end
        log = read_run_log(; archive_dir = tree)
        @test nrow(log) == 1
        @test log.status[1] == "failed"
        @test occursin("boom", log.detail[1])
    end

    @testset "one file per run, so two writers cannot collide" begin
        tree = mktempdir()
        for phase in ["ingest-league", "derive-winners", "ingest-race"]
            record_run(phase; run_id = "shared-id", archive_dir = tree) do
                "done"
            end
        end
        # A single appended monthly file would be read-modify-write across two
        # clones with no shared lock; unique filenames make that unrepresentable.
        @test length(readdir(run_log_dir(; archive_dir = tree))) == 3
        @test nrow(read_run_log(; archive_dir = tree)) == 3
        @test all(read_run_log(; archive_dir = tree).run_id .== "shared-id")
    end

    @testset "VELOGAMES_RUN_ID ties a publish's phases together" begin
        withenv("VELOGAMES_RUN_ID" => "publish-42") do
            @test new_run_id() == "publish-42"
        end
        withenv("VELOGAMES_RUN_ID" => "") do
            @test new_run_id() != "publish-42"
        end
    end
end

@testset "Race catalogue export (Phase 2)" begin
    @testset "squashing is stable and collision-free" begin
        # Must agree with vgleague's `_squash_tag`, which strips everything that
        # is not a letter or digit *after* decomposing accents.
        @test race_squash("La Flèche Wallonne") == "laflechewallonne"
        @test race_squash("Kuurne - Brussel - Kuurne") == "kuurnebrusselkuurne"
        @test race_squash("Grand Prix Cycliste de Québec") == "grandprixcyclistedequebec"
        @test race_squash("Il Lombardia") == "illombardia"

        squashes = [race_squash(r.name) for r in Velogames.CLASSICS_RACES_2026]
        @test all(!isempty, squashes)
        # A collision would file two races' results under one slug.
        @test length(unique(squashes)) == length(squashes)
    end

    @testset "the export is derived, so --check is a comparison" begin
        tree = mktempdir()
        @test !race_catalogue_matches(; archive_dir = tree)
        write_race_catalogue(; archive_dir = tree)
        @test race_catalogue_matches(; archive_dir = tree)

        text = read(race_catalogue_path(; archive_dir = tree), String)
        cat = TOML.parse(text)["races"]
        @test length(cat) == length(Velogames.CLASSICS_RACES_2026) +
              length(Velogames._STAGE_RACE_VG_SLUGS)
        # Everything Python needs to key a file and pick a fetcher.
        @test cat["milano-sanremo"]["format"] == "oneday"
        @test cat["vuelta-a-espana"]["format"] == "stage"
        @test cat["vuelta-a-espana"]["vg_game_slug"] == "spain"
        @test cat["vuelta-a-espana"]["n_stages"] == 21
        @test cat["tour-de-france-femmes"]["n_stages"] == 9
        for (slug, spec) in cat
            @test spec["squash"] == race_squash(spec["name"])
        end
    end
end

# ---------------------------------------------------------------------------
# PCS Cloudflare block: detection, and archive-first specialty resolution
# ---------------------------------------------------------------------------

@testset "PCS block detection" begin
    @testset "looks_blocked" begin
        # A 403/429, with or without the Cloudflare header, is a block.
        @test Velogames.looks_blocked(Velogames.HTTP.Response(403, []; body = ""))
        @test Velogames.looks_blocked(Velogames.HTTP.Response(429, []; body = ""))
        @test Velogames.looks_blocked(
            Velogames.HTTP.Response(
                200,
                ["cf-mitigated" => "challenge"];
                body = "<title>Just a moment...</title>",
            ),
        )
        @test Velogames.looks_blocked(
            Velogames.HTTP.Response(200, []; body = "Sorry, you have been blocked"),
        )

        # A 404 and an ordinary 200 are not blocks, so a missing rider stays a
        # missing-data row.
        @test !Velogames.looks_blocked(
            Velogames.HTTP.Response(404, []; body = "<h1>Page not found</h1>"),
        )
        @test !Velogames.looks_blocked(
            Velogames.HTTP.Response(200, []; body = "<html>ordinary page</html>"),
        )
    end

    @testset "scrape_get raises ScrapeBlockedError against a simulated challenge" begin
        # A loopback server standing in for a Cloudflare-challenged PCS, so the
        # test does not depend on PCS or the network.
        server = Velogames.HTTP.serve!(8971; verbose = false) do req
            if occursin("blocked", req.target)
                return Velogames.HTTP.Response(
                    403,
                    ["cf-mitigated" => "challenge"];
                    body = "<title>Just a moment...</title>",
                )
            elseif occursin("notfound", req.target)
                return Velogames.HTTP.Response(404, []; body = "not found")
            else
                return Velogames.HTTP.Response(200, []; body = "ok")
            end
        end
        sleep(0.2)
        # A block escalates to the browser transport. To test the escalation
        # without waiting out a real browser launch and its block backoff, point
        # `VGLEAGUE_BIN` at something that cannot run: `prefetch!` fails
        # immediately, and `scrape_get` is left with nothing to return, the one
        # remaining route to `ScrapeBlockedError`.
        saved_bin = get(ENV, "VGLEAGUE_BIN", nothing)
        ENV["VGLEAGUE_BIN"] = joinpath(mktempdir(), "no-such-vgleague")
        try
            # A 404 stays an ordinary StatusError, so a caller's
            # `e.status in (400, 404)` → missing-data handling still applies.
            # Asserted BEFORE the block below, because a block puts the host in
            # `_BLOCKED_HOSTS` and every later request to it skips `HTTP.get`.
            @test_throws Velogames.HTTP.Exceptions.StatusError Velogames.scrape_get(
                "http://127.0.0.1:8971/rider/notfound",
            )

            # An ordinary page passes through untouched.
            @test Velogames.scrape_get("http://127.0.0.1:8971/rider/ok").status == 200

            # A challenge escalates to the transport; the transport cannot run,
            # so this surfaces as ScrapeBlockedError rather than being folded
            # into `getpcs_rider_pts`'s `_missing_rider_df()` row.
            @test_throws Velogames.ScrapeBlockedError Velogames.scrape_get(
                "http://127.0.0.1:8971/rider/blocked",
            )

            # That refusal is remembered for the host, so the next request skips
            # the doomed `HTTP.get`, including one that would have been an
            # ordinary 200.
            @test "127.0.0.1:8971" in Velogames._BLOCKED_HOSTS
            @test_throws Velogames.ScrapeBlockedError Velogames.scrape_get(
                "http://127.0.0.1:8971/rider/ok",
            )
        finally
            close(server)
            empty!(Velogames._BLOCKED_HOSTS)
            saved_bin === nothing ? delete!(ENV, "VGLEAGUE_BIN") :
            (ENV["VGLEAGUE_BIN"] = saved_bin)
        end
    end

    @testset "looks_blocked/scrape_get do not consume response.body" begin
        # `String(v::Vector{UInt8})` takes ownership of `v` and empties it. If
        # `looks_blocked` decoded `response.body` that way to peek for challenge
        # markers, every caller of `scrape_get` that goes on to
        # `String(response.body)` would see "" on every fetch, blocked or not.
        # This checks byte length before and after.
        page_body = "<html>" * "x"^500 * "<div class=\"xvalue\">1</div></html>"

        # looks_blocked alone must not touch the buffer. The body must be a
        # `Vector{UInt8}`, as a fetched response's is: `HTTP.Response` stores a
        # String body as `Base.CodeUnits`, whose `String(...)` method is a
        # no-op unwrap and would pass even with the bug present.
        resp = Velogames.HTTP.Response(200, []; body = Vector{UInt8}(codeunits(page_body)))
        @test resp.body isa Vector{UInt8}
        before_len = length(resp.body)
        @test before_len == ncodeunits(page_body)
        @test !Velogames.looks_blocked(resp)
        after_len = length(resp.body)
        @info "looks_blocked body length" before = before_len after = after_len
        @test after_len == before_len  # not emptied by the peek
        @test String(copy(resp.body)) == page_body  # and the content survived intact

        # End-to-end: a scrape_get round trip through a loopback server must
        # leave response.body with its full original content, not "".
        server = Velogames.HTTP.serve!(8972; verbose = false) do req
            return Velogames.HTTP.Response(200, []; body = page_body)
        end
        sleep(0.2)
        try
            resp2 = Velogames.scrape_get("http://127.0.0.1:8972/rider/ok")
            @info "scrape_get body length" before = ncodeunits(page_body) after =
                length(resp2.body)
            @test length(resp2.body) == ncodeunits(page_body)
            @test String(resp2.body) == page_body
        finally
            close(server)
        end
    end
end

@testset "_load_pcs_specialty: archive-first, cross-race, then live fetch" begin
    tree = mktempdir()
    # Real slugs: the cross-race tier orders donors by their resolved race date
    # and refuses to read one dated after the target, so it is a no-op for a
    # slug `resolve_race_date` does not know, and a test on invented slugs
    # would exercise nothing. Lombardia in October with two Milano-Sanremos
    # before it gives real dates in a known order.
    target_slug, target_year = "il-lombardia", 2026
    donor_new, donor_new_year = "milano-sanremo", 2026   # March 2026, newest before the target
    donor_old, donor_old_year = "milano-sanremo", 2023   # March 2023
    withenv("VELOGAMES_ARCHIVE" => tree) do
        # Rider A: covered by the race's own archived pcs_specialty file.
        save_race_snapshot(
            DataFrame(
                riderkey = ["a"],
                rider = ["Rider A"],
                oneday = [100],
                gc = [50],
                tt = [10],
                sprint = [5],
                climber = [20],
            ),
            "pcs_specialty",
            target_slug,
            target_year;
            archive_dir = tree,
        )

        # Rider B: absent from the own-race file, but present in two OTHER
        # archived races — an older one and a newer one. Newest-first means
        # the 2026 rating should win over the 2023 one.
        save_race_snapshot(
            DataFrame(
                riderkey = ["b"],
                rider = ["Rider B"],
                oneday = [1],
                gc = [1],
                tt = [1],
                sprint = [1],
                climber = [1],
            ),
            "pcs_specialty",
            donor_old,
            donor_old_year;
            archive_dir = tree,
        )
        save_race_snapshot(
            DataFrame(
                riderkey = ["b"],
                rider = ["Rider B"],
                oneday = [999],
                gc = [999],
                tt = [999],
                sprint = [999],
                climber = [999],
            ),
            "pcs_specialty",
            donor_new,
            donor_new_year;
            archive_dir = tree,
        )

        # Rider C: in neither the own-race file nor any other archived race —
        # only a live fetch can cover them. Pre-seed the ephemeral HTTP cache
        # (not the permanent archive) with the response `getpcs_rider_pts`
        # would build for this rider, so the "live fetch" tier is exercised
        # without touching the network.
        cache_tmp = mktempdir()
        cache_config = Velogames.CacheConfig(cache_tmp, 168)
        rider_c_name = "Rider C"
        slug_c = Velogames.normalisename(rider_c_name)
        pageurl_c = "https://www.procyclingstats.com/rider/" * slug_c
        params_c = Dict("rider" => rider_c_name)
        key_c = Velogames.cache_key(pageurl_c, params_c)
        Velogames.save_to_cache(
            DataFrame(
                rider = [rider_c_name],
                oneday = [777],
                gc = [777],
                tt = [777],
                sprint = [777],
                climber = [777],
                riderkey = [createkey(rider_c_name)],
            ),
            key_c,
            pageurl_c,
            cache_tmp,
            params_c,
        )

        # `_load_pcs_specialty` matches on the riderkey a real fetch would
        # produce (`createkey(rider)`). Rider C's entry has to carry that, or
        # the live-fetched row never matches `wanted` and looks like a miss.
        riderkey_c = createkey(rider_c_name)
        riderdf = DataFrame(
            riderkey = ["a", "b", riderkey_c],
            rider = ["Rider A", "Rider B", rider_c_name],
        )
        specialty_df, provenance = Velogames._load_pcs_specialty(
            target_slug,
            target_year,
            riderdf;
            cache_config = cache_config,
        )

        @test provenance == (own_race = 1, cross_race = 1, live_fetched = 1)
        @test Set(specialty_df.riderkey) == Set(["a", "b", riderkey_c])

        row_a = only(filter(:riderkey => ==("a"), specialty_df))
        @test row_a.oneday == 100   # own-race, not overwritten by anything else

        row_b = only(filter(:riderkey => ==("b"), specialty_df))
        @test row_b.oneday == 999   # newest cross-race file wins over the 2023 one

        row_c = only(filter(:riderkey => ==(createkey(rider_c_name)), specialty_df))
        @test row_c.oneday == 777  # resolved by the live-fetch tier
    end
end

@testset "pcs_specialty archive never shrinks on a narrower re-render" begin
    # `_load_pcs_specialty` harvests only riders in the current pool, so a
    # re-render with a tighter racehash or more exclusions produces a strict
    # subset of the archived rows. `pcs_specialty` is `refetchable = false`, so
    # writing that subset straight over the file destroys ratings nothing can
    # fetch back. This is the merge `_prepare_rider_data` applies to stop it, on
    # the shape the call site uses.
    tree = mktempdir()
    spec(keys, pts) = DataFrame(
        riderkey = keys,
        rider = ["Rider $k" for k in keys],
        oneday = pts,
        gc = pts,
        tt = pts,
        sprint = pts,
        climber = pts,
    )

    save_race_snapshot(
        spec(["a", "b", "c"], [10, 20, 30]),
        "pcs_specialty",
        "coppa-sabatini",
        2026;
        archive_dir = tree,
    )

    # The narrow re-render: only rider A is in the pool this time, and PCS has
    # moved their rating on.
    archivable = spec(["a"], [99])
    existing = load_race_snapshot("pcs_specialty", "coppa-sabatini", 2026; archive_dir = tree)
    fresh = Set(archivable.riderkey)
    kept = filter(r -> !(r.riderkey in fresh), existing)
    merged = vcat(archivable, kept; cols = :union)
    save_race_snapshot(merged, "pcs_specialty", "coppa-sabatini", 2026; archive_dir = tree)

    after = load_race_snapshot("pcs_specialty", "coppa-sabatini", 2026; archive_dir = tree)
    @test Set(after.riderkey) == Set(["a", "b", "c"])      # B and C survive
    @test only(filter(:riderkey => ==("a"), after)).oneday == 99   # fresh row wins
    @test only(filter(:riderkey => ==("b"), after)).oneday == 20   # untouched
end

@testset "load_vg_race_pool reads vg_stage_riders for a stage race" begin
    # Stage-race pools live in `vg_stage_riders`, keyed by pcs_slug.
    # `load_vg_startlist` is keyed by the classics game slug and holds no
    # grand-tour rows, so a tour read through it alone falls through to a live
    # Velogames fetch that Cloudflare refuses.
    tree = mktempdir()
    save_race_snapshot(
        DataFrame(
            riderkey = ["a", "b"],
            rider = ["Rider A", "Rider B"],
            team = ["Team One", "Team Two"],
            cost = [24, 6],
            points = [0.0, 0.0],
            classraw = ["All Rounder", "Unclassed"],
        ),
        "vg_stage_riders",
        "tour-de-france",
        2026;
        archive_dir = tree,
    )

    pool = load_vg_race_pool("tour-de-france", 2026, ""; archive_dir = tree)
    @test nrow(pool) == 2
    # `build_model_stage` matches on "allrounder", not the page's "All Rounder".
    @test pool.class == ["allrounder", "unclassed"]
    @test pool.classraw == ["All Rounder", "Unclassed"]
    # No start-list flag exists for a stage race, and `_prepare_rider_data`
    # treats a missing column as "no filter" — synthesising one would only
    # invite someone to trust it.
    @test !hasproperty(pool, :startlist)
    @test pool.value == [0.0, 0.0]
end

@testset "hollow-column guard: pcs_results.breakaway_km is exempt, nothing else is" begin
    tree = mktempdir()

    # breakaway_km can be missing in EVERY row (no titled breakaway shield, or a
    # file written before fetches went through a browser), so this must still
    # write.
    pcs_results_df = DataFrame(
        riderkey = ["a", "b"],
        rider = ["Rider A", "Rider B"],
        team = ["Team X", "Team Y"],
        position = [1, 2],
        in_breakaway = [false, false],
        breakaway_km = Union{Float64,Missing}[missing, missing],
    )
    save_race_snapshot(pcs_results_df, "pcs_results", "test-race", 2026; archive_dir = tree)
    @test has_race_snapshot("pcs_results", "test-race", 2026; archive_dir = tree)

    # A hollow mandatory column on the SAME data type is still refused: the
    # exemption is scoped to breakaway_km alone.
    poisoned = DataFrame(
        riderkey = ["a", "b"],
        rider = ["Rider A", "Rider B"],
        team = Union{String,Missing}[missing, missing],
        position = [1, 2],
        in_breakaway = [false, false],
        breakaway_km = Union{Float64,Missing}[missing, missing],
    )
    @test_throws ErrorException save_race_snapshot(
        poisoned,
        "pcs_results",
        "test-race-2",
        2026;
        archive_dir = tree,
    )

    # The exemption does not leak to a different data type: pcs_specialty has
    # none, so an all-missing rating column is still refused.
    poisoned_specialty = DataFrame(
        riderkey = ["a"],
        rider = ["Rider A"],
        oneday = Union{Int,Missing}[missing],
        gc = Union{Int,Missing}[missing],
        tt = Union{Int,Missing}[missing],
        sprint = Union{Int,Missing}[missing],
        climber = Union{Int,Missing}[missing],
    )
    @test_throws ErrorException save_race_snapshot(
        poisoned_specialty,
        "pcs_specialty",
        "test-race",
        2026;
        archive_dir = tree,
    )
end

# ---------------------------------------------------------------------------
# Block-aware batch fetchers: sub-threshold blocks stay uncovered rather than
# masquerading as missing data, and blocks past the threshold escalate.
#
# getpcs_rider_pts / getpcs_rider_seasons build their URL from a hardcoded
# procyclingstats.com prefix, so they are not network-injectable. Each
# testset below stubs the single-rider fetcher for its duration and restores
# the real implementation afterward by re-including the file it lives in,
# which restores every function that file defines to what is on disk.
# ---------------------------------------------------------------------------

@testset "getpcs_rider_pts_batch: sub-threshold blocked riders are left uncovered" begin
    function Velogames.getpcs_rider_pts(
        ridername::String;
        pcs_slug::String = "",
        force_refresh::Bool = false,
        cache_config::Velogames.CacheConfig = Velogames.DEFAULT_CACHE,
    )
        if startswith(ridername, "Blocked")
            throw(Velogames.ScrapeBlockedError("simulated block for $ridername"))
        elseif startswith(ridername, "Miss")
            return DataFrame(
                rider = [ridername],
                oneday = Union{Int,Missing}[missing],
                gc = Union{Int,Missing}[missing],
                tt = Union{Int,Missing}[missing],
                sprint = Union{Int,Missing}[missing],
                climber = Union{Int,Missing}[missing],
                riderkey = [createkey(ridername)],
            )
        else
            return DataFrame(
                rider = [ridername],
                oneday = [42],
                gc = [42],
                tt = [42],
                sprint = [42],
                climber = [42],
                riderkey = [createkey(ridername)],
            )
        end
    end

    try
        riders = ["Found Rider", "Miss Rider", "Blocked One", "Blocked Two"]
        result = getpcs_rider_pts_batch(riders)

        # Two riders blocked below the raise threshold: no row for either, not
        # even a missing-value one, which downstream would be indistinguishable
        # from a miss.
        @test nrow(result) == 2
        @test Set(String.(result.rider)) == Set(["Found Rider", "Miss Rider"])
        found_row = only(filter(:rider => ==("Found Rider"), result))
        @test !ismissing(found_row.oneday)
        miss_row = only(filter(:rider => ==("Miss Rider"), result))
        @test ismissing(miss_row.oneday)
    finally
        Base.include(Velogames, joinpath(pkgdir(Velogames), "src", "get_data.jl"))
    end
end

@testset "getpcs_rider_pts_batch: blocks past the raise threshold escalate" begin
    function Velogames.getpcs_rider_pts(
        ridername::String;
        pcs_slug::String = "",
        force_refresh::Bool = false,
        cache_config::Velogames.CacheConfig = Velogames.DEFAULT_CACHE,
    )
        throw(Velogames.ScrapeBlockedError("simulated block for $ridername"))
    end

    try
        riders = ["R$i" for i = 1:(Velogames.PCS_BLOCK_RAISE_THRESHOLD+1)]
        @test_throws Velogames.ScrapeBlockedError getpcs_rider_pts_batch(riders)
    finally
        Base.include(Velogames, joinpath(pkgdir(Velogames), "src", "get_data.jl"))
    end
end

@testset "getpcs_rider_seasons_batch: sub-threshold blocked riders are skipped" begin
    function Velogames.getpcs_rider_seasons(
        pcs_slug::String;
        force_refresh::Bool = false,
        cache_config::Velogames.CacheConfig = Velogames.DEFAULT_CACHE,
    )
        if pcs_slug == "blocked-slug"
            throw(Velogames.ScrapeBlockedError("simulated block for $pcs_slug"))
        end
        return DataFrame(year = [2026], pcs_points = [100.0], pcs_rank = [5])
    end

    try
        slugs = Dict("ok-rider" => "ok-slug", "blocked-rider" => "blocked-slug")
        result = getpcs_rider_seasons_batch(slugs)
        @test Set(result.riderkey) == Set(["ok-rider"])
    finally
        Base.include(Velogames, joinpath(pkgdir(Velogames), "src", "pcs_extended.jl"))
    end
end

@testset "getpcs_rider_seasons_batch: blocks past the raise threshold escalate" begin
    function Velogames.getpcs_rider_seasons(
        pcs_slug::String;
        force_refresh::Bool = false,
        cache_config::Velogames.CacheConfig = Velogames.DEFAULT_CACHE,
    )
        throw(Velogames.ScrapeBlockedError("simulated block for $pcs_slug"))
    end

    try
        slugs = Dict("r$i" => "slug$i" for i = 1:(Velogames.PCS_BLOCK_RAISE_THRESHOLD+1))
        @test_throws Velogames.ScrapeBlockedError getpcs_rider_seasons_batch(slugs)
    finally
        Base.include(Velogames, joinpath(pkgdir(Velogames), "src", "pcs_extended.jl"))
    end
end

# ---------------------------------------------------------------------------
# PCS history and specialty loaders: empty history, blocks that must propagate,
# hollow rows, the cross-race date bound, and own-race archive writes
# ---------------------------------------------------------------------------

@testset "_pcs_race_history_archive_first / assemble_pcs_race_history: no history anywhere returns nothing" begin
    tree = mktempdir()
    withenv("VELOGAMES_ARCHIVE" => tree) do
        # A `pcs_results` archive file that itself holds zero rows, as written
        # by a fetch that found no results but did not error. The
        # archive-hit path in `_pcs_results_archive_first` hands this back
        # directly, with no live fetch needed, so this is fully network-free.
        save_race_snapshot(
            DataFrame(
                position = Int[],
                rider = String[],
                team = String[],
                riderkey = String[],
                in_breakaway = Bool[],
                breakaway_km = Union{Float64,Missing}[],
            ),
            "pcs_results",
            "no-history-race",
            2024;
            archive_dir = tree,
        )

        # Zero rows collected across every year requested must come back as
        # `nothing`, not a frame carrying only `:variance_penalty` and none of
        # `riderkey`/`position`/`year`, a shape that crashes
        # `_prepare_rider_data`'s `race_history_df.riderkey` access.
        result = Velogames._pcs_race_history_archive_first("no-history-race", [2024])
        @test result === nothing

        # Same at the caller: "no-history-race" is unmapped in
        # `SIMILAR_RACES`/`GT_SIMILAR_RACES`, so no similar-race fetch runs
        # either — the whole assembly is archive-only and still degrades to
        # `nothing` cleanly.
        history = Velogames.assemble_pcs_race_history("no-history-race", 2025, 1)
        @test history === nothing
    end
end

@testset "_pcs_race_history_archive_first: one bad year doesn't discard the rest, a block still propagates" begin
    # `function Velogames.getpcs_race_results(...)` below has to sit at true
    # top level (of the testset, not inside a `do` block) or Julia refuses the
    # global method definition — so the archive directory is set via `ENV`
    # directly rather than `withenv(...) do ... end`.
    tree = mktempdir()
    save_race_snapshot(
        DataFrame(
            position = [1, 2],
            rider = ["Rider A", "Rider B"],
            team = ["Team X", "Team Y"],
            riderkey = ["ridera", "riderb"],
            in_breakaway = [false, false],
            breakaway_km = Union{Float64,Missing}[missing, missing],
        ),
        "pcs_results",
        "bad-year-race",
        2024;
        archive_dir = tree,
    )

    # 2025 has no archive entry for either slug below, so
    # `_pcs_results_archive_first` falls through to a live fetch. A *non-block*
    # transient failure cannot be provoked reliably against the real site (see
    # docs/pcs-fetch-architecture.md), so stand one in at the
    # `getpcs_race_results` boundary, alongside a simulated block for a second
    # slug.
    function Velogames.getpcs_race_results(slug::String, year::Int; kwargs...)
        slug == "blocked-year-race" &&
            throw(Velogames.ScrapeBlockedError("simulated block for $slug $year"))
        error("simulated transient failure for $slug $year")
    end

    old_archive = get(ENV, "VELOGAMES_ARCHIVE", nothing)
    ENV["VELOGAMES_ARCHIVE"] = tree
    try
        # A non-block failure on the one year needing a live fetch doesn't
        # discard the year the archive already served.
        result = Velogames._pcs_race_history_archive_first("bad-year-race", [2024, 2025])
        @test result !== nothing
        @test nrow(result) == 2
        @test Set(result.riderkey) == Set(["ridera", "riderb"])
        @test all(==(2024), result.year)

        # A block still propagates rather than being folded into "no history
        # for that year", which would render the race on VG points alone with a
        # clean log.
        @test_throws Velogames.ScrapeBlockedError Velogames._pcs_race_history_archive_first(
            "blocked-year-race",
            [2025],
        )

        # Except in reconstruction, where the transport is off and "blocked"
        # means only "not archived". A backtest asks for three or four prior
        # editions; one missing must not discard the race.
        with_browser_transport(false) do
            @test Velogames._pcs_race_history_archive_first(
                "blocked-year-race",
                [2025],
            ) === nothing
        end
    finally
        if old_archive === nothing
            delete!(ENV, "VELOGAMES_ARCHIVE")
        else
            ENV["VELOGAMES_ARCHIVE"] = old_archive
        end
        Base.include(Velogames, joinpath(pkgdir(Velogames), "src", "pcs_extended.jl"))
    end
end

@testset "assemble_pcs_classification_history: a block propagates rather than being skipped" begin
    function Velogames.getpcs_race_results(slug::String, year::Int; kwargs...)
        throw(Velogames.ScrapeBlockedError("simulated block for $slug $year"))
    end
    try
        @test_throws Velogames.ScrapeBlockedError Velogames.assemble_pcs_classification_history(
            "some-gt-slug",
            2026,
            1,
            :points,
        )
    finally
        Base.include(Velogames, joinpath(pkgdir(Velogames), "src", "pcs_extended.jl"))
    end
end

@testset "_apply_pcs_recency!: a PCS block propagates rather than folding into missing recency" begin
    function Velogames.getpcs_specialty_by_season(slug::String, specialty::Symbol; kwargs...)
        throw(Velogames.ScrapeBlockedError("simulated block for $slug"))
    end
    try
        riderdf = DataFrame(riderkey = ["r1"], rider = ["Rider One"])
        @test_throws Velogames.ScrapeBlockedError Velogames._apply_pcs_recency!(
            riderdf,
            Dict{String,String}(),
            2026;
            specialties = (:climber,),
        )
    finally
        Base.include(Velogames, joinpath(pkgdir(Velogames), "src", "pcs_extended.jl"))
    end
end

@testset "_load_pcs_specialty: a hollow own-race row doesn't block the fallback tiers" begin
    tree = mktempdir()
    # Real slugs for the same reason as the tiering test above: the cross-race
    # tier is date-bounded, so it is a no-op for a slug `resolve_race_date`
    # cannot place.
    target_slug, target_year = "il-lombardia", 2026
    donor_slug, donor_year = "milano-sanremo", 2023
    withenv("VELOGAMES_ARCHIVE" => tree) do
        # Own-race archive: "hollow" is present but every rating is missing —
        # riderkey/rider populated, as a blocked fetch that does not error
        # writes, alongside a rated rider, so the file-level hollow-column guard
        # (which checks whether a whole COLUMN is all-missing) doesn't catch
        # this per-ROW hollowness.
        save_race_snapshot(
            DataFrame(
                riderkey = ["hollow", "rated"],
                rider = ["Hollow Rider", "Rated Rider"],
                oneday = Union{Int,Missing}[missing, 500],
                gc = Union{Int,Missing}[missing, 400],
                tt = Union{Int,Missing}[missing, 300],
                sprint = Union{Int,Missing}[missing, 200],
                climber = Union{Int,Missing}[missing, 100],
            ),
            "pcs_specialty",
            target_slug,
            target_year;
            archive_dir = tree,
        )

        # A different archived race carries a real rating for the hollow
        # rider — the cross-race tier should be free to heal them with it.
        save_race_snapshot(
            DataFrame(
                riderkey = ["hollow"],
                rider = ["Hollow Rider"],
                oneday = [999],
                gc = [999],
                tt = [999],
                sprint = [999],
                climber = [999],
            ),
            "pcs_specialty",
            donor_slug,
            donor_year;
            archive_dir = tree,
        )

        riderdf = DataFrame(
            riderkey = ["hollow", "rated"],
            rider = ["Hollow Rider", "Rated Rider"],
        )
        specialty_df, provenance = Velogames._load_pcs_specialty(
            target_slug,
            target_year,
            riderdf;
            cache_config = Velogames.CacheConfig(mktempdir(), 24),
        )

        # The hollow row does NOT count as own-race coverage, so the
        # cross-race tier gets a chance to heal it.
        @test provenance == (own_race = 1, cross_race = 1, live_fetched = 0)

        row_hollow = only(filter(:riderkey => ==("hollow"), specialty_df))
        @test row_hollow.oneday == 999

        row_rated = only(filter(:riderkey => ==("rated"), specialty_df))
        @test row_rated.oneday == 500
    end
end

@testset "_load_pcs_specialty: cross-race lookup respects the future-leak date bound" begin
    tree = mktempdir()
    withenv("VELOGAMES_ARCHIVE" => tree) do
        # Target race: Omloop Het Nieuwsblad 2026 (2026-02-28 per
        # CLASSICS_RACES_2026).

        # A PRIOR edition (a year before the target is earlier regardless of
        # month) should be picked up by the cross-race tier.
        save_race_snapshot(
            DataFrame(
                riderkey = ["past"],
                rider = ["Past Rider"],
                oneday = [555],
                gc = [555],
                tt = [555],
                sprint = [555],
                climber = [555],
            ),
            "pcs_specialty",
            "omloop-het-nieuwsblad",
            2025;
            archive_dir = tree,
        )

        # Strade Bianche 2026 (2026-03-07) is dated AFTER Omloop 2026, as when
        # an earlier race is backfilled after a later one is archived:
        # re-rendering Omloop must not leak Strade's rating back into it.
        save_race_snapshot(
            DataFrame(
                riderkey = ["future"],
                rider = ["Future Rider"],
                oneday = [999],
                gc = [999],
                tt = [999],
                sprint = [999],
                climber = [999],
            ),
            "pcs_specialty",
            "strade-bianche",
            2026;
            archive_dir = tree,
        )

        # Pre-seed the ephemeral HTTP cache with what a live fetch of the
        # "future" rider would find — a value distinct from the future
        # archive's 999 — so a correctly-excluded future candidate still
        # resolves via the live tier rather than silently going uncovered.
        cache_tmp = mktempdir()
        cache_config = Velogames.CacheConfig(cache_tmp, 168)
        future_name = "Future Rider"
        slug_f = Velogames.normalisename(future_name)
        pageurl_f = "https://www.procyclingstats.com/rider/" * slug_f
        params_f = Dict("rider" => future_name)
        key_f = Velogames.cache_key(pageurl_f, params_f)
        Velogames.save_to_cache(
            DataFrame(
                rider = [future_name],
                oneday = [42],
                gc = [42],
                tt = [42],
                sprint = [42],
                climber = [42],
                riderkey = [createkey(future_name)],
            ),
            key_f,
            pageurl_f,
            cache_tmp,
            params_f,
        )

        riderkey_future = createkey(future_name)
        riderdf = DataFrame(
            riderkey = ["past", riderkey_future],
            rider = ["Past Rider", future_name],
        )
        specialty_df, provenance = Velogames._load_pcs_specialty(
            "omloop-het-nieuwsblad",
            2026,
            riderdf;
            cache_config = cache_config,
        )

        # "future" is NOT resolved by the cross-race tier (excluded by the
        # date bound), so it falls through to the live tier instead.
        @test provenance == (own_race = 0, cross_race = 1, live_fetched = 1)

        row_past = only(filter(:riderkey => ==("past"), specialty_df))
        @test row_past.oneday == 555

        row_future = only(filter(:riderkey => ==(riderkey_future), specialty_df))
        @test row_future.oneday == 42  # NOT 999 — the future archive was excluded
    end
end

@testset "_archivable_pcs_specialty: cross-race rows are excluded from the own-race archive write" begin
    tree = mktempdir()
    # Real slugs: the cross-race tier is date-bounded and skips any slug
    # `resolve_race_date` cannot place.
    target_slug, target_year = "il-lombardia", 2026
    donor_slug, donor_year = "milano-sanremo", 2023
    withenv("VELOGAMES_ARCHIVE" => tree) do
        save_race_snapshot(
            DataFrame(
                riderkey = ["a"],
                rider = ["Rider A"],
                oneday = [100],
                gc = [50],
                tt = [10],
                sprint = [5],
                climber = [20],
            ),
            "pcs_specialty",
            target_slug,
            target_year;
            archive_dir = tree,
        )
        save_race_snapshot(
            DataFrame(
                riderkey = ["b"],
                rider = ["Rider B"],
                oneday = [200],
                gc = [60],
                tt = [20],
                sprint = [15],
                climber = [30],
            ),
            "pcs_specialty",
            donor_slug,
            donor_year;
            archive_dir = tree,
        )

        riderdf = DataFrame(riderkey = ["a", "b"], rider = ["Rider A", "Rider B"])
        specialty_df, provenance = Velogames._load_pcs_specialty(
            target_slug,
            target_year,
            riderdf;
            cache_config = Velogames.CacheConfig(mktempdir(), 24),
        )
        @test provenance == (own_race = 1, cross_race = 1, live_fetched = 0)
        @test Set(specialty_df.riderkey) == Set(["a", "b"])

        archivable = Velogames._archivable_pcs_specialty(specialty_df)
        @test Set(archivable.riderkey) == Set(["a"])  # "b" (cross-race) excluded
        @test :_source ∉ propertynames(archivable)

        # Writing the filtered frame under the race's own key, then reading it
        # back, must not surface the cross-race-sourced rider. A cross-race
        # blend persisted into the own-race file could never be corrected,
        # because `pcs_specialty` is `refetchable = false`.
        save_race_snapshot(archivable, "pcs_specialty", "own-race", 2026; archive_dir = tree)
        reloaded = load_race_snapshot("pcs_specialty", "own-race", 2026; archive_dir = tree)
        @test Set(reloaded.riderkey) == Set(["a"])
    end
end

@testset "PCS Hills: an absent rating is no observation, not an average one" begin
    # `pcs_z` yields `zeros(n_riders)` for a column that is not in the frame,
    # and a z-score of 0.0 is a valid observation of "exactly average", so
    # routing it into `:hilly` would sharpen every rider's hilly posterior
    # toward the prior mean in every race archived before PCS began publishing
    # Hills in September 2026. That is most of the archive, and it can never be
    # backfilled: the ratings are season-cumulative, so a re-fetch records
    # today's value under a past race's key.
    base = (
        has_pcs = true,
        pcs_sprint_z = 0.4,
        pcs_oneday_z = 1.1,
        pcs_climber_z = 0.9,
        pcs_tt_z = -0.2,
        pcs_gc_z = 0.3,
        rider_class = "allrounder",
    )
    hilly = Velogames._DIM_INDEX[:hilly]

    without = Velogames.estimate_rider_strength_multidim(
        Velogames.RiderSignalData(; base..., has_pcs_hills = false, pcs_hills_z = 0.0),
    )
    # A rider the archive says nothing about on hills must land exactly where
    # the pre-Hills model put them.
    zeroed = Velogames.estimate_rider_strength_multidim(
        Velogames.RiderSignalData(; base..., has_pcs_hills = true, pcs_hills_z = 0.0),
    )
    @test without.variance[hilly] > zeroed.variance[hilly]

    # And a real rating moves the dimension it is about.
    strong = Velogames.estimate_rider_strength_multidim(
        Velogames.RiderSignalData(; base..., has_pcs_hills = true, pcs_hills_z = 2.0),
    )
    weak = Velogames.estimate_rider_strength_multidim(
        Velogames.RiderSignalData(; base..., has_pcs_hills = true, pcs_hills_z = -2.0),
    )
    @test strong.mean[hilly] > without.mean[hilly] > weak.mean[hilly]

    # Hills carries no weight on :flat or :itt.
    for dim in (:flat, :itt)
        d = Velogames._DIM_INDEX[dim]
        @test strong.mean[d] ≈ weak.mean[d] atol = 1e-9
    end
end

@testset "PCS Hills: the parser and the archive tolerate its absence" begin
    # `hills` is not mandatory: the 30 files written before September 2026 lack
    # it and must stay readable and writable.
    @test :hills ∉ Velogames.ARCHIVE_TYPES["pcs_specialty"].mandatory
    @test Velogames.ARCHIVE_TYPES["pcs_specialty"].version == 2

    dir = mktempdir()
    old = DataFrame(
        riderkey = ["aaa"],
        rider = ["Old Rider"],
        oneday = [100],
        gc = [50],
        tt = [10],
        sprint = [5],
        climber = [20],
    )
    save_race_snapshot(old, "pcs_specialty", "milano-sanremo", 2023; archive_dir = dir)
    @test load_race_snapshot("pcs_specialty", "milano-sanremo", 2023; archive_dir = dir) !==
          nothing

    new = DataFrame(
        riderkey = ["bbb"],
        rider = ["New Rider"],
        oneday = [200],
        gc = [60],
        tt = [15],
        sprint = [8],
        climber = [30],
        hills = Union{Int,Missing}[42],
    )
    save_race_snapshot(new, "pcs_specialty", "il-lombardia", 2026; archive_dir = dir)
    back = load_race_snapshot("pcs_specialty", "il-lombardia", 2026; archive_dir = dir)
    @test back.hills[1] == 42
end

@testset "Breakaway rates: shrinkage, recency and temporal integrity" begin
    dir = mktempdir()
    # Two riders over four editions of a real slug, so `race_format` and
    # `resolve_race_date` resolve: a habitual attacker and a rider who never goes.
    for (year, breaker_in) in ((2023, true), (2024, true), (2025, false), (2026, true))
        df = DataFrame(
            position = [5, 6],
            rider = ["Break Away", "Sits In"],
            team = ["A", "B"],
            riderkey = ["breakaway", "sitsin"],
            in_breakaway = [breaker_in, false],
            breakaway_km = Union{Float64,Missing}[breaker_in ? 180.0 : missing, missing],
        )
        save_race_snapshot(df, "pcs_results", "milano-sanremo", year; archive_dir = dir)
    end
    Velogames.breakaway_observations(; archive_dir = dir, force_rebuild = true)

    keys = ["breakaway", "sitsin", "neverseen"]
    # An explicit prior_strength: the shrinkage ordering below is about the
    # three values relative to each other, and relying on the default would
    # make the test fail when the default is retuned.
    rates, sectors = Velogames.compute_breakaway_rates_archive(
        keys; as_of = Date(2026, 12, 1), history_years = 10,
        prior_strength = 29.0, archive_dir = dir,
    )

    # The attacker outranks the passenger, and both are pulled toward the field
    # rate rather than sitting at the raw 3/4 and 0/4.
    @test rates[1] > rates[2]
    @test rates[1] < 0.75
    @test rates[2] > 0.0
    # An unseen rider gets the field rate, not zero.
    @test rates[3] > 0.0
    @test rates[3] ≈ rates[2] atol = 0.05

    # Weaker shrinkage moves the attacker closer to his raw rate.
    strong, _ = Velogames.compute_breakaway_rates_archive(
        keys; as_of = Date(2026, 12, 1), history_years = 10,
        prior_strength = 100.0, archive_dir = dir,
    )
    weak, _ = Velogames.compute_breakaway_rates_archive(
        keys; as_of = Date(2026, 12, 1), history_years = 10,
        prior_strength = 2.0, archive_dir = dir,
    )
    @test weak[1] > rates[1] > strong[1]

    # Temporal integrity: a cutoff before every archived edition sees nothing.
    early, _ = Velogames.compute_breakaway_rates_archive(
        keys; as_of = Date(2022, 1, 1), history_years = 10, archive_dir = dir,
    )
    @test all(iszero, early)

    # 180 km of a 298 km Sanremo clears half distance and nothing else.
    @test sectors[1] > 0.0
    @test Velogames.breakaway_sectors_from_km(180.0, 298.0) == 1
    @test Velogames.breakaway_sectors_from_km(295.0, 298.0) == 4
    @test Velogames.breakaway_sectors_from_km(50.0, 298.0) == 0
end

@testset "Breakaway shields parse from a results row" begin
    html = """
    <table><tr>
      <td>47</td>
      <td><a href="rider/filip-maciejuk">Maciejuk Filip</a></td>
      <td><a href="team/bahrain-2025">Bahrain</a></td>
      <td><div class="svg_shield" title="204 kilometre in a group in front of the peloton"></div></td>
    </tr></table>
    """
    row = first(eachmatch(Velogames.Cascadia.Selector("tr"),
                          Velogames.Gumbo.parsehtml(html).root))
    flag, km = Velogames._row_breakaway(row)
    @test flag
    @test km == 204.0

    plain = first(eachmatch(Velogames.Cascadia.Selector("tr"),
                            Velogames.Gumbo.parsehtml("<table><tr><td>1</td></tr></table>").root))
    # `missing == missing` is `missing`, not `true` — compare with isequal.
    @test isequal(Velogames._row_breakaway(plain), (false, missing))

    # A shield whose title we cannot read is still a breakaway, distance unknown.
    untitled = first(eachmatch(Velogames.Cascadia.Selector("tr"),
        Velogames.Gumbo.parsehtml(
            """<table><tr><td><div class="svg_shield"></div></td></tr></table>""").root))
    flag2, km2 = Velogames._row_breakaway(untitled)
    @test flag2
    @test ismissing(km2)
end
