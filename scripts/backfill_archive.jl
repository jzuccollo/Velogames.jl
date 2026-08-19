#!/usr/bin/env julia
# ---------------------------------------------------------------------------
# backfill_archive.jl — fill the gaps that are still fetchable
#
# `archive_audit.jl` reports what is wrong with the files we have. This reports
# what is *missing*, and fetches back whatever the sources still serve.
#
# What is recoverable, and what is not:
#
#   pcs_results   RECOVERABLE. PCS keeps finishing orders indefinitely, and a
#                 final result does not change, so a fetch today is the same
#                 fact as a fetch on the day. 2023–2025 hold none at all.
#   vg_scoring    RECOVERABLE while the rules page is up; it retires with the
#                 season like every other Velogames page.
#   pcs_specialty NOT recoverable. It is a snapshot of a live rating: fetching
#   pcs_seasons   it today returns today's values, which would let a backtest
#                 see results the model could not have seen. A gap here stays a
#                 gap — filling it would be worse than leaving it.
#   odds, oracle  NOT recoverable. The market closed; the blog post is edited.
#   vg_riders     Handled by backfill_vg_pages.jl, which pins Internet Archive
#   vg_racelist   timestamps for the seasons Velogames has taken down.
#
# `--rekey` is a separate, narrower job: some 2023/2024 `vg_results` carry
# riderkeys made by an older `createkey` that kept apostrophes, so O'Brien and
# O'Connor fall out of every join against a pool keyed today. It rewrites only
# rows where the recomputed key is in that season's rider pool and the stored
# one is not — which is why it leaves alone the two `oracle` rows whose stored
# key is deliberately the fuller name ("Juan Sebastián Molano" against a
# display name of "Sebastian Molano"), where recomputing would break the match.
#
# Run:  julia --project scripts/backfill_archive.jl            # report only
#       julia --project scripts/backfill_archive.jl --run      # fetch and archive
#       julia --project scripts/backfill_archive.jl --run --years=2023,2024
#       julia --project scripts/backfill_archive.jl --rekey [--run]
#       julia --project scripts/backfill_archive.jl --repair-predictions [--run]
# ---------------------------------------------------------------------------

using Velogames
using DataFrames
using Printf

const RUN = "--run" in ARGS
const REKEY = "--rekey" in ARGS
const REPAIR = "--repair-predictions" in ARGS
const YEARS = let a = filter(x -> startswith(x, "--years="), ARGS)
    isempty(a) ? [2023, 2024, 2025, 2026] :
    parse.(Int, split(replace(a[1], "--years=" => ""), ","))
end

# PCS is a courtesy host for a 130-request sweep.
const FETCH_DELAY_S = 1.0

oneday_races() = [r for r in all_races() if r.type == :oneday]

"""
Races with a Velogames result but no PCS finishing order. The VG side is the
gate: those are the races we actually played, and the ones a report or a
backtest wants a finishing order for.
"""
function missing_pcs_results(years)
    gaps = NamedTuple{(:slug, :name, :year),Tuple{String,String,Int}}[]
    for r in oneday_races(), y in years
        has_race_snapshot("vg_results", r.slug, y) || continue
        has_race_snapshot("pcs_results", r.slug, y) && continue
        push!(gaps, (slug = r.slug, name = r.name, year = y))
    end
    return gaps
end

function backfill_pcs_results(years)
    gaps = missing_pcs_results(years)
    @printf("pcs_results: %d races have a VG result but no PCS finishing order\n", length(gaps))
    for y in sort(unique(g.year for g in gaps))
        @printf("  %d: %d\n", y, count(g -> g.year == y, gaps))
    end
    RUN || return (0, 0)

    println()
    archived = empty = 0
    for (i, g) in enumerate(gaps)
        @printf("[%3d/%3d] %-28s %d  ", i, length(gaps), g.slug, g.year)
        try
            res = getpcs_race_results(g.slug, g.year)
            if nrow(res) == 0
                println("no result page — skipped")
                empty += 1
            else
                save_race_snapshot(
                    res,
                    "pcs_results",
                    g.slug,
                    g.year;
                    source_url = "https://www.procyclingstats.com/race/$(g.slug)/$(g.year)",
                )
                @printf("archived %d rows\n", nrow(res))
                archived += 1
            end
        catch e
            println("FAILED: ", sprint(showerror, e))
            empty += 1
        end
        sleep(FETCH_DELAY_S)
    end
    return (archived, empty)
end

