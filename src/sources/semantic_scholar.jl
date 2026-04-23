# ---------- Semantic Scholar ----------
#
# Semantic Scholar's graph API offers three things BiblioFetch doesn't get
# from Crossref / Unpaywall / arXiv:
#
#   * abstracts — Crossref records don't include them
#   * an extra OA PDF URL set, sometimes disjoint from Unpaywall
#   * a `references` array with inline externalIds (DOI / arXiv) per cite,
#     giving a second citation-graph source for papers Crossref doesn't link
#
# This module focuses on (1) and (2). Citation graph via S2 is a natural
# follow-up but would duplicate the existing Crossref-based expansion until
# we add per-source preference policy, so it's left for later.
#
# Without an API key, S2 allows ~1 req/s publicly; with one, ~10 req/s. The
# retry helper handles the resulting 429s transparently, but running `:s2`
# with `parallel > 1` on an unauthenticated account will still be slow.

# Field selector — asking for everything would be wasteful.
const _S2_FIELDS = "title,authors,year,abstract,openAccessPdf,journal,externalIds"

# Translate a normalize_key'd key into S2's identifier format.
# S2 accepts: DOI:10.xxx / ARXIV:1234.5678 / MAG:... / ACL:... / URL:...
function _s2_key(normalized::AbstractString)
    if startswith(normalized, "arxiv:")
        return "ARXIV:" * normalized[7:end]
    elseif is_doi(normalized)
        return "DOI:" * normalized
    else
        throw(ArgumentError("s2_lookup: cannot convert key to S2 form: $(normalized)"))
    end
end

# Pick the API key: explicit kwarg wins; otherwise check the env var.
function _s2_api_key(api_key)
    api_key === nothing || return String(api_key)
    v = get(ENV, "SEMANTIC_SCHOLAR_API_KEY", nothing)
    return v === nothing || isempty(v) ? nothing : String(v)
end

"""
    s2_lookup(ref; api_key = ENV["SEMANTIC_SCHOLAR_API_KEY"], proxy = nothing,
              timeout = 15, base_url = S2_URL, max_retries, base_delay)
        -> Dict

Look up a paper on Semantic Scholar. `ref` is a normalized key (`10.xxxx/yyy`
or `arxiv:…`).

Returns a `Dict{String,Any}` with the fields BiblioFetch cares about:

  * `"title"`        — `String`
  * `"authors"`      — `Vector{String}` (display names, one per author)
  * `"year"`         — `Int` or `nothing`
  * `"abstract"`     — `String` (empty when S2 didn't have one)
  * `"journal"`      — `String` (empty when S2 didn't record one)
  * `"oa_pdf_url"`   — `String` pointing at the publisher / repository PDF,
                       present only when `openAccessPdf.url` is non-empty
  * `"s2_paper_id"`  — S2's own stable id, useful for follow-ups

Empty `Dict` on any failure (unreachable, 404, malformed JSON, etc.).
"""
function s2_lookup(
    ref::AbstractString;
    api_key=nothing,
    proxy=nothing,
    timeout=15,
    base_url=S2_URL,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
)
    s2_key = _s2_key(ref)
    url = base_url * URIs.escapeuri(s2_key) * "?fields=" * URIs.escapeuri(_S2_FIELDS)

    headers = Pair{String,String}["User-Agent" => USER_AGENT]
    eff_key = _s2_api_key(api_key)
    eff_key === nothing || push!(headers, "x-api-key" => eff_key)

    resp, _ = _http_get_with_retry(
        url;
        proxy=proxy,
        request_kwargs=(;
            headers=headers, connect_timeout=timeout, readtimeout=timeout,
        ),
        max_retries=max_retries,
        base_delay=base_delay,
        sleep_fn=sleep_fn,
    )
    (resp === nothing || resp.status != 200) && return Dict{String,Any}()
    try
        obj = _to_plain(JSON3.read(resp.body))
        return _extract_s2_fields(obj)
    catch e
        @debug "s2_lookup: JSON parse failed" ref exception=e
        return Dict{String,Any}()
    end
end

# Pull just the subset of S2's rich record we care about.
function _extract_s2_fields(obj::AbstractDict)
    out = Dict{String,Any}()
    t = String(get(obj, "title", ""))
    isempty(t) || (out["title"] = t)

    authors_raw = get(obj, "authors", nothing)
    if authors_raw isa AbstractVector
        names = String[]
        for a in authors_raw
            a isa AbstractDict || continue
            n = String(get(a, "name", ""))
            isempty(n) || push!(names, n)
        end
        isempty(names) || (out["authors"] = names)
    end

    y = get(obj, "year", nothing)
    if y isa Integer
        out["year"] = Int(y)
    elseif y isa AbstractString
        yi = tryparse(Int, y)
        yi === nothing || (out["year"] = yi)
    end

    ab = String(get(obj, "abstract", ""))
    isempty(ab) || (out["abstract"] = ab)

    j = get(obj, "journal", nothing)
    if j isa AbstractDict
        jn = String(get(j, "name", ""))
        isempty(jn) || (out["journal"] = jn)
    end

    oa = get(obj, "openAccessPdf", nothing)
    if oa isa AbstractDict
        u = String(get(oa, "url", ""))
        isempty(u) || (out["oa_pdf_url"] = u)
    end

    pid = String(get(obj, "paperId", ""))
    isempty(pid) || (out["s2_paper_id"] = pid)
    return out
end
