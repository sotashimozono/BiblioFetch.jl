const USER_AGENT = "BiblioFetch/0.1 (+https://github.com/; mailto:souta.shimozono@gmail.com)"

# Default base URLs for the external APIs. Each lookup function accepts a
# `base_url` kwarg that overrides these — used by the mock-server tests to
# point the code at a local HTTP.serve handler without any monkey-patching.
const CROSSREF_URL = "https://api.crossref.org/works/"
const UNPAYWALL_URL = "https://api.unpaywall.org/v2/"
const ARXIV_API_URL = "http://export.arxiv.org/api/query"

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
                         retry_statuses, sleep_fn) -> (resp_or_nothing, err_or_nothing)

GET `url` with exponential backoff on `retry_statuses` (default 429 / 502 / 503
/ 504) and on raised exceptions. Honors the `Retry-After` response header for
rate-limit responses. Returns the final `HTTP.Response` (even if it's still in
`retry_statuses` after all attempts), or `(nothing, error_msg)` when every
attempt threw.

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
    for attempt in 0:max_retries
        try
            resp =
                proxy === nothing ? HTTP.get(url; kw...) : HTTP.get(url; proxy=proxy, kw...)
            if resp.status in retry_statuses && attempt < max_retries
                delay = _parse_retry_after(resp)
                delay === nothing && (delay = base_delay * 2.0^attempt)
                @debug "retrying" url status=resp.status attempt delay
                sleep_fn(delay)
                continue
            end
            return (resp, nothing)
        catch e
            last_err = sprint(showerror, e)
            if attempt >= max_retries
                return (nothing, last_err)
            end
            @debug "retrying after exception" url attempt err=last_err
            sleep_fn(base_delay * 2.0^attempt)
        end
    end
    return (nothing, last_err)
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

# ---------- key normalization ----------

const _DOI_RE = r"^10\.\d{4,9}/\S+$"i
const _ARXIV_RE = r"^(arxiv:)?(\d{4}\.\d{4,5}(v\d+)?|[a-z\-]+(\.[A-Z]{2})?/\d{7}(v\d+)?)$"i

"""
    is_doi(s) -> Bool

Whether `s` looks like a DOI (`10.xxxx/anything`). Strips surrounding whitespace
but does not otherwise transform the input.
"""
is_doi(s::AbstractString) = occursin(_DOI_RE, strip(s))

"""
    is_arxiv(s) -> Bool

Whether `s` looks like an arXiv id — both the new-style (`1706.03762`,
optionally with a version suffix `v2` and an `arxiv:` prefix) and the legacy
slash form (`cond-mat/0608208`).
"""
is_arxiv(s::AbstractString) = occursin(_ARXIV_RE, strip(s))

"""
    normalize_key(s) -> String

Normalize a user-provided reference to a canonical key:
  * DOI  → lowercase DOI (`10.1103/physrevb.xx.yyyy`)
  * arXiv → `arxiv:<id>`
Throws `ArgumentError` if unrecognized.
"""
function normalize_key(s::AbstractString)
    t = strip(s)
    # strip common URL prefixes
    for pre in (
        "https://doi.org/",
        "http://doi.org/",
        "doi:",
        "DOI:",
        "https://arxiv.org/abs/",
        "http://arxiv.org/abs/",
        "https://arxiv.org/pdf/",
    )
        if startswith(t, pre)
            t = t[(length(pre) + 1):end]
            break
        end
    end
    t = rstrip(t, ['/'])
    if is_arxiv(t)
        id = startswith(lowercase(t), "arxiv:") ? t[7:end] : t
        return "arxiv:" * lowercase(id)
    elseif is_doi(t)
        return lowercase(t)
    else
        throw(ArgumentError("Unrecognized reference: $(s)"))
    end
end

# ---------- Crossref ----------

