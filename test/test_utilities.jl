@testset "league_race_slug" begin
    # scripts/auto_publish.jl decides whether a scraped league race is a
    # publishable classic by whether this comes back non-empty, so the empty
    # string for a grand tour stage is load-bearing, not just a miss.
    @test league_race_slug("Ronde van Brugge") == "classic-brugge-de-panne"
    @test league_race_slug("In Flanders Fields-Middelkerke to Wevelgem") == "gent-wevelgem"
    @test league_race_slug("Stage 4: Pau - Luchon") == ""
end

@testset "League archive round-trip (Phase 1b)" begin
    # The league scrape spells races the Velogames way ("Ronde van Brugge"),
    # which has to resolve to the PCS slug the renderers work in.
    classics = """
    {"meta": {"game_slug": "sixes-classics", "year": 2026, "league_id": "1",
              "series_type": "classics", "race_catalogue": {
                "7": {"name": "Ronde van Brugge", "deadline": "2026-03-25 11:00:00", "category": 2}}},
     "teams": {"JZ": {"username": "JZ", "teamname": "T", "teamid": "9", "races": {
        "Ronde van Brugge": {"race_number": 7, "score": 300,
                             "riders": ["Jasper Philipsen", "Max Kanter"],
                             "rider_costs": {"Jasper Philipsen": 20, "Max Kanter": 6},
                             "rider_scores": {"Jasper Philipsen": 260, "Max Kanter": 40}}}},
               "AN": {"username": "AN", "teamname": "Other", "teamid": "8", "races": {
        "Ronde van Brugge": {"race_number": 7, "score": 120,
                             "riders": ["Max Kanter"],
                             "rider_costs": {"Max Kanter": 6},
                             "rider_scores": {"Max Kanter": 120}}}}}}
    """
    gt = """
    {"meta": {"game_slug": "velogame", "year": 2026, "league_id": "2",
              "series_type": "grand_tour", "race_catalogue": {
                "1": {"name": "Stage 1: A-B", "deadline": null, "category": "road"},
                "2": {"name": "Stage 2: B-C", "deadline": null, "category": "road"}}},
     "teams": {"JZ": {"username": "JZ", "teamname": "T", "teamid": "9", "races": {
        "Stage 1: A-B": {"race_number": 1, "score": 10, "riders": ["Old Pick"],
                         "rider_costs": {"Old Pick": 4}, "rider_scores": {"Old Pick": 10}},
        "Stage 2: B-C": {"race_number": 2, "score": 20, "riders": ["Tadej Pogačar"],
                         "rider_costs": {"Tadej Pogačar": 30},
                         "rider_scores": {"Tadej Pogačar": 20}}}}}}
    """
    mktempdir() do dir
        tree = mktempdir()
        write(joinpath(dir, "sixes-classics_2026_1.json"), classics)
        write(joinpath(dir, "velogame_2026_2.json"), gt)
        ingest_league_dir(dir; date = Date(2026, 4, 1), archive_dir = tree)

        @test archived_leagues(; archive_dir = tree) == [
            (game_slug = "sixes-classics", year = 2026, league_id = "1"),
            (game_slug = "velogame", year = 2026, league_id = "2"),
        ]

        rosters =
            load_race_snapshot("league/rosters", "sixes-classics_1", 2026; archive_dir = tree)
        @test nrow(rosters) == 3
        @test sum(rosters.score) == 420

        pull(; kwargs...) =
            load_league_team(; year = 2026, username = "JZ", archive_dir = tree, kwargs...)

        @test pull(
            game_slug = "sixes-classics",
            league_id = "1",
            pcs_slug = "classic-brugge-de-panne",
        ) == ["Jasper Philipsen", "Max Kanter"]

        # A race the entrant hasn't an archived roster for, an unknown entrant
        # and a missing league all fall back to empty rather than throwing — the
        # normal state before the entry deadline.
        @test pull(game_slug = "sixes-classics", league_id = "1", pcs_slug = "il-lombardia") ==
              String[]
        @test load_league_team(;
            game_slug = "sixes-classics",
            year = 2026,
            league_id = "1",
            username = "Nobody",
            pcs_slug = "classic-brugge-de-panne",
            archive_dir = tree,
        ) == String[]
        @test pull(game_slug = "absent", league_id = "9", pcs_slug = "il-lombardia") == String[]

        # Grand tour rosters are locked, so the slug is ignored and the latest
        # stage's roster is the entered team.
        @test pull(game_slug = "velogame", league_id = "2", pcs_slug = "tour-de-france") ==
              ["Tadej Pogačar"]

        standings = load_league_standings(;
            game_slug = "sixes-classics",
            year = 2026,
            league_id = "1",
            archive_dir = tree,
        )
        @test nrow(standings) == 2
        @test sort(standings.score; rev = true) == [300.0, 120.0]

        # Re-ingesting identical content adds no snapshot; changed content does.
        again = ingest_league_file(
            joinpath(dir, "sixes-classics_2026_1.json");
            date = Date(2026, 4, 2),
            archive_dir = tree,
        )
        @test again.snapshot_date === nothing
        @test league_snapshot_dates("sixes-classics", 2026, "1"; archive_dir = tree) ==
              [Date(2026, 4, 1)]

        renamed = replace(classics, "\"teamname\": \"T\"" => "\"teamname\": \"T2\"")
        write(joinpath(dir, "sixes-classics_2026_1.json"), renamed)
        moved = ingest_league_file(
            joinpath(dir, "sixes-classics_2026_1.json");
            date = Date(2026, 4, 3),
            archive_dir = tree,
        )
        @test moved.snapshot_date == Date(2026, 4, 3)

        # The winner is derived from the snapshot contemporaneous with the race,
        # not the newest — which is the whole reason the raw tier is dated. Both
        # snapshots postdate the deadline by more than the settling window, so
        # the earliest one wins and the rename does not rewrite history.
        winners = derive_league_winners(
            "sixes-classics",
            2026,
            "1";
            now = DateTime(2026, 5, 1),
            archive_dir = tree,
        )
        @test nrow(winners) == 1
        @test winners.pcs_slug[1] == "classic-brugge-de-panne"
        @test winners.teamname[1] == "T"
        @test winners.snapshot_date[1] == "2026-04-01"

        # Held back until the scores have had time to settle.
        @test isempty(
            derive_league_winners(
                "sixes-classics",
                2026,
                "1";
                now = DateTime(2026, 3, 25, 12),
                archive_dir = tree,
            ),
        )

        append_league_winners(winners, "sixes-classics", 2026, "1"; archive_dir = tree)
        recorded = load_league_winners(; archive_dir = tree)
        @test length(recorded) == 1
        @test recorded[1] == (
            pcs_slug = "classic-brugge-de-panne",
            year = 2026,
            name = "T",
            score = 300,
        )
        # Recorded once and never re-derived, so a later rename cannot move it.
        @test isempty(
            derive_league_winners(
                "sixes-classics",
                2026,
                "1";
                now = DateTime(2026, 5, 1),
                archive_dir = tree,
            ),
        )

        # A grand tour is one entry for the whole tour, and waits for every race
        # in its catalogue to be scored.
        @test nrow(
            derive_league_winners("velogame", 2026, "2"; archive_dir = tree),
        ) == 1
    end
