"""
    crossref_lookup(doi; proxy = nothing, timeout = 15, base_url = CROSSREF_URL,
                    max_retries, base_delay) -> Dict

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

"""
    crossref_references(meta) -> Vector{String}

Extract the DOIs of cited references from a Crossref metadata dict (as returned
by [`crossref_lookup`](@ref)). Only entries with a `DOI` field are included —
Crossref also carries unstructured text citations, which we can't follow.
DOIs are lowercased for consistency with normalize_key.
"""
function crossref_references(meta::AbstractDict)
    refs = get(meta, "reference", nothing)
    refs isa AbstractVector || return String[]
    out = String[]
    for r in refs
        r isa AbstractDict || continue
        doi = get(r, "DOI", nothing)
        doi === nothing && continue
        s = strip(String(doi))
        isempty(s) || push!(out, lowercase(s))
    end
    return out
end

"""
    arxiv_id_from_crossref(meta) -> String or nothing

Mine a Crossref record for an arXiv preprint link. Checks
`relation.has-preprint` / `is-preprint-of` / `has-version` for entries whose
`id-type == "arxiv"` or whose `id` contains `arxiv`.
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
