# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

"""
    _try_archive(df, data_type, slug, year)

Best-effort archival: persist `df` under `data_type` but never throw — a failed
snapshot must not abort a prediction run. Warns on failure.
"""
function _try_archive(df, data_type::AbstractString, slug::AbstractString, year::Integer)
    try
        save_race_snapshot(df, data_type, slug, year)
    catch e
        @warn "Failed to archive $data_type: $e"
    end
    return nothing
end

"""
    StageResult

Bundle of outputs from `solve_stage`. Fields:
- `predicted` — full per-rider prediction DataFrame
- `chosenteam` — riders in the optimal team (`top_teams[1]`)
- `top_teams` — the `n_alternatives` best distinct near-optimal teams, ranked
  best-first (k-best enumeration via no-good cuts on risk-adjusted EVG)
- `sim_vg_points` — `n_riders × n_resamples` matrix of simulated VG points
- `diagnostics` — per-stage / per-classification position counters from
  `simulate_stage_race` (only set on the per-stage pipeline; `nothing` on
  the aggregate fallback)
"""
struct StageResult
    predicted::DataFrame
    chosenteam::DataFrame
    top_teams::Vector{DataFrame}
    sim_vg_points::Matrix{Float64}
    diagnostics::Union{StageRaceDiagnostics,Nothing}
end

"""Extract the chosen team (highest selection_frequency riders) and mark all riders."""
function _extract_chosen_team!(predicted::DataFrame, top_teams::Vector{DataFrame})
    if isempty(top_teams)
        predicted[!, :chosen] .= false
        return predicted, DataFrame()
    end
    best_team = top_teams[1]
    best_keys = Set(best_team.riderkey)
    predicted[!, :chosen] = [k in best_keys for k in predicted.riderkey]
    chosenteam = filter(:chosen => ==(true), predicted)

    total_cost = sum(chosenteam.cost)
    total_evg = sum(chosenteam.expected_vg_points)
    @info "Selected $(nrow(chosenteam)) riders | Cost: $total_cost | Expected VG points: $(round(total_evg, digits=1))"

    return predicted, chosenteam
end

"""Return true if the race has already happened (so its archive should be protected).

Dates come from `resolve_race_date`, which covers the classics schedule and the
grand tours. The previous lookup was `find_race(config.name)`, which searches
`CLASSICS_RACES_2026` alone: every stage race resolved to `nothing`, fell to the
"unknown date — protect by default" branch, and was treated as already run. So a
grand tour's prediction archive was write-once — the first render of a season
kept its snapshot for ever, and every later pre-race re-run (fresh odds, a model
fix, a corrected startlist) was declined with a warning. Prospective evaluation
then scored a prediction the model no longer makes.
"""
function _race_has_happened(config::RaceConfig)
    today = Dates.today()
    config.year < Dates.year(today) && return true
    config.year > Dates.year(today) && return false
    date = resolve_race_date(config.pcs_slug, config.year)
    date === nothing && return true  # unknown date — protect by default
    return date < today
end

"""Archive the predicted DataFrame for prospective evaluation."""
function _archive_predictions(predicted::DataFrame, config::RaceConfig)
    isempty(config.pcs_slug) && return
    # Protect post-race archives from being clobbered (preserves the pre-race
    # snapshot used for prospective evaluation). Pre-race re-runs always overwrite.
    # Set VELOGAMES_FORCE_ARCHIVE=1 to override the post-race protection.
    if _race_has_happened(config)
        existing = load_race_snapshot("predictions", config.pcs_slug, config.year)
        if existing !== nothing && get(ENV, "VELOGAMES_FORCE_ARCHIVE", "") != "1"
            @warn "Race date has passed and prediction archive exists for $(config.pcs_slug) $(config.year) — skipping to preserve pre-race snapshot. Set VELOGAMES_FORCE_ARCHIVE=1 to overwrite."
            return
        end
    end

    # `save_race_snapshot` checks the mandatory columns too, but it is reached
    # through a `try` here, so the error would become a warning and the run would
    # carry on having archived nothing. Check before the allowlist trims the frame.
    missing_cols = missing_mandatory_columns("predictions", predicted)
    isempty(missing_cols) || error(
        "_archive_predictions: predicted DataFrame is missing mandatory columns $missing_cols — refusing to write an incomplete prediction archive",
    )

    # union with the mandatory set so a future mandatory column can never pass
    # the check above yet be silently dropped by this allowlist.
    cols = intersect(
        propertynames(predicted),
        union(
            ARCHIVE_TYPES["predictions"].mandatory,
            [
                :riderkey,
                :rider,
                :team,
                :cost,
                :strength,
                :uncertainty,
                :shift_pcs,
                :shift_vg,
                :shift_history,
                :shift_vg_history,
                :shift_oracle,
                :shift_oracle_points,
                :shift_oracle_kom,
                :shift_odds,
                :info_share_pcs,
                :info_share_vg,
                :info_share_history,
                :info_share_vg_history,
                :info_share_points_history,
                :info_share_kom_history,
                :info_share_oracle,
                :info_share_oracle_gc,
                :info_share_oracle_points,
                :info_share_oracle_kom,
                :info_share_odds,
                :info_share_odds_points,
                :info_share_odds_kom,
                :info_share_odds_stagewin,
                :strength_flat,
                :strength_hilly,
                :strength_mountain,
                :strength_itt,
                :strength_gc,
                :strength_kom,
                :uncertainty_flat,
                :uncertainty_hilly,
                :uncertainty_mountain,
                :uncertainty_itt,
                :uncertainty_gc,
                :uncertainty_kom,
                :expected_vg_points,
                :market_blend_points,
                :selection_frequency,
                :chosen,
            ],
        ),
    )
    out = predicted[:, cols]
    try
        save_race_snapshot(out, "predictions", config.pcs_slug, config.year)
    catch e
        @warn "Failed to archive predictions: $e"
    end
end

"""
    _load_breakaway_rates(breakaway_dir, riderkeys; as_of, spec) -> (rates, sectors)

Per-rider breakaway probability and expected sector count for the simulation.

Prefers the per-race archive, which carries a dated `in_breakaway` /
`breakaway_km` for every archived one-day result since the September 2026
backfill. Falls back to the old hand-saved season leaderboard in
`breakaway_dir` when `as_of` is unknown or the archive has nothing to say.

The archive path is the one that can be reconstructed as of a past date, which
is what lets the backtest evaluate this channel at all — the season totals
cannot, and `champion_oneday_evg` documented the channel as inert because of it.

`spec` is the tunable half, passed through to
`compute_breakaway_rates_archive`: `prior_strength`, `km_weighted`,
`decay_rate`, `history_years`.
"""
function _load_breakaway_rates(
    breakaway_dir::String,
    riderkeys::AbstractVector;
    as_of::Union{Date,Nothing} = nothing,
    spec::NamedTuple = NamedTuple(),
    archive_dir::String = archive_dir(),
)
    if as_of !== nothing
        try
            rates, sectors = compute_breakaway_rates_archive(
                String.(riderkeys);
                as_of = as_of,
                archive_dir = archive_dir,
                spec...,
            )
            if any(>(0.0), rates)
                @info "Breakaway rates from the archive as of $as_of " *
                      "(mean $(round(mean(rates), digits = 3)), " *
                      "mean sectors $(round(mean(sectors), digits = 2)))"
                return rates, sectors
            end
        catch e
            @warn "Archive breakaway rates failed; falling back to $breakaway_dir" exception =
                e
        end
    end
    isempty(breakaway_dir) && return Float64[], Float64[]
    !isdir(breakaway_dir) && return Float64[], Float64[]
    try
        breakaway_df = load_pcs_breakaway_stats(breakaway_dir)
        rates, sectors = compute_breakaway_rates(breakaway_df, String.(riderkeys))
        n_matched = count(>(0.0), rates)
        @info "Breakaway data (season leaderboard): $n_matched/$(length(riderkeys)) riders matched"
        return rates, sectors
    catch e
        @warn "Failed to load breakaway data: $e"
        return Float64[], Float64[]
    end
end

