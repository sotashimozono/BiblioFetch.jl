"""
    FetchEntry

One reference pulled from a job file: normalized key, assigned group, and (after
running) its fetch status and per-source attempt log.
"""
mutable struct FetchEntry
    key::String
    group::String
    raw::String                         # as written in the TOML (for error msgs)
    status::Symbol                         # :pending | :ok | :failed | :skipped | :duplicate
    source::Symbol                         # :unpaywall | :arxiv | :direct | :cached | :none
    pdf_path::Union{String,Nothing}
    attempts::Vector{AttemptLog}
    fetched_at::Union{Dates.DateTime,Nothing}
    error::Union{String,Nothing}
end

function FetchEntry(key, group, raw)
    FetchEntry(key, group, raw, :pending, :none, nothing, AttemptLog[], nothing, nothing)
end

"""
    FetchJob

Parsed `bibliofetch.toml` — the list of references to pull, where to put them,
and which sources / concurrency / overwrite policy to use.
"""
struct FetchJob
    name::String
    target::String                   # absolute, expanded
    bibtex::Union{String,Nothing}
    log_file::Union{String,Nothing}
    email::Union{String,Nothing}
    proxy::Union{String,Nothing}    # overrides runtime
    parallel::Int
    force::Bool
    sources::Vector{Symbol}
    strict_duplicates::Bool
    refs::Vector{FetchEntry}       # status=:pending at load
    duplicates::Vector{NTuple{3,String}} # (key, kept_group, rejected_group)
end

"""
    FetchJobResult

Returned by `BiblioFetch.run` — the job plus post-run entries and elapsed time.
"""
struct FetchJobResult
    job::FetchJob
    entries::Vector{FetchEntry}
    elapsed::Float64
end

# ---------- TOML → FetchJob ----------

"""
    load_job(path; runtime = detect_environment()) -> FetchJob

Parse a `bibliofetch.toml` file. Fills in missing `fetch.email` from `runtime`,
flattens `[doi]` groups into `FetchEntry`s, deduplicates keys (lenient by
default), and returns the job without performing any network I/O.
"""
function load_job(path::AbstractString; runtime::Union{Runtime,Nothing}=nothing)
    isfile(path) || throw(ArgumentError("job config not found: $(path)"))
    cfg = TOML.parsefile(path)

    folder = get(cfg, "folder", Dict{String,Any}())
    fetch = get(cfg, "fetch", Dict{String,Any}())
    logsec = get(cfg, "log", Dict{String,Any}())
    jobsec = get(cfg, "job", Dict{String,Any}())
    doisec = get(cfg, "doi", Dict{String,Any}())

    target_raw = get(folder, "target", "")
    isempty(target_raw) && throw(ArgumentError("[folder].target is required in $(path)"))
    target = abspath(expanduser(String(target_raw)))

    # log file path — default into <target>/.metadata/run.log
    log_file = let f = get(logsec, "file", nothing)
        if f === nothing || f == ""
            joinpath(target, METADATA_DIRNAME, "run.log")
        else
            s = String(f)
            isabspath(expanduser(s)) ? expanduser(s) : joinpath(target, expanduser(s))
        end
    end

    bibtex = let b = get(folder, "bibtex", nothing)
        if (b === nothing || b == "")
            nothing
        else
            (
            if isabspath(expanduser(String(b)))
                expanduser(String(b))
            else
                joinpath(target, expanduser(String(b)))
            end
        )
        end
    end

    # email / proxy defaults from runtime
    email = let e = get(fetch, "email", nothing)
        if e === nothing || e == ""
            runtime === nothing ? nothing : runtime.email
        else
            String(e)
        end
    end
    proxy = let p = get(fetch, "proxy", nothing)
        if p === nothing || p == ""
            runtime === nothing ? nothing : runtime.proxy
        else
            String(p)
        end
    end

    parallel = Int(get(fetch, "parallel", 1))
    parallel < 1 && throw(ArgumentError("[fetch].parallel must be >= 1"))
    force = Bool(get(fetch, "force", false))

    sources_raw = get(fetch, "sources", String[String(s) for s in DEFAULT_SOURCES])
    sources = Symbol[]
    for s in sources_raw
        sym = Symbol(String(s))
        sym in DEFAULT_SOURCES ||
            throw(ArgumentError("unknown source '$(s)'; allowed: $(DEFAULT_SOURCES)"))
        push!(sources, sym)
    end
    isempty(sources) && throw(ArgumentError("[fetch].sources may not be empty"))

    strict = Bool(get(fetch, "strict_duplicates", false))

    # ---- flatten refs ----
    raw_entries = _flatten_doi_groups(doisec, "")   # Vector{Tuple{String,String}} (raw, group)

    seen = Dict{String,String}()                     # key → first-seen group
    refs = FetchEntry[]
    dups = NTuple{3,String}[]
    for (raw, g) in raw_entries
        key = try
            normalize_key(raw)
        catch e
            throw(
                ArgumentError(
                    "invalid reference '$(raw)' in group '$(g)': $(sprint(showerror, e))",
                ),
            )
        end
        if haskey(seen, key)
            push!(dups, (key, seen[key], g))
            if strict
                throw(
                    ArgumentError(
                        "duplicate key $(key) in groups '$(seen[key])' and '$(g)' (strict_duplicates = true)",
                    ),
                )
            else
                @warn "same DOI has appeared; keeping first occurrence" key kept=seen[key] rejected=g
            end
            continue
        end
        seen[key] = g
        push!(refs, FetchEntry(key, g, String(raw)))
    end

    name = String(get(jobsec, "name", basename(dirname(abspath(path)))))

    return FetchJob(
        name,
        target,
        bibtex,
        log_file,
        email,
        proxy,
        parallel,
        force,
        sources,
        strict,
        refs,
        dups,
    )