end

# =========================================================================
# Smoke test: VG rider scraping
# =========================================================================

@testset "getvg_riders" begin
    url = vg_classics_url(Dates.year(Dates.today()))
    df = getvg_riders(url, force_refresh = true)
    @test df isa DataFrame
    @test nrow(df) > 0

    # Core columns present on all VG game types
    for col in ["rider", "team", "cost", "points", "riderkey"]
        @test col in names(df)
    end

    @test length(unique(df.riderkey)) == length(df.riderkey)

    # Caching round-trip
    df_cached = getvg_riders(url)
    @test size(df_cached) == size(df)

    # Stage race pages have class columns; one-day classics may not
    if hasproperty(df, :class) && hasproperty(df, :classraw)
        @test all(df.class .== lowercase.(replace.(df.classraw, " " => "")))
    end
end

# =========================================================================
# Utility functions
# =========================================================================

@testset "Utility Functions" begin
    @testset "createkey" begin
        @test createkey("John Doe") isa String
        @test createkey("John Doe") == createkey("john doe")
        @test createkey("José García") != ""
        @test createkey("") == ""
        @test createkey("Tadej Pogačar") == createkey("Tadej Pogačar")
        # Smart quotes (U+2019, U+2018) must produce the same key as ASCII apostrophe
        @test createkey("Ben O'Connor") == createkey("Ben O\u2019Connor")
        @test createkey("Ben O'Connor") == createkey("Ben O\u2018Connor")
        @test createkey("Andrea d'Amato") == createkey("Andrea d\u2019Amato")
    end

    @testset "normalisename and unpipe" begin
        if isdefined(Velogames, :normalisename)
            @test Velogames.normalisename("John Doe") isa String
        end
        if isdefined(Velogames, :unpipe)
            @test Velogames.unpipe("test|pipe") == "test-pipe"
        end
    end
