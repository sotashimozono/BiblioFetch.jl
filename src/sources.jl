const USER_AGENT = "BiblioFetch/0.1 (+https://github.com/; mailto:souta.shimozono@gmail.com)"

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

is_doi(s::AbstractString) = occursin(_DOI_RE, strip(s))
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
    crossref_lookup(doi; proxy = nothing) -> Dict

Fetch Crossref metadata for a DOI. Returns an empty Dict on failure.
"""
function crossref_lookup(doi::AbstractString; proxy=nothing, timeout=15)
    url = "https://api.crossref.org/works/" * URIs.escapeuri(doi)
    try
        kw = (;
            headers=["User-Agent" => USER_AGENT],
            connect_timeout=timeout,
            readtimeout=timeout,
            status_exception=false,
            retry=false,
        )
        resp = proxy === nothing ? HTTP.get(url; kw...) : HTTP.get(url; proxy=proxy, kw...)
        resp.status == 200 || return Dict{String,Any}()
        obj = JSON3.read(resp.body)
        return _to_plain(obj[:message])
    catch e
        @debug "crossref_lookup failed" doi exception=e
        return Dict{String,Any}()
    end
end

# ---------- Unpaywall ----------

"""
    unpaywall_lookup(doi; email, proxy = nothing) -> (url_or_nothing, metadata_dict)

Ask Unpaywall for the best OA PDF URL. Requires `email`.
"""
function unpaywall_lookup(
    doi::AbstractString; email::AbstractString, proxy=nothing, timeout=15
)
    url =
        "https://api.unpaywall.org/v2/" *
        URIs.escapeuri(doi) *
        "?email=" *
        URIs.escapeuri(email)
    try
        kw = (;
            headers=["User-Agent" => USER_AGENT],
            connect_timeout=timeout,
            readtimeout=timeout,
            status_exception=false,
            retry=false,
        )
        resp = proxy === nothing ? HTTP.get(url; kw...) : HTTP.get(url; proxy=proxy, kw...)
        resp.status == 200 || return (nothing, Dict{String,Any}())
        obj = _to_plain(JSON3.read(resp.body))
        loc = get(obj, "best_oa_location", nothing)
        loc === nothing && return (nothing, obj)
        pdf = get(loc, "url_for_pdf", nothing)
        pdf === nothing && (pdf = get(loc, "url", nothing))
        return (pdf === nothing ? nothing : String(pdf), obj)
    catch e
        @debug "unpaywall_lookup failed" doi exception=e
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
    arxiv_search_by_title(title; authors, proxy, timeout) -> String or nothing

Fallback: hit the arXiv API by title (and optionally first author) and return the
first matching arXiv id. Approximate — use as a last resort.
"""
function arxiv_search_by_title(
    title::AbstractString;
    authors::Vector{<:AbstractString}=String[],
    proxy=nothing,
    timeout=15,
)
    q = "ti:\"" * replace(title, '"' => ' ') * "\""
    isempty(authors) || (q *= " AND au:\"" * replace(first(authors), '"' => ' ') * "\"")
    url =
        "http://export.arxiv.org/api/query?max_results=1&search_query=" * URIs.escapeuri(q)
    try
        kw = (;
            headers=["User-Agent" => USER_AGENT],
            connect_timeout=timeout,
            readtimeout=timeout,
            status_exception=false,
            retry=false,
        )
        resp = proxy === nothing ? HTTP.get(url; kw...) : HTTP.get(url; proxy=proxy, kw...)
        resp.status == 200 || return nothing
        body = String(resp.body)
        m = match(r"<id>https?://arxiv\.org/abs/([^<]+)</id>"i, body)
        m === nothing && return nothing
        id = m.captures[1]
        # strip version
        id2 = replace(id, r"v\d+$" => "")
        return String(id2)
    catch e
        @debug "arxiv_search_by_title failed" title exception=e
        return nothing
    end
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
    arxiv_metadata(id; proxy = nothing, timeout = 15) -> NamedTuple | nothing

Hit the arXiv API for a single id (`1706.03762` / `cond-mat/0608208`) and
return the parsed metadata, or `nothing` if the lookup fails. Strips the
`arxiv:` prefix if passed.
"""
function arxiv_metadata(id::AbstractString; proxy=nothing, timeout=15)
    raw = startswith(lowercase(String(id)), "arxiv:") ? id[7:end] : id
    url = "http://export.arxiv.org/api/query?id_list=" * URIs.escapeuri(String(raw))
    try
        kw = (;
            headers=["User-Agent" => USER_AGENT],
            connect_timeout=timeout,
            readtimeout=timeout,
            status_exception=false,
            retry=false,
        )
        resp = proxy === nothing ? HTTP.get(url; kw...) : HTTP.get(url; proxy=proxy, kw...)
        resp.status == 200 || return nothing
        return _parse_arxiv_atom(String(resp.body))
    catch e
        @debug "arxiv_metadata failed" id exception=e
        return nothing
    end
end

# ---------- direct DOI landing (needs proxy for paywalled) ----------

doi_landing_url(doi::AbstractString) = "https://doi.org/" * doi
