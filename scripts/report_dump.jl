#!/usr/bin/env julia
"""
Render race reports into a directory for `vgleague verify-report` to diff.

The reports are ported to Python, whose pages take the league site's chrome, so
diffing markup would fail on every styling difference. This writes Julia's HTML
somewhere harmless and the Python side extracts each table from both and
compares them row by row, which also catches rows in the wrong order.

Writes nowhere near `site/docs`, so a verification run cannot touch what is
published.

Usage:
    julia --project scripts/report_dump.jl OUTDIR [--years=2025,2026] [--limit=N]
"""

using Velogames, DataFrames, Dates, JSON3

include(joinpath(@__DIR__, "render_reports.jl"))

function main(args)
    isempty(args) && error("report_dump.jl: first argument is the output directory")
    outdir = args[1]
    years = nothing
    limit = 0
    for arg in args[2:end]
        if startswith(arg, "--years=")
            years = parse.(Int, split(split(arg, "="; limit = 2)[2], ","))
        elseif startswith(arg, "--limit=")
            limit = parse(Int, split(arg, "="; limit = 2)[2])
        else
            error("report_dump.jl: unrecognised argument $(repr(arg))")
        end
    end
    mkpath(outdir)

    # The dossier's two JSON payloads, dumped alongside the reports. Being data,
    # these can be compared byte for byte.
    all_years = years === nothing ? [2023, 2024, 2025, 2026] : years
    write(joinpath(outdir, "riders.json"), JSON3.write(collect_rider_rows(all_years)))
    write(joinpath(outdir, "stages.json"), JSON3.write(collect_stage_rows(all_years)))

    winners = league_winners_by_race()
    written = 0
    for (data_type, fmt) in (("vg_results", :oneday), ("vg_stage_totals", :stage))
        for slug in archive_races(data_type)
            Velogames.race_format(slug) == fmt || continue
            for year in archive_years(data_type, slug)
                years === nothing || year in years || continue
                limit > 0 && written >= limit && return println("$written report(s)")

                ri = Velogames._find_race_by_slug(slug)
                gt = fmt == :stage ? _find_grand_tour(slug) : nothing
                name =
                    ri !== nothing ? ri.name :
                    gt !== nothing ? gt.name : titlecase(replace(slug, "-" => " "))
                date =
                    ri !== nothing ? replace(ri.date, r"^\d{4}" => string(year)) :
                    gt !== nothing ? Dates.format(Date(year, gt.month, 1), "U yyyy") : ""
                w = get(winners, (slug, year), nothing)

                html =
                    fmt == :stage ?
                    stage_race_report_html(;
                        pcs_slug = slug,
                        year = year,
                        race_name = name,
                        race_date = date,
                        n_stages = gt === nothing ? 21 : gt.n_stages,
                        winner_name = w === nothing ? "" : w.name,
                        winner_score = w === nothing ? 0 : w.score,
                    ) :
                    report_html(;
                        pcs_slug = slug,
                        year = year,
                        race_name = name,
                        race_date = date,
                        winner_name = w === nothing ? "" : w.name,
                        winner_score = w === nothing ? 0 : w.score,
                    )
                html === nothing && continue
                write(joinpath(outdir, "$slug-$year.html"), html)
                written += 1
            end
        end
    end
    println("$written report(s)")
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