"""
    crossref_lookup(doi; proxy = nothing, timeout = 15, base_url = CROSSREF_URL,
                    max_retries = $(DEFAULT_MAX_RETRIES),
                    base_delay = $(DEFAULT_BASE_DELAY)) -> Dict

Fetch Crossref metadata for a DOI. Returns an empty `Dict` on any failure
(network error, non-200 response, malformed JSON). Retries `429` / `502-504`
responses with exponential backoff honoring `Retry-After`.
"""
function crossref_lookup(
    doi::AbstractString;
    proxy=nothing,
    timeout=15,
    base_url=CROSSREF_URL,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
)
    url = base_url * URIs.escapeuri(doi)
    resp, _ = _http_get_with_retry(
        url;
        proxy=proxy,
        request_kwargs=(; connect_timeout=timeout, readtimeout=timeout),
        max_retries=max_retries,
        base_delay=base_delay,
        sleep_fn=sleep_fn,
    )
    (resp === nothing || resp.status != 200) && return Dict{String,Any}()
    try
        obj = JSON3.read(resp.body)
        return _to_plain(obj[:message])
    catch e
        @debug "crossref_lookup: JSON parse failed" doi exception=e
        return Dict{String,Any}()
    end
end

# ---------- Unpaywall ----------

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

# ---------- arXiv ----------

"""
    arxiv_id_from_crossref(meta) -> String or nothing

Mine a Crossref record for an arXiv preprint link.
"""
function arxiv_id_from_crossref(meta)
    isempty(meta) && return nothing
    rel = get(meta, "relation", nothing)
    if rel !== nothing
        for key in ("has-preprint", "is-preprint-of", "has-version")
            v = get(rel, key, nothing)
            v === nothing && continue
            for entry in v
                id = get(entry, "id", "")
                idtype = lowercase(string(get(entry, "id-type", "")))
                if idtype == "arxiv" || occursin("arxiv", lowercase(string(id)))
                    m = match(r"(\d{4}\.\d{4,5}|[a-z\-]+/\d{7})", String(id))
                    m !== nothing && return m.captures[1]
                end
            end
        end
    end
    return nothing
end

"""
    arxiv_search_by_title(title; authors, proxy, timeout,
                          base_url = ARXIV_API_URL) -> String or nothing

Fallback: hit the arXiv API by title (and optionally first author) and return the
first matching arXiv id. Approximate — use as a last resort.
"""
function arxiv_search_by_title(
    title::AbstractString;
    authors::Vector{<:AbstractString}=String[],
    proxy=nothing,
    timeout=15,
    base_url=ARXIV_API_URL,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
)
    q = "ti:\"" * replace(title, '"' => ' ') * "\""
    isempty(authors) || (q *= " AND au:\"" * replace(first(authors), '"' => ' ') * "\"")
    url = base_url * "?max_results=1&search_query=" * URIs.escapeuri(q)
    resp, _ = _http_get_with_retry(
        url;
        proxy=proxy,
        request_kwargs=(; connect_timeout=timeout, readtimeout=timeout),
        max_retries=max_retries,
        base_delay=base_delay,
        sleep_fn=sleep_fn,
    )
    (resp === nothing || resp.status != 200) && return nothing
    body = String(resp.body)
    m = match(r"<id>https?://arxiv\.org/abs/([^<]+)</id>"i, body)
    m === nothing && return nothing
    id = m.captures[1]
    # strip version
    id2 = replace(id, r"v\d+$" => "")
    return String(id2)
end

arxiv_pdf_url(id::AbstractString) = "https://arxiv.org/pdf/" * id * ".pdf"

# --- arXiv Atom metadata parsing ---

# Decode the minimal HTML-entity set the arXiv API uses inside text fields.
# Order matters: &amp; must run last so we don't double-decode entities like &amp;lt;.
function _decode_html_entities(s::AbstractString)
    out = String(s)
    out = replace(out, "&lt;" => "<")
    out = replace(out, "&gt;" => ">")
    out = replace(out, "&quot;" => "\"")
    out = replace(out, "&apos;" => "'")
    out = replace(out, "&amp;" => "&")
    return out
end

# Strip element content: decode entities + collapse internal whitespace.
function _clean_text(s::AbstractString)
    t = _decode_html_entities(String(s))
    return strip(replace(t, r"\s+" => " "))
