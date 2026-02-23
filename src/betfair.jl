# ---------------------------------------------------------------------------
# Betfair Exchange API client
# ---------------------------------------------------------------------------

const BETFAIR_LOGIN_URL = "https://identitysso.betfair.com/api/login"
const BETFAIR_API_URL = "https://api.betfair.com/exchange/betting/json-rpc/v1"

# Mutable session state (module-level, not persisted across Julia sessions)
const _BETFAIR_SESSION = Ref{Union{Nothing,String}}(nothing)
const _BETFAIR_APP_KEY = Ref{Union{Nothing,String}}(nothing)

"""
    betfair_login(; username, password, app_key) -> String

Authenticate with the Betfair Exchange API using the interactive login endpoint.

Reads credentials from environment variables by default (`BETFAIR_USERNAME`,
`BETFAIR_PASSWORD`, `BETFAIR_APP_KEY`). Returns the session token and stores it
for subsequent API calls.
"""
function betfair_login(;
    username::String = get(ENV, "BETFAIR_USERNAME", ""),
    password::String = get(ENV, "BETFAIR_PASSWORD", ""),
    app_key::String = get(ENV, "BETFAIR_APP_KEY", ""),
)::String
    if isempty(username) || isempty(password) || isempty(app_key)
        error(
            "Betfair credentials not found. Set BETFAIR_USERNAME, BETFAIR_PASSWORD, " *
            "and BETFAIR_APP_KEY environment variables (e.g. via .envrc with direnv).",
        )
    end

    response = HTTP.post(
        BETFAIR_LOGIN_URL,
        ["Accept" => "application/json", "X-Application" => app_key],
        HTTP.Form(Dict("username" => username, "password" => password)),
    )

    result = JSON3.read(String(response.body))

    if get(result, :status, "") != "SUCCESS"
        err = get(result, :error, "unknown error")
        error("Betfair login failed: $err")
    end

    token = String(result.token)
    _BETFAIR_SESSION[] = token
    _BETFAIR_APP_KEY[] = app_key
    @info "Betfair login successful"
    return token
end

"""
    betfair_ensure_session() -> (String, String)

Return `(session_token, app_key)`, logging in lazily if no session exists.
"""
function betfair_ensure_session()::Tuple{String,String}
    if _BETFAIR_SESSION[] === nothing
        betfair_login()
    end
    return (_BETFAIR_SESSION[]::String, _BETFAIR_APP_KEY[]::String)
end

"""
    betfair_api_call(method, params) -> Any

Make a JSON-RPC call to the Betfair Betting API. Returns the parsed result.
"""
function betfair_api_call(method::String, params::Dict)
    session, app_key = betfair_ensure_session()

    body = JSON3.write(Dict(
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params,
        "id" => 1,
    ))

    headers = [
        "X-Application" => app_key,
        "X-Authentication" => session,
        "Content-Type" => "application/json",
        "Accept" => "application/json",
    ]

    response = HTTP.post(BETFAIR_API_URL, headers, body)
    parsed = JSON3.read(String(response.body))

    # Check for JSON-RPC error
    if haskey(parsed, :error)
        err = parsed.error
        # Clear session on auth failures so next call retries login
        if haskey(err, :data) && haskey(err.data, :APINGException)
            exc = err.data.APINGException
            if get(exc, :errorCode, "") == "INVALID_SESSION_INFORMATION"
                _BETFAIR_SESSION[] = nothing
            end
        end
        error("Betfair API error in $method: $(JSON3.write(err))")
    end

    return parsed.result
end

"""
    betfair_get_market_odds(market_id) -> DataFrame

Fetch odds from a Betfair Exchange market. Returns a DataFrame with columns
`rider` (String), `odds` (Float64), and `riderkey` (String).

Returns an empty DataFrame if the market is not found or has no active runners.
"""
function betfair_get_market_odds(market_id::String)::DataFrame
    empty_df = DataFrame(rider = String[], odds = Float64[], riderkey = String[])

    # Step 1: get runner names and selection IDs
    catalogue = betfair_api_call(
        "SportsAPING/v1.0/listMarketCatalogue",
        Dict(
            "filter" => Dict("marketIds" => [market_id]),
            "maxResults" => "200",
            "marketProjection" => ["RUNNER_DESCRIPTION"],
        ),
    )

    if isempty(catalogue)
        @warn "Betfair market $market_id not found"
        return empty_df
    end

    market = first(catalogue)
    runners_cat = market.runners

    # Build selectionId -> runner name mapping
    id_to_name = Dict{Int,String}()
    for r in runners_cat
        id_to_name[Int(r.selectionId)] = String(r.runnerName)
    end

    # Step 2: get prices
    books = betfair_api_call(
        "SportsAPING/v1.0/listMarketBook",
        Dict(
            "marketIds" => [market_id],
            "priceProjection" => Dict("priceData" => ["EX_BEST_OFFERS"]),
        ),
    )

    if isempty(books)
        @warn "Betfair market $market_id returned no book data"
        return empty_df
    end

    book = first(books)

    # Step 3: extract odds for active runners with available back prices
    names_out = String[]
    odds_out = Float64[]

    for runner in book.runners
        status = String(get(runner, :status, ""))
        if status != "ACTIVE"
            continue
        end

        sel_id = Int(runner.selectionId)
        if !haskey(id_to_name, sel_id)
            continue
        end

        # Get best available back price
        back_prices = get(get(runner, :ex, (;)), :availableToBack, [])
        if isempty(back_prices)
            continue
        end

        best_back = Float64(first(back_prices).price)
        push!(names_out, id_to_name[sel_id])
        push!(odds_out, best_back)
    end

    if isempty(names_out)
        @warn "Betfair market $market_id has no active runners with prices"
        return empty_df
    end

    df = DataFrame(rider = names_out, odds = odds_out)
    df.riderkey = map(createkey, df.rider)

    @info "Fetched Betfair odds for $(nrow(df)) runners from market $market_id"
    return df
end