end

# Recursively walk `[doi]` table extracting `list` arrays per group key.
function _flatten_doi_groups(tbl, group_prefix::AbstractString)
    out = Tuple{String,String}[]
    list = get(tbl, "list", nothing)
    if list !== nothing
        isa(list, AbstractVector) ||
            throw(ArgumentError("[doi.$(group_prefix)].list must be an array of strings"))
        for r in list
            push!(out, (String(r), String(group_prefix)))
        end
    end
    # Sort keys so group traversal order is deterministic (TOML parses into an
    # unordered Dict). Lexicographic order also gives the intuitive "first one
    # you listed / earliest alphabetically" behavior for duplicate detection.
    for k in sort!(collect(keys(tbl)))
        k == "list" && continue
        v = tbl[k]
        v isa AbstractDict || continue
        sub = isempty(group_prefix) ? String(k) : string(group_prefix, "/", k)
        append!(out, _flatten_doi_groups(v, sub))
    end
    return out
end

# ---------- run ----------

"""
    BiblioFetch.run(path_or_job; verbose = true) -> FetchJobResult

Execute a job. `path_or_job` may be a path to a `bibliofetch.toml` or an
already-loaded `FetchJob`. Writes PDFs into `job.target/<group>/`, metadata
into `job.target/.metadata/`, and a run log into `job.log_file`.
"""
function run(
    path::AbstractString; verbose::Bool=true, runtime::Union{Runtime,Nothing}=nothing
)
    rt = runtime === nothing ? detect_environment() : runtime
    job = load_job(path; runtime=rt)
    return run(job; verbose=verbose, runtime=rt)
end

function run(job::FetchJob; verbose::Bool=true, runtime::Union{Runtime,Nothing}=nothing)
    rt = runtime === nothing ? detect_environment() : runtime

    # per-job runtime: override email / proxy if job specifies them
    rt_job = Runtime(
        rt.hostname,
        rt.profile,
        job.proxy === nothing ? rt.proxy : job.proxy,
        job.proxy === nothing ? rt.proxy_source : :job,
        rt.reachable,
        rt.store_root,
        job.email === nothing ? rt.email : job.email,
        rt.mode,
        rt.config_path,
    )

    store = open_store(job.target)

    mkpath(dirname(job.log_file))
    logio = open(job.log_file, "a")
    _logln(
        logio,
        "run start job=$(job.name) refs=$(length(job.refs)) mode=$(rt_job.mode) " *
        "proxy=$(rt_job.proxy === nothing ? "-" : rt_job.proxy)",
    )

    t0 = time()
    entries = job.refs
    if job.parallel > 1
        _run_parallel!(entries, store, rt_job, job, logio, verbose)
    else
        _run_sequential!(entries, store, rt_job, job, logio, verbose)
    end
    elapsed = time() - t0

    n_ok = count(e -> e.status === :ok, entries)
    _logln(
        logio,
        "run end   ok=$(n_ok)/$(length(entries)) elapsed=$(round(elapsed; digits = 2))s",
    )

    if job.bibtex !== nothing
        n_bib = write_bibtex(store, job.bibtex)
        _logln(logio, "bibtex written: $(job.bibtex) entries=$(n_bib)")
    end

    close(logio)

    return FetchJobResult(job, entries, elapsed)
