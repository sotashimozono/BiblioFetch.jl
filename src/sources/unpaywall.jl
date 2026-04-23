"""
    unpaywall_lookup(doi; email, proxy = nothing, timeout = 15,
                     base_url = UNPAYWALL_URL) -> (url_or_nothing, metadata_dict)

Ask Unpaywall for the best OA PDF URL. Requires `email` (Unpaywall API policy).
Returns `(pdf_url, metadata)` where `pdf_url === nothing` when no OA copy is
registered, and `metadata === Dict()` on hard failure.
"""
function unpaywall_lookup(
    doi::AbstractString;
    email::AbstractString,
    proxy=nothing,
    timeout=15,
    base_url=UNPAYWALL_URL,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
)
    url = base_url * URIs.escapeuri(doi) * "?email=" * URIs.escapeuri(email)
    resp, _ = _http_get_with_retry(
        url;
        proxy=proxy,
        request_kwargs=(; connect_timeout=timeout, readtimeout=timeout),
        max_retries=max_retries,
        base_delay=base_delay,
        sleep_fn=sleep_fn,
    )
    (resp === nothing || resp.status != 200) && return (nothing, Dict{String,Any}())
    try
        obj = _to_plain(JSON3.read(resp.body))
        loc = get(obj, "best_oa_location", nothing)
        loc === nothing && return (nothing, obj)
        pdf = get(loc, "url_for_pdf", nothing)
        pdf === nothing && (pdf = get(loc, "url", nothing))
        return (pdf === nothing ? nothing : String(pdf), obj)
    catch e
        @debug "unpaywall_lookup: JSON parse failed" doi exception=e
        return (nothing, Dict{String,Any}())
    end
end
