@testset "league_race_slug" begin
    # Winner derivation treats a scraped league race as a publishable classic
    # only when this comes back non-empty, so the empty string for a grand tour
    # stage is a verdict, not a miss.
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

        rosters = load_race_snapshot(
            "league/rosters",
            "sixes-classics_1",
            2026;
            archive_dir = tree,
        )
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
        @test pull(
            game_slug = "sixes-classics",
            league_id = "1",
            pcs_slug = "il-lombardia",
        ) == String[]
        @test load_league_team(;
            game_slug = "sixes-classics",
            year = 2026,
            league_id = "1",
            username = "Nobody",
            pcs_slug = "classic-brugge-de-panne",
            archive_dir = tree,
        ) == String[]
        @test pull(game_slug = "absent", league_id = "9", pcs_slug = "il-lombardia") ==
              String[]

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
        # not the newest, which is why the raw tier is dated. Both
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
        @test recorded[1] ==
              (pcs_slug = "classic-brugge-de-panne", year = 2026, name = "T", score = 300)
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
        @test nrow(derive_league_winners("velogame", 2026, "2"; archive_dir = tree)) == 1
    end
end

# The winner above is derived from the 2026-04-01 snapshot and `now` defaults to
# today, which is far past any settling window. That guards the diagnostic pass
# in `_derive_classics_winners`: it must report on races the dated pass could
# not settle and never settle one itself. If it ever starts publishing,
# `snapshot_date` there stops being "2026-04-01".

@testset "Grand tour waits for the whole catalogue (WP6)" begin
    # A grand tour catalogue grows: End-of-Tour is added when the tour finishes.
    # A snapshot taken in between lists every race it knows about as scored, so
    # testing it against its own catalogue settles the tour on a partial total.
    partial = """
    {"meta": {"game_slug": "velogame", "year": 2026, "league_id": "3",
              "series_type": "grand_tour", "race_catalogue": {
                "1": {"name": "Stage 1", "deadline": null, "category": "road"},
                "2": {"name": "Stage 2", "deadline": null, "category": "road"}}},
     "teams": {"X": {"username": "X", "teamname": "X", "teamid": "1", "races": {
        "Stage 1": {"race_number": 1, "score": 60, "riders": ["A"],
                    "rider_costs": {"A": 10}, "rider_scores": {"A": 60}},
        "Stage 2": {"race_number": 2, "score": 40, "riders": ["A"],
                    "rider_costs": {"A": 10}, "rider_scores": {"A": 40}}}},
               "Y": {"username": "Y", "teamname": "Y", "teamid": "2", "races": {
        "Stage 1": {"race_number": 1, "score": 50, "riders": ["B"],
                    "rider_costs": {"B": 12}, "rider_scores": {"B": 50}},
        "Stage 2": {"race_number": 2, "score": 40, "riders": ["B"],
                    "rider_costs": {"B": 12}, "rider_scores": {"B": 40}}}}}}
    """
    # End-of-Tour lands, and it changes the order.
    complete = replace(
        partial,
        """"2": {"name": "Stage 2", "deadline": null, "category": "road"}}}""" => """"2": {"name": "Stage 2", "deadline": null, "category": "road"},
                                                                                      "3": {"name": "End-of-Tour", "deadline": null, "category": "road"}}}""",
        """"rider_scores": {"A": 40}}}}""" => """"rider_scores": {"A": 40}},
                                          "End-of-Tour": {"race_number": 3, "score": 0, "riders": ["A"],
                                                          "rider_costs": {"A": 10}, "rider_scores": {"A": 0}}}}""",
        """"rider_scores": {"B": 40}}}}}}""" => """"rider_scores": {"B": 40}},
                                            "End-of-Tour": {"race_number": 3, "score": 50, "riders": ["B"],
                                                            "rider_costs": {"B": 12}, "rider_scores": {"B": 50}}}}}}""",
    )

    mktempdir() do dir
        tree = mktempdir()
        path = joinpath(dir, "velogame_2026_3.json")

        write(path, partial)
        ingest_league_file(path; date = Date(2026, 6, 1), archive_dir = tree)

        write(path, complete)
        ingest_league_file(path; date = Date(2026, 6, 2), archive_dir = tree)

        w = derive_league_winners(
            "velogame",
            2026,
            "3";
            now = DateTime(2026, 6, 5),
            archive_dir = tree,
        )
        @test nrow(w) == 1
        # Gating each snapshot against its own catalogue would flip all three:
        # it picks X, on 100, from the 06-01 snapshot.
        @test w.teamname[1] == "Y"
        @test w.score[1] == 140.0
        @test w.snapshot_date[1] == "2026-06-02"

        # The newest catalogue is only trustworthy once it has settled. A
        # publish landing inside the window sees the partial catalogue as the
        # current one, so gating on "newest" alone cannot help.
        @test isempty(
            derive_league_winners(
                "velogame",
                2026,
                "3";
                now = DateTime(2026, 6, 2, 6),
                archive_dir = tree,
            ),
        )
    end

    # A tour with a race still unscored holds back however long it has settled.
    unscored = """
    {"meta": {"game_slug": "velogame", "year": 2026, "league_id": "4",
              "series_type": "grand_tour", "race_catalogue": {
                "1": {"name": "Stage 1", "deadline": null, "category": "road"},
                "2": {"name": "Stage 2", "deadline": null, "category": "road"},
                "3": {"name": "End-of-Tour", "deadline": null, "category": "road"}}},
     "teams": {"X": {"username": "X", "teamname": "X", "teamid": "1", "races": {
        "Stage 1": {"race_number": 1, "score": 60, "riders": ["A"],
                    "rider_costs": {"A": 10}, "rider_scores": {"A": 60}},
        "Stage 2": {"race_number": 2, "score": 40, "riders": ["A"],
                    "rider_costs": {"A": 10}, "rider_scores": {"A": 40}}}}}}
    """
    mktempdir() do dir
        tree = mktempdir()
        path = joinpath(dir, "velogame_2026_4.json")
        write(path, unscored)
        ingest_league_file(path; date = Date(2026, 6, 2), archive_dir = tree)
        @test isempty(
            derive_league_winners(
                "velogame",
                2026,
                "4";
                now = DateTime(2026, 7, 1),
                archive_dir = tree,
            ),
        )
    end
