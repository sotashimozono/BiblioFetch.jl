# CSL JSON export — sister of io/bibtex.jl. CSL JSON is the format Pandoc,
# Quarto, RMarkdown, Zotero, and Hugo bibliography plugins consume directly,
# so the same store that powers LaTeX (via write_bibtex) now also powers
# Markdown-pipeline workflows. Reference schema:
#   https://github.com/citation-style-language/schema (csl-data.json)

# Split an author string into CSL `{family, given}` parts. Heuristic: the last
# whitespace-separated token is the family name, everything before it is the
# given name. Same spirit as `_surname_ascii` in bibtex.jl, but here we keep
# Unicode intact (CSL processors and JSON consumers handle UTF-8 natively —
# unlike legacy BibTeX, where we ASCII-sanitize for citekey safety).
function _csl_author_parts(name::AbstractString)
    s = strip(String(name))
    isempty(s) && return Dict{String,Any}("family" => "", "given" => "")
    parts = split(s)
    if length(parts) == 1
        return Dict{String,Any}("family" => String(parts[1]))
    end
    family = String(last(parts))
    given = String(strip(join(parts[1:(end - 1)], " ")))
    return Dict{String,Any}("family" => family, "given" => given)
end

"""
    csl_entry(md; id = _bibtex_key(md)) -> Dict{String,Any}

Map one internal metadata TOML dict to a CSL JSON record. The returned
`Dict` is ready to be passed straight to `JSON3.write` as one element of a
CSL JSON array. Empty / missing fields are omitted rather than written as
empty strings — Pandoc/Quarto are happier with absent keys than with
empty ones, and the resulting file stays diffable.

Field mapping:
- `id`              → `_bibtex_key(md)` (same citekey as the BibTeX export)
- `type`            → `"article-journal"` if `md["journal"]` is non-empty,
                      else `"manuscript"` (CSL's term for unpublished /
                      preprint material)
- `title`           → `md["title"]`
- `author`          → `[{family, given}, …]` from `md["authors"]`
- `container-title` → `md["journal"]`
- `issued`          → `{date-parts: [[year]]}`
- `DOI`             → `md["key"]` when it parses as a DOI, else `md["doi"]`
- `URL`             → `https://doi.org/<DOI>` whenever a DOI is present
- `abstract`        → `md["abstract"]` when non-empty
"""
function csl_entry(md::AbstractDict; id::AbstractString=_bibtex_key(md))
    out = Dict{String,Any}("id" => String(id))

    journal = String(get(md, "journal", ""))
    out["type"] = isempty(journal) ? "manuscript" : "article-journal"

    title = String(get(md, "title", ""))
    isempty(title) || (out["title"] = title)

    authors = get(md, "authors", String[])
    if authors isa AbstractVector && !isempty(authors)
        parts = [_csl_author_parts(String(a)) for a in authors]
        # drop entries that ended up entirely empty (e.g., a stray "" in the list)
        parts = [p for p in parts if !isempty(get(p, "family", "")) ||
                                     !isempty(get(p, "given", ""))]
        isempty(parts) || (out["author"] = parts)
    end

    isempty(journal) || (out["container-title"] = journal)

    y = get(md, "year", "")
    year_int = if y isa Integer
        Int(y)
    else
        ys = String(y)
        isempty(ys) ? nothing : tryparse(Int, ys)
    end
    if year_int !== nothing
        out["issued"] = Dict{String,Any}("date-parts" => [[year_int]])
    end

    raw_key = String(get(md, "key", ""))
    doi = is_doi(raw_key) ? raw_key : String(get(md, "doi", ""))
    if !isempty(doi)
        out["DOI"] = doi
        out["URL"] = "https://doi.org/" * doi
    end

    abstract_str = String(get(md, "abstract", ""))
    isempty(abstract_str) || (out["abstract"] = abstract_str)

    return out
end

"""
    write_csl(store, path; key_filter = nothing) -> Int

Iterate every `status = "ok"` entry in the store's `.metadata/`, build a CSL
JSON array, and write it to `path`. Returns the number of entries written.
When `key_filter` is a `Set{String}` of normalized keys only those entries
are included. Citekeys (`id`) are disambiguated with a trailing letter
suffix on collision, mirroring [`write_bibtex`](@ref) so the two exports
stay in sync.
"""
function write_csl(
    store::Store, path::AbstractString; key_filter::Union{Set{String},Nothing}=nothing
)
    mkpath(dirname(path))
    used = Dict{String,Int}()
    entries = Dict{String,Any}[]

    for safekey in list_entries(store)
        p = joinpath(store.root, METADATA_DIRNAME, safekey * ".toml")
        isfile(p) || continue
        md = TOML.parsefile(p)
        get(md, "status", "") == "ok" || continue
        if key_filter !== nothing
            entry_key = String(get(md, "key", ""))
            entry_key in key_filter || continue
        end

        base = _bibtex_key(md)
        seen = get(used, base, 0)
        used[base] = seen + 1
        id = seen == 0 ? base : string(base, Char('a' + seen - 1))

        push!(entries, csl_entry(md; id=id))
    end

    open(path, "w") do io
        JSON3.write(io, entries)
    end
    return length(entries)
end
