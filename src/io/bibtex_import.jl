# ---------- BibTeX import ----------
#
# Goes the other direction of `write_bibtex`: read an existing `.bib` and
# pull out anything that normalizes to a DOI or arXiv id, then queue those
# into the store. Useful when a user already has a LaTeX project with a
# bibliography they want BiblioFetch to manage.
#
# This is deliberately a lightweight regex-based parser, not a full BibTeX
# implementation. We don't care about entry types, authors, titles — only
# fields that yield a downloadable identifier: `doi`, `eprint` (with
# `archivePrefix = arXiv`), or a `url` pointing at `doi.org` / `arxiv.org`.
# That keeps us dep-free and unsurprising.

"""
    BibEntry

One entry scanned out of a `.bib` file — type, citekey, and a flattened
field map. Field keys are lowercased; field values are stripped of their
`{…}` / `"…"` wrapper but not of nested LaTeX braces (which almost never
appear in the identifier fields we care about).
"""
struct BibEntry
    type::String
    citekey::String
    fields::Dict{String,String}
end

"""
    parse_bibtex(text) -> Vector{BibEntry}

Walk a BibTeX source string and collect every `@TYPE{key, fields…}` entry.
Top-level brace balancing is manual (so nested `{…}` inside field values
don't confuse the scanner); individual field extraction uses regex that
tolerates single-level braces, which covers every real `doi` / `eprint` /
`url` value.

Entries that fail to parse (malformed headers, unbalanced braces, etc.)
are skipped silently — a single broken entry shouldn't abort the whole
import.
"""
function parse_bibtex(text::AbstractString)
    text = String(text)
    entries = BibEntry[]
    i = firstindex(text)
    n = lastindex(text)
    while i <= n
        at = findnext('@', text, i)
        at === nothing && break
        # Find '{' after '@type'
        ob = findnext('{', text, at)
        ob === nothing && break
        # Match balanced braces starting at ob
        depth = 1
        p = nextind(text, ob)
        while p <= n && depth > 0
            c = text[p]
            if c == '{'
                depth += 1
            elseif c == '}'
                depth -= 1
            end
            depth == 0 && break
            p = nextind(text, p)
        end
        p > n && break
        entry_text = text[at:p]
        parsed = _parse_bib_entry(entry_text)
        parsed === nothing || push!(entries, parsed)
        i = nextind(text, p)
    end
    return entries
end

# Parse a single `@type{citekey, f1 = v1, f2 = v2}` blob.
function _parse_bib_entry(s::AbstractString)
    m = match(r"^@(\w+)\s*\{\s*([^,\s]+)\s*,(.*)\}\s*$"s, String(s))
    m === nothing && return nothing
    etype = lowercase(String(m.captures[1]))
    citekey = String(m.captures[2])
    body = String(m.captures[3])
    fields = Dict{String,String}()
    # field = {value} or field = "value" or field = bareword
    # Tolerate one level of nested `{…}` inside the value (common in names).
    re = r"(\w+)\s*=\s*(?:\{((?:[^{}]|\{[^{}]*\})*)\}|\"([^\"]*)\"|(\w+))"s
    for fm in eachmatch(re, body)
        name = lowercase(String(fm.captures[1]))
        val_raw = if fm.captures[2] !== nothing
            String(fm.captures[2])
        elseif fm.captures[3] !== nothing
            String(fm.captures[3])
        else
            String(fm.captures[4])
        end
        fields[name] = strip(val_raw)
    end
    return BibEntry(etype, citekey, fields)
end

"""
    bibentry_to_ref(entry) -> String | Nothing

Derive the identifier BiblioFetch should queue for a bib entry. Checks, in
order:

  1. `doi`            → return the DOI as-is (will be normalized downstream)
  2. `eprint`         → if `archivePrefix` is `arxiv` or absent, return
                        `arxiv:<eprint>`
  3. `url`            → if it's a `doi.org/…` or `arxiv.org/abs/…` URL,
                        return the extracted identifier

Returns `nothing` when nothing usable is found (e.g. an entry with only a
title and unstructured publisher).
"""
function bibentry_to_ref(entry::BibEntry)
    f = entry.fields
    if haskey(f, "doi")
        v = strip(f["doi"])
        isempty(v) || return v
    end
    if haskey(f, "eprint")
        v = strip(f["eprint"])
        archive = lowercase(get(f, "archiveprefix", ""))
        if !isempty(v) && (isempty(archive) || archive == "arxiv")
            return "arxiv:" * v
        end
    end
    if haskey(f, "url")
        u = strip(f["url"])
        if occursin(r"doi\.org/"i, u)
            m = match(r"doi\.org/(.+?)$"i, u)
            m === nothing || return strip(String(m.captures[1]))
        elseif occursin(r"arxiv\.org/abs/"i, u)
            m = match(r"arxiv\.org/abs/(.+?)$"i, u)
            m === nothing || return "arxiv:" * strip(String(m.captures[1]))
        end
    end
    return nothing
end

"""
    import_bib!(store, path) -> (added, skipped)

Parse `path` as a BibTeX file and queue every entry that yields a
recognizable DOI or arXiv id into `store`. Returns:

  * `added::Vector{NamedTuple{(:citekey, :ref, :key)}}` — entries
    successfully queued. `citekey` is the BibTeX citekey, `ref` is what we
    extracted, `key` is the normalized store key.
  * `skipped::Vector{NamedTuple{(:citekey, :reason)}}` — entries rejected
    either because no usable identifier was found or because normalization
    of the extracted string failed.

Duplicate refs already in the store are treated as success (queued = idempotent).
"""
function import_bib!(store::Store, path::AbstractString)
    isfile(path) || throw(ArgumentError("import_bib!: file not found: $(path)"))
    text = read(path, String)
    entries = parse_bibtex(text)
    added = NamedTuple{(:citekey, :ref, :key),Tuple{String,String,String}}[]
    skipped = NamedTuple{(:citekey, :reason),Tuple{String,String}}[]
    for e in entries
        ref = bibentry_to_ref(e)
        if ref === nothing
            push!(skipped, (; citekey=e.citekey, reason="no doi / eprint / url"))
            continue
        end
        try
            key = queue_reference!(store, ref)
            push!(added, (; citekey=e.citekey, ref=String(ref), key=key))
        catch err
            push!(skipped, (; citekey=e.citekey, reason=sprint(showerror, err)))
        end
    end
    return (added=added, skipped=skipped)
end