end

@testset "A classic the gate cannot settle says so (WP6)" begin
    # `save_league_snapshot` dedupes on content, so once the season's final race
    # settles nothing changes again and no snapshot dated a full window past its
    # deadline is ever written. The gate then cannot be satisfied, and has to
    # say so.
    late = """
    {"meta": {"game_slug": "sixes-classics", "year": 2026, "league_id": "9",
              "series_type": "classics", "race_catalogue": {
                "7": {"name": "Ronde van Brugge", "deadline": "2026-10-11 11:00:00", "category": 2}}},
     "teams": {"JZ": {"username": "JZ", "teamname": "T", "teamid": "9", "races": {
        "Ronde van Brugge": {"race_number": 7, "score": 300, "riders": ["A"],
                             "rider_costs": {"A": 20}, "rider_scores": {"A": 300}}}}}}
    """
    mktempdir() do dir
        tree = mktempdir()
        path = joinpath(dir, "sixes-classics_2026_9.json")
        write(path, late)
        ingest_league_file(path; date = Date(2026, 10, 11), archive_dir = tree)
        write(path, replace(late, "\"score\": 300" => "\"score\": 320"))
        ingest_league_file(path; date = Date(2026, 10, 12), archive_dir = tree)

        # The newest snapshot is 13h past the deadline, short of the 24h window,
        # so nothing publishes however long we wait.
        call() = derive_league_winners(
            "sixes-classics",
            2026,
            "9";
            now = DateTime(2026, 11, 1),
            archive_dir = tree,
        )
        @test isempty(call())
        # A silent gate would also return empty, so the log is the test.
        @test_logs (:info, r"Settle it by hand") match_mode = :any call()

        # And the remedy it names has to work.
        w = derive_league_winners(
            "sixes-classics",
            2026,
            "9";
            min_age_hours = 13,
            now = DateTime(2026, 11, 1),
            archive_dir = tree,
        )
        @test nrow(w) == 1
        @test w.snapshot_date[1] == "2026-10-12"
    end
end

@testset "A scored race with no deadline says so (WP6)" begin
    # The live classics catalogue can shrink, so a scored race can be absent
    # from every catalogue held.
    orphan = """
    {"meta": {"game_slug": "sixes-classics", "year": 2026, "league_id": "8",
              "series_type": "classics", "race_catalogue": {}},
     "teams": {"JZ": {"username": "JZ", "teamname": "T", "teamid": "9", "races": {
        "Ronde van Brugge": {"race_number": 7, "score": 300, "riders": ["A"],
                             "rider_costs": {"A": 20}, "rider_scores": {"A": 300}}}}}}
    """
    mktempdir() do dir
        tree = mktempdir()
        path = joinpath(dir, "sixes-classics_2026_8.json")
        write(path, orphan)
        ingest_league_file(path; date = Date(2026, 4, 1), archive_dir = tree)

        call() = derive_league_winners(
            "sixes-classics",
            2026,
            "8";
            now = DateTime(2026, 12, 1),
            archive_dir = tree,
        )
        @test isempty(call())
        @test_logs (:info, r"no deadline in any snapshot's race catalogue") match_mode =
            :any call()
    end
