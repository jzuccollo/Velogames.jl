"""
One record per pipeline phase run, so "why didn't Hamburg publish?" is a question
the archive can answer.

Before Phase 2 the only trace a publish left was launchd's log file, in a clone,
on one machine, rotated by nobody. Archival was a side effect of rendering, so
even that log could not distinguish "the ingest ran and Velogames had nothing"
from "the ingest never ran" — the two look identical from the outside and have
opposite remedies.

**One file per run, not one appended file per month.** The design note asked for
`_runs/{YYYY-MM}.arrow`. A single monthly file is read-modify-write, and the two
writers are separate processes in separate clones holding different locks — the
same shape WP6 named as the reason `append_league_winners` needed
`.velogames-publish.lock`, except that here no lock is shared. Dropbox has no
locking either, so a monthly file would also be the one file in the archive
guaranteed to be edited from two machines on the same day. Unique filenames make
the conflict unrepresentable, and a reader that wants the month concatenates the
directory — which is how `league/raw` already works, for the same reason.
"""

const RUN_LOG_TREE = "_runs"

"""
    RunRecord

What one phase of one pipeline run did. `status` is `"ok"`, `"partial"` or
`"failed"`; `detail` is a human sentence, and `items` the slugs it touched.
"""
struct RunRecord
    run_id::String
    phase::String
    started_at::DateTime
    finished_at::DateTime
    status::String
    host::String
    items::Vector{String}
    detail::String
end

"""
A run identifier shared by every phase of one publish.

`auto_publish.sh` exports `VELOGAMES_RUN_ID` so its five phases — three Julia
processes, a shell step and a deploy — land in the log under one id and can be
read back as one publish. Without it each process would invent its own, and
"why didn't Hamburg publish?" would mean correlating on timestamps.

The `\\T` escapes the literal separator, which Dates would otherwise read as a
format code.
"""
function new_run_id()
    env = get(ENV, "VELOGAMES_RUN_ID", "")
    isempty(env) || return env
    return Dates.format(Dates.now(UTC), "yyyymmdd\\THHMMSS") *
           "-" *
           string(rand(UInt16), base = 16, pad = 4)
end

run_log_dir(month::Date = Dates.today(); archive_dir::String = archive_dir()) =
    joinpath(archive_dir, RUN_LOG_TREE, Dates.format(month, "yyyy-mm"))

"""
    write_run_record(r; archive_dir) -> String

Append one run record to `_runs/{YYYY-MM}/`. Returns the path written.

Failures here are warnings: a run log that cannot be written must not take down
the publish it is describing. That is the whole point of it being a log.
"""
function write_run_record(r::RunRecord; archive_dir::String = archive_dir())
    dir = run_log_dir(Date(r.started_at); archive_dir = archive_dir)
    path = joinpath(dir, "$(r.run_id)-$(r.phase).json")
    try
        mkpath(dir)
        payload = Dict(
            "run_id" => r.run_id,
            "phase" => r.phase,
            "started_at" => Dates.format(r.started_at, "yyyy-mm-ddTHH:MM:SS"),
            "finished_at" => Dates.format(r.finished_at, "yyyy-mm-ddTHH:MM:SS"),
            "status" => r.status,
            "host" => r.host,
            "items" => r.items,
            "detail" => r.detail,
        )
        # `atomic_write` hands the block a temporary path, not an IO.
        atomic_write(path) do tmp
            open(tmp, "w") do io
                JSON3.pretty(io, payload)
            end
        end
    catch e
        @warn "Could not write the run log record for $(r.phase) — the phase itself is unaffected" exception = e
        return ""
    end
    return path
end

"""
    record_run(f, phase; items, archive_dir) -> the value `f` returns

Run `f`, time it, and log the outcome. `f` returns `(status, detail)` or a bare
detail string, which is logged as `"ok"`. An exception is logged as `"failed"`
and rethrown — the log records what happened, it does not decide what happens.
"""
function record_run(
    f::Function,
    phase::AbstractString;
    run_id::AbstractString = new_run_id(),
    items::Vector{String} = String[],
    archive_dir::String = archive_dir(),
)
    started = Dates.now(UTC)
    host = gethostname()
    try
        out = f()
        status, detail = out isa Tuple ? (String(out[1]), String(out[2])) : ("ok", string(out))
        write_run_record(
            RunRecord(run_id, String(phase), started, Dates.now(UTC), status, host, items, detail);
            archive_dir = archive_dir,
        )
        return out
    catch e
        write_run_record(
            RunRecord(
                run_id,
                String(phase),
                started,
                Dates.now(UTC),
                "failed",
                host,
                items,
                sprint(showerror, e),
            );
            archive_dir = archive_dir,
        )
        rethrow()
    end
end

"""
    read_run_log(; months, archive_dir) -> DataFrame

Every run record for the given months, newest first. `months` defaults to this
month and last.
"""
function read_run_log(;
    months::Vector{Date} = [Dates.today(), Dates.today() - Dates.Month(1)],
    archive_dir::String = archive_dir(),
)
    rows = NamedTuple[]
    for m in months
        dir = run_log_dir(m; archive_dir = archive_dir)
        isdir(dir) || continue
        for f in readdir(dir)
            endswith(f, ".json") && !startswith(f, ".") || continue
            try
                d = JSON3.read(read(joinpath(dir, f), String))
                push!(
                    rows,
                    (
                        run_id = String(d.run_id),
                        phase = String(d.phase),
                        started_at = String(d.started_at),
                        finished_at = String(d.finished_at),
                        status = String(d.status),
                        host = String(d.host),
                        items = join(String.(d.items), " "),
                        detail = String(d.detail),
                    ),
                )
            catch e
                @warn "Skipping unreadable run log record $f" exception = e
            end
        end
    end
    isempty(rows) && return DataFrame(
        run_id = String[],
        phase = String[],
        started_at = String[],
        finished_at = String[],
        status = String[],
        host = String[],
        items = String[],
        detail = String[],
    )
    return sort!(DataFrame(rows), :started_at, rev = true)
end
