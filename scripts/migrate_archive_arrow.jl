#!/usr/bin/env julia
# ---------------------------------------------------------------------------
# migrate_archive_arrow.jl — one-shot Feather V1 → Arrow IPC conversion (WP1b)
#
# Feather.jl v0.5.10 is end-of-life and pyarrow warns that V1 support "will be
# removed in a future version", so the durable record has to move before a Julia
# upgrade takes the reader away. Hard cutover: the library reads `.arrow` only
# from the moment the code flips, so run this immediately after, in one sitting,
# on the machine that owns the cron.
#
# Reads V1 with Feather, writes Arrow, and deletes the V1 file only when row
# count, column names in order, per-column eltype AND full value equality all
# agree. On any mismatch it keeps both files, records the failure and exits
# non-zero.
#
# `_retired/` and `_inputs/` are skipped deliberately — a historical record does
# not need the current format (see RETIRED_ARCHIVE_TYPES).
#
# Delete this script, and the Feather dependency, once the archive is converted.
#
# Run:  julia --project scripts/migrate_archive_arrow.jl [--dry-run]
# ---------------------------------------------------------------------------

using Velogames
using DataFrames
using Arrow
using Feather
using Printf

const DRY_RUN = "--dry-run" in ARGS
const SKIP_TREES = ("_retired", "_inputs")

archive_root() = Velogames.archive_dir()

"""
Every `.feather` file under the archive, excluding the retired and raw-input
trees. Counted dynamically rather than asserted against a number — the archive
has grown twice while this migration was being written.
"""
function feather_files(root::String)
    out = String[]
    for entry in sort(readdir(root))
        entry in SKIP_TREES && continue
        startswith(entry, ".") && continue
        p = joinpath(root, entry)
        isdir(p) || continue
        for (dir, _, files) in walkdir(p), f in sort(files)
            endswith(f, ".feather") && push!(out, joinpath(dir, f))
        end
    end
    return out
end

"""
Convert one file. Returns `(ok, note)`; `ok == false` leaves both files on disk.
"""
function convert_file(src::String)
    dest = replace(src, r"\.feather$" => ".arrow")

    original = DataFrame(Feather.read(src))
    DRY_RUN && return (true, "would write $(nrow(original))×$(ncol(original))")

    Arrow.write(dest, original)
    roundtripped = DataFrame(Arrow.Table(dest); copycols = true)

    nrow(original) == nrow(roundtripped) ||
        return (false, "row count $(nrow(original)) → $(nrow(roundtripped))")
    names(original) == names(roundtripped) ||
        return (false, "column names differ")

    for c in names(original)
        eltype(original[!, c]) == eltype(roundtripped[!, c]) ||
            return (
                false,
                "$c eltype $(eltype(original[!, c])) → $(eltype(roundtripped[!, c]))",
            )
        isequal(original[!, c], roundtripped[!, c]) || return (false, "$c values differ")
    end

    rm(src)
    return (true, "$(nrow(original))×$(ncol(original))")
end

function main()
    root = archive_root()
    isdir(root) || error("No archive at $root")

    files = feather_files(root)
    println("Archive: $root")
    println("Feather files to convert: $(length(files))")
    DRY_RUN && println("(dry run — nothing will be written or deleted)")
    println()

    before_rows = Dict{String,Int}()
    before_files = Dict{String,Int}()
    for f in files
        t = relpath(f, root) |> splitpath |> first
        before_files[t] = get(before_files, t, 0) + 1
        before_rows[t] = get(before_rows, t, 0) + nrow(DataFrame(Feather.read(f)))
    end

    failures = Tuple{String,String}[]
    converted = 0
    for f in files
        ok, note = convert_file(f)
        if ok
            converted += 1
        else
            push!(failures, (relpath(f, root), note))
            @warn "MISMATCH, keeping both files" file = relpath(f, root) note
        end
    end

    println("Converted: $converted / $(length(files))")
    DRY_RUN && return 0

    # Final pass: the archive should now hold the same rows in the new format
    # and no stray V1 files outside the skipped trees.
    after_rows = Dict{String,Int}()
    after_files = Dict{String,Int}()
    leftover = String[]
    for entry in sort(readdir(root))
        entry in SKIP_TREES && continue
        startswith(entry, ".") && continue
        p = joinpath(root, entry)
        isdir(p) || continue
        for (dir, _, fs) in walkdir(p), f in fs
            if endswith(f, ".arrow")
                after_files[entry] = get(after_files, entry, 0) + 1
                after_rows[entry] =
                    get(after_rows, entry, 0) +
                    nrow(DataFrame(Arrow.Table(joinpath(dir, f)); copycols = true))
            elseif endswith(f, ".feather")
                push!(leftover, relpath(joinpath(dir, f), root))
            end
        end
    end

    println()
    @printf("%-28s %8s %8s %10s %10s\n", "TYPE", "files/b", "files/a", "rows/b", "rows/a")
    total_before = total_after = 0
    for t in sort(collect(union(keys(before_files), keys(after_files))))
        fb, fa = get(before_files, t, 0), get(after_files, t, 0)
        rb, ra = get(before_rows, t, 0), get(after_rows, t, 0)
        total_before += rb
        total_after += ra
        flag = (fb == fa && rb == ra) ? "" : "  <-- CHECK"
        @printf("%-28s %8d %8d %10d %10d%s\n", t, fb, fa, rb, ra, flag)
    end
    @printf("%-28s %8d %8d %10d %10d\n", "TOTAL", length(files), converted,
            total_before, total_after)

    println()
    if !isempty(leftover)
        println("Stray .feather files remaining ($(length(leftover))):")
        foreach(f -> println("  ", f), leftover)
    end
    if !isempty(failures)
        println("FAILURES ($(length(failures))):")
        foreach(((f, n),) -> println("  ", f, " — ", n), failures)
        return 1
    end
    if total_before != total_after
        println("ROW TOTAL MISMATCH: $total_before → $total_after")
        return 1
    end

    println("All $converted files converted and verified. Row totals unchanged.")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
