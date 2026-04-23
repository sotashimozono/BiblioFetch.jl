# ---------- arXiv Atom XML parsing (no XML dep; regex-based) ----------

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

# ---------- arXiv HTTP API ----------

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