end

@testset "Empty input edge cases" begin
    result = get_cycling_oracle("")
    @test result isa DataFrame
    @test nrow(result) == 0
    @test names(result) == ["rider", "win_prob", "riderkey"]
end

# =========================================================================
# Caching
# =========================================================================

@testset "Caching System" begin
    @testset "CacheConfig" begin
        @test DEFAULT_CACHE.max_age_hours == 168
        @test endswith(DEFAULT_CACHE.cache_dir, ".velogames_cache")

        custom_cache = CacheConfig("/tmp/test_cache", 12)
        @test custom_cache.cache_dir == "/tmp/test_cache"
        @test custom_cache.max_age_hours == 12
    end

    @testset "Cache Key Generation" begin
        key1 = Velogames.cache_key("http://example.com")
        key2 = Velogames.cache_key("http://example.com", Dict("param" => "value"))
        key3 = Velogames.cache_key("http://different.com")

        @test length(key1) == 16
        @test key1 != key2
        @test key1 != key3
        @test key2 != key3
    end

    @testset "Cache Clear" begin
        test_cache_dir = "/tmp/velogames_test_cache"
        @test_nowarn clear_cache(test_cache_dir)
    end
end

# =========================================================================
# Race configuration
# =========================================================================

@testset "Race Configuration" begin
    @test length(CLASSICS_RACES_2026) == 44
    @test count(r -> r.category == 1, CLASSICS_RACES_2026) == 7
    @test all(r -> r.category in [1, 2, 3], CLASSICS_RACES_2026)

    omloop = find_race("Omloop")
    @test omloop !== nothing &&
          omloop.category == 2 &&
          omloop.pcs_slug == "omloop-het-nieuwsblad"
    @test find_race("Paris-Roubaix").category == 1
    @test find_race("NonExistentRace") === nothing
    # Prefix match, not substring: "Tour" used to resolve to Paris-Tours Elite.
    @test find_race("Tour") === nothing

    # Every race the picker can offer must resolve, and round-trip its slug.
    # `all_races()` emits PCS slugs, so this is what stops the race list from
    # containing entries `get_url_pattern` cannot look up.
    races = all_races()
    @test length(races) == 55
    @test count(r -> r.type == :oneday, races) == 44
    for r in races
        p = get_url_pattern(r.slug; year = 2026)
        @test p.pcs_slug == r.slug
    end

    # An unresolved name must throw rather than silently become a stage race.
    @test_throws ErrorException get_url_pattern("not-a-real-race")
    @test_throws ErrorException setup_race("not-a-real-race", 2026)

    config = RaceConfig(
        "test",
        2025,
        :oneday,
        "test-slug",
        "http://example.com",
        6,
        CacheConfig("/tmp/test", 12),
        2,
        "omloop-het-nieuwsblad",
        200.0,
    )
    @test config.category == 2 && config.pcs_slug == "omloop-het-nieuwsblad"
    @test config.total_distance_km == 200.0

    # RenderConfig: the TOML -> config mapping the renderers and the form share.
    toml_oneday = Dict(
        "race" => Dict("name" => "roubaix", "year" => 2026, "racehash" => "#PR"),
        "data_sources" => Dict("oracle_url" => "", "use_oddschecker" => false),
        "optimisation" => Dict(
            "n_resamples" => 250,
            "history_years" => 4,
            "domestique_discount" => 1.0,
            "risk_aversion" => 0.5,
            "max_per_team" => 2,
            "simulation_df" => 5,
            "excluded_riders" => ["Some Rider"],
        ),
    )
    rc = RenderConfig(toml_oneday; repo_root = "/tmp")
    @test rc.race.type == :oneday && rc.race.team_size == 6
    @test rc.racehash == "#PR" && rc.n_resamples == 250 && rc.history_years == 4
    @test rc.simulation_df == 5 && rc.excluded_riders == ["Some Rider"]
    @test rc.odds_df === nothing
    @test rc.market_blend_weight == DEFAULT_MARKET_BLEND_WEIGHT  # absent -> shipped default

    toml_stage = deepcopy(toml_oneday)
    toml_stage["race"]["name"] = "tdf"
    @test RenderConfig(toml_stage; repo_root = "/tmp").race.type == :stage
    @test RenderConfig(toml_stage; repo_root = "/tmp").race.team_size == 9

    toml_stage["optimisation"]["gt_vg_propensity_mode"] = "posthock"
    @test_throws ErrorException RenderConfig(toml_stage; repo_root = "/tmp")

    pattern = get_url_pattern("omloop")
    @test pattern.category == 2 && pattern.pcs_slug == "omloop-het-nieuwsblad"
    @test pattern.total_distance_km == 200.0
    @test get_url_pattern("roubaix").category == 1
    @test get_url_pattern("tdf").category == 0
    @test get_url_pattern("tdf").total_distance_km == 0.0

    # Stage-race URLs are derived, not tabulated: alias → PCS slug → VG slug.
    # `get_url_pattern` indexes the VG dict unguarded, so every PCS slug an alias
    # resolves to must have a VG slug or a lookup throws.
    @test Set(values(Velogames._STAGE_RACE_PCS_SLUGS)) ==
          Set(keys(Velogames._STAGE_RACE_VG_SLUGS))
    for alias in ("tdf", "giro", "vuelta", "tdff", "romandie", "dauphine")
        p = get_url_pattern(alias)
        @test p.template == "https://www.velogames.com/$(p.slug)/{year}/riders.php"
    end
    @test get_url_pattern("tdff").slug == "velogame-femmes"
    @test get_url_pattern("tdff").pcs_slug == "tour-de-france-femmes"

    # Grand-tour membership is read off GT_SIMILAR_RACES (it gates /gc scraping),
    # and resolve_race_date needs an approximate date for each.
    @test Set(keys(Velogames.GT_SIMILAR_RACES)) == Set(keys(Velogames._GT_APPROX_DATE))

    # RaceInfo carries total_distance_km
    omloop_info = find_race("Omloop")
    @test omloop_info !== nothing
    @test omloop_info.total_distance_km == 200.0
    roubaix_info = find_race("Paris-Roubaix")
    @test roubaix_info !== nothing
    @test roubaix_info.total_distance_km > 200.0
