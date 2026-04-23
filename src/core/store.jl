const METADATA_DIRNAME = ".metadata"

"""
    Store(root)

Handle on a BiblioFetch store directory. Holds the root path; all PDF and
metadata paths are derived from it. Construct with [`open_store`](@ref) — the
raw constructor does not create the backing directory layout.
"""
struct Store
    root::String
end

"""
    open_store(root) -> Store

Create (if needed) the store directory layout under `root`:

    <root>/
      <group>/<safekey>.pdf         # PDFs live next to their group subdir
      <safekey>.pdf                 # (or at the root for ungrouped entries)
      .metadata/<safekey>.toml      # one TOML per paper (editable, hidden)
"""
function open_store(root::AbstractString)
    r = expanduser(String(root))
    mkpath(joinpath(r, METADATA_DIRNAME))
    return Store(r)
end

function _safe_key(key::AbstractString)
    # Filesystem-safe slug from a DOI or arxiv id.
    s = replace(String(key), r"[^A-Za-z0-9._:\-/]" => "_")
    s = replace(s, ":" => "__")
    s = replace(s, "/" => "_")
    return s
end

# Normalize a group path: "", "condensed-matter", "condensed-matter/haldane".
# Strips leading/trailing separators, rejects empty segments and absolute paths.
function _normalize_group(group::AbstractString)
    g = strip(String(group), '/')
    isempty(g) && return ""
    segments = split(g, '/'; keepempty=false)
    any(s -> s == ".." || s == ".", segments) &&
        throw(ArgumentError("group path may not contain '.' or '..': $(group)"))
    return join(segments, '/')
end

metadata_path(s::Store, key) = joinpath(s.root, METADATA_DIRNAME, _safe_key(key) * ".toml")

function pdf_path(s::Store, key; group::AbstractString="")
    g = _normalize_group(group)
    dir = isempty(g) ? s.root : joinpath(s.root, g)
    return joinpath(dir, _safe_key(key) * ".pdf")
end

has_metadata(s::Store, key) = isfile(metadata_path(s, key))
has_pdf(s::Store, key; group::AbstractString="") =
    let p = pdf_path(s, key; group=group);
        isfile(p) && filesize(p) > 0
    end

# Locate an existing PDF for `key` regardless of group (for migrations / lookups).
function find_pdf(s::Store, key)
    md = read_metadata(s, key)
    if !isempty(md) && haskey(md, "pdf_path")
        p = String(md["pdf_path"])
        isfile(p) && filesize(p) > 0 && return p
    end
    # fallback: try ungrouped location
    p = pdf_path(s, key)
    isfile(p) && filesize(p) > 0 && return p
    return nothing
end

function read_metadata(s::Store, key)
    p = metadata_path(s, key)
    isfile(p) || return Dict{String,Any}()
    try
        return TOML.parsefile(p)
    catch
        return Dict{String,Any}()
    end
end

function write_metadata!(s::Store, key, md::AbstractDict)
    p = metadata_path(s, key)
    mkpath(dirname(p))
    open(p, "w") do io
        TOML.print(io, _stringify(md); sorted=true)
    end
    return p
end

# TOML.print rejects some JSON3 scalar subtypes; coerce defensively.
function _stringify(x)
    if x isa AbstractDict
        return Dict{String,Any}(String(k) => _stringify(v) for (k, v) in x)
    elseif x isa AbstractVector
        return Any[_stringify(v) for v in x]
    elseif x isa AbstractString
        return String(x)
    elseif x isa Symbol
        return String(x)
    elseif x isa Number || x isa Bool || x isa Dates.AbstractTime
        return x
    elseif x === nothing
        return ""
    else
        return string(x)
    end
end

"""
    list_entries(store) -> Vector{String}

Return the filesystem-safe keys of every paper currently tracked in the store,
sorted alphabetically. These are the stems of files under `<root>/.metadata/`,
not the canonical DOI/arXiv keys (use [`entry_info`](@ref) to get the key).
"""
function list_entries(s::Store)
    dir = joinpath(s.root, METADATA_DIRNAME)
    isdir(dir) || return String[]
    return sort([splitext(f)[1] for f in readdir(dir) if endswith(f, ".toml")])
end

"""
    entry_info(store, key) -> NamedTuple | Nothing

Summary record for one entry — `key`, `title`, `status`, `source`, `group`,
`pdf_path`, `year`. Returns `nothing` when the key has no metadata on disk.
"""
function entry_info(s::Store, key::AbstractString)
    md = read_metadata(s, key)
    isempty(md) && return nothing
    return (
        key=get(md, "key", ""),
        title=get(md, "title", ""),
        status=get(md, "status", "unknown"),
        source=get(md, "source", ""),
        group=get(md, "group", ""),
        pdf_path=get(md, "pdf_path", ""),
        year=get(md, "year", nothing),
    )
end

function queue_reference!(s::Store, raw::AbstractString; group::AbstractString="")
    key = normalize_key(raw)
    md = read_metadata(s, key)
    if isempty(md)
        md["key"] = key
        md["added_at"] = string(Dates.now())
        md["status"] = "pending"
        md["raw"] = String(raw)
        md["group"] = _normalize_group(group)
        write_metadata!(s, key, md)
    end
    return key
end
