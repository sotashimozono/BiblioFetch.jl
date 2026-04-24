const USER_AGENT = "BiblioFetch/0.1 (+https://github.com/; mailto:souta.shimozono@gmail.com)"

# Default base URLs for the external APIs. Each lookup function accepts a
# `base_url` kwarg that overrides these — used by the mock-server tests to
# point the code at a local HTTP.serve handler without any monkey-patching.
const CROSSREF_URL = "https://api.crossref.org/works/"
const UNPAYWALL_URL = "https://api.unpaywall.org/v2/"
const ARXIV_API_URL = "http://export.arxiv.org/api/query"
const DATACITE_URL = "https://api.datacite.org/dois/"
const S2_URL = "https://api.semanticscholar.org/graph/v1/paper/"
const APS_TDM_URL = "https://harvest.aps.org/v2/journals/articles/"
const ELSEVIER_TDM_URL = "https://api.elsevier.com/content/article/doi/"
const SPRINGER_OA_URL = "https://api.springernature.com/openaccess/json"

# Retry defaults. Overridable per-call on every lookup function.
const DEFAULT_RETRY_STATUSES = (429, 502, 503, 504)
const DEFAULT_MAX_RETRIES = 3
const DEFAULT_BASE_DELAY = 1.0   # seconds; doubled each attempt

# Parse a Retry-After response header as a non-negative number of seconds.
# Returns `nothing` for HTTP-date-form values (rare for the APIs we hit, and
# not worth pulling in a date parser for).
function _parse_retry_after(resp::HTTP.Response)
    for (k, v) in resp.headers
        lowercase(String(k)) == "retry-after" || continue
        n = tryparse(Float64, strip(String(v)))
        n === nothing || return max(0.0, Float64(n))
        return nothing
    end
    return nothing
end

"""
    _http_get_with_retry(url; proxy, request_kwargs, max_retries, base_delay,
                         retry_statuses, sleep_fn)
        -> (resp_or_nothing, err_or_nothing, trace)

GET `url` with exponential backoff on `retry_statuses` (default 429 / 502 / 503
/ 504) and on raised exceptions. Honors the `Retry-After` response header for
rate-limit responses. Returns the final `HTTP.Response` (even if it's still in
`retry_statuses` after all attempts), or `(nothing, error_msg, trace)` when every
attempt threw.

`trace` is a `NamedTuple` `(; retry_count, retried_statuses)` — number of
retries burned before the returned response, and the status codes that
triggered each retry. Exception-driven retries are recorded as `0` (the
request never reached the server so no status exists). Callers that
discard trace via `resp, _ = ...` are unaffected (tuple destructuring
takes the first two elements).

All lookup functions route through here; callers never handle retry logic
directly. `sleep_fn` is injectable for tests.
"""
function _http_get_with_retry(
    url::AbstractString;
    proxy=nothing,
    request_kwargs=(;),
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    retry_statuses=DEFAULT_RETRY_STATUSES,
    sleep_fn=Base.sleep,
)
    kw = merge(
        (;
            headers=["User-Agent" => USER_AGENT],
            connect_timeout=15,
            readtimeout=15,
            status_exception=false,
            retry=false,
        ),
        request_kwargs,
    )

    last_err::Union{String,Nothing} = nothing
    retried_statuses = Int[]   # one entry per retry actually taken
    for attempt in 0:max_retries
        try
            resp =
                proxy === nothing ? HTTP.get(url; kw...) : HTTP.get(url; proxy=proxy, kw...)
            if resp.status in retry_statuses && attempt < max_retries
                delay = _parse_retry_after(resp)
                delay === nothing && (delay = base_delay * 2.0^attempt)
                @debug "retrying" url status=resp.status attempt delay
                push!(retried_statuses, Int(resp.status))
                sleep_fn(delay)
                continue
            end
            return (resp, nothing, (; retry_count=length(retried_statuses), retried_statuses))
        catch e
            last_err = sprint(showerror, e)
            if attempt >= max_retries
                return (
                    nothing,
                    last_err,
                    (; retry_count=length(retried_statuses), retried_statuses),
                )
            end
            @debug "retrying after exception" url attempt err=last_err
            push!(retried_statuses, 0)   # 0 = exception / pre-server retry
            sleep_fn(base_delay * 2.0^attempt)
        end
    end
    return (nothing, last_err, (; retry_count=length(retried_statuses), retried_statuses))
end

# Deeply convert JSON3 objects/arrays to plain Dict{String,Any} / Vector{Any}
# so that String-keyed `get(x, "foo", …)` and TOML.print both work predictably.
function _to_plain(x)
    if x isa JSON3.Object
        return Dict{String,Any}(string(k) => _to_plain(v) for (k, v) in pairs(x))
    elseif x isa JSON3.Array
        return Any[_to_plain(v) for v in x]
    elseif x isa AbstractDict
        return Dict{String,Any}(string(k) => _to_plain(v) for (k, v) in x)
    elseif x isa AbstractVector && !(x isa AbstractString)
        return Any[_to_plain(v) for v in x]
    elseif x isa AbstractString
        return String(x)
    else
        return x
    end
end