end

function _run_sequential!(entries, store, rt, job, logio, verbose)
    for e in entries
        _run_one!(e, store, rt, job, logio, verbose)
    end
end

function _run_parallel!(entries, store, rt, job, logio, verbose)
    # bounded concurrency via a counting semaphore; tasks are IO-bound.
    sem = Base.Semaphore(job.parallel)
    lock = ReentrantLock()
    @sync for e in entries
        Base.acquire(sem)
        @async try
            _run_one!(e, store, rt, job, logio, verbose; lock=lock)
        finally
            Base.release(sem)
        end
    end
end

function _run_one!(
    e::FetchEntry,
    store,
    rt,
    job,
    logio,
    verbose;
    lock::Union{ReentrantLock,Nothing}=nothing,
)
    t0 = time()
    res = try
        fetch_paper!(
            store,
            e.key;
            rt=rt,
            group=e.group,
            force=job.force,
            sources=job.sources,
            verbose=verbose,
        )
    catch err
        msg = "exception: " * sprint(showerror, err)
        FetchResult(e.key, false, :none, nothing, msg, AttemptLog[])
    end
    dt = time() - t0

    e.status = res.ok ? (res.source === :cached ? :ok : :ok) : :failed
    e.source = res.source
    e.pdf_path = res.pdf_path
    e.attempts = res.attempts
    e.error = res.error
    e.fetched_at = res.ok ? Dates.now() : nothing

    if lock === nothing
        _log_entry(logio, e, dt)
    else
        Base.lock(lock) do ;
            _log_entry(logio, e, dt);
        end
    end
end

function _log_entry(logio, e::FetchEntry, dt)
    if e.status === :ok
        _logln(
            logio,
            "ok    [$(e.source)] $(e.key)  group=$(isempty(e.group) ? "-" : e.group)  $(round(dt; digits=2))s",
        )
    else
        trail = if isempty(e.attempts)
            "no-candidate"
        else
            join(
            (
                "$(a.source)=$(a.ok ? "ok" : (a.error === nothing ? "?" : _short_err(a.error)))"
                for a in e.attempts
            ),
            ", ",
        )
        end
        _logln(logio, "fail  $(e.key)  group=$(isempty(e.group) ? "-" : e.group)  $(trail)")
    end
end

_short_err(s) = length(s) > 80 ? s[1:77] * "..." : s

function _logln(io, msg)
    ts = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    println(io, ts, " ", msg)
    flush(io)
end

# ---------- pretty show ----------

function Base.show(io::IO, ::MIME"text/plain", r::FetchJobResult)
    n_ok = count(e -> e.status === :ok, r.entries)
    n_fail = count(e -> e.status === :failed, r.entries)
    println(io, "BiblioFetch job '", r.job.name, "'")
    println(io, "  target   : ", r.job.target)
    println(io, "  log      : ", r.job.log_file)
    println(io, "  refs     : ", length(r.entries), "  (ok=", n_ok, " failed=", n_fail, ")")
    println(io, "  elapsed  : ", round(r.elapsed; digits=2), "s")
    if !isempty(r.job.duplicates)
        println(io, "  duplicates: ", length(r.job.duplicates), " (first occurrence kept)")
    end
    # group-by-group summary
    groups = Dict{String,Vector{FetchEntry}}()
    for e in r.entries
        push!(get!(groups, e.group, FetchEntry[]), e)
    end
    for g in sort!(collect(keys(groups)))
        gents = groups[g]
        gok = count(e -> e.status === :ok, gents)
        println(io, "  ── ", isempty(g) ? "(root)" : g, "  ", gok, "/", length(gents))
        for e in gents
            mark = e.status === :ok ? "✓" : "✗"
            src = e.status === :ok ? "[" * String(e.source) * "]" : ""
            detail = if e.status === :ok
                ""
            else
                if isempty(e.attempts)
                    "no candidate"
                else
                    join(
                    (
                        "$(a.source):$(a.error === nothing ? "?" : _short_err(a.error))"
                        for a in e.attempts
                    ),
                    " / ",
                )
                end
            end
            print(io, "      ", mark, " ", rpad(e.key, 42), " ", src, " ", detail, "\n")
        end
    end
end
