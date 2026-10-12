@testset "cache_key is independent of Dict iteration order" begin
    url = "https://www.procyclingstats.com/race/cyclassics-hamburg/2025/result"
    d = Dict("slug" => "cyclassics-hamburg", "year" => "2025")
    # ImmutableDict iterates newest-first, so these two iterate in opposite orders.
    a = Base.ImmutableDict("slug" => "cyclassics-hamburg", "year" => "2025")
    b = Base.ImmutableDict("year" => "2025", "slug" => "cyclassics-hamburg")
    @test collect(keys(a)) == reverse(collect(keys(b)))
    @test Velogames.cache_key(url, a) == Velogames.cache_key(url, b)
    @test Velogames.cache_key(url, d) == Velogames.cache_key(url, a)
    @test Velogames.cache_key(url, d) != Velogames.cache_key(url, Dict("slug" => "x", "year" => "2025"))
end

@testset "cache_key reproduces keys written under Julia 1.12" begin
    # (filename in ~/.velogames_cache, url, params) from entries written before
    # the move to Julia 1.13; the stored metadata names the url and params.
    pinned = [
        (
            "047d1d431259c664",
            "https://www.procyclingstats.com/race/cyclassics-hamburg/2025/result",
            Dict("slug" => "cyclassics-hamburg", "year" => "2025"),
        ),
        (
            "004b7a36602c345a",
            "https://www.procyclingstats.com/rider/lorenzo-rota/results/career-points-time-trial",
            Dict("slug" => "lorenzo-rota", "specialty" => "tt"),
        ),
        (
            "045a618ae598ec6d",
            "https://www.procyclingstats.com/rider/clement-champoussin",
            Dict("rider" => "Clément Champoussin"),
        ),
        (
            "003f1c790cd26136",
            "https://www.procyclingstats.com/race/bretagne-classic/2026/result",
            Dict(),
        ),
    ]
    for (key, url, params) in pinned
        @test Velogames.cache_key(url, params) == key
    end
end