end

@testset "Similar races mapping" begin
    @test SIMILAR_RACES isa Dict{String,Vector{String}}
    @test haskey(SIMILAR_RACES, "omloop-het-nieuwsblad")
    @test "e3-harelbeke" in SIMILAR_RACES["omloop-het-nieuwsblad"]
    @test haskey(SIMILAR_RACES, "kuurne-brussel-kuurne")
    @test "scheldeprijs" in SIMILAR_RACES["kuurne-brussel-kuurne"]
    @test !haskey(SIMILAR_RACES, "world-championship")
end

@testset "Race lookup helpers" begin
    @testset "_find_race_by_slug" begin
        ri = Velogames._find_race_by_slug("paris-roubaix")
        @test ri !== nothing
        @test ri.name == "Paris-Roubaix"
        @test ri.category == 1

        @test Velogames._find_race_by_slug("nonexistent-race") === nothing
    end

    @testset "_race_date_for_year" begin
        ri = Velogames._find_race_by_slug("paris-roubaix")
        @test ri !== nothing
        d = Velogames._race_date_for_year(ri, 2024)
        @test Dates.year(d) == 2024
        @test Dates.month(d) == Dates.month(Date(ri.date))
    end
end

# =========================================================================
# Race name matching and VG integration
# =========================================================================

