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

"""Load breakaway rates from PCS data, or return empty vectors if unavailable."""
function _load_breakaway_rates(breakaway_dir::String, riderkeys::AbstractVector)
    isempty(breakaway_dir) && return Float64[], Float64[]
    !isdir(breakaway_dir) && return Float64[], Float64[]
    try
        breakaway_df = load_pcs_breakaway_stats(breakaway_dir)
        rates, sectors = compute_breakaway_rates(breakaway_df, String.(riderkeys))
        n_matched = count(>(0.0), rates)
        @info "Breakaway data: $n_matched/$(length(riderkeys)) riders matched"
        return rates, sectors
    catch e
        @warn "Failed to load breakaway data: $e"
        return Float64[], Float64[]
    end
end

"""
    archive_race_results(race_name, year; cache_config, force_refresh)

Fetch and archive actual PCS results and VG results for a completed race.

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
    # Archive PCS race results
    if force_refresh || load_race_snapshot("pcs_results", pcs_slug, year) === nothing
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
            catch
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
    # --- 1. Fetch VG rider data ---
    @info "Fetching VG rider data from $(config.current_url)..."
    riderdf = getvg_riders(
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

    # --- 2. Fetch PCS specialty ratings ---
    @info "Fetching PCS specialty ratings for $(nrow(riderdf)) riders..."
    rider_names = String.(riderdf.rider)
    pcsriderpts = getpcs_rider_pts_batch(
        rider_names;
        slug_map = pcs_slug_map,
        cache_config = cache_config,
        force_refresh = force_refresh,
    )

    riderdf = join_pcs_specialty(riderdf, pcsriderpts)

    # Recency-weight all five PCS specialties from per-season points, so current
    # form outweighs stale career palmarès. Adds :<spec>_r columns consumed by
    # the multidim z-scoring; returns the raw per-season data for archival. Only
    # the stage-race (multidim) path reads the :<spec>_r columns — the one-day
    # scalar path uses its own single-dimension recency source — so skip the
    # 5×N per-rider specialty fetches for one-day races.
    if apply_recency
        pcs_seasons = _apply_pcs_recency!(
            riderdf,
            pcs_slug_map,
            config.year;
            cache_config = cache_config,
            force_refresh = force_refresh,
        )

        # Archive per-season specialty points (long format) so backtests can
        # recompute recency-weighted specialty scores as-of the race date.
        if !isempty(config.pcs_slug) && nrow(pcs_seasons) > 0
            _try_archive(pcs_seasons, "pcs_specialty_seasons", config.pcs_slug, config.year)
        end
    end

    # Archive PCS specialty scores for future backtesting
    if !isempty(config.pcs_slug) && nrow(pcsriderpts) > 0
        _try_archive(pcsriderpts, "pcs_specialty", config.pcs_slug, config.year)
    end

    # --- 3. Fetch PCS race history (primary + similar + within-year) ---
    race_info = _find_race_by_slug(config.pcs_slug)
    race_date = resolve_race_date(config.pcs_slug, config.year)
    race_history_df = assemble_pcs_race_history(
        config.pcs_slug,
        config.year,
        history_years;
        race_date = race_date,
        include_gt_history = include_gt_history,
        cache_config = cache_config,
        force_refresh = force_refresh,
    )

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
    if !isempty(pcs_slug_map)
        try
            seasons_df = getpcs_rider_seasons_batch(
                pcs_slug_map;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(seasons_df) > 0
                n_riders_with_seasons = length(unique(seasons_df.riderkey))
                @info "Got cross-season PCS points for $n_riders_with_seasons riders"
                if !isempty(config.pcs_slug)
                    _try_archive(seasons_df, "pcs_seasons", config.pcs_slug, config.year)
                end
            end
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

    @info "Data quality summary" riders = n_total pcs_specialty = "$n_pcs/$n_total" race_history = "$n_history/$n_total" vg_history = "$n_vg_history/$n_total" odds = "$n_odds/$n_total" oracle = "$n_oracle/$n_total" seasons = "$n_seasons/$n_total"
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
    b_rates, b_sectors = _load_breakaway_rates(breakaway_dir, data.rider_df.riderkey)

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

        b_rates, b_sectors = _load_breakaway_rates(breakaway_dir, predicted.riderkey)

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
