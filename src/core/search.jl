"""
    SearchMatch

One row in the result of [`search_entries`](@ref) — the hit's normalized key,
its status/title/year/group for display, which fields contained the query,
and a ±40-char snippet around the first match for context.
"""
struct SearchMatch
    key::String
    status::String
    title::String
    year::String
    group::String
    matched_fields::Vector{Symbol}
    snippet::String
end

const _SEARCHABLE_FIELDS = (:title, :authors, :abstract, :journal, :key)

# Extract a ±window-char window around the first occurrence of `needle` (case-
# insensitive). Returns an empty string when `needle` isn't in `hay`.
function _snippet(hay::AbstractString, needle::AbstractString; window::Int=40)
    isempty(needle) && return ""
    lo_h = lowercase(hay)
    lo_n = lowercase(needle)
    idx = findfirst(lo_n, lo_h)
    idx === nothing && return ""
    start = max(firstindex(hay), prevind(hay, first(idx), window))
    stop = min(lastindex(hay), nextind(hay, last(idx), window))
    prefix = start == firstindex(hay) ? "" : "…"
    suffix = stop == lastindex(hay) ? "" : "…"
    return string(prefix, hay[start:stop], suffix)
end

function _field_haystack(md::AbstractDict, field::Symbol)
    if field === :authors
        v = get(md, "authors", String[])
        v isa AbstractVector ? join(String.(v), ", ") : String(v)
    elseif field === :year
        y = get(md, "year", "")
        y isa Integer ? string(y) : String(y)
    else
        String(get(md, String(field), ""))
    end
end

"""
    search_entries(store, query; fields, group, status, case_sensitive)
        -> Vector{SearchMatch}

Substring-search the store's metadata. By default matches in any of
`title` / `authors` / `abstract` / `journal` / `key`; override with `fields`.

  * `query`          — the text to search for (empty ⇒ every entry, useful
                       with filters).
  * `fields`         — tuple / vector of `Symbol` field names to match against.
  * `group`          — optional group-prefix filter (empty ⇒ all groups).
  * `status`         — optional exact-match filter (`"ok"` / `"failed"` /
                       `"pending"`).
  * `case_sensitive` — default `false`.

Results are sorted by number of matched fields (desc), key (asc). A paper is
returned at most once even if multiple fields hit.
"""
function search_entries(
    store::Store,
    query::AbstractString;
    fields=_SEARCHABLE_FIELDS,
    group::AbstractString="",
    status::AbstractString="",
    case_sensitive::Bool=false,
)
    q_raw = String(query)
    q = case_sensitive ? q_raw : lowercase(q_raw)
    group_filter = _normalize_group(group)
    fields = Tuple(Symbol.(fields))

    results = SearchMatch[]
    for safekey in list_entries(store)
        p = joinpath(store.root, METADATA_DIRNAME, safekey * ".toml")
        md = try
            TOML.parsefile(p)
        catch
            continue
        end
        key_norm = String(get(md, "key", ""))
        isempty(key_norm) && continue

        # filters
        if !isempty(status) && String(get(md, "status", "")) != status
            continue
        end
        g = String(get(md, "group", ""))
        if !isempty(group_filter) &&
            !(g == group_filter || startswith(g, group_filter * "/"))
            continue
        end

        # find which fields hit the query
        matched = Symbol[]
        snippet = ""
        for f in fields
            hay_raw = _field_haystack(md, f)
            isempty(hay_raw) && continue
            hay = case_sensitive ? hay_raw : lowercase(hay_raw)
            if isempty(q) || occursin(q, hay)
                push!(matched, f)
                isempty(snippet) && (snippet = _snippet(hay_raw, q_raw))
            end
        end

        (isempty(matched) && !isempty(q)) && continue

        y = get(md, "year", "")
        push!(
            results,
            SearchMatch(
                key_norm,
                String(get(md, "status", "")),
                String(get(md, "title", "")),
                y isa Integer ? string(y) : String(y),
                g,
                matched,
                snippet,
            ),
        )
    end

    sort!(results; by=m -> (-length(m.matched_fields), m.key))
    return results
end

function Base.show(io::IO, ::MIME"text/plain", ms::AbstractVector{SearchMatch})
    if isempty(ms)
        println(io, "(no matches)")
        return
    end
    println(io, length(ms), " match(es):")
    for m in ms
        mark = m.status == "ok" ? "✓" :
               m.status == "pending" ? "…" :
               m.status == "failed" ? "✗" : "?"
        yr = isempty(m.year) ? "" : " ($(m.year))"
        gr = isempty(m.group) ? "" : "   group: $(m.group)"
        fields_str = join(string.(m.matched_fields), ", ")
        println(io, "  ", mark, " ", m.key, yr)
        isempty(m.title) || println(io, "      title: ", _truncate_for_show(m.title, 90))
        println(io, "      matched in: ", fields_str, gr)
        isempty(m.snippet) || println(io, "      …", m.snippet, "…")
    end
end

# Local helper — name distinct from cli.jl's _truncate to avoid conflict.
function _truncate_for_show(s::AbstractString, n::Int)
    length(s) <= n ? String(s) : String(s[1:(n - 1)]) * "…"
end