@testset "normalise_race_name" begin
    @test Velogames.normalise_race_name("Omloop Nieuwsblad") ==
          Velogames.normalise_race_name("omloop nieuwsblad")

    @test Velogames.normalise_race_name("Liège-Bastogne-Liège") ==
          Velogames.normalise_race_name("Liege-Bastogne-Liege")

    name = Velogames.normalise_race_name("Milano-Sanremo")
    @test !occursin("-", name)
    @test !isempty(name)
end

@testset "match_vg_race_number" begin
    mock_racelist = DataFrame(
        race_number = [1, 2, 3, 4],
        deadline = [
            "2025-03-01 12:00",
            "2025-03-02 12:00",
            "2025-03-08 12:00",
            "2025-04-06 12:00",
        ],
        name = [
            "Omloop Nieuwsblad",
            "Kuurne-Brussel-Kuurne",
            "Strade Bianche",
            "Ronde van Vlaanderen",
        ],
        category = [2, 3, 2, 1],
        namekey = Velogames.normalise_race_name.([
            "Omloop Nieuwsblad",
            "Kuurne-Brussel-Kuurne",
            "Strade Bianche",
            "Ronde van Vlaanderen",
        ]),
    )

    @test match_vg_race_number("Omloop Nieuwsblad", mock_racelist) == 1
    @test match_vg_race_number("Kuurne-Brussel-Kuurne", mock_racelist) == 2
    @test match_vg_race_number("Ronde van Vlaanderen", mock_racelist) == 4
    @test match_vg_race_number("Tour de France", mock_racelist) === nothing

    empty_racelist = DataFrame(
        race_number = Int[],
        deadline = String[],
        name = String[],
        category = Int[],
        namekey = String[],
    )
    @test match_vg_race_number("Omloop", empty_racelist) === nothing
end

@testset "_compute_cumulative_vg_points edge cases" begin
    race_no_date = BacktestRace("Test", 2024, "test-slug", 2, 5, nothing)
    @test Velogames._compute_cumulative_vg_points(race_no_date) === nothing
end

@testset "rematch_riderkeys! compound surnames" begin
    # VG hyphenates compound surnames; bookmakers usually space them. That
    # changes the riderkey (which keeps the hyphen) AND the whitespace-split
    # surname, so surname-only matching misses them.
    reference = DataFrame(
        rider = ["Pauline Ferrand-Prévot", "Demi Vollering"],
        riderkey = createkey.(["Pauline Ferrand-Prévot", "Demi Vollering"]),
    )
    external = DataFrame(
        rider = ["Pauline Ferrand Prevot", "Demi Vollering"],
        riderkey = createkey.(["Pauline Ferrand Prevot", "Demi Vollering"]),
    )
    Velogames.rematch_riderkeys!(external, reference)
    @test external.riderkey[1] == createkey("Pauline Ferrand-Prévot")
    @test external.riderkey[2] == createkey("Demi Vollering")

    # Surname-only matching still works for given-name variants
    ref2 = DataFrame(rider = ["Thomas Pidcock"], riderkey = [createkey("Thomas Pidcock")])
    ext2 = DataFrame(rider = ["Tom Pidcock"], riderkey = [createkey("Tom Pidcock")])
    Velogames.rematch_riderkeys!(ext2, ref2)
    @test ext2.riderkey[1] == createkey("Thomas Pidcock")
end

