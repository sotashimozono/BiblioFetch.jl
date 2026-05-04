# ---------- OpenAlex ----------
#
# OpenAlex (https://openalex.org/) is a free, open scholarly knowledge graph
# that effectively unions Crossref + Unpaywall + the retired Microsoft Academic
# Graph. From BiblioFetch's perspective it's two things in one:
#
#   * a metadata source — title / authors / journal / year / abstract,
#     reachable by DOI or arXiv id without any auth
#   * an OA-PDF source — surfaces `open_access.oa_url` and
#     `best_oa_location.pdf_url`, which sometimes point at PDFs Unpaywall
#     hasn't indexed yet (newer arXiv preprints in particular)
#
# Endpoint shape:
#   https://api.openalex.org/works/doi:10.1234/foo
#   https://api.openalex.org/works/arxiv:2301.00001
# Add `?mailto=<email>` to land in the polite-pool (faster, more stable).
#
# We translate the OpenAlex JSON into the Crossref-shaped metadata dict the
# `fetch_paper!` extraction already understands — same trick `datacite.jl`
# uses — so no downstream changes are needed.

# Reconstruct an abstract from OpenAlex's `abstract_inverted_index`.
# The index maps each token to the positions where it appears, e.g.
#   {"Recent": [0], "advances": [1], "in": [2, 7], ...}
# Sort by position, then join by space. Returns "" for missing/malformed input.
function _openalex_abstract_from_inverted_index(idx)
    idx isa AbstractDict || return ""
    isempty(idx) && return ""
    pairs_pos = Tuple{Int,String}[]
    for (token, positions) in idx
        positions isa AbstractVector || continue
        tok_str = String(token)
        for p in positions
            pi = p isa Integer ? Int(p) : tryparse(Int, String(p))
            pi === nothing && continue
            push!(pairs_pos, (pi, tok_str))
        end
    end
    isempty(pairs_pos) && return ""
    sort!(pairs_pos; by=first)
    return join((t for (_, t) in pairs_pos), " ")
end

# Split a display name like "Jane Q. Doe" into ("Jane Q.", "Doe"). OpenAlex
# returns full display names rather than separated given/family fields, so
# we use the same heuristic Crossref consumers expect: last whitespace-
# separated token = family, everything before = given. Single-token names
# go into family with empty given (matches DataCite's mononym handling).
function _split_openalex_name(display_name::AbstractString)
    s = strip(String(display_name))
    isempty(s) && return ("", "")
    parts = split(s)
    length(parts) == 1 && return ("", String(parts[1]))
    family = String(parts[end])
    given = strip(join(parts[1:(end - 1)], " "))
    return (String(given), family)
end

# Translate an OpenAlex `work` object into a Crossref-shaped metadata dict.
function _openalex_to_crossref_shape(work::AbstractDict)
    titles = String[]
    t = String(get(work, "title", ""))
    isempty(t) || push!(titles, t)

    container_title = String[]
    primary_loc = get(work, "primary_location", nothing)
    if primary_loc isa AbstractDict
        src = get(primary_loc, "source", nothing)
        if src isa AbstractDict
            disp = String(get(src, "display_name", ""))
            isempty(disp) || push!(container_title, disp)
        end
    end

    authors = Dict{String,Any}[]
    for a in get(work, "authorships", [])
        a isa AbstractDict || continue
        author = get(a, "author", nothing)
        author isa AbstractDict || continue
        disp = String(get(author, "display_name", ""))
        given, family = _split_openalex_name(disp)
        isempty(given) && isempty(family) && continue
        push!(authors, Dict{String,Any}("given" => given, "family" => family))
    end

    year_val = get(work, "publication_year", nothing)
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

    abs_str = _openalex_abstract_from_inverted_index(
        get(work, "abstract_inverted_index", nothing)
    )
    isempty(abs_str) || (out["abstract"] = abs_str)

    return out
end

# Pull an OA PDF URL out of an OpenAlex work, preferring the canonical
# `open_access.oa_url` (which already represents OpenAlex's best pick across
# its locations). Falls back to `best_oa_location.pdf_url` when oa_url is
# missing.
function _openalex_pdf_url(work::AbstractDict)
    oa = get(work, "open_access", nothing)
    if oa isa AbstractDict
        u = get(oa, "oa_url", nothing)
        if u !== nothing
            s = String(u)
            isempty(s) || return s
        end
    end
    best = get(work, "best_oa_location", nothing)
    if best isa AbstractDict
        u = get(best, "pdf_url", nothing)
        if u !== nothing
            s = String(u)
            isempty(s) || return s
        end
    end
    return nothing
end

"""
    openalex_lookup(ref; mailto = nothing, proxy = nothing, timeout = 15,
                    base_url = OPENALEX_URL, max_retries, base_delay)
        -> (oa_pdf_url_or_nothing, metadata_dict)

Look up a work on OpenAlex by DOI or arXiv id. `ref` is the OpenAlex selector
string — either `"doi:<DOI>"` or `"arxiv:<id>"`.

Returns `(pdf_url, metadata)`:

  * `pdf_url` — best OA PDF URL OpenAlex has, or `nothing` when none is
    registered. Sourced from `open_access.oa_url`, falling back to
    `best_oa_location.pdf_url`.
  * `metadata` — Crossref-shaped dict (`title` / `author` / `container-title`
    / `issued` / `abstract`), so it slots straight into the existing
    `fetch_paper!` extraction. Empty `Dict` on hard failure.

`mailto` enables OpenAlex's polite pool — pass `rt.email` here for nicer
rate limits. No auth is needed beyond that.
"""
function openalex_lookup(
    ref::AbstractString;
    mailto=nothing,
    proxy=nothing,
    timeout=15,
    base_url=OPENALEX_URL,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
)
    url = base_url * URIs.escapeuri(String(ref))
    if mailto !== nothing && !isempty(String(mailto))
        url *= "?mailto=" * URIs.escapeuri(String(mailto))
    end
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
        work = _to_plain(JSON3.read(resp.body))
        work isa AbstractDict || return (nothing, Dict{String,Any}())
        meta = _openalex_to_crossref_shape(work)
        return (_openalex_pdf_url(work), meta)
    catch e
        @debug "openalex_lookup: JSON parse failed" ref exception = e
        return (nothing, Dict{String,Any}())
    end
end
