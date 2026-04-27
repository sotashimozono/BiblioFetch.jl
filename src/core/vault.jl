"""
    Vault — topic-based paper collection management

A vault lives at `~/.config/bibliofetch/vault/` (or `BIBLIOFETCH_VAULT`).
Each topic is a TOML file in that directory:

    [topic]
    name  = "MPS Algorithms"
    tags  = ["tensor-network", "dmrg"]
    notes = "Core MPS/DMRG references"

    [doi]
    list = ["arxiv:cond-mat/0407066", "10.1103/RevModPhys.93.045003"]

A `vault.toml` index (optional) pins the shared store path:

    topics = ["mps-algorithms.toml", "dmrg-foundations.toml"]
    store  = "~/papers/vault"
"""

const DEFAULT_VAULT_DIR = joinpath(homedir(), ".config", "bibliofetch", "vault")
const VAULT_INDEX_FILE  = "vault.toml"

"""
    VaultTopic

One topic loaded from a TOML file in the vault directory.
"""
struct VaultTopic
    name::String           # [topic].name or filename stem
    file::String           # absolute path to the .toml
    tags::Vector{String}
    notes::String
    refs::Vector{Tuple{String,String}}  # (raw_ref, group)
end

"""
    VaultIndex

Parsed vault.toml (or a synthetic one from the directory listing).
"""
struct VaultIndex
    dir::String
    store::String
    topic_files::Vector{String}   # filenames (not full paths) in load order
end

function _vault_dir()
    d = get(ENV, "BIBLIOFETCH_VAULT", DEFAULT_VAULT_DIR)
    return expanduser(d)
end

"""
    load_vault_index(dir) -> VaultIndex

Read `vault.toml` if present; otherwise treat every `*.toml` (except
`vault.toml`) in `dir` as a topic file.
"""
function load_vault_index(dir::AbstractString=_vault_dir())
    index_path = joinpath(dir, VAULT_INDEX_FILE)
    cfg = isfile(index_path) ? TOML.parsefile(index_path) : Dict{String,Any}()
    store_raw = get(cfg, "store", joinpath(homedir(), "papers", "vault"))
    store = expanduser(String(store_raw))
    topic_files = if haskey(cfg, "topics")
        String.(cfg["topics"])
    else
        # auto-discover: every *.toml except vault.toml, sorted
        isdir(dir) || return VaultIndex(dir, store, String[])
        sort([f for f in readdir(dir) if endswith(f, ".toml") && f != VAULT_INDEX_FILE])
    end
    return VaultIndex(dir, store, topic_files)
end

"""
    load_topic(path) -> VaultTopic
"""
function load_topic(path::AbstractString)
    isfile(path) || throw(ArgumentError("vault topic not found: $path"))
    cfg = TOML.parsefile(path)
    meta = get(cfg, "topic", Dict{String,Any}())
    stem = splitext(basename(path))[1]
    name = String(get(meta, "name", stem))
    tags = String.(get(meta, "tags", String[]))
    notes = String(get(meta, "notes", ""))
    doisec = get(cfg, "doi", Dict{String,Any}())
    refs = _flatten_doi_groups(doisec, "")
    return VaultTopic(name, path, tags, notes, refs)
end

"""
    list_topics(index) -> Vector{VaultTopic}
"""
function list_topics(index::VaultIndex)
    topics = VaultTopic[]
    for f in index.topic_files
        p = isabspath(f) ? f : joinpath(index.dir, f)
        try
            push!(topics, load_topic(p))
        catch e
            @warn "vault: could not load topic" file=p exception=e
        end
    end
    return topics
end

"""
    topic_refs(topic) -> Vector{String}

Return the normalized keys for all refs in a topic.
"""
function topic_refs(t::VaultTopic)
    keys = String[]
    for (raw, _) in t.refs
        try push!(keys, normalize_key(raw)) catch; end
    end
    return keys
end

"""
    vault_add_ref!(topic_name, raw_ref; dir) -> String

Append `raw_ref` to `[doi].list` in `<dir>/<topic_name>.toml`,
creating the file with an empty [topic] header if it does not exist.
Returns the normalized key.
"""
function vault_add_ref!(
    topic_name::AbstractString,
    raw_ref::AbstractString;
    dir::AbstractString=_vault_dir(),
)
    mkpath(dir)
    fname = endswith(topic_name, ".toml") ? topic_name : topic_name * ".toml"
    path = joinpath(dir, fname)
    key = normalize_key(raw_ref)   # validate before touching disk

    cfg = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
    doisec = get!(cfg, "doi", Dict{String,Any}())
    list = get!(doisec, "list", String[])
    list isa AbstractVector || (list = Any[list])
    # deduplicate
    existing = try [normalize_key(String(r)) for r in list] catch; String[] end
    key in existing && return key
    push!(list, raw_ref)
    doisec["list"] = list
    cfg["doi"] = doisec
    if !haskey(cfg, "topic")
        cfg["topic"] = Dict{String,Any}("name" => replace(topic_name, "-" => " "))
    end
    open(path, "w") do io TOML.print(io, cfg; sorted=true) end
    return key