end

@testset "Forced rebuild of the derived tables (WP6)" begin
    # The derived tables are a function of the newest snapshot AND of
    # `league_rosters_frame`. Only the snapshot half is checked, so without
    # `force` a finished season keeps whatever an older `league_rosters_frame`
    # wrote.
    src = """
    {"meta": {"game_slug": "sixes-classics", "year": 2026, "league_id": "7",
              "series_type": "classics", "race_catalogue": {
                "7": {"name": "Ronde van Brugge", "deadline": "2026-03-25 11:00:00", "category": 2}}},
     "teams": {"JZ": {"username": "JZ", "teamname": "T", "teamid": "9", "races": {
        "Ronde van Brugge": {"race_number": 7, "score": 300,
                             "riders": ["Jasper Philipsen", "Max Kanter"],
                             "rider_costs": {"Jasper Philipsen": 20, "Max Kanter": 6},
                             "rider_scores": {"Jasper Philipsen": 260, "Max Kanter": 40}}}}}}
    """
    mktempdir() do dir
        tree = mktempdir()
        path = joinpath(dir, "sixes-classics_2026_7.json")
        write(path, src)
        first_pass = ingest_league_file(path; date = Date(2026, 4, 1), archive_dir = tree)
        @test first_pass.rebuilt
        @test first_pass.rows == 2

        again = ingest_league_file(path; date = Date(2026, 4, 2), archive_dir = tree)
        @test again.snapshot_date === nothing
        @test !again.rebuilt

        # A stale derived table: present, readable, and no longer what
        # `league_rosters_frame` produces.
        save_race_snapshot(
            DataFrame(
                username = ["x"],
                teamname = ["x"],
                teamid = ["x"],
                race_number = [1],
                race_name = ["x"],
                rider = ["x"],
                cost = [1],
                score = [1.0],
                race_score = [1.0],
            ),
            "league/rosters",
            "sixes-classics_7",
            2026;
            archive_dir = tree,
        )
        unforced = ingest_league_file(path; date = Date(2026, 4, 2), archive_dir = tree)
        @test !unforced.rebuilt
        @test nrow(
            load_race_snapshot(
                "league/rosters",
                "sixes-classics_7",
                2026;
                archive_dir = tree,
            ),
        ) == 1

        forced = ingest_league_file(
            path;
            date = Date(2026, 4, 2),
            force = true,
            archive_dir = tree,
        )
        @test forced.rebuilt
        @test forced.source_date == Date(2026, 4, 1)
        @test nrow(
            load_race_snapshot(
                "league/rosters",
                "sixes-classics_7",
                2026;
                archive_dir = tree,
            ),
        ) == 2

        # A dry run reports and writes nothing.
        before = read(
            Velogames.archive_path(
                "league/rosters",
                "sixes-classics_7",
                2026;
                archive_dir = tree,
            ),
        )
        dry = ingest_league_file(
            path;
            date = Date(2026, 4, 5),
            force = true,
            dry_run = true,
            archive_dir = tree,
        )
        @test dry.rows == 2
        @test Velogames.league_snapshot_dates(
            "sixes-classics",
            2026,
            "7";
            archive_dir = tree,
        ) == [Date(2026, 4, 1)]
        @test read(
            Velogames.archive_path(
                "league/rosters",
                "sixes-classics_7",
                2026;
                archive_dir = tree,
            ),
        ) == before
    end
end

@testset "One winner per race across leagues (WP6)" begin
    # `derive_league_winners`' contract is one league-season, so two leagues on
    # the same game and year each derive the same race. The guard therefore has
    # to live in the caller — and `load_league_winners` has to say when the
    # archive holds two, because readers key on (pcs_slug, year) and silently
    # keep whichever came last.
    src = """
    {"meta": {"game_slug": "sixes-classics", "year": 2026, "league_id": "LID",
              "series_type": "classics", "race_catalogue": {
                "7": {"name": "Ronde van Brugge", "deadline": "2026-03-25 11:00:00", "category": 2}}},
     "teams": {"JZ": {"username": "JZ", "teamname": "T", "teamid": "9", "races": {
        "Ronde van Brugge": {"race_number": 7, "score": 300, "riders": ["A"],
                             "rider_costs": {"A": 20}, "rider_scores": {"A": 300}}}}}}
    """
    mktempdir() do dir
        tree = mktempdir()
        for lid in ("a", "b")
            path = joinpath(dir, "sixes-classics_2026_$lid.json")
            write(path, replace(src, "LID" => lid))
            ingest_league_file(path; date = Date(2026, 4, 1), archive_dir = tree)
            w = derive_league_winners(
                "sixes-classics",
                2026,
                lid;
                now = DateTime(2026, 5, 1),
                archive_dir = tree,
            )
            @test nrow(w) == 1
            append_league_winners(w, "sixes-classics", 2026, lid; archive_dir = tree)
        end

        recorded =
            @test_logs (:warn, r"more than one winner") match_mode = :any load_league_winners(;
                archive_dir = tree,
            )
        @test length(recorded) == 2
        @test length(unique(w -> (w.pcs_slug, w.year), recorded)) == 1
    end
