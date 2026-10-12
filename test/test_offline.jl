# Offline mode: reconstruction must not reach the network.
#
# Every test here stubs `HTTP.get` with a counter for the exact signature
# `scrape_get` calls, so even a regression makes no request. Run it under a
# network-denying sandbox as well when changing the guard.

const _HTTP = Velogames.HTTP

"""Run `f(calls)` with `HTTP.get(url, headers)` replaced by a counter that
returns an empty 200; the stub is removed afterwards. `f` runs in the latest
world so it sees the stub."""
function with_counted_http(f)
    calls = String[]
    @eval _HTTP.get(url::String, headers::Vector{Pair{String,String}}) =
        (push!($calls, url); _HTTP.Response(200, Pair{String,String}[]; body = UInt8[]))
    try
        return Base.invokelatest(f, calls)
    finally
        Base.delete_method(which(_HTTP.get, (String, Vector{Pair{String,String}})))
    end
end

# Unroutable (TEST-NET-1), so even an unstubbed request could not land anywhere.
const _NOWHERE = "http://192.0.2.1/velogames-offline-test"

@testset "offline: scrape_get refuses before any request" begin
    with_counted_http() do calls
        # The stub intercepts: outside offline mode it is called.
        Velogames.scrape_get(_NOWHERE * "/sanity")
        @test calls == [_NOWHERE * "/sanity"]
        empty!(calls)

        err = try
            with_offline() do
                Velogames.scrape_get(_NOWHERE * "/a")
            end
            nothing
        catch e
            e
        end
        @test err isa Velogames.ScrapeBlockedError
        @test err.offline
        @test isempty(calls)

        # Pages held in-process were fetched today, so they are refused too,
        # and left where they were.
        Velogames._PREFETCHED[_NOWHERE*"/held"] = Vector{UInt8}("x")
        try
            @test_throws Velogames.ScrapeBlockedError with_offline(
                () -> Velogames.scrape_get(_NOWHERE * "/held"),
            )
            @test haskey(Velogames._PREFETCHED, _NOWHERE * "/held")
        finally
            delete!(Velogames._PREFETCHED, _NOWHERE * "/held")
        end
        @test isempty(calls)

        # A plain block keeps its old constructor and is not marked offline.
        @test !Velogames.ScrapeBlockedError("x").offline
    end
end

@testset "offline: prefetch! launches nothing" begin
    dir = mktempdir()
    marker = joinpath(dir, "ran")
    bin = joinpath(dir, "fake-vgleague")
    write(bin, "#!/bin/sh\ntouch '$marker'\n")
    chmod(bin, 0o755)
    old = get(ENV, "VGLEAGUE_BIN", nothing)
    ENV["VGLEAGUE_BIN"] = bin
    try
        r = with_offline(() -> prefetch!([_NOWHERE * "/p"]))
        @test r == (requested = 1, fetched = 0, blocked = 1)
        @test !isfile(marker)
        # Sanity: the fake binary is what would have run.
        prefetch!([_NOWHERE * "/p"])
        @test isfile(marker)
    finally
        old === nothing ? delete!(ENV, "VGLEAGUE_BIN") : (ENV["VGLEAGUE_BIN"] = old)
    end
end

@testset "offline: scope, tasks and the opt-in" begin
    @test !is_offline()
    # Inherited by a task spawned inside the scope; gone once it exits, even
    # by a throw.
    @test with_offline(() -> fetch(Threads.@spawn is_offline()))
    @test_throws ErrorException with_offline(() -> error("boom"))
    @test !is_offline()

    @test Velogames._needs_offline_scope()
    @test !with_offline(Velogames._needs_offline_scope)
    @test_logs (:warn, r"ALLOWED TO FETCH") (:warn, r"ALLOWED TO FETCH") begin
        @test !with_reconstruction_fetch(Velogames._needs_offline_scope)
        @test !with_reconstruction_fetch(is_offline)
    end
end

@testset "offline: backtest prefetch enters offline mode by itself" begin
    cache = CacheConfig(mktempdir(), 168)
    race = BacktestRace("Nowhere Classic", 2024, "nowhere-classic", 1, 1, Date(2024, 4, 1))
    with_counted_http() do calls
        err = try
            prefetch_race_data(race; cache_config = cache)
            nothing
        catch e
            e
        end
        @test err isa Velogames.ScrapeBlockedError && err.offline
        @test isempty(calls)
        @test !is_offline()   # the entry point's scope did not leak

        # The opt-in does reach `HTTP.get` (here the stub; the empty page
        # then fails the race as having no results).
        @test_logs (:warn, r"ALLOWED TO FETCH") match_mode = :any begin
            @test_throws ErrorException with_reconstruction_fetch(
                () -> prefetch_race_data(race; cache_config = cache),
            )
        end
        @test !isempty(calls)
    end
end

@testset "offline: an expired cache entry with data is still served" begin
    dir = mktempdir()
    cache = CacheConfig(dir, 1)
    url = _NOWHERE * "/cached"
    key = Velogames.cache_key(url)
    Velogames.save_to_cache(DataFrame(a = [1]), key, url, dir)
    # Backdate the entry past its one-hour TTL.
    _, meta_file = Velogames.cache_paths(key, dir)
    write(
        meta_file,
        Velogames.JSON3.write(
            Velogames.CacheMetadata(url, now() - Hour(48), "1.0", Dict()),
        ),
    )
    fetches = Ref(0)
    fetcher = (u, p) -> (fetches[] += 1; DataFrame(a = [2]))

    df = with_offline(() -> Velogames.cached_fetch(fetcher, url; cache_config = cache))
    @test df.a == [1]
    @test fetches[] == 0

    Velogames.clear_memory_cache!()
    df = Velogames.cached_fetch(fetcher, url; cache_config = cache)
    @test df.a == [2]   # online the TTL still applies
    @test fetches[] == 1
    Velogames.clear_memory_cache!()
end

@testset "offline: a missing prior edition's standings degrade, not abort" begin
    function Velogames.getpcs_race_results(slug::String, year::Int; kwargs...)
        throw(Velogames.ScrapeBlockedError("simulated block for $slug $year"))
    end
    try
        # Live: a block still propagates.
        @test_throws Velogames.ScrapeBlockedError Velogames.assemble_pcs_classification_history(
            "some-gt-slug",
            2026,
            1,
            :points,
        )
        # Reconstructing: the edition is skipped with a warning.
        for mode in (with_offline, f -> with_browser_transport(f, false))
            @test_logs (:warn, r"No cached points standings for some-gt-slug 2025") mode() do
                @test Velogames.assemble_pcs_classification_history(
                    "some-gt-slug",
                    2026,
                    1,
                    :points,
                ) === nothing
            end
        end
    finally
        Base.include(Velogames, joinpath(pkgdir(Velogames), "src", "pcs_extended.jl"))
    end
end