"""
Rows whose `riderkey` disagrees with `createkey(rider)` today *and* whose
recomputed key matches that season's Velogames pool while the stored one does
not. Both halves matter: the first finds the drift, the second establishes that
recomputing is an improvement rather than a different kind of wrong.
"""
function rekey_vg_results(years)
    fixed_files = 0
    fixed_rows = 0
    for y in years
        pool = try
            Set(load_vg_classics_riders(y).riderkey)
        catch
            continue
        end
        isempty(pool) && continue
        for r in oneday_races()
            has_race_snapshot("vg_results", r.slug, y) || continue
            df = load_race_snapshot("vg_results", r.slug, y)
            rows = [
                i for i in 1:nrow(df) if
                createkey(String(df.rider[i])) != String(df.riderkey[i]) &&
                createkey(String(df.rider[i])) in pool &&
                String(df.riderkey[i]) ∉ pool
            ]
            isempty(rows) && continue
            for i in rows
                @printf(
                    "  %-28s %d  %-24s %s → %s\n",
                    r.slug, y, df.rider[i], df.riderkey[i], createkey(String(df.rider[i]))
                )
            end
            fixed_rows += length(rows)
            fixed_files += 1
            RUN || continue
            for i in rows
                df.riderkey[i] = createkey(String(df.rider[i]))
            end
            # Written without provenance, deliberately. These are legacy files
            # that never carried any, and re-deriving a join key does not make
            # today the date the result was fetched — stamping it would put a
            # false fetch date on a 2023 record. The audit goes on reporting
            # them as what they are: files written before the stamp existed.
            Velogames.Arrow.write(archive_path("vg_results", r.slug, y), df)
        end
    end
    return (fixed_files, fixed_rows)
end

"""
Restore `team` and `cost` to prediction archives that lack them, by joining the
season's Velogames pool on `riderkey`. Costs are constant within a season, so
the pool still carries February's prices.

`chosen`, `selection_frequency` and `expected_vg_points` are **not** restored,
here or ever. They are model outputs, and the model has changed since — the
April 2026 ablation dropped signals, the July market blend changed the pick — so
recomputing them today produces a different prediction from the one that was
actually made, in a file labelled "what we predicted". Materialising them as
all-`missing` to satisfy the write guard would be the same dishonesty wearing a
disguise: the audit would read the file as complete while it carried nothing.
Those races stay deficient, the audit goes on saying so, and that is the end
state.
"""
function repair_predictions(years)
    repaired = 0
    for r in oneday_races(), y in years
        has_race_snapshot("predictions", r.slug, y) || continue
        df = load_race_snapshot("predictions", r.slug, y)
        gaps = intersect([:team, :cost], missing_mandatory_columns("predictions", df))
        isempty(gaps) && continue

        pool = load_vg_classics_riders(y)
        cols = intersect(propertynames(pool), [:riderkey; gaps])
        joined = leftjoin(df, unique(pool[:, cols], :riderkey), on = :riderkey)
        filled = count(!ismissing, joined[!, first(gaps)])
        @printf("  %-28s %d  %s ← pool: %d/%d riders matched\n",
                r.slug, y, join(gaps, ", "), filled, nrow(df))
        still = missing_mandatory_columns("predictions", joined)
        isempty(still) || @printf("      still missing (model outputs, not restorable): %s\n", join(still, ", "))

        RUN || continue
        # Arrow.write, not save_race_snapshot: the frame is still short of the
        # three model columns, and the guard would rightly refuse it. Provenance
        # is stamped because this file *is* new — a join performed today over an
        # archived prediction — unlike the re-key above, which leaves the record
        # exactly as fetched.
        path = archive_path("predictions", r.slug, y)
        Velogames.Arrow.write(
            path,
            joined;
            metadata = Velogames._archive_provenance(
                "predictions",
                ARCHIVE_TYPES["predictions"].version,
                "",
            ),
        )
        repaired += 1
    end
    return repaired
end

function report_other_gaps(years)
    println()
    println("Other gaps, for the record:")
    stage = [r for r in all_races() if r.type != :oneday]
    for t in ["vg_scoring", "pcs_stage_profiles", "pcs_gc_results"]
        missing = [
            "$(r.slug) $y" for r in stage, y in years if
            has_race_snapshot("vg_stage_totals", r.slug, y) && !has_race_snapshot(t, r.slug, y)
        ]
        isempty(missing) || println("  $t missing where the tour was played: ", join(missing, ", "))
    end
    for t in ["odds", "oracle", "pcs_specialty"]
        yrs = [y for y in years if any(r -> has_race_snapshot(t, r.slug, y), oneday_races())]
        println("  $t: present for $(isempty(yrs) ? "no years" : join(yrs, ", ")) — earlier seasons are not recoverable")
    end
end

function main()
    println("Years: ", join(YEARS, ", "), RUN ? "  (writing)" : "  (report only — pass --run to write)")
    println()

    if REPAIR
        println("Prediction archives missing team/cost:")
        n = repair_predictions(YEARS)
        @printf("\n%d file(s)%s\n", n, RUN ? " repaired" : " — pass --run to repair")
        return 0
    end

    if REKEY
        println("vg_results rows whose riderkey predates today's createkey:")
        files, rows = rekey_vg_results(YEARS)
        @printf("\n%d row(s) across %d file(s)%s\n", rows, files, RUN ? " rewritten" : " — pass --run to rewrite")
        return 0
    end

    archived, skipped = backfill_pcs_results(YEARS)
    report_other_gaps(YEARS)
    if RUN
        @printf("\nArchived %d, skipped %d.\n", archived, skipped)
        println("Re-run `julia --project scripts/archive_audit.jl` to confirm the new files are clean.")
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
