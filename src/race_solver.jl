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

"""Return true if the race has already happened (so its archive should be protected)."""
function _race_has_happened(config::RaceConfig)
    today = Dates.today()
    config.year < Dates.year(today) && return true
    config.year > Dates.year(today) && return false
    info = find_race(config.name)
    info === nothing && return true  # unknown date — protect by default
    return Dates.Date(info.date) < today
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
    cols = intersect(
        propertynames(predicted),
        [
            :riderkey,
            :rider,
            :team,
            :cost,
            :strength,
            :uncertainty,
            :shift_pcs,
            :shift_vg,
            :shift_form,
            :shift_history,
            :shift_vg_history,
            :shift_oracle,
            :shift_oracle_points,
            :shift_oracle_kom,
            :shift_qualitative,
            :shift_odds,
            :info_share_pcs,
            :info_share_vg,
            :info_share_form,
            :info_share_history,
            :info_share_vg_history,
            :info_share_points_history,
            :info_share_kom_history,
            :info_share_oracle,
            :info_share_oracle_gc,
            :info_share_oracle_points,
            :info_share_oracle_kom,
            :info_share_qualitative,
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
            :selection_frequency,
            :chosen,
        ],
    )
    try
        save_race_snapshot(predicted[:, cols], "predictions", config.pcs_slug, config.year)
    catch e
        @warn "Failed to archive predictions: $e"
    end
end

