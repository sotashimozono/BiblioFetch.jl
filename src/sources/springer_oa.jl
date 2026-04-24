# ---------- Springer Nature OpenAccess ----------
#
# Springer Nature exposes an OA lookup API at api.springernature.com that
# resolves a DOI to its OA metadata (title, journal, abstract, licence) when
# the article is open-access. Authenticated via `api_key` *query parameter*
# (free keys from https://dev.springernature.com/), not a header — that's the
# key shape difference from the APS/Elsevier TDM sources.
#
# Strategy: use the OA API as a gating step (is this DOI really OA?), then
# download from the canonical `link.springer.com/content/pdf/<DOI>.pdf` URL.
# For gold-OA content that URL is publicly reachable — no second auth hop —
# so the PDF download itself doesn't need any Springer-specific headers.
#
# Like `:aps` / `:elsevier`, `:springer` is opt-in via `[fetch].sources` and
# only fires for Springer DOIs, guarded by an API-key check so the fetch
# pipeline can't spray un-keyed requests at the endpoint.

"""
    is_springer_doi(doi) -> Bool

Whether `doi` is published under a Springer Nature imprint. Covers the four
prefixes worth gating on:

  * `10.1007/` — Springer (journals + books, the overwhelming majority)
  * `10.1038/` — Nature portfolio (mix of OA and paywalled; OA API will tell
    us which)
  * `10.1186/` — BMC / BioMed Central (all OA)
  * `10.1140/` — European Physical Journal (EPJ)

Other Springer-distributed prefixes (10.1057 Palgrave, 10.1023 legacy Kluwer,
10.1134 Allerton) are rare in practice and omitted to keep the guard tight.
"""
function is_springer_doi(doi::AbstractString)
    d = lowercase(strip(doi))
    return startswith(d, "10.1007/") ||
           startswith(d, "10.1038/") ||
           startswith(d, "10.1186/") ||
           startswith(d, "10.1140/")
end

# Canonical public PDF URL for a Springer OA article. Works for every
# Springer Nature imprint's OA content — the OA API's own `url` array
# sometimes omits a direct PDF entry, so we don't rely on it.
_springer_pdf_url(doi::AbstractString) =
    "https://link.springer.com/content/pdf/" * String(doi) * ".pdf"

# API key lookup: explicit kwarg wins, then $SPRINGER_API_KEY.
function _springer_api_key(api_key)
    api_key === nothing || return String(api_key)
    v = get(ENV, "SPRINGER_API_KEY", nothing)
    return v === nothing || isempty(v) ? nothing : String(v)
end

"""
    springer_oa_lookup(doi; api_key = ENV["SPRINGER_API_KEY"],
                       proxy = nothing, timeout = 15,
                       base_url = SPRINGER_OA_URL)
        -> (pdf_url_or_nothing, metadata_dict)

Ask the Springer Nature OpenAccess API whether `doi` is registered as an OA
article. Returns `(pdf_url, metadata)`:

  * `pdf_url` is the canonical `link.springer.com/content/pdf/<DOI>.pdf` URL
    when the API confirms OA registration, else `nothing`.
  * `metadata` is the parsed JSON body (empty `Dict` on hard failure or when
    the response has no `records`).

Returns `(nothing, Dict())` without a network call when no API key is
configured — the fetch pipeline uses that to skip `:springer` entirely,
matching the APS/Elsevier "don't spray un-authenticated requests" pattern.
"""
function springer_oa_lookup(
    doi::AbstractString;
    api_key=nothing,
    proxy=nothing,
    timeout=15,
    base_url=SPRINGER_OA_URL,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
)
    key = _springer_api_key(api_key)
    key === nothing && return (nothing, Dict{String,Any}())

    query = "q=" * URIs.escapeuri("doi:" * String(doi)) * "&api_key=" * URIs.escapeuri(key)
    url = base_url * "?" * query
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
        records = get(obj, "records", Any[])
        isempty(records) && return (nothing, obj)
        return (_springer_pdf_url(doi), obj)
    catch e
        @debug "springer_oa_lookup: JSON parse failed" doi exception = e
        return (nothing, Dict{String,Any}())
    end
end
