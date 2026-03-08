# =========================================================================
# Smoke test: VG rider scraping
# =========================================================================

@testset "getvgriders" begin
    url = vg_classics_url(Dates.year(Dates.today()))
    df = getvgriders(url, force_refresh = true)
    @test df isa DataFrame
    @test nrow(df) > 0

    # Core columns present on all VG game types
    for col in ["rider", "team", "cost", "points", "riderkey"]
        @test col in names(df)
    end

    @test length(unique(df.riderkey)) == length(df.riderkey)

    # Caching round-trip
    df_cached = getvgriders(url)
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
    result = getodds("")
    @test result isa DataFrame
    @test nrow(result) == 0
    @test names(result) == ["rider", "odds", "riderkey"]

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

    pattern = get_url_pattern("omloop")
    @test pattern.category == 2 && pattern.pcs_slug == "omloop-het-nieuwsblad"
    @test pattern.total_distance_km == 200.0
    @test get_url_pattern("roubaix").category == 1
    @test get_url_pattern("tdf").category == 0
    @test get_url_pattern("tdf").total_distance_km == 0.0

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