"""Load breakaway rates from PCS data, or return empty vectors if unavailable.

`max_rate` is the one-day default (0.35 — see `compute_breakaway_rates`) unless
overridden; stage-race callers pass `STAGE_BREAKAWAY_MAX_RATE` (0.15) since a
grand tour offers many hilly/mountain stages rather than a single race day.
"""
function _load_breakaway_rates(
    breakaway_dir::String,
    riderkeys::AbstractVector;
    max_rate::Float64 = 0.35,
)
    isempty(breakaway_dir) && return Float64[], Float64[]
    !isdir(breakaway_dir) && return Float64[], Float64[]
    try
        breakaway_df = load_pcs_breakaway_stats(breakaway_dir)
        rates, sectors =
            compute_breakaway_rates(breakaway_df, String.(riderkeys); max_rate = max_rate)
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
Idempotent: safe to re-run. Intended to be called from team_assessor.qmd
after each race to build the prospective validation dataset.
"""
function archive_race_results(
    pcs_slug::String,
    year::Int;
    vg_race_number::Int = 0,
    cache_config::CacheConfig = DEFAULT_CACHE,
    force_refresh::Bool = false,
)
    # Archive PCS race results
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

    # Archive VG race results. Stage races (grand tours / week-long races) run
    # their own separate VG competition from the one-day classics — fetching
    # via `getvg_race_results` (which always hits the classics competition
    # URL) would silently archive an unrelated one-day race's scores under
    # this stage race's pcs_slug. Route stage races to `getvg_stage_race_totals`
    # with the correct VG slug instead; `vg_race_number` is a one-day-only
    # concept (the classics `st` parameter) and is ignored for stage races.
    vg_slug = get(_STAGE_RACE_VG_SLUGS, pcs_slug, "")
    if !isempty(vg_slug)
        try
            vg_results = getvg_stage_race_totals(
                year,
                vg_slug;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(vg_results) > 0
                save_race_snapshot(vg_results, "vg_results", pcs_slug, year)
            end
        catch e
            @warn "Failed to archive VG stage totals for $pcs_slug $year: $e"
        end
    elseif vg_race_number > 0
        try
            vg_results = getvg_race_results(
                year,
                vg_race_number;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(vg_results) > 0
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
    qualitative_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
    points_oracle_url::String = "",
    kom_oracle_url::String = "",
    points_odds_df::Union{DataFrame,Nothing} = nothing,
    kom_odds_df::Union{DataFrame,Nothing} = nothing,
    stagewin_odds_df::Union{DataFrame,Nothing} = nothing,
    use_gt_vg_history::Bool = false,
    use_gt_vg_propensity::Bool = false,
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
    # Same-race only: the isolation backtest (scripts/eval_classification_history.jl)
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
            cache_config = cache_config,
            force_refresh = force_refresh,
        )
    end

    # --- 3c. Fetch PCS form scores (automatic) ---
    form_df = nothing
    if !isempty(config.pcs_slug)
        try
            form_df = getpcs_race_form(
                config.pcs_slug,
                config.year;
                cache_config = cache_config,
                force_refresh = force_refresh,
            )
            if nrow(form_df) > 0
                @info "Got PCS form scores for $(nrow(form_df)) riders"
                _try_archive(form_df, "pcs_form", config.pcs_slug, config.year)
            end
        catch e
            @warn "Failed to fetch PCS form data: $e"
        end
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
    n_qualitative = if qualitative_df !== nothing
        length(intersect(riderdf.riderkey, qualitative_df.riderkey))
    else
        0
    end
    n_form = if form_df !== nothing
        length(intersect(riderdf.riderkey, form_df.riderkey))
    else
        0
    end
    n_seasons = if seasons_df !== nothing
        length(intersect(riderdf.riderkey, unique(seasons_df.riderkey)))
    else
        0
    end

    # Archive qualitative data for prospective evaluation
    if qualitative_df !== nothing && nrow(qualitative_df) > 0 && !isempty(config.pcs_slug)
        _try_archive(qualitative_df, "qualitative", config.pcs_slug, config.year)
    end

    @info "Data quality summary" riders = n_total pcs_specialty = "$n_pcs/$n_total" race_history = "$n_history/$n_total" vg_history = "$n_vg_history/$n_total" odds = "$n_odds/$n_total" oracle = "$n_oracle/$n_total" qualitative = "$n_qualitative/$n_total" form = "$n_form/$n_total" seasons = "$n_seasons/$n_total"
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
        qualitative_df = qualitative_df,
        form_df = form_df,
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
    qualitative_df::Union{DataFrame,Nothing} = nothing,
    odds_df::Union{DataFrame,Nothing} = nothing,
    domestique_discount::Float64 = 0.0,
    max_per_team::Int = 0,
    risk_aversion::Float64 = 0.5,
    n_alternatives::Int = 20,
    breakaway_dir::String = "",
    simulation_df::Union{Int,Nothing} = nothing,
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
        qualitative_df = qualitative_df,
        odds_df = odds_df,
        apply_recency = false,
    )
    if data === nothing
        return DataFrame(), DataFrame(), DataFrame[], Matrix{Float64}(undef, 0, 0)
    end

    # --- 5. Estimate rider strengths ---
    scoring = get_scoring(config.category > 0 ? config.category : 2)

    @info "Estimating rider strengths (Cat $(config.category))..."
    predicted = estimate_strengths(
        data;
        race_year = config.year,
        domestique_discount = domestique_discount,
    )

    # --- 6. Breakaway rates ---
    b_rates, b_sectors = _load_breakaway_rates(breakaway_dir, predicted.riderkey)

    # --- 7. Resampled optimisation ---
    @info "Running resampled optimisation ($n_resamples resamples)..."
    predicted, top_teams, sim_vg_points = resample_optimise!(
        predicted,
        scoring,
        build_model_oneday;
        team_size = config.team_size,
        n_resamples = n_resamples,
        max_per_team = max_per_team,
        risk_aversion = risk_aversion,
        n_alternatives = n_alternatives,
        breakaway_rates = b_rates,
        breakaway_mean_sectors = b_sectors,
        simulation_df = simulation_df,
    )

    predicted, chosenteam = _extract_chosen_team!(predicted, top_teams)

    # Archive after optimisation so chosen / selection_frequency / expected_vg_points are persisted
    _archive_predictions(predicted, config)

    return predicted, chosenteam, top_teams, sim_vg_points
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
one-day races), both pipelines enable per-rider breakaway scoring: the
aggregate fallback via `resample_optimise!`'s one-day-style mechanism, and the
per-stage pipeline via the discrete per-stage breakaway event in
`simulate_stage_race` (hilly/mountain stages only, capped at
`STAGE_BREAKAWAY_MAX_RATE` per stage). Empty `breakaway_dir` (the default)
leaves both pipelines unaffected.

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
    qualitative_df::Union{DataFrame,Nothing} = nothing,
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
        qualitative_df = qualitative_df,
        odds_df = odds_df,
        points_oracle_url = points_oracle_url,
        kom_oracle_url = kom_oracle_url,
        points_odds_df = points_odds_df,
        kom_odds_df = kom_odds_df,
        stagewin_odds_df = stagewin_odds_df,
        use_gt_vg_history = use_gt_vg_history,
        use_gt_vg_propensity = use_gt_vg_propensity,
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

    @info "Estimating rider strengths (stage race)..."
    predicted = estimate_strengths(
        data;
        race_type = :stage,
        race_year = config.year,
        domestique_discount = domestique_discount,
    )

    if !isempty(stages)
        # --- Per-stage pipeline ---
        @info "Building per-stage strengths from multidim posterior ($(length(stages)) stages)..."
        stage_strengths = compute_stage_strengths(predicted)
        gc_strengths_vec = Float64.(predicted.strength_gc)

        # Archive stage profiles
        if !isempty(config.pcs_slug)
            try
                stage_df = DataFrame(
                    stage_number = [s.stage_number for s in stages],
                    stage_type = [String(s.stage_type) for s in stages],
                    distance_km = [s.distance_km for s in stages],
                    profile_score = [s.profile_score for s in stages],
                    vertical_meters = [s.vertical_meters for s in stages],
                    n_hc_climbs = [s.n_hc_climbs for s in stages],
                    n_cat1_climbs = [s.n_cat1_climbs for s in stages],
                    is_summit_finish = [s.is_summit_finish for s in stages],
                )
                save_race_snapshot(stage_df, "stage_profiles", config.pcs_slug, config.year)
            catch e
                @debug "Failed to archive stage profiles: $e"
            end
        end

        scoring_table = stage_scoring !== nothing ? stage_scoring : SCORING_GRAND_TOUR

        # Breakaway rates (prototype, July 2026 — see roadmap.md "Stage-race
        # breakaway modelling"): reuses the same archived PCS breakaway-km
        # data as one-day races, but capped at STAGE_BREAKAWAY_MAX_RATE per
        # stage rather than the one-day 0.35, since a grand tour offers
        # ~10-13 hilly/mountain stages rather than a single race day (see
        # scoring.jl). `_b_stage_sectors` (one-day sector counts) is unused —
        # GT scoring has a single flat `breakaway_points` bonus, not one-day's
        # 4-checkpoint sectors.
        b_stage_rates, _b_stage_sectors = _load_breakaway_rates(
            breakaway_dir,
            predicted.riderkey;
            max_rate = STAGE_BREAKAWAY_MAX_RATE,
        )

        @info "Running per-stage resampled optimisation ($n_resamples resamples, $(length(stages)) stages)..."
        predicted, top_teams, sim_vg_points, diagnostics = resample_optimise_stage!(
            predicted,
            stages,
            stage_strengths,
            scoring_table,
            build_model_stage;
            team_size = config.team_size,
            n_resamples = n_resamples,
            cross_stage_alpha = cross_stage_alpha,
            gc_strengths = gc_strengths_vec,
            max_per_team = max_per_team,
            risk_aversion = risk_aversion,
            n_alternatives = n_alternatives,
            sim_config = sim_config,
            breakaway_rates = b_stage_rates,
        )

        # --- Option B: GT VG points-propensity layer (prototype, July 2026 —
        # see roadmap.md). Two-sided EVG correction learned from the residual
        # between each rider's REAL prior GT totals and their ability-implied
        # EVG. Default off ⇒ inert. Stacks on Option A: because `evg_raw` here
        # is the (A-lifted, if `use_gt_vg_history`) prediction, B captures only
        # the residual A leaves, so the two compose without double-counting.
        if use_gt_vg_propensity && data.gt_vg_history_df !== nothing
            evg_raw = vec(mean(sim_vg_points, dims = 2))
            factors = gt_propensity_factors(
                String.(predicted.riderkey),
                evg_raw,
                data.gt_vg_history_df,
                config.year,
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
                    team_size = config.team_size,
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
                    team_size = config.team_size,
                    max_per_team = max_per_team,
                    n_alternatives = n_alternatives,
                )
                select!(predicted, Not(:_adj_pts))
                top_teams =
                    [filter(row -> row.riderkey in Set(keys), predicted) for keys in key_lists]
            end
        end
    else
        # --- Aggregate fallback ---
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