end

@testset "A recorded winner can be re-derived (WP6)" begin
    src = """
    {"meta": {"game_slug": "sixes-classics", "year": 2026, "league_id": "6",
              "series_type": "classics", "race_catalogue": {
                "7": {"name": "Ronde van Brugge", "deadline": "2026-03-25 11:00:00", "category": 2}}},
     "teams": {"JZ": {"username": "JZ", "teamname": "T", "teamid": "9", "races": {
        "Ronde van Brugge": {"race_number": 7, "score": 300, "riders": ["A"],
                             "rider_costs": {"A": 20}, "rider_scores": {"A": 300}}}}}}
    """
    mktempdir() do dir
        tree = mktempdir()
        path = joinpath(dir, "sixes-classics_2026_6.json")
        write(path, src)
        ingest_league_file(path; date = Date(2026, 4, 1), archive_dir = tree)
        args = ("sixes-classics", 2026, "6")
        derive() =
            derive_league_winners(args...; now = DateTime(2026, 5, 1), archive_dir = tree)

        w = derive()
        append_league_winners(w, args...; archive_dir = tree)
        @test isempty(derive())  # recorded once, never re-derived

        @test remove_league_winner(
            "classic-brugge-de-panne",
            args...;
            archive_dir = tree,
        ) == 1
        again = derive()
        @test nrow(again) == 1
        @test again.teamname[1] == w.teamname[1]
        @test again.snapshot_date[1] == w.snapshot_date[1]

        @test remove_league_winner("no-such-race", args...; archive_dir = tree) == 0

        # A seeded row is the only copy there is, so it is refused.
        append_league_winners(
            DataFrame(
                pcs_slug = ["milano-sanremo"],
                year = [2026],
                race_number = [1],
                username = ["u"],
                teamname = ["t"],
                score = [1.0],
                snapshot_date = [""],
            ),
            args...;
            archive_dir = tree,
        )
        @test_throws ErrorException remove_league_winner(
            "milano-sanremo",
            args...;
            archive_dir = tree,
        )
    end
end

# =========================================================================
# Smoke test: VG rider scraping
# =========================================================================

@testset "getvg_riders reaches Velogames through the browser transport" begin
    # Velogames answers `HTTP.jl` with a 403, so this passes only if
    # `scrape_get` fell through to `vgleague fetch` and got the page (see
    # docs/pcs-fetch-architecture.md). A live network call, because nothing
    # short of one tests the transport. Needs `vgleague` on PATH and a GUI
    # session.
    url = vg_classics_url(Dates.year(Dates.today()))
    riders = getvg_riders(url, force_refresh = true)
    @test nrow(riders) > 100
    @test all(!isempty, riders.riderkey)
    @test !any(ismissing, riders.cost)
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
    # Prefix match, not substring, so "Tour" does not resolve to Paris-Tours
    # Elite.
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
    # Worlds is deliberately absent from this test: the course changes every
    # year, so its similar races are set by hand for each edition.
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

    # PCS adds a middle name: "Finn" is also Fisher-Black's given name and
    # "Mark" Donovan's, so the surname rule alone picks the wrong rider.
    ref3 = DataFrame(
        rider = ["Lorenzo Finn", "Finn Fisher-Black", "Mark Donovan", "Taco van der Hoorn"],
    )
    ref3.riderkey = createkey.(ref3.rider)
    ext3 = DataFrame(rider = ["FINN Lorenzo Mark", "VAN DER POEL Mathieu"])
    ext3.riderkey = createkey.(ext3.rider)
    Velogames.rematch_riderkeys!(ext3, ref3)
    @test ext3.riderkey[1] == createkey("Lorenzo Finn")
    # Sharing "van der" is not a match
    @test ext3.riderkey[2] == createkey("VAN DER POEL Mathieu")
end
