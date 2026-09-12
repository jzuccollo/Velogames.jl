#!/usr/bin/env julia
"""
Re-fetch archived one-day `pcs_results` so they carry their breakaway columns.

PCS marks a breakaway rider with a `div.svg_shield` carrying the distance in its
`title`. That element is rendered by JavaScript, so it never appeared in a raw
`HTTP.jl` response: `in_breakaway` was hardcoded `false` and `breakaway_km`
always `missing` in every file the archive holds. Now that fetches go through a
browser (`docs/pcs-fetch-architecture.md`) the data is reachable, and
`pcs_results` is `refetchable = true`, so the history can be recovered rather
than merely accumulated from here on.

Verified before writing anything: a force-refresh of il-lombardia 2024 returned
the identical 175 rows on `position`, `rider`, `team` and `riderkey`, gaining 20
breakaway riders. The finishing order does not move; only the two columns that
were previously unfillable change.

Every URL is prefetched in ONE browser session. One launch costs seconds and a
page about a quarter of one, so the alternative — letting `scrape_get` fall
through per race — would be a browser launch per race.

Usage:
    julia --project scripts/backfill_breakaways.jl [--dry-run] [--limit=N]
"""

using Velogames
using DataFrames

const DRY_RUN = "--dry-run" in ARGS
const LIMIT = something(
    findfirst(a -> startswith(a, "--limit="), ARGS) === nothing ? nothing :
    tryparse(Int, split(ARGS[findfirst(a -> startswith(a, "--limit="), ARGS)], "=")[2]),
    typemax(Int),
)

result_url(slug, year) = "https://www.procyclingstats.com/race/$slug/$year/result"

function targets()
    out = Tuple{String,Int}[]
    for slug in archive_races("pcs_results")
        for year in archive_years("pcs_results", slug)
            # Stage races keep their standings under `pcs_gc_results`; a GC page
            # has no breakaway shields, so anything filed here is a one-day
            # result and `/result` is the page that carries them.
            race_format(slug) == :stage && continue
            push!(out, (slug, year))
        end
    end
    return sort(out)
end

function main()
    todo = targets()
    length(todo) > LIMIT && (todo = todo[1:LIMIT])
    @info "Backfilling breakaway columns for $(length(todo)) archived one-day results"

    urls = String[result_url(s, y) for (s, y) in todo]
    if !DRY_RUN
        res = prefetch!(urls)
        @info "Prefetch: $(res.fetched)/$(res.requested) pages, $(res.blocked) missed"
    end

    # Zero TTL: the prefetched page is the fetch, and the on-disk cache holds
    # pre-browser parses of these very URLs that would otherwise be served back.
    cc = Velogames.CacheConfig(mktempdir(), 0)
    changed, unchanged, failed, riders = 0, 0, 0, 0
    for (slug, year) in todo
        try
            fresh = Velogames.getpcs_race_results(
                slug,
                year;
                cache_config = cc,
                force_refresh = true,
            )
            n_break = sum(fresh.in_breakaway)
            if nrow(fresh) == 0
                failed += 1
                @warn "No rows returned for $slug $year — leaving the archive alone"
                continue
            end
            existing = load_race_snapshot("pcs_results", slug, year)
            if existing !== nothing && nrow(existing) != nrow(fresh)
                failed += 1
                @warn "Row count moved for $slug $year ($(nrow(existing)) → $(nrow(fresh))) — skipping rather than overwriting"
                continue
            end
            if n_break == 0
                unchanged += 1
            else
                changed += 1
                riders += n_break
            end
            DRY_RUN || save_race_snapshot(fresh, "pcs_results", slug, year)
        catch e
            failed += 1
            @warn "Failed $slug $year" exception = e
        end
    end

    @info "Backfill complete" races_with_breakaways = changed races_without = unchanged failed =
        failed rider_races_in_break = riders dry_run = DRY_RUN
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