end

# Pull the first <tag>...</tag> body (with optional attributes), or `nothing`.
# The tag name may contain a colon (`arxiv:doi`) — we escape it for the regex.
function _first_tag(xml::AbstractString, tag::AbstractString)
    esc = replace(tag, ":" => "\\:")
    re = Regex("<$(esc)(?:\\s[^>]*)?>([^<]*)</$(esc)>", "s")
    m = match(re, xml)
    m === nothing ? nothing : _clean_text(String(m.captures[1]))
end

# Pull every <author>…<name>X</name>…</author> body. Handles optional
# <arxiv:affiliation> siblings that appear in some real arXiv responses.
function _all_author_names(xml::AbstractString)
    out = String[]
    for block in eachmatch(r"<author\b[^>]*>(.*?)</author>"s, xml)
        m = match(r"<name\b[^>]*>\s*(.*?)\s*</name>"s, String(block.captures[1]))
        m === nothing && continue
        push!(out, _clean_text(String(m.captures[1])))
    end
    return out
end

"""
    _parse_arxiv_atom(xml) -> NamedTuple | nothing

Parse an arXiv Atom response (single-entry feed) into
`(title, authors, year, journal, doi, primary_category)`. Returns `nothing` if
the feed has no `<entry>`.

The parser is regex-based rather than a full XML parser — arXiv's Atom is
well-behaved and staying dep-free keeps the package lightweight.
"""
function _parse_arxiv_atom(xml::AbstractString)
    entry = match(r"<entry>(.*?)</entry>"s, String(xml))
    entry === nothing && return nothing
    body = String(entry.captures[1])

    title = something(_first_tag(body, "title"), "")
    isempty(title) && return nothing     # not a usable entry

    authors = _all_author_names(body)

    pub = _first_tag(body, "published")
    year = if pub === nothing
        nothing
    else
        m = match(r"^(\d{4})", pub)
        m === nothing ? nothing : parse(Int, m.captures[1])
    end

    journal = _first_tag(body, "arxiv:journal_ref")
    doi = _first_tag(body, "arxiv:doi")

    # Prefer the journal publication year over the arXiv submission year when
    # the journal_ref supplies one (e.g. "Annals Phys. 321 (2006) 2-111").
    if journal !== nothing
        my = match(r"\((\d{4})\)", journal)
        my === nothing || (year = parse(Int, my.captures[1]))
    end

    primary_category =
        let m = match(r"<arxiv:primary_category[^>]*term=\"([^\"]+)\""s, body)
            m === nothing ? nothing : String(m.captures[1])
        end

    return (
        title=title,
        authors=authors,
        year=year,
        journal=journal,
        doi=doi,
        primary_category=primary_category,
    )
end

"""
    arxiv_metadata(id; proxy = nothing, timeout = 15,
                   base_url = ARXIV_API_URL) -> NamedTuple | nothing

Hit the arXiv API for a single id (`1706.03762` / `cond-mat/0608208`) and
return the parsed metadata, or `nothing` if the lookup fails. Strips the
`arxiv:` prefix if passed.
"""
function arxiv_metadata(
    id::AbstractString;
    proxy=nothing,
    timeout=15,
    base_url=ARXIV_API_URL,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
)
    raw = startswith(lowercase(String(id)), "arxiv:") ? id[7:end] : id
    url = base_url * "?id_list=" * URIs.escapeuri(String(raw))
    resp, _ = _http_get_with_retry(
        url;
        proxy=proxy,
        request_kwargs=(; connect_timeout=timeout, readtimeout=timeout),
        max_retries=max_retries,
        base_delay=base_delay,
        sleep_fn=sleep_fn,
    )
    (resp === nothing || resp.status != 200) && return nothing
    return _parse_arxiv_atom(String(resp.body))
end

# ---------- direct DOI landing (needs proxy for paywalled) ----------

doi_landing_url(doi::AbstractString) = "https://doi.org/" * doi
