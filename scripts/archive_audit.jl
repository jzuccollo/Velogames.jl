#!/usr/bin/env julia
# ---------------------------------------------------------------------------
# archive_audit.jl — what the write guard cannot see
#
# `save_race_snapshot` refuses an unknown data type or a frame missing a
# mandatory column, so no *new* file can drift. This walks what is already
# there: unknown top-level types, files short of their mandatory columns, files
# written before provenance was stamped, stray extensions, unreadable files, and
# per-type counts.
#
# Run:  julia --project scripts/archive_audit.jl
#       julia --project scripts/archive_audit.jl --write-manifest
#       julia --project scripts/archive_audit.jl --write-races
#       julia --project scripts/archive_audit.jl --check
#
# `--check` compares `_manifest.toml` against ARCHIVE_TYPES and `_races.toml`
# against the race catalogue, exiting non-zero when either differs — so a
# forgotten export fails a run rather than leaving a stale description of the
# archive for Python to read.
#
# `_races.toml` is which Velogames race name is which PCS slug. Python needs it
# to key a `vg_results` file at all, and the mapping exists only in
# `CLASSICS_RACES_2026`.
# ---------------------------------------------------------------------------

using Velogames
using Printf

function report(root::String)
    a = audit_archive(; archive_dir = root)

    println("Archive: $root\n")
    @printf("%-24s %7s %7s %10s\n", "type", "races", "files", "rows")
    for c in a.counts
        @printf("%-24s %7d %7d %10d\n", c.data_type, c.races, c.files, c.rows)
    end
    @printf(
        "%-24s %7s %7d %10d\n",
        "TOTAL",
        "",
        sum(c.files for c in a.counts; init = 0),
        sum(c.rows for c in a.counts; init = 0)
    )

    section(title, items, fmt = string) = begin
        println("\n$title: $(length(items))")
        for i in items
            println("  ", fmt(i))
        end
    end

    section("Unknown top-level types", a.unknown_types)
    section("Unreadable files", a.unreadable)
    section("Stray files inside race directories", a.stray_files)
    section("Race directories holding no archive file", a.empty_races)
    section(
        "Files missing mandatory columns",
        a.missing_columns,
        x -> "$(x.path)  missing $(x.missing)",
    )
    # Every file written before WP5 is in this state, so print the count and a
    # sample rather than several hundred paths.
    println("\nFiles with no provenance metadata: $(length(a.missing_provenance))")
    for p in first(a.missing_provenance, 5)
        println("  ", p)
    end
    length(a.missing_provenance) > 5 &&
        println("  … and $(length(a.missing_provenance) - 5) more")

    manifest_ok = archive_manifest_matches(; archive_dir = root)
    println(
        "\n_manifest.toml: ",
        manifest_ok ? "matches ARCHIVE_TYPES" :
        "MISSING OR STALE — run with --write-manifest",
    )
    println(
        "_races.toml:    ",
        race_catalogue_matches(; archive_dir = root) ? "matches the race catalogue" :
        "MISSING OR STALE — run with --write-races",
    )
    return a
end

function main(args)
    root = archive_dir()
    wrote = false
    if "--write-manifest" in args
        println("Wrote ", write_archive_manifest(; archive_dir = root))
        wrote = true
    end
    if "--write-races" in args
        println("Wrote ", write_race_catalogue(; archive_dir = root))
        wrote = true
    end
    wrote && return 0
    if "--check" in args
        stale = String[]
        archive_manifest_matches(; archive_dir = root) ||
            push!(stale, "_manifest.toml (--write-manifest)")
        race_catalogue_matches(; archive_dir = root) ||
            push!(stale, "_races.toml (--write-races)")
        if isempty(stale)
            println("_manifest.toml and _races.toml are both current")
            return 0
        end
        for s in stale
            println("missing or stale: $s")
        end
        return 1
    end
    report(root)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