end

"""
    vault_fetch!(index; topic_name, runtime, verbose) -> Dict{String,FetchJobResult}

Fetch papers for all topics (or a named subset) into `index.store`.
Returns a Dict mapping topic name → FetchJobResult.
"""
function vault_fetch!(
    index::VaultIndex;
    topic_name::Union{String,Nothing}=nothing,
    runtime=nothing,
    verbose::Bool=true,
)
    rt = runtime === nothing ? detect_environment() : runtime
    topics = list_topics(index)
    topic_name === nothing || filter!(t -> t.name == topic_name || splitext(basename(t.file))[1] == topic_name, topics)
    isempty(topics) && throw(ArgumentError("no matching vault topic: $topic_name"))
    results = Dict{String,Any}()
    for t in topics
        isempty(t.refs) && continue
        # Build a synthetic FetchJob for this topic
        entries = FetchEntry[]
        for (raw, group) in t.refs
            key = try normalize_key(raw) catch; continue end
            push!(entries, FetchEntry(key, group, raw))
        end
        job = FetchJob(
            t.name, index.store, nothing,
            joinpath(index.store, METADATA_DIRNAME, "run.log"),
            rt.email, rt.proxy, 1, false,
            collect(DEFAULT_SOURCES), false, :lenient, :pending,
            false, false, 1, 50,
            entries, NTuple{3,String}[], String[],
        )
        result = BiblioFetch.run(job; verbose=verbose, runtime=rt)
        results[t.name] = result
    end
    return results
end

"""
    vault_bib(index; topic_name, out) -> Int

Write a BibTeX file for all vault papers (or one topic). Returns entry count.
"""
function vault_bib(
    index::VaultIndex;
    topic_name::Union{String,Nothing}=nothing,
    out::AbstractString=joinpath(index.store, "vault.bib"),
)
    store = open_store(index.store)
    if topic_name === nothing
        return write_bibtex(store, out)
    end
    # filter to topic keys only
    topics = list_topics(index)
    filter!(t -> t.name == topic_name || splitext(basename(t.file))[1] == topic_name, topics)
    isempty(topics) && throw(ArgumentError("no matching vault topic: $topic_name"))
    wanted = Set{String}()
    for t in topics, (raw, _) in t.refs
        try push!(wanted, normalize_key(raw)) catch; end
    end
    return write_bibtex(store, out; key_filter=wanted)
end

"""
    expand_vault_inherit(job) -> FetchJob

Return a new `FetchJob` with vault refs from `job.inherit_topics` prepended
to `job.refs`. Refs already present in `job.refs` are not duplicated.
"""
function expand_vault_inherit(job::FetchJob)
    isempty(job.inherit_topics) && return job
    index = load_vault_index()
    topics = list_topics(index)
    seen = Dict{String,String}(e.key => e.group for e in job.refs)
    extra = FetchEntry[]
    for tname in job.inherit_topics
        matched = filter(
            t -> t.name == tname || splitext(basename(t.file))[1] == tname,
            topics,
        )
        isempty(matched) && @warn "vault inherit: topic not found" topic=tname
        for t in matched, (raw, g) in t.refs
            key = try normalize_key(raw) catch; continue end
            haskey(seen, key) && continue
            seen[key] = g
            push!(extra, FetchEntry(key, g, raw))
        end
    end
    isempty(extra) && return job
    new_refs = vcat(extra, job.refs)
    return FetchJob(
        job.name, job.target, job.bibtex, job.log_file,
        job.email, job.proxy, job.parallel, job.force,
        job.sources, job.strict_duplicates, job.source_policy, job.on_fail,
        job.also_arxiv, job.follow_references, job.max_depth, job.max_refs_per_paper,
        new_refs, job.duplicates, job.inherit_topics,
    )
end

"""
    vault_search(index, query; fields, case_sensitive) -> Vector{SearchMatch}

Search across all papers in the vault store.
"""
function vault_search(
    index::VaultIndex,
    query::AbstractString;
    fields=BiblioFetch._SEARCHABLE_FIELDS,
    case_sensitive::Bool=false,
)
    store = open_store(index.store)
    return search_entries(store, query; fields=fields, case_sensitive=case_sensitive)
end
