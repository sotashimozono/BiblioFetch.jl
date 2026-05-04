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

# ---------- title-similarity guard helpers ----------

# Tokenize a title: lowercase, drop non-[a-z0-9 ] noise, split on whitespace.
function _title_tokens(s::AbstractString)
    return split(replace(lowercase(String(s)), r"[^a-z0-9 ]" => " "))
end

"""
    _title_similarity(a, b) -> Float64

Jaccard similarity on lowercased token bigrams of two titles. Returns 0.0
if either title is empty. Falls back to token-set Jaccard when one side
has fewer than two tokens (so a single-word title can still match itself).
"""
function _title_similarity(a::AbstractString, b::AbstractString)
    (isempty(a) || isempty(b)) && return 0.0
    ta = _title_tokens(a)
    tb = _title_tokens(b)
    (isempty(ta) || isempty(tb)) && return 0.0

    # Bigram path (preferred for multi-word titles).
    if length(ta) >= 2 && length(tb) >= 2
        A = Set(collect(zip(ta[1:(end - 1)], ta[2:end])))
        B = Set(collect(zip(tb[1:(end - 1)], tb[2:end])))
        union_sz = length(union(A, B))
        return union_sz == 0 ? 0.0 : length(intersect(A, B)) / union_sz
    end

    # Fallback: token-set Jaccard for very short (single-token) titles.
    A = Set(ta)
    B = Set(tb)
    union_sz = length(union(A, B))
    return union_sz == 0 ? 0.0 : length(intersect(A, B)) / union_sz
end

"""
    _surname_overlaps(query_author, candidate_authors) -> Bool

True when the last whitespace-delimited token of `query_author` matches
the last token of any name in `candidate_authors` (case-insensitive).
Used as a rescue path when title similarity falls below threshold.
"""
function _surname_overlaps(
    query_author::AbstractString, candidate_authors::Vector{<:AbstractString}
)
    qparts = split(strip(query_author))
    isempty(qparts) && return false
    qsur = lowercase(String(last(qparts)))
    isempty(qsur) && return false
    for ca in candidate_authors
        cparts = split(strip(ca))
        isempty(cparts) && continue
        lowercase(String(last(cparts))) == qsur && return true
    end
    return false
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
    raw = if startswith(lowercase(String(id)), "arxiv:")
        chopprefix(String(id), r"(?i)arxiv:")
    else
        id
    end
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
    arxiv_latest_version(id; proxy, timeout, base_url = ARXIV_API_URL)
        -> Int or nothing

Return the number of the latest published version of arXiv paper `id`.
arXiv's API answers an `id_list=<id>` query with the entry's canonical URL
in `<id>`, which always carries the current `vN` suffix — the integer after
`v` is the latest-version number. Missing or unparseable responses return
`nothing`. Strips an `arxiv:` prefix if passed.
"""
function arxiv_latest_version(
    id::AbstractString;
    proxy=nothing,
    timeout=15,
    base_url=ARXIV_API_URL,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
)
    raw = if startswith(lowercase(String(id)), "arxiv:")
        chopprefix(String(id), r"(?i)arxiv:")
    else
        id
    end
    # Strip any trailing version so the API returns the latest.
    raw = replace(String(raw), r"v\d+$" => "")
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
    body = String(resp.body)
    # The first <id> inside an <entry> carries the abs URL. Match its vN tail.
    entry = match(r"<entry>(.*?)</entry>"s, body)
    entry === nothing && return nothing
    idtag = match(r"<id>([^<]+)</id>"s, String(entry.captures[1]))
    idtag === nothing && return nothing
    m = match(r"v(\d+)$", strip(String(idtag.captures[1])))
    m === nothing && return 1   # no vN suffix → only v1 exists
    return parse(Int, m.captures[1])
end

"""
    arxiv_list_versions(id; kwargs...) -> Vector{Int}

Return every version number an arXiv paper has, in ascending order. arXiv
numbers versions sequentially from 1, so this is `1:arxiv_latest_version(id)`
with the API call cached into a single trip. Returns `Int[]` on lookup
failure.

`kwargs` are forwarded to `arxiv_latest_version`.
"""
function arxiv_list_versions(id::AbstractString; kwargs...)
    latest = arxiv_latest_version(id; kwargs...)
    latest === nothing && return Int[]
    return collect(1:Int(latest))
end

"""
    arxiv_search_by_title(title; authors, proxy, timeout,
                          base_url = ARXIV_API_URL,
                          similarity_threshold = 0.8) -> String or nothing

Fallback: hit the arXiv API by title (and optionally first author) and return
the matching arXiv id when the candidate's own title clears
`similarity_threshold` (Jaccard on lowercased token bigrams). Falls back to a
first-author last-name match when the title score is below threshold; returns
`nothing` if neither rescues. Prevents silently attaching Reply / Comment /
Erratum papers as the canonical preprint.
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
    similarity_threshold::Real=0.8,
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

    parsed = _parse_arxiv_atom(body)
    parsed === nothing && return nothing

    sim = _title_similarity(title, parsed.title)
    if sim < similarity_threshold
        author_match =
            !isempty(authors) && any(a -> _surname_overlaps(a, parsed.authors), authors)
        if !author_match
            @debug "arxiv_search_by_title: title similarity too low" wanted = title got =
                parsed.title sim
            return nothing
        end
    end

    m = match(r"<id>https?://arxiv\.org/abs/([^<]+)</id>"i, body)
    m === nothing && return nothing
    id = m.captures[1]
    # strip version
    id2 = replace(id, r"v\d+$" => "")
    return String(id2)
end