"""
    archive_race_results(race_name, year; cache_config, force_refresh)

Fetch and archive actual PCS results and VG results for a completed race.
Stage races archive their GC under `pcs_gc_results`; one-day races archive
their finishing order under `pcs_results`.

**Skips whatever is already archived** unless `force_refresh` is set. It used to
re-fetch and overwrite on every call, which is the wrong default for a file in a
shared, Dropbox-synced archive with no locking: a transient scrape failure or a
rate-limited PCS page would replace a good snapshot with a worse one, and a
re-run during a live race would race whoever else is writing. Velogames does
revise scores for about 24 hours after a race, which is the case for overwriting
— `force_refresh` is how to ask for it, deliberately.
"""
function archive_race_results(
    pcs_slug::String,
    year::Int;
    vg_race_number::Int = 0,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    # Archive PCS race results. A stage race's result is its general
    # classification, and `/result` returns the final stage's sprint instead —
    # so it goes to `pcs_gc_results` via `prefer_gc`, on the same four-column
    # projection `archive_stage_race_results` writes. Writing a stage race's
    # final-stage order under `pcs_results` would put a frame the race-history
    # path reads as a GC one page away from the page it means.
    if race_format(pcs_slug) == :stage
        if force_refresh || load_race_snapshot("pcs_gc_results", pcs_slug, year) === nothing
            try
                gc = getpcs_race_results(
                    pcs_slug,
                    year;
                    prefer_gc = true,
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
                if nrow(gc) > 0
                    save_race_snapshot(
                        gc[:, [:position, :rider, :team, :riderkey]],
                        "pcs_gc_results",
                        pcs_slug,
                        year,
                    )
                end
            catch e
                @warn "Failed to archive PCS GC results for $pcs_slug $year: $e"
            end
        end
    elseif force_refresh || load_race_snapshot("pcs_results", pcs_slug, year) === nothing
        try
            pcs_results = getpcs_race_results(
                pcs_slug,
                year;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(pcs_results) > 0
                save_race_snapshot(pcs_results, "pcs_results", pcs_slug, year)
            end
        catch e
            @warn "Failed to archive PCS results for $pcs_slug $year: $e"
        end
    end

    # Archive VG race results. Stage races (grand tours / week-long races) run
    # their own separate VG competition from the one-day classics — fetching
    # via `getvg_race_results` (which always hits the classics competition
    # URL) would silently archive an unrelated one-day race's scores under
    # this stage race's pcs_slug. Route stage races to `getvg_stage_race_totals`
    # with the correct VG slug instead; `vg_race_number` is a one-day-only
    # concept (the classics `st` parameter) and is ignored for stage races.
    vg_slug = get(_STAGE_RACE_VG_SLUGS, pcs_slug, "")
    if force_refresh || load_race_snapshot("vg_results", pcs_slug, year) === nothing
        try
            vg_results = if !isempty(vg_slug)
                getvg_stage_race_totals(
                    year,
                    vg_slug;
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
            elseif vg_race_number > 0
                getvg_race_results(
                    year,
                    vg_race_number;
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
            else
                nothing
            end
            if vg_results !== nothing && nrow(vg_results) > 0
                save_race_snapshot(vg_results, "vg_results", pcs_slug, year)
            end
        catch e
            @warn "Failed to archive VG results for $pcs_slug $year: $e"
        end
    end
end

# ---------------------------------------------------------------------------
# Shared data preparation
# ---------------------------------------------------------------------------

"""
    _prepare_rider_data(config, racehash, excluded_riders, history_years,
                        oracle_url, min_riders, cache_config,
                        force_refresh; pcs_check_col=:oneday,
                        filter_startlist=true)

Shared data-fetching pipeline for `solve_oneday` and `solve_stage`.

Fetches VG riders, filters by startlist hash and exclusions, optionally filters
against PCS confirmed startlist, joins PCS specialty ratings, fetches race history
(including similar races), VG historical race points, odds, and Cycling Oracle
predictions, and logs a data quality summary. Odds come from a pre-parsed
DataFrame (e.g. Oddschecker paste) passed via the `odds_df` keyword.

Returns a `RaceData` struct or `nothing` if fewer than `min_riders` remain
after filtering.
"""
# Recency-weight all five PCS specialties. For each rider and specialty, fetch
# per-season points and collapse to a decay-weighted sum (recent seasons
# dominate) using the default `pcs_season_decay`. Adds `:<spec>_r` columns
# consumed by the multidim z-scoring. Riders with no PCS profile / no specialty
# results are left `missing` (NOT 0), so the z-scoring falls back to their
# career specialty per-rider rather than reading a spurious zero. Returns the
# raw per-season data in long format (riderkey, specialty, year, points) so the
# caller can archive it for backtest temporal integrity. Logs coverage so a
# scrape regression is visible.
function _apply_pcs_recency!(
    riderdf::DataFrame,
    pcs_slug_map::Dict{String,String},
    current_year::Int;
    specialties = (:climber, :gc, :tt, :sprint, :oneday),
    decay::Float64 = DEFAULT_BAYESIAN_CONFIG.pcs_season_decay,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    n = nrow(riderdf)
    seasons_long = DataFrame(
        riderkey = String[],
        specialty = String[],
        year = Int[],
        points = Float64[],
    )
    for spec in specialties
        # `missing` (not 0.0) for riders whose scrape returned nothing, so the
        # z-scoring downstream can fall back to career × currency per-rider
        # rather than reading a spurious zero. A field-wide scrape regression
        # then degrades gracefully to career data instead of zeroing the whole
        # specialty dimension.
        scores = Vector{Union{Missing,Float64}}(missing, n)
        covered = 0
        for i = 1:n
            key = riderdf.riderkey[i]
            slug = get(pcs_slug_map, key, "")
            if isempty(slug)
                slug = get(
                    PCS_SLUG_OVERRIDES,
                    normalisename(riderdf.rider[i]),
                    normalisename(riderdf.rider[i]),
                )
            end
            df = try
                getpcs_specialty_by_season(
                    slug,
                    spec;
                    cache_config = cache_config,
                    force_refresh = force_refresh,
                )
            catch e
                # A block found for one rider will be found for the rest too —
                # propagate rather than silently reading it as "no per-season
                # data for this rider" and quietly working through the field.
                e isa ScrapeBlockedError && rethrow()
                DataFrame(year = Int[], points = Float64[])
            end
            # A cached "no data for this rider/specialty" result can come back
            # as a columnless DataFrame rather than raising — treat the same
            # as the catch-block fallback above (no data, skip this rider).
            hasproperty(df, :year) || continue
            # Only seasons up to the race year. A per-season page can carry
            # post-race results (re-run after the race, or a stale current_year);
            # a year > current_year would also flip the decay weight above 1 and
            # let a future season dominate. Filtering here also keeps the
            # archived long-format seasons temporally clean for backtests.
            keep = df.year .<= current_year
            any(keep) || continue
            yrs = df.year[keep]
            pts = df.points[keep]
            w = exp.(-decay .* (current_year .- yrs))
            scores[i] = sum(w .* pts)
            covered += 1
            for (yr, p) in zip(yrs, pts)
                push!(seasons_long, (key, String(spec), yr, p))
            end
        end
        riderdf[!, Symbol(spec, "_r")] = scores
        if covered < n ÷ 2
            @warn "PCS recency ($spec): only $covered/$n riders with per-season " *
                  "points — check PCS slugs / scrape (falling back to career points)"
        else
            @info "PCS recency ($spec): $covered/$n riders with per-season points"
        end
    end
    return seasons_long
end

"""
    _archived_races_before(data_type, pcs_slug, year) -> Vector{Tuple{String,Int}}

Every archived `(slug, year)` of `data_type` other than this race's own, dated
on or before this race, newest first. The candidate list the cross-race tier of
an archive-first loader walks.

Two rules are doing work here. A candidate dated *after* the target is skipped:
re-rendering or backfilling an earlier race once later races are archived must
not leak a future rating into the past, which is the whole reason these types
are `refetchable = false`. And the whole list is empty when *this* race's date
cannot be resolved — with no bound to draw, running the tier unbounded would
make every archived file eligible, including later ones. That costs coverage
on races outside the catalogue; the live tier still runs for them.

Ordering is on the resolved date, not the year. Ordering on year alone leaves
the within-season tie to `archive_races`' alphabetical directory order, so
rendering an August race would take `amstel-gold-race` (April) ahead of
`cyclassics-hamburg` three weeks earlier — the opposite of the freshness
argument the tier rests on.
"""
function _archived_races_before(data_type::String, pcs_slug::String, year::Int)
    target_date = resolve_race_date(pcs_slug, year)
    target_date === nothing && return Tuple{String,Int}[]
    pairs = Tuple{String,Int,Date}[]
    for slug in archive_races(data_type)
        for yr in archive_years(data_type, slug)
            (slug == pcs_slug && yr == year) && continue
            cand_date = resolve_race_date(slug, yr)
            (cand_date === nothing || cand_date > target_date) && continue
            push!(pairs, (slug, yr, cand_date))
        end
    end
    sort!(pairs, by = p -> p[3], rev = true)
    return [(p[1], p[2]) for p in pairs]
end

"""
    _load_pcs_specialty(pcs_slug, year, riderdf; slug_map, cache_config, force_refresh)
        -> (DataFrame, NamedTuple)

Resolve PCS specialty ratings for every rider in `riderdf` (columns
`:riderkey`, `:rider`), archive-first in three steps, cheapest and most
temporally faithful first:

1. this race's own archived `pcs_specialty` snapshot for `(pcs_slug, year)`;
2. for riders still uncovered, the union across every *other* archived
   `pcs_specialty` file dated on or before this race, most recent race first —
   specialty ratings are season-cumulative and move slowly, so a rating from
   a recent race is a close read on race day (see
   `docs/pcs-cloudflare-block-evaluation.md`). A candidate dated after this
   race — or whose own date can't be resolved — is skipped: re-rendering or
   backfilling an earlier race after later races have been archived must not
   leak a future rating into the past. The whole tier is skipped when *this*
   race's date can't be resolved, since there is then no bound to apply;
3. for whoever is still uncovered, a live fetch (`getpcs_rider_pts_batch`),
   which now raises `ScrapeBlockedError` rather than degrading silently when
   PCS is actually blocking the run.

A rider only counts as covered by a tier if at least one specialty column in
that tier's row is a real (non-missing) value — a hollow row (riderkey
present, every rating missing, exactly what a blocked-but-not-erroring fetch
used to produce) does not block the later tiers from healing that rider.

`force_refresh` skips both archive steps and live-fetches everyone, matching
every other fetcher's escape hatch.

Returns `(specialty_df, provenance)` where `specialty_df` has the same
columns as `getpcs_rider_pts_batch`'s output (`riderkey, rider, oneday, gc,
tt, sprint, climber`) plus an internal `:_source` column (`:own`, `:cross` or
`:live`) recording which tier each row came from — see
`_archivable_pcs_specialty`, which uses it to keep cross-race rows out of
this race's own archive file. `provenance` is a `(own_race, cross_race,
live_fetched)` NamedTuple of rider counts, used for the data-quality log.
"""
function _load_pcs_specialty(
    pcs_slug::String,
    year::Int,
    riderdf::DataFrame;
    slug_map::Dict{String,String} = Dict{String,String}(),
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    # `hills` rides along in the projection but is not a `rating_col`: coverage
    # is still judged on the five ratings every archive has, so a pre-2026 file
    # is as good a tier-2 donor as it ever was. The `vcat(...; cols = :union)`
    # below is what lets layers with and without it combine.
    spec_cols = ["riderkey", "rider", "oneday", "gc", "tt", "sprint", "climber", "hills"]
    rating_cols = ["oneday", "gc", "tt", "sprint", "climber"]
    wanted = Set(String.(riderdf.riderkey))
    covered = Set{String}()
    layers = DataFrame[]

    function harvest!(df::Union{DataFrame,Nothing}, source::Symbol)
        df === nothing && return 0
        present_ratings = intersect(names(df), rating_cols)
        has_rating(row) =
            !isempty(present_ratings) && any(!ismissing(row[c]) for c in present_ratings)
        new_rows = filter(
            r -> r.riderkey in wanted && !(r.riderkey in covered) && has_rating(r),
            df,
        )
        isempty(new_rows) && return 0
        layer = new_rows[:, intersect(names(new_rows), spec_cols)]
        layer[!, :_source] .= source
        push!(layers, layer)
        for k in new_rows.riderkey
            push!(covered, k)
        end
        return nrow(new_rows)
    end

    # --- 1. This race's own archived snapshot ---
    n_own =
        force_refresh ? 0 :
        harvest!(load_race_snapshot("pcs_specialty", pcs_slug, year), :own)

    # --- 2. Union across every other archived race, newest edition first,
    #        never dated after this race ---
    n_cross = 0
    if !force_refresh && length(covered) < length(wanted)
        for (slug, yr) in _archived_races_before("pcs_specialty", pcs_slug, year)
            length(covered) >= length(wanted) && break
            n_cross += harvest!(load_race_snapshot("pcs_specialty", slug, yr), :cross)
        end
    end

    # --- 3. Live fetch for whoever is still uncovered ---
    # The tier that is allowed to fail. A block here must cost only the riders
    # the archive could not cover — throwing would discard every row tiers 1
    # and 2 just harvested, which is the whole point of doing them first. The
    # caller still hears about it: this warns, and the coverage counts it
    # returns show the live tier contributed nothing.
    n_live = 0
    remaining = filter(r -> !(r.riderkey in covered), riderdf)
    if nrow(remaining) > 0
        try
            live = getpcs_rider_pts_batch(
                String.(remaining.rider);
                slug_map = slug_map,
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            n_live = harvest!(live, :live)
        catch e
            e isa ScrapeBlockedError || rethrow()
            @warn "PCS blocked the specialty fetch for the $(nrow(remaining)) riders " *
                  "the archive could not cover — keeping the $(length(covered)) it did" exception =
                e
        end
    end

    specialty_df = if isempty(layers)
        DataFrame(
            riderkey = String[],
            rider = String[],
            oneday = Union{Int,Missing}[],
            gc = Union{Int,Missing}[],
            tt = Union{Int,Missing}[],
            sprint = Union{Int,Missing}[],
            climber = Union{Int,Missing}[],
            _source = Symbol[],
        )
    else
        vcat(layers...; cols = :union)
    end

    return specialty_df, (own_race = n_own, cross_race = n_cross, live_fetched = n_live)
end

"""
    _archivable_pcs_specialty(specialty_df) -> DataFrame

The subset of `_load_pcs_specialty`'s blended output that was genuinely
sourced for THIS race — own-race archive hit or live fetch — with the
internal `:_source` provenance column dropped, ready to write under the
race's own `pcs_specialty` archive key.

Excludes cross-race-sourced rows (tier 2) deliberately: `pcs_specialty` is
`refetchable = false` specifically because it means "what PCS said on this
race's day", and persisting a rating pulled from another race's archive
under this race's key would corrupt that guarantee for a later render's own
cross-race lookup, which would then treat the contaminated file as
trustworthy own-race data.
"""
function _archivable_pcs_specialty(specialty_df::DataFrame)
    :_source in propertynames(specialty_df) || return specialty_df
    archivable = filter(:_source => !=(:cross), specialty_df)
    select!(archivable, Not(:_source))
    return archivable
end

"""
    _load_pcs_seasons(pcs_slug, year, riderdf; slug_map, cache_config,
        force_refresh) -> (DataFrame, NamedTuple)

Per-season PCS points and rank for this race's field, resolved archive-first in
the same three tiers as `_load_pcs_specialty`: this race's own `pcs_seasons`
snapshot, then the union across every other archived race dated on or before
this one (newest first), then a live fetch for whoever is left.

This was the last full-field PCS fetch in a render, and after the specialty
loader went archive-first it became the dominant one by an order of magnitude:
on Quebec the specialty tier reached the network for 9 riders while this one
still asked for all 153, on the very same profile pages. The archive already
held 151 `pcs_seasons` files.

A rider counts as covered once any tier yields at least one season row with a
real `pcs_points` value, so a hollow row — riderkey present, points missing,
what a blocked-but-not-erroring fetch produces — does not block the later
tiers from healing them.

The staleness this admits is the same shape as the specialty loader's and is
acceptable for the same reason: prior seasons are closed and never move, and
only the current year's row grows through the season, so a file from a race a
few weeks earlier understates the current year slightly and is exact on every
other. `force_refresh` skips both archive tiers.

Returns `(seasons_df, provenance)` with `getpcs_rider_seasons_batch`'s columns
(`riderkey, year, pcs_points, pcs_rank`) plus the internal `:_source` tier
marker that `_archivable_pcs_seasons` uses to keep cross-race rows out of this
race's own file.
"""
function _load_pcs_seasons(
    pcs_slug::String,
    year::Int,
    riderdf::DataFrame;
    slug_map::Dict{String,String} = Dict{String,String}(),
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    season_cols = ["riderkey", "year", "pcs_points", "pcs_rank"]
    wanted = Set(String.(riderdf.riderkey))
    covered = Set{String}()
    layers = DataFrame[]

    function harvest!(df::Union{DataFrame,Nothing}, source::Symbol)
        df === nothing && return 0
        "pcs_points" in names(df) || return 0
        new_rows = filter(
            r ->
                r.riderkey in wanted &&
                    !(r.riderkey in covered) &&
                    !ismissing(r.pcs_points),
            df,
        )
        isempty(new_rows) && return 0
        layer = new_rows[:, intersect(names(new_rows), season_cols)]
        layer[!, :_source] .= source
        push!(layers, layer)
        # One rider has many season rows, so coverage is counted in riders, not
        # rows — otherwise the tier counts read as 400-odd "riders" covered.
        newly = Set(String.(new_rows.riderkey))
        union!(covered, newly)
        return length(newly)
    end

    n_own =
        force_refresh ? 0 :
        harvest!(load_race_snapshot("pcs_seasons", pcs_slug, year), :own)

    n_cross = 0
    if !force_refresh && length(covered) < length(wanted)
        for (slug, yr) in _archived_races_before("pcs_seasons", pcs_slug, year)
            length(covered) >= length(wanted) && break
            n_cross += harvest!(load_race_snapshot("pcs_seasons", slug, yr), :cross)
        end
    end

    # The tier allowed to fail, for the same reason as the specialty loader's:
    # a block must cost only the riders the archive could not cover.
    n_live = 0
    remaining = filter(k -> !(k in covered), collect(keys(slug_map)))
    if !isempty(remaining)
        try
            live = getpcs_rider_seasons_batch(
                Dict(k => slug_map[k] for k in remaining);
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            n_live = harvest!(live, :live)
        catch e
            e isa ScrapeBlockedError || rethrow()
            @warn "PCS blocked the seasons fetch for the $(length(remaining)) riders " *
                  "the archive could not cover — keeping the $(length(covered)) it did" exception =
                e
        end
    end

    seasons_df = if isempty(layers)
        DataFrame(
            riderkey = String[],
            year = Int[],
            pcs_points = Float64[],
            pcs_rank = Int[],
            _source = Symbol[],
        )
    else
        vcat(layers...; cols = :union)
    end

    return seasons_df, (own_race = n_own, cross_race = n_cross, live_fetched = n_live)
end

"""Own-race and live-fetched season rows only — `_archivable_pcs_specialty`'s
twin, for the same reason: `pcs_seasons` is `refetchable = false` and means
"what PCS said on this race's day"."""
function _archivable_pcs_seasons(seasons_df::DataFrame)
    :_source in propertynames(seasons_df) || return seasons_df
    archivable = filter(:_source => !=(:cross), seasons_df)
    select!(archivable, Not(:_source))
    return archivable
end

function _prepare_rider_data(
    config::RaceConfig,
    racehash::String,
    excluded_riders::Vector{String},
    history_years::Int,
    oracle_url::String,
    min_riders::Int,
    cache_config::CacheConfig,
    force_refresh::Bool;
    pcs_check_col::Symbol = :oneday,
    filter_startlist::Bool = true,
    include_gt_history::Bool = true,
    apply_recency::Bool = true,
    odds_df::Union{DataFrame,Nothing} = nothing,
    points_oracle_url::String = "",
    kom_oracle_url::String = "",
    points_odds_df::Union{DataFrame,Nothing} = nothing,
    kom_odds_df::Union{DataFrame,Nothing} = nothing,
    stagewin_odds_df::Union{DataFrame,Nothing} = nothing,
    use_gt_vg_history::Bool = false,
    use_gt_vg_propensity::Bool = false,
    season_round_slugs::Vector{String} = String[],
)
    # --- 1. Load the VG rider pool (archived startlist first, live pool last) ---
    riderdf = load_vg_race_pool(
        config.pcs_slug,
        config.year,
        config.current_url;
        cache_config = cache_config,
        force_refresh = force_refresh,
    )

    # Filter by startlist hash if provided
    if !isempty(racehash)
        filtered = filter(
            row -> hasproperty(row, :startlist) ? row.startlist == racehash : true,
            riderdf,
        )
        if nrow(filtered) > 0
            riderdf = filtered
            @info "Filtered to $(nrow(riderdf)) riders for startlist: $racehash"
        else
            @warn "No riders matched startlist hash '$racehash' — ignoring hash filter"
        end
    end

    # Exclude riders
    if !isempty(excluded_riders)
        before = nrow(riderdf)
        riderdf = filter(row -> !(row.rider in excluded_riders), riderdf)
        @info "Excluded $(before - nrow(riderdf)) riders"
    end

    # Filter against PCS confirmed startlist
    pcs_slug_map = Dict{String,String}()
    if filter_startlist && !isempty(config.pcs_slug)
        try
            startlist_df = getpcs_race_startlist(
                config.pcs_slug,
                config.year;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(startlist_df) > 0 && :riderkey in propertynames(startlist_df)
                # PCS and VG disagree on given names ("Tom" vs "Thomas" Pidcock),
                # and this is a hard semijoin: an unmatched key silently deletes a
                # rider from the field. Reconcile against the VG pool first, which
                # also fixes the pcs_slug map built from the same frame below.
                rematch_riderkeys!(startlist_df, riderdf)
                before = nrow(riderdf)
                riderdf = semijoin(riderdf, startlist_df[:, [:riderkey]], on = :riderkey)
                @info "Filtered to $(nrow(riderdf)) riders confirmed on PCS startlist (removed $(before - nrow(riderdf)))"

                # Build riderkey → PCS slug mapping from startlist
                if :pcs_slug in propertynames(startlist_df)
                    for row in eachrow(startlist_df)
                        if !isempty(row.pcs_slug)
                            pcs_slug_map[row.riderkey] = row.pcs_slug
                        end
                    end
                    n_slugs = length(pcs_slug_map)
                    if n_slugs > 0
                        @info "Extracted $n_slugs PCS profile slugs from startlist"
                    end
                end
            end
        catch e
            @warn "Could not fetch PCS startlist: $e — skipping startlist filter"
        end
    end

    if nrow(riderdf) < min_riders
        @warn "Not enough riders ($(nrow(riderdf))) for a $(min_riders)-rider team"
        return nothing
    end

    # Single-race VG games (the Femmes/GT format) open with `points` at zero for
    # the whole field, which z-scores to a constant and switches the VG-season
    # signal off entirely. Substitute mean points per round from the other
    # rounds of the same season-long series.
    #
    # Placed AFTER every row filter above: `fill_value` has to be the mean of the
    # frame that actually gets z-scored, or the filled riders land at a non-zero
    # z and the substitution starts saying something about them.
    if !isempty(season_round_slugs) && all(iszero, coalesce.(riderdf.points, 0.0))
        season = assemble_season_vg_points(
            config.year,
            season_round_slugs;
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
        lookup =
            season === nothing ? Dict{String,Float64}() :
            Dict(r.riderkey => r.points for r in eachrow(season))
        covered = [k in keys(lookup) for k in riderdf.riderkey]
        if !any(covered)
            @warn "Season VG points: no rider on this startlist appears in " *
                  "$(season_round_slugs) — leaving `points` at zero"
        else
            # Riders who skipped every scored round are missing data, not weak
            # ones: give them the covered-field mean so they z-score to exactly
            # 0 and leave the posterior untouched, rather than 0 points, which
            # would read as evidence of weakness.
            fill_value = mean(lookup[k] for k in riderdf.riderkey[covered])
            riderdf.points = [
                covered[i] ? lookup[riderdf.riderkey[i]] : fill_value for
                i = 1:nrow(riderdf)
            ]
            # `frac_nonzero` in `_assemble_signals` reads this when present. The
            # fill makes every rider's `points` non-zero, so counting non-zeros
            # would report full season coverage and switch off the very variance
            # widening (`vg_season_penalty`) that thin VG data calls for.
            riderdf[!, :vg_points_observed] = covered
            @info "Season VG points: filled $(count(covered))/$(nrow(riderdf)) riders " *
                  "($(round(Int, 100count(covered) / nrow(riderdf)))% covered)"
        end
    end

    # --- 2. Fetch PCS specialty ratings (archive-first: own race → cross-race
    #        union → live fetch — see _load_pcs_specialty) ---
    # Specialty scores are season-cumulative and move slowly, unlike the race
    # data `cache_config` is tuned for — reusing that short TTL means a fresh
    # 100+-rider burst against PCS on almost every render, which is what
    # tripped its Cloudflare protection for GP Industria 2026. A week-long TTL
    # cuts that burst down to roughly once a week instead of once a race.
    @info "Fetching PCS specialty ratings for $(nrow(riderdf)) riders..."
    specialty_cache_config = CacheConfig(cache_config.cache_dir, 24 * 7)
    pcsriderpts, specialty_provenance = try
        _load_pcs_specialty(
            config.pcs_slug,
            config.year,
            riderdf;
            slug_map = pcs_slug_map,
            cache_config = specialty_cache_config,
            force_refresh = force_refresh,
        )
    catch e
        # Sibling fetch steps (startlist, oracle, seasons, below) all degrade
        # the same way on failure: warn and carry on with nothing, rather than
        # crash the whole render. PCS blocking more than a handful of riders
        # raises `ScrapeBlockedError` out of the live-fetch tier — that's exactly
        # the case this is for.
        @warn "Failed to fetch PCS specialty ratings: $e — continuing with no PCS specialty data"
        DataFrame(
            riderkey = String[],
            rider = String[],
            oneday = Union{Int,Missing}[],
            gc = Union{Int,Missing}[],
            tt = Union{Int,Missing}[],
            sprint = Union{Int,Missing}[],
            climber = Union{Int,Missing}[],
            _source = Symbol[],
        ),
        (own_race = 0, cross_race = 0, live_fetched = 0)
    end
    @info "PCS specialty coverage" own_race = specialty_provenance.own_race cross_race =
        specialty_provenance.cross_race live_fetched = specialty_provenance.live_fetched

    riderdf = join_pcs_specialty(riderdf, pcsriderpts)

    # Recency-weight all five PCS specialties from per-season points, so current
    # form outweighs stale career palmarès. Adds :<spec>_r columns consumed by
    # the multidim z-scoring; returns the raw per-season data for archival. Only
    # the stage-race (multidim) path reads the :<spec>_r columns — the one-day
    # scalar path uses its own single-dimension recency source — so skip the
    # 5×N per-rider specialty fetches for one-day races.
    if apply_recency
        # `_apply_pcs_recency!` rethrows a block rather than reading it as "no
        # per-season data for this rider", which is right — but the render must
        # still finish on the career specialty ratings tiers 1 and 2 just
        # harvested, exactly as the specialty step above degrades. Letting it
        # propagate here would abort the run and throw those away.
        pcs_seasons = try
            _apply_pcs_recency!(
                riderdf,
                pcs_slug_map,
                config.year;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
        catch e
            e isa ScrapeBlockedError || rethrow()
            @warn "PCS blocked the per-season specialty fetch — continuing on career specialty ratings, without recency weighting" exception =
                e
            DataFrame()
        end

        # Archive per-season specialty points (long format) so backtests can
        # recompute recency-weighted specialty scores as-of the race date.
        if !isempty(config.pcs_slug) && nrow(pcs_seasons) > 0
            _try_archive(pcs_seasons, "pcs_specialty_seasons", config.pcs_slug, config.year)
        end
    end

    # Archive PCS specialty scores for future backtesting — own-race and
    # live-fetched rows only, never cross-race ones (see
    # `_archivable_pcs_specialty`), merged over whatever is already on disk.
    #
    # The merge is what stops this shrinking the file. `harvest!` keeps only
    # riders in the current pool, so a re-render with a narrower one — a
    # tighter `racehash`, more `excluded_riders`, a PCS startlist that lost
    # names — would otherwise overwrite a full field with a subset, and
    # `pcs_specialty` is `refetchable = false`, so those rows are gone. Both
    # sides are this race's own as-of-race-day data, so the union is the whole
    # of what was true; fresh rows win a riderkey collision, which is what
    # keeps `force_refresh` meaningful.
    if !isempty(config.pcs_slug) && nrow(pcsriderpts) > 0
        archivable_specialty = _archivable_pcs_specialty(pcsriderpts)
        if nrow(archivable_specialty) > 0
            existing =
                load_race_snapshot("pcs_specialty", config.pcs_slug, config.year)
            if existing !== nothing
                fresh = Set(archivable_specialty.riderkey)
                kept = filter(r -> !(r.riderkey in fresh), existing)
                if nrow(kept) > 0
                    archivable_specialty =
                        vcat(archivable_specialty, kept; cols = :union)
                end
            end
            _try_archive(
                archivable_specialty,
                "pcs_specialty",
                config.pcs_slug,
                config.year,
            )
        end
    end

    # --- 3. Fetch PCS race history (primary + similar + within-year) ---
    race_info = _find_race_by_slug(config.pcs_slug)
    race_date = resolve_race_date(config.pcs_slug, config.year)
    # Same reasoning as the recency step: `assemble_pcs_race_history` rethrows a
    # block found while filling in the years its archive doesn't cover, which is
    # the right call there — one blocked year means every other live year is
    # blocked too, so there is nothing to be gained by working through them. But
    # a render with no race history is a degraded render, not a failed one, and
    # the archive usually covers most years on its own.
    race_history_df = try
        assemble_pcs_race_history(
            config.pcs_slug,
            config.year,
            history_years;
            race_date = race_date,
            include_gt_history = include_gt_history,
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
    catch e
        e isa ScrapeBlockedError || rethrow()
        @warn "PCS blocked the race-history fetch — continuing without race history" exception =
            e
        nothing
    end

    # --- 3b. Fetch VG race history (automatic; one-day classics only) ---
    # Grand tours / week-long stage races have no entry in CLASSICS_RACES_2026,
    # so `race_info` is always `nothing` and `race_name` would be "". Skip
    # entirely for stage races rather than looking up VG race history under a
    # blank name — that VG competition (`sixes-classics`) is unrelated to a
    # stage race's own VG competition, and this signal is one-day-specific.
    race_name = race_info !== nothing ? race_info.name : ""
    vg_history_df = if config.type == :stage
        nothing
    else
        assemble_vg_race_history(
            race_name,
            config.pcs_slug,
            config.year,
            history_years;
            race_date = race_date,
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
    end

    # --- 3b-ii. Fetch prior-edition points/KOM classification history (stage races) ---
    # Same-race only: the July 2026 isolation backtest (recorded in roadmap.md;
    # its successor is backtest_stage_race(...; target = :points/:kom))
    # found same-race jersey history predictive (ρ≈0.33) but GT cross-history
    # harmful for jerseys (KOM no-harm Δρ −0.10) — jersey roles are parcours- and
    # team-specific and transfer poorly across grand tours, unlike GC ability.
    points_history_df = nothing
    kom_history_df = nothing
    if config.type == :stage && !isempty(config.pcs_slug)
        points_history_df = assemble_pcs_classification_history(
            config.pcs_slug,
            config.year,
            history_years,
            :points;
            race_date = race_date,
            include_gt_history = false,
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
        kom_history_df = assemble_pcs_classification_history(
            config.pcs_slug,
            config.year,
            history_years,
            :kom;
            race_date = race_date,
            include_gt_history = false,
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
    end

    # --- 3b-iii. Fetch this grand tour's own prior-edition VG totals (Option A
    # prototype, July 2026 — see roadmap.md "GT VG-history strength signal").
    # A rider's own prior GT VG success is a role-conditional (lower-bias) proxy
    # for their GT VG points than their role-blind general ability is. Gated by
    # `use_gt_vg_history` (default off ⇒ nothing ⇒ signal inert), stage races only.
    # Also fetched for the Option B points-propensity layer (`use_gt_vg_propensity`),
    # which learns a role factor from the same prior-edition totals but applies it
    # at the EVG level rather than as a strength nudge (see roadmap.md Option B).
    gt_vg_history_df = nothing
    if (use_gt_vg_history || use_gt_vg_propensity) && config.type == :stage
        vg_slug = get(_STAGE_RACE_VG_SLUGS, config.pcs_slug, "")
        gt_vg_history_df = assemble_gt_vg_history(
            vg_slug,
            config.year,
            history_years;
            pcs_slug = config.pcs_slug,
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
    end

    # --- 3d. Fetch cross-season PCS points for the PCS seasons signal (automatic) ---
    # Build slug map from rider names if the startlist didn't provide one
    if isempty(pcs_slug_map)
        for row in eachrow(riderdf)
            slug = normalisename(row.rider)
            slug = get(PCS_SLUG_OVERRIDES, slug, slug)
            pcs_slug_map[row.riderkey] = slug
        end
    end
    seasons_df = nothing
    seasons_provenance = (own_race = 0, cross_race = 0, live_fetched = 0)
    if !isempty(pcs_slug_map)
        try
            seasons_df, seasons_provenance = _load_pcs_seasons(
                config.pcs_slug,
                config.year,
                riderdf;
                slug_map = pcs_slug_map,
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(seasons_df) > 0
                n_riders_with_seasons = length(unique(seasons_df.riderkey))
                @info "Got cross-season PCS points for $n_riders_with_seasons riders"
                if !isempty(config.pcs_slug)
                    archivable_seasons = _archivable_pcs_seasons(seasons_df)
                    # Same merge as the specialty write, for the same reason —
                    # a narrower pool must not shrink a `refetchable = false`
                    # file. Keyed on riderkey, so a rider re-fetched this run
                    # replaces all of their season rows rather than doubling
                    # them.
                    if nrow(archivable_seasons) > 0
                        existing = load_race_snapshot(
                            "pcs_seasons",
                            config.pcs_slug,
                            config.year,
                        )
                        if existing !== nothing
                            fresh = Set(archivable_seasons.riderkey)
                            kept = filter(r -> !(r.riderkey in fresh), existing)
                            if nrow(kept) > 0
                                archivable_seasons =
                                    vcat(archivable_seasons, kept; cols = :union)
                            end
                        end
                        _try_archive(
                            archivable_seasons,
                            "pcs_seasons",
                            config.pcs_slug,
                            config.year,
                        )
                    end
                end
            end
            seasons_df =
                seasons_df === nothing || :_source ∉ propertynames(seasons_df) ?
                seasons_df : select(seasons_df, Not(:_source))
        catch e
            @warn "Failed to fetch PCS seasons data: $e"
        end
    end

    # --- 4. Odds (pre-parsed, e.g. Oddschecker paste) ---
    final_odds_df = odds_df
    if !isnothing(final_odds_df) && nrow(final_odds_df) > 0 && !isempty(config.pcs_slug)
        _try_archive(final_odds_df, "odds", config.pcs_slug, config.year)
    end

    # --- 4b. Secondary bookmaker markets (stage races) ---
    function _archive_secondary(odds_input_df, archive_type)
        if odds_input_df !== nothing && nrow(odds_input_df) > 0 && !isempty(config.pcs_slug)
            _try_archive(odds_input_df, archive_type, config.pcs_slug, config.year)
        end
    end
    _archive_secondary(points_odds_df, "odds_points")
    _archive_secondary(kom_odds_df, "odds_kom")
    _archive_secondary(stagewin_odds_df, "odds_stagewin")

    # --- 5. Fetch Cycling Oracle predictions (GC + optional points/KOM) ---
    function _fetch_oracle(url::String, archive_type::String, label::String)
        isempty(url) && return nothing
        try
            df = get_cycling_oracle(
                url;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(df) > 0
                @info "Got Cycling Oracle $label predictions for $(nrow(df)) riders"
                if !isempty(config.pcs_slug)
                    _try_archive(df, archive_type, config.pcs_slug, config.year)
                end
            else
                @info "Cycling Oracle $label returned no predictions"
            end
            return df
        catch e
            @warn "Failed to fetch Cycling Oracle $label predictions: $e"
            return nothing
        end
    end

    oracle_df = _fetch_oracle(oracle_url, "oracle", "GC")
    points_oracle_df = _fetch_oracle(points_oracle_url, "oracle_points", "points")
    kom_oracle_df = _fetch_oracle(kom_oracle_url, "oracle_kom", "KOM")

    # --- Data quality summary ---
    n_total = nrow(riderdf)
    n_pcs = if pcs_check_col in propertynames(riderdf)
        count(row -> !ismissing(row[pcs_check_col]) && row[pcs_check_col] > 0, eachrow(riderdf))
    else
        0
    end
    n_history = if race_history_df !== nothing
        length(intersect(riderdf.riderkey, unique(race_history_df.riderkey)))
    else
        0
    end
    n_odds = if final_odds_df !== nothing
        length(intersect(riderdf.riderkey, final_odds_df.riderkey))
    else
        0
    end
    n_oracle = if oracle_df !== nothing
        length(intersect(riderdf.riderkey, oracle_df.riderkey))
    else
        0
    end
    n_vg_history = if vg_history_df !== nothing
        length(intersect(riderdf.riderkey, unique(vg_history_df.riderkey)))
    else
        0
    end
    n_seasons = if seasons_df !== nothing
        length(intersect(riderdf.riderkey, unique(seasons_df.riderkey)))
    else
        0
    end

    @info "Data quality summary" riders = n_total pcs_specialty = "$n_pcs/$n_total" pcs_specialty_source = "own=$(specialty_provenance.own_race) cross=$(specialty_provenance.cross_race) live=$(specialty_provenance.live_fetched)" race_history = "$n_history/$n_total" vg_history = "$n_vg_history/$n_total" odds = "$n_odds/$n_total" oracle = "$n_oracle/$n_total" seasons = "$n_seasons/$n_total" pcs_seasons_source = "own=$(seasons_provenance.own_race) cross=$(seasons_provenance.cross_race) live=$(seasons_provenance.live_fetched)"
    if n_pcs == 0
        @warn "No riders have PCS specialty data — strength estimates will rely on VG season points only"
    end
    if race_history_df !== nothing && n_history == 0
        @warn "No riders matched to race history — historical finishing positions won't inform predictions"
    end

    return RaceData(;
        rider_df = riderdf,
        race_history_df = race_history_df,
        odds_df = final_odds_df,
        oracle_df = oracle_df,
        vg_history_df = vg_history_df,
        seasons_df = seasons_df,
        actual_df = nothing,
        points_oracle_df = points_oracle_df,
        kom_oracle_df = kom_oracle_df,
        points_odds_df = points_odds_df,
        kom_odds_df = kom_odds_df,
        stagewin_odds_df = stagewin_odds_df,
        points_history_df = points_history_df,
        kom_history_df = kom_history_df,
        gt_vg_history_df = gt_vg_history_df,
    )
end


# ---------------------------------------------------------------------------
# One-day solver
# ---------------------------------------------------------------------------

"""
## `solve_oneday`

Construct an optimal team for a Sixes Classics one-day race using resampled
optimisation of expected Velogames points.

## Pipeline:
1. Fetch VG rider data (costs, season points, teams)
2. Fetch PCS specialty ratings for each rider
3. Fetch PCS race-specific history (past editions)
4. Optionally use pre-parsed odds and Cycling Oracle predictions
5. Estimate rider strength via Bayesian updating
6. Resampled optimisation: draw strengths, score, optimise, repeat
7. Optionally blend the market into the final team pick (`market_blend_weight`)

## Market blend
`market_blend_weight < 1` mixes the bookmaker's implied win probabilities into
the column the final team optimisation maximises:
`w · unitnorm(risk-adjusted EVG) + (1 − w) · unitnorm(implied win prob)`. On the
12 marketed 2026 classics this lifted team-points-captured from 0.572 to 0.651
(see roadmap.md, "Experiment 2"). `w = 1` (the default) disables it, as does a
race with no odds.

## Returns
A tuple `(predicted, chosenteam, top_teams, sim_vg_points)` where `predicted` is
a DataFrame of all riders with expected VG points and selection frequency,
`chosenteam` is the optimal team (`top_teams[1]`), `top_teams` is the
`n_alternatives` best distinct near-optimal teams ranked best-first (k-best
enumeration), and `sim_vg_points` is a Matrix{Float64} (n_riders × n_resamples)
of per-draw VG points (row order matches `predicted`).
"""
function solve_oneday(
    config::RaceConfig;
    racehash::String = "",
    history_years::Int = 5,
    oracle_url::String = "",
    n_resamples::Int = 500,
    excluded_riders::Vector{String} = String[],
    filter_startlist::Bool = true,
    cache_config::CacheConfig = config.cache,
    force_refresh::Bool = false,
    odds_df::Union{DataFrame,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    max_per_team::Int = 0,
    risk_aversion::Float64 = 0.5,
    n_alternatives::Int = 20,
    breakaway_dir::String = "",
    breakaway_spec::NamedTuple = NamedTuple(),
    simulation_df::Union{Int,Nothing} = nothing,
    market_blend_weight::Float64 = 1.0,
)
    data = _prepare_rider_data(
        config,
        racehash,
        excluded_riders,
        history_years,
        oracle_url,
        config.team_size,
        cache_config,
        force_refresh;
        pcs_check_col = :oneday,
        filter_startlist = filter_startlist,
        odds_df = odds_df,
        apply_recency = false,
    )
    if data === nothing
        return DataFrame(), DataFrame(), DataFrame[], Matrix{Float64}(undef, 0, 0)
    end

    # --- 5. Estimate rider strengths + resampled optimisation ---
    scoring = get_scoring(config.category > 0 ? config.category : 2)

    # Breakaway rates (I/O) — loaded here and passed into the fetch-free core.
    # Keyed on data.rider_df.riderkey; estimate_strengths preserves row order,
    # so the rate vector aligns with the resampled `predicted` frame.
    b_rates, b_sectors = _load_breakaway_rates(
        breakaway_dir,
        data.rider_df.riderkey;
        as_of = resolve_race_date(config.pcs_slug, config.year),
        spec = breakaway_spec,
    )

    @info "Estimating rider strengths (Cat $(config.category))..."
    predicted, top_teams, sim_vg_points = _oneday_prediction_core(
        data,
        scoring;
        race_year = config.year,
        team_size = config.team_size,
        n_resamples = n_resamples,
        domestique_discount = domestique_discount,
        max_per_team = max_per_team,
        risk_aversion = risk_aversion,
        n_alternatives = n_alternatives,
        breakaway_rates = b_rates,
        breakaway_mean_sectors = b_sectors,
        simulation_df = simulation_df,
        market_blend_weight = market_blend_weight,
    )

    predicted, chosenteam = _extract_chosen_team!(predicted, top_teams)

    # Archive after optimisation so chosen / selection_frequency / expected_vg_points are persisted
    _archive_predictions(predicted, config)

    return predicted, chosenteam, top_teams, sim_vg_points
end

"""
    solve_oneday(rc::RenderConfig)

Run the one-day pipeline from a `RenderConfig`. See `solve_stage(::RenderConfig, ...)`
for why the unpacking lives here rather than at each render script.
"""
function solve_oneday(rc::RenderConfig)
    return solve_oneday(
        rc.race;
        racehash = rc.racehash,
        history_years = rc.history_years,
        oracle_url = rc.oracle_url,
        n_resamples = rc.n_resamples,
        excluded_riders = rc.excluded_riders,
        cache_config = rc.race.cache,
        force_refresh = rc.fresh,
        odds_df = rc.odds_df,
        domestique_discount = rc.domestique_discount,
        max_per_team = rc.max_per_team,
        risk_aversion = rc.risk_aversion,
        n_alternatives = rc.n_alternatives,
        breakaway_dir = rc.breakaway_dir,
        simulation_df = rc.simulation_df,
        market_blend_weight = rc.market_blend_weight,
    )
end


"""
    _stage_prediction_core(data, stages, scoring_table; race_year, ...)
        -> (predicted, top_teams, sim_vg_points, diagnostics)

Pure per-stage prediction pipeline shared by `solve_stage` (production) and
the stage-race backtest harness (`champion_evg` in backtest.jl): multidim
`estimate_strengths` → `compute_stage_strengths` → `resample_optimise_stage!`
→ optional Option B propensity adjustment (`gt_propensity_factors`, reading
`data.gt_vg_history_df`). No I/O or archival side effects — callers handle
data fetching and prediction archival.
"""
function _stage_prediction_core(
    data::RaceData,
    stages::Vector{StageProfile},
    scoring_table::StageRaceScoringTable;
    race_year::Int,
    team_size::Integer = 9,
    n_resamples::Int = 500,
    domestique_discount::Float64 = 0.0,
    max_per_team::Integer = 0,
    risk_aversion::Float64 = 0.5,
    n_alternatives::Integer = 20,
    cross_stage_alpha::Float64 = 0.7,
    sim_config::StageSimConfig = DEFAULT_STAGE_SIM_CONFIG,
    use_gt_vg_propensity::Bool = false,
    gt_vg_propensity_mode::Symbol = :posthoc,
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    rng::AbstractRNG = Random.default_rng(),
)
    @info "Estimating rider strengths (stage race)..."
    predicted = estimate_strengths(
        data;
        race_type = :stage,
        race_year = race_year,
        domestique_discount = domestique_discount,
        config = config,
    )

    @info "Building per-stage strengths from multidim posterior ($(length(stages)) stages)..."
    stage_strengths = compute_stage_strengths(predicted)
    gc_strengths_vec = Float64.(predicted.strength_gc)

    @info "Running per-stage resampled optimisation ($n_resamples resamples, $(length(stages)) stages)..."
    predicted, top_teams, sim_vg_points, diagnostics = resample_optimise_stage!(
        predicted,
        stages,
        stage_strengths,
        scoring_table,
        build_model_stage;
        team_size = team_size,
        n_resamples = n_resamples,
        cross_stage_alpha = cross_stage_alpha,
        gc_strengths = gc_strengths_vec,
        rng = rng,
        max_per_team = max_per_team,
        risk_aversion = risk_aversion,
        n_alternatives = n_alternatives,
        sim_config = sim_config,
    )

    # --- Option B: GT VG points-propensity layer (prototype, July 2026 —
    # see roadmap.md). Two-sided EVG correction learned from the residual
    # between each rider's REAL prior GT totals and their ability-implied
    # EVG. Default off ⇒ inert. Stacks on Option A: because `evg_raw` here
    # is the A-lifted prediction whenever the RaceData carries
    # `gt_vg_history_df` (A is data-gated at signal assembly, two layers up),
    # B captures only the residual A leaves, so the two compose without
    # double-counting.
    if use_gt_vg_propensity && data.gt_vg_history_df !== nothing
        evg_raw = vec(mean(sim_vg_points, dims = 2))
        factors = gt_propensity_factors(
            String.(predicted.riderkey),
            evg_raw,
            data.gt_vg_history_df,
            race_year,
        )
        predicted[!, :gt_propensity_factor] = round.(factors, digits = 3)
        if gt_vg_propensity_mode == :sim
            # (b) Inside-the-sim: scale every per-draw column, so the mean,
            # the downside deviation AND the per-draw selection frequency
            # all reflect propensity. Re-runs only the (RNG-free) optimise
            # tail on the scaled matrix — no re-simulation.
            sim_vg_points = sim_vg_points .* exp.(factors)
            predicted, top_teams = _resample_core!(
                predicted,
                sim_vg_points,
                build_model_stage;
                team_size = team_size,
                max_per_team = max_per_team,
                risk_aversion = risk_aversion,
                n_alternatives = n_alternatives,
            )
        else
            # (a) Post-hoc: multiply the final EVG mean and re-enumerate the
            # k-best near-optimal teams on the adjusted points. Per-draw
            # selection frequency is left on the unadjusted simulation.
            adj = evg_raw .* exp.(factors)
            predicted[!, :expected_vg_points] = round.(adj, digits = 1)
            predicted[!, :_adj_pts] = adj
            key_lists = _kbest_team_keys(
                predicted,
                build_model_stage,
                :_adj_pts;
                team_size = team_size,
                max_per_team = max_per_team,
                n_alternatives = n_alternatives,
            )
            select!(predicted, Not(:_adj_pts))
            top_teams =
                [filter(row -> row.riderkey in Set(keys), predicted) for keys in key_lists]
        end
    end

    return predicted, top_teams, sim_vg_points, diagnostics
end


"""
    _oneday_prediction_core(data, scoring; race_year, ...)
        -> (predicted, top_teams, sim_vg_points)

Pure one-day prediction pipeline shared by `solve_oneday` (production) and the
one-day backtest harness (`champion_oneday_evg` in backtest.jl): scalar
`estimate_strengths` → `resample_optimise!(build_model_oneday)`. No I/O or
archival side effects — callers handle data fetching, breakaway-rate loading,
and prediction archival. The one-day twin of `_stage_prediction_core`.

`market_blend_weight < 1` mixes the bookmaker market into the final team
optimisation (see `blend_market_points`); on a marketless race there is nothing
to blend and the run is identical to `w = 1`.
"""
function _oneday_prediction_core(
    data::RaceData,
    scoring::ScoringTable;
    race_year::Int,
    team_size::Integer = 6,
    n_resamples::Int = 500,
    domestique_discount::Float64 = 0.0,
    max_per_team::Integer = 0,
    risk_aversion::Float64 = 0.5,
    n_alternatives::Integer = 20,
    breakaway_rates::Vector{Float64} = Float64[],
    breakaway_mean_sectors::Vector{Float64} = Float64[],
    simulation_df::Union{Int,Nothing} = nothing,
    market_blend_weight::Float64 = 1.0,
    config::BayesianConfig = DEFAULT_BAYESIAN_CONFIG,
    rng::AbstractRNG = Random.default_rng(),
)
    @info "Estimating rider strengths..."
    predicted = estimate_strengths(
        data;
        race_year = race_year,
        domestique_discount = domestique_discount,
        config = config,
    )

    # After `estimate_strengths`, which rematches odds riderkeys against the
    # rider frame in place. Empty vector on a marketless race ⇒ no blend.
    market_probs = market_win_probs(data.odds_df, predicted.riderkey)

    @info "Running resampled optimisation ($n_resamples resamples)..."
    predicted, top_teams, sim_vg_points = resample_optimise!(
        predicted,
        scoring,
        build_model_oneday;
        team_size = team_size,
        n_resamples = n_resamples,
        rng = rng,
        max_per_team = max_per_team,
        risk_aversion = risk_aversion,
        n_alternatives = n_alternatives,
        breakaway_rates = breakaway_rates,
        breakaway_mean_sectors = breakaway_mean_sectors,
        simulation_df = simulation_df,
        market_probs = market_probs,
        market_blend_weight = market_blend_weight,
    )

    return predicted, top_teams, sim_vg_points
end


"""
## `solve_stage`

Construct an optimal team for a stage race using resampled optimisation.

When `stages` is non-empty, uses per-stage simulation with stage-type strength
modifiers (the new pipeline). When empty, falls back to the aggregate GC-position
approach.

Uses class-aware strength estimation and enforces VG classification constraints
(all-rounders, climbers, sprinters, unclassed) during optimisation.

When `breakaway_dir` points at archived PCS breakaway-km data (same source as
one-day races), the aggregate fallback enables per-rider breakaway scoring via
`resample_optimise!`'s one-day-style mechanism. The per-stage pipeline does not
model breakaway participation (deleted July 2026, WP2.3 — it failed to move
team-points-captured on the backtest harness).

## Returns
A `StageResult` (`predicted`, `chosenteam`, `top_teams`, `sim_vg_points`,
`diagnostics`). `top_teams` is the `n_alternatives` best distinct near-optimal
teams ranked best-first (k-best enumeration via no-good cuts), which the report
uses to surface the interchangeable filler pool and the structural fork decisions.
"""
function solve_stage(
    config::RaceConfig;
    stages::Vector{StageProfile} = StageProfile[],
    racehash::String = "",
    history_years::Int = 3,
    oracle_url::String = "",
    points_oracle_url::String = "",
    kom_oracle_url::String = "",
    n_resamples::Int = 500,
    excluded_riders::Vector{String} = String[],
    filter_startlist::Bool = true,
    cache_config::CacheConfig = config.cache,
    force_refresh::Bool = false,
    odds_df::Union{DataFrame,Nothing} = nothing,
    points_odds_df::Union{DataFrame,Nothing} = nothing,
    kom_odds_df::Union{DataFrame,Nothing} = nothing,
    stagewin_odds_df::Union{DataFrame,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    max_per_team::Int = 0,
    risk_aversion::Float64 = 0.5,
    n_alternatives::Int = 20,
    breakaway_dir::String = "",
    breakaway_spec::NamedTuple = NamedTuple(),
    simulation_df::Union{Int,Nothing} = nothing,
    cross_stage_alpha::Float64 = 0.7,
    stage_scoring::Union{StageRaceScoringTable,Nothing} = nothing,
    sim_config::StageSimConfig = DEFAULT_STAGE_SIM_CONFIG,
    include_gt_history::Bool = true,
    use_gt_vg_history::Bool = false,
    use_gt_vg_propensity::Bool = false,
    gt_vg_propensity_mode::Symbol = :posthoc,
    season_round_slugs::Vector{String} = String[],
)
    data = _prepare_rider_data(
        config,
        racehash,
        excluded_riders,
        history_years,
        oracle_url,
        config.team_size,
        cache_config,
        force_refresh;
        pcs_check_col = :gc,
        filter_startlist = filter_startlist,
        include_gt_history = include_gt_history,
        odds_df = odds_df,
        points_oracle_url = points_oracle_url,
        kom_oracle_url = kom_oracle_url,
        points_odds_df = points_odds_df,
        kom_odds_df = kom_odds_df,
        stagewin_odds_df = stagewin_odds_df,
        use_gt_vg_history = use_gt_vg_history,
        use_gt_vg_propensity = use_gt_vg_propensity,
        season_round_slugs = season_round_slugs,
    )
    if data === nothing
        return StageResult(
            DataFrame(),
            DataFrame(),
            DataFrame[],
            Matrix{Float64}(undef, 0, 0),
            nothing,
        )
    end

    if !isempty(stages)
        # --- Per-stage pipeline ---
        # Archive stage profiles
        if !isempty(config.pcs_slug)
            try
                save_race_snapshot(
                    stage_profiles_frame(stages),
                    "pcs_stage_profiles",
                    config.pcs_slug,
                    config.year,
                )
            catch e
                @debug "Failed to archive stage profiles: $e"
            end
        end

        scoring_table = stage_scoring !== nothing ? stage_scoring : SCORING_GRAND_TOUR

        predicted, top_teams, sim_vg_points, diagnostics = _stage_prediction_core(
            data,
            stages,
            scoring_table;
            race_year = config.year,
            team_size = config.team_size,
            n_resamples = n_resamples,
            domestique_discount = domestique_discount,
            max_per_team = max_per_team,
            risk_aversion = risk_aversion,
            n_alternatives = n_alternatives,
            cross_stage_alpha = cross_stage_alpha,
            sim_config = sim_config,
            use_gt_vg_propensity = use_gt_vg_propensity,
            gt_vg_propensity_mode = gt_vg_propensity_mode,
        )
    else
        # --- Aggregate fallback ---
        @info "Estimating rider strengths (stage race)..."
        predicted = estimate_strengths(
            data;
            race_type = :stage,
            race_year = config.year,
            domestique_discount = domestique_discount,
        )
        scoring = get_scoring(:stage)

        b_rates, b_sectors = _load_breakaway_rates(
            breakaway_dir,
            predicted.riderkey;
            as_of = resolve_race_date(config.pcs_slug, config.year),
            spec = breakaway_spec,
        )

        @info "Running aggregate resampled optimisation ($n_resamples resamples, class constraints)..."
        predicted, top_teams, sim_vg_points = resample_optimise!(
            predicted,
            scoring,
            build_model_stage;
            team_size = config.team_size,
            n_resamples = n_resamples,
            max_per_team = max_per_team,
            risk_aversion = risk_aversion,
            n_alternatives = n_alternatives,
            breakaway_rates = b_rates,
            breakaway_mean_sectors = b_sectors,
            simulation_df = simulation_df,
        )
        diagnostics = nothing
    end

    predicted, chosenteam = _extract_chosen_team!(predicted, top_teams)

    # Archive after optimisation so chosen / selection_frequency / expected_vg_points are persisted
    _archive_predictions(predicted, config)

    return StageResult(predicted, chosenteam, top_teams, sim_vg_points, diagnostics)
end

"""
    solve_stage(rc::RenderConfig, stages, stage_scoring)

Run the stage-race pipeline from a `RenderConfig`. The single place the knobs
are unpacked — every renderer goes through here, so none of them can pass a
different subset of the solver's inputs than the others.
"""
function solve_stage(
    rc::RenderConfig,
    stages::Vector{StageProfile},
    stage_scoring::Union{StageRaceScoringTable,Nothing},
)
    return solve_stage(
        rc.race;
        stages = stages,
        racehash = rc.racehash,
        history_years = rc.history_years,
        oracle_url = rc.oracle_url,
        points_oracle_url = rc.points_oracle_url,
        kom_oracle_url = rc.kom_oracle_url,
        n_resamples = rc.n_resamples,
        excluded_riders = rc.excluded_riders,
        cache_config = rc.race.cache,
        force_refresh = rc.fresh,
        odds_df = rc.odds_df,
        points_odds_df = rc.points_odds_df,
        kom_odds_df = rc.kom_odds_df,
        stagewin_odds_df = rc.stagewin_odds_df,
        domestique_discount = rc.domestique_discount,
        max_per_team = rc.max_per_team,
        risk_aversion = rc.risk_aversion,
        n_alternatives = rc.n_alternatives,
        breakaway_dir = rc.breakaway_dir,
        simulation_df = rc.simulation_df,
        cross_stage_alpha = rc.cross_stage_alpha,
        stage_scoring = stage_scoring,
        use_gt_vg_history = rc.use_gt_vg_history,
        use_gt_vg_propensity = rc.use_gt_vg_propensity,
        gt_vg_propensity_mode = rc.gt_vg_propensity_mode,
        season_round_slugs = rc.season_round_slugs,
    )
end
