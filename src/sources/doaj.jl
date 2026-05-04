# ---------- DOAJ (Directory of Open Access Journals) ----------
#
# DOAJ vets ~20k gold-OA journals; coverage skews to smaller / non-English /
# regional titles that Unpaywall sometimes misses. It's an opt-in publisher
# source — when configured we look up the article record by DOI, surface the
# first PDF link, and translate the bibjson into a Crossref-shaped metadata
# dict so the existing fetch_paper! extraction can backfill missing fields.
#
# Search endpoint: https://doaj.org/api/search/articles/doi:<DOI>
# Returns a paged result set; we only ever care about results[1].

# Translate a DOAJ `bibjson` object into a Crossref-shaped metadata dict, so
# fetch_paper!'s existing extraction code works unchanged.
#
# DOAJ's bibjson shape (the bits we use):
#   { "title":   "...",
#     "author":  [{"name": "Last, First"}, ...],
#     "year":    "2023",
#     "journal": {"title": "..."},
#     "abstract": "...",
#     "link":    [{"type": "fulltext", "content_type": "application/pdf",
#                  "url": "..."}, ...] }
function _doaj_to_crossref_shape(bib::AbstractDict)
    titles = String[]
    t = strip(String(get(bib, "title", "")))
    isempty(t) || push!(titles, t)

    authors = Dict{String,Any}[]
    for a in get(bib, "author", [])
        a isa AbstractDict || continue
        name = String(get(a, "name", ""))
        given = ""
        family = ""
        if occursin(",", name)
            parts = split(name, ','; limit=2)
            family = strip(parts[1])
            given = length(parts) > 1 ? strip(parts[2]) : ""
        else
            family = strip(name)
        end
        isempty(family) && isempty(given) && continue
        push!(authors, Dict{String,Any}("given" => given, "family" => family))
    end

    journal_title = ""
    j = get(bib, "journal", nothing)
    if j isa AbstractDict
        journal_title = String(get(j, "title", ""))
    end
    container_title = isempty(journal_title) ? String[] : [journal_title]

    year_val = get(bib, "year", nothing)
    year_int = if year_val isa Integer
        Int(year_val)
    elseif year_val isa AbstractString
        tryparse(Int, String(year_val))
    else
        nothing
    end
    issued = Dict{String,Any}("date-parts" => [Any[year_int]])

    out = Dict{String,Any}(
        "title" => titles,
        "author" => authors,
        "container-title" => container_title,
        "issued" => issued,
    )
    abstract = String(get(bib, "abstract", ""))
    isempty(abstract) || (out["abstract"] = abstract)
    return out
end

# Pick the first link whose content_type contains "pdf" or whose url ends
# with ".pdf". Returns `nothing` when no link looks like a PDF.
function _doaj_pdf_link(bib::AbstractDict)
    links = get(bib, "link", nothing)
    links isa AbstractVector || return nothing
    for l in links
        l isa AbstractDict || continue
        ct = lowercase(String(get(l, "content_type", "")))
        url = String(get(l, "url", ""))
        isempty(url) && continue
        if occursin("pdf", ct) || endswith(lowercase(url), ".pdf")
            return url
        end
    end
    return nothing
end

"""
    doaj_lookup(doi; proxy = nothing, timeout = 15, base_url = DOAJ_URL,
                max_retries, base_delay, sleep_fn)
        -> (pdf_url_or_nothing, metadata_dict)

Look up a DOI in DOAJ's article index. Returns `(pdf_url, metadata)` where:

  * `pdf_url` is the first `link` entry whose `content_type` contains "pdf"
    or whose `url` ends in `.pdf` — `nothing` when no such link exists.
  * `metadata` is a Crossref-shaped dict translated from DOAJ's `bibjson`
    (title / author / container-title / issued / abstract). Returns
    `Dict()` on hard failure (unreachable, non-200, no results, malformed
    JSON).

Used as an opt-in publisher source for vetted gold-OA journals — surfaces
PDFs from smaller / non-English titles that Unpaywall doesn't index.
"""
function doaj_lookup(
    doi::AbstractString;
    proxy=nothing,
    timeout=15,
    base_url=DOAJ_URL,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
)
    # DOAJ's search endpoint takes a Lucene-style query; we limit to a
    # single DOI lookup. The literal `doi:` prefix is part of the query
    # string — only the DOI value itself is escaped.
    url = base_url * "doi:" * URIs.escapeuri(doi)
    resp, _ = _http_get_with_retry(
        url;
        proxy=proxy,
        request_kwargs=(;
            headers=["User-Agent" => user_agent(), "Accept" => "application/json"],
            connect_timeout=timeout,
            readtimeout=timeout,
        ),
        max_retries=max_retries,
        base_delay=base_delay,
        sleep_fn=sleep_fn,
    )
    (resp === nothing || resp.status != 200) && return (nothing, Dict{String,Any}())
    try
        obj = _to_plain(JSON3.read(resp.body))
        results = get(obj, "results", nothing)
        results isa AbstractVector || return (nothing, Dict{String,Any}())
        isempty(results) && return (nothing, Dict{String,Any}())
        first_record = results[1]
        first_record isa AbstractDict || return (nothing, Dict{String,Any}())
        bib = get(first_record, "bibjson", nothing)
        bib isa AbstractDict || return (nothing, Dict{String,Any}())
        pdf = _doaj_pdf_link(bib)
        meta = _doaj_to_crossref_shape(bib)
        return (pdf, meta)
    catch e
        @debug "doaj_lookup: JSON parse failed" doi exception=e
        return (nothing, Dict{String,Any}())
    end
end
