"""
    find_duplicates(store) -> Vector{Pair{String,Vector{String}}}

Scan `store`'s metadata directory and return a list of `sha256 => keys` pairs
for every hash held by more than one entry. Each `keys` vector is sorted
lexicographically, so the canonical (kept) key in dedup operations is
deterministic.

The SHA-256 comes from the `sha256` field written by [`fetch_paper!`](@ref).
Entries whose metadata lacks that field (very old stores, failed fetches,
entries resolved into `duplicate_of`) are skipped.
"""
function find_duplicates(store::Store)
    buckets = Dict{String,Vector{String}}()
    for safekey in list_entries(store)
        p = joinpath(store.root, METADATA_DIRNAME, safekey * ".toml")
        md = try
            TOML.parsefile(p)
        catch
            continue
        end
        key = String(get(md, "key", ""))
        isempty(key) && continue
        # Skip entries that are already resolved duplicates — they point at
        # someone else's PDF; there's nothing to dedup further.
        isempty(String(get(md, "duplicate_of", ""))) || continue
        hash = String(get(md, "sha256", ""))
        isempty(hash) && continue
        push!(get!(buckets, hash, String[]), key)
    end
    out = Pair{String,Vector{String}}[]
    for (h, ks) in buckets
        length(ks) > 1 || continue
        push!(out, h => sort(ks))
    end
    sort!(out; by=p -> first(p.second))  # stable ordering
    return out
end

"""
    resolve_duplicates!(store; apply = false) -> NamedTuple

Walk the duplicate groups reported by [`find_duplicates`](@ref). For each group
keep the lexicographically first key as canonical; the rest are recorded with
`duplicate_of = "<canonical>"` and their `pdf_path` is redirected to the
canonical entry's file. On-disk duplicate PDFs are removed when `apply = true`;
otherwise the function just reports what *would* happen.

Returns `(; groups, bytes_freed, canonicals)` — `groups` is the output of
`find_duplicates`, `bytes_freed` is the size that would be (or was) recovered,
and `canonicals` is a `duplicate_key => canonical_key` map.
"""
function resolve_duplicates!(store::Store; apply::Bool=false)
    groups = find_duplicates(store)
    canonicals = Dict{String,String}()
    bytes_freed = 0

    for (_hash, keys) in groups
        canonical = first(keys)
        canon_md = read_metadata(store, canonical)
        canon_pdf = String(get(canon_md, "pdf_path", ""))
        isfile(canon_pdf) || continue   # canonical's file is gone; nothing to link

        for dup in keys[2:end]
            dup_md = read_metadata(store, dup)
            dup_pdf = String(get(dup_md, "pdf_path", ""))
            if isfile(dup_pdf) && dup_pdf != canon_pdf
                bytes_freed += filesize(dup_pdf)
                apply && rm(dup_pdf; force=true)
            end
            if apply
                dup_md["duplicate_of"] = canonical
                dup_md["pdf_path"] = canon_pdf
                write_metadata!(store, dup, dup_md)
            end
            canonicals[dup] = canonical
        end
    end
    return (groups=groups, bytes_freed=bytes_freed, canonicals=canonicals)
end
