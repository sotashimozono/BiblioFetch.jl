"""
    FetchEntry

One reference pulled from a job file: normalized key, assigned group, and (after
running) its fetch status and per-source attempt log.
"""
mutable struct FetchEntry
    key::String
    group::String
    raw::String                         # as written in the TOML (for error msgs)
    depth::Int                          # 0 = user-listed; incremented per citation hop
    referenced_by::String               # parent key that queued us; "" for user-listed
    status::Symbol                      # :pending | :ok | :failed | :skipped | :duplicate
    source::Symbol                      # :unpaywall | :arxiv | :direct | :cached | :none
    pdf_path::Union{String,Nothing}
    attempts::Vector{AttemptLog}
    fetched_at::Union{Dates.DateTime,Nothing}
    error::Union{String,Nothing}
end

function FetchEntry(key, group, raw; depth::Int=0, referenced_by::AbstractString="")
    return FetchEntry(
        key,
        group,
        raw,
        depth,
        String(referenced_by),
        :pending,
        :none,
        nothing,
        AttemptLog[],
        nothing,
        nothing,
    )
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
    # source_policy: :strict keeps only PUBLISHER_SOURCES (and publisher-
    # hosted Unpaywall); :lenient is the historical everything-goes default.
    source_policy::Symbol
    # on_fail: what happens when a reference fails all candidates.
    #   :pending — status=:pending, sync retries it later. Default.
    #   :skip    — status=:skipped, excluded from sync's retry set.
    #   :error   — abort the whole run after the current batch finishes.
    on_fail::Symbol
    # also_arxiv: when true, `fetch_paper!` does a second pass for each
    # primary-successful ref whose source wasn't already `:arxiv` and
    # fetches the arXiv preprint into `<key>__preprint.pdf` alongside the
    # publisher PDF. Records `preprint_*` fields in the entry's metadata
    # TOML. Skipped silently when no arXiv id is discoverable.
    also_arxiv::Bool
    # citation graph expansion
    follow_references::Bool          # [graph].follow_references, default false
    max_depth::Int                   # [graph].max_depth (hops from seed), default 1
    max_refs_per_paper::Int          # [graph].max_refs_per_paper, default 50
    #
    refs::Vector{FetchEntry}       # status=:pending at load
    duplicates::Vector{NTuple{3,String}} # (key, kept_group, rejected_group)
    # vault topics to inherit refs from (resolved lazily by vault.jl)
    inherit_topics::Vector{String}
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
    # Relative `target` paths resolve against the job file's directory, not
    # `pwd()` — so `bibliofetch run /elsewhere/job.toml` from any cwd puts
    # PDFs next to the job file. Absolute and `~`-prefixed paths are
    # honored verbatim. This matches Cargo / npm / tox / pre-commit, and
    # fixes the footgun where running from the repo root scattered output
    # into the repo.
    target = let t = expanduser(String(target_raw))
        isabspath(t) ? t : normpath(joinpath(dirname(abspath(path)), t))
    end

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
        sym in KNOWN_SOURCES ||
            throw(ArgumentError("unknown source '$(s)'; allowed: $(KNOWN_SOURCES)"))
        push!(sources, sym)
    end
    isempty(sources) && throw(ArgumentError("[fetch].sources may not be empty"))

    strict = Bool(get(fetch, "strict_duplicates", false))

    # source_policy + on_fail — both default to the historical behavior
    # (lenient cascade, deferred entries go to :pending).
    source_policy = let sp = String(get(fetch, "source_policy", "lenient"))
        sym = Symbol(sp)
        sym in KNOWN_SOURCE_POLICIES || throw(
            ArgumentError(
                "[fetch].source_policy '$(sp)' is unknown; allowed: $(KNOWN_SOURCE_POLICIES)",
            ),
        )
        sym
    end
    on_fail = let of = String(get(fetch, "on_fail", "pending"))
        sym = Symbol(of)
        sym in KNOWN_ON_FAIL_POLICIES || throw(
            ArgumentError(
                "[fetch].on_fail '$(of)' is unknown; allowed: $(KNOWN_ON_FAIL_POLICIES)",
            ),
        )
        sym
    end
    also_arxiv = Bool(get(fetch, "also_arxiv", false))

    # citation graph config
    graphsec = get(cfg, "graph", Dict{String,Any}())
    follow_references = Bool(get(graphsec, "follow_references", false))
    max_depth = Int(get(graphsec, "max_depth", 1))
    max_refs_per_paper = Int(get(graphsec, "max_refs_per_paper", 50))
    max_depth < 0 && throw(ArgumentError("[graph].max_depth must be >= 0"))
    max_refs_per_paper < 1 &&
        throw(ArgumentError("[graph].max_refs_per_paper must be >= 1"))

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

    # [vault] inherit = ["topic-name", …] — stored for later expansion by vault.jl
    vaultsec = get(cfg, "vault", Dict{String,Any}())
    inherit_topics = String.(get(vaultsec, "inherit", String[]))

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
        source_policy,
        on_fail,
        also_arxiv,
        follow_references,
        max_depth,
        max_refs_per_paper,
        refs,
        dups,
        inherit_topics,
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
    # arXiv version-spec pseudo-refs (`arxiv:<id>@all` / `@v1,v3`) live in
    # `job.refs` with their `@…` suffix intact. Expand them in-place into
    # one FetchEntry per version before the first batch runs, so the
    # downstream fetch loop only sees normal single-ref entries. The
    # expansion hits arxiv.org once per @-spec for the `@all` case.
    entries = _expand_arxiv_version_specs(job.refs, rt_job, logio, verbose)
    _run_batch!(entries, store, rt_job, job, logio, verbose)

    # on_fail=:error — throw after the seed batch if any ref didn't make
    # it, before graph expansion runs. In-flight parallel workers have
    # already settled because `_run_batch!` joins on the task group.
    _maybe_abort_on_fail(entries, job, logio)

    # Citation-graph expansion: after the seed layer completes, read each
    # successfully-fetched entry's recorded `referenced_dois` and queue any
    # previously-unseen ones as depth-d+1 entries. Each hop is a fresh fetch
    # round, so the expansion respects `parallel`, `force`, and `sources`.
    if job.follow_references && job.max_depth >= 1
        seen_keys = Set(e.key for e in entries)
        for d in 0:(job.max_depth - 1)
            new_entries = _collect_references(store, entries, seen_keys, d, job)
            isempty(new_entries) && break
            _logln(
                logio,
                "expand  depth=$(d + 1)  new_refs=$(length(new_entries))  from_parents=$(count(e -> e.depth == d && e.status === :ok, entries))",
            )
            _run_batch!(new_entries, store, rt_job, job, logio, verbose)
            append!(entries, new_entries)
            for e in new_entries
                push!(seen_keys, e.key)
            end
            # Re-check between expansion layers too.
            _maybe_abort_on_fail(entries, job, logio)
        end
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

function _run_batch!(entries, store, rt_job, job, logio, verbose)
    if job.parallel > 1
        _run_parallel!(entries, store, rt_job, job, logio, verbose)
    else
        _run_sequential!(entries, store, rt_job, job, logio, verbose)
    end
end

# Walk already-fetched entries at depth `d` and collect the next layer of
# references that aren't already in the store/job. Children inherit their
# parent's group and `referenced_by` points back at the parent's key.
function _collect_references(store, entries, seen_keys, d::Int, job::FetchJob)
    new_entries = FetchEntry[]
    for e in entries
        (e.depth == d && e.status === :ok) || continue
        md = read_metadata(store, e.key)
        refs = get(md, "referenced_dois", nothing)
        refs isa AbstractVector || continue
        n = 0
        for ref_raw in refs
            n >= job.max_refs_per_paper && break
            key = try
                normalize_key(String(ref_raw))
            catch
                continue
            end
            key in seen_keys && continue
            push!(
                new_entries,
                FetchEntry(key, e.group, String(ref_raw); depth=d + 1, referenced_by=e.key),
            )
            push!(seen_keys, key)
            n += 1
        end
    end
    return new_entries
end

# Expand any `arxiv:<id>@all` / `arxiv:<id>@v1,v3` pseudo-refs in `refs`
# into one FetchEntry per version. Non-pseudo refs pass through verbatim,
# preserving input order. For `@all` we call `arxiv_latest_version` once per
# pseudo-ref; the entry's base version list (1..latest) is materialized
# into keys of the form `arxiv:<id>v<N>`. Each produced child keeps the
# parent's `group` and copies `raw` as the original `@...` string so the
# provenance stays visible in metadata.
function _expand_arxiv_version_specs(refs, rt, logio, verbose)
    out = FetchEntry[]
    for e in refs
        if !occursin('@', e.key)
            push!(out, e)
            continue
        end
        base_key, spec = try
            parse_arxiv_version_spec(e.key)
        catch err
            _logln(
                logio,
                "skip invalid version-spec ref $(e.key): $(sprint(showerror, err))",
            )
            continue
        end
        # `base_key` is `arxiv:<id>`; strip the prefix for API / URL building.
        id = startswith(base_key, "arxiv:") ? base_key[7:end] : base_key
        versions = if spec === :all
            verbose && @info "→ arXiv version discovery" id
            vs = arxiv_list_versions(id; proxy=rt.proxy)
            if isempty(vs)
                _logln(logio, "version discovery failed for $(e.key) — skipping")
                Int[]
            else
                vs
            end
        else
            spec::Vector{Int}
        end
        for n in versions
            versioned_key = base_key * "v" * string(n)
            child = FetchEntry(
                versioned_key, e.group, e.raw; depth=e.depth, referenced_by=e.referenced_by
            )
            push!(out, child)
        end
        _logln(
            logio,
            "expand  @-spec  $(e.key) → $(length(versions)) version(s): " *
            (isempty(versions) ? "-" : join(("v" * string(n) for n in versions), ", ")),
        )
    end
    return out
end

# on_fail=:error raises after a batch settles so we don't leak running
# tasks mid-loop. `:failed` and `:pending` both count as non-success here —
# if the user asked to abort on failure, a deferred ref is just as bad.
function _maybe_abort_on_fail(entries, job, logio)
    job.on_fail === :error || return nothing
    bad = filter(e -> e.status in (:failed, :pending), entries)
    isempty(bad) && return nothing
    msg = "run aborted (on_fail=error): $(length(bad)) ref(s) did not succeed — first: $(bad[1].key) [$(bad[1].status)]"
    _logln(logio, msg)
    throw(ErrorException(msg))
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
            source_policy=job.source_policy,
            also_arxiv=job.also_arxiv,
            verbose=verbose,
        )
    catch err
        msg = "exception: " * sprint(showerror, err)
        FetchResult(e.key, false, :none, nothing, msg, AttemptLog[])
    end
    dt = time() - t0

    # Graph-expanded entries carry depth + parent. Persist these into the
    # per-paper TOML so `bibliofetch info` can render "referenced_by" and so
    # a future `bibliofetch graph` command has something to traverse.
    if e.depth > 0 || !isempty(e.referenced_by)
        md = read_metadata(store, e.key)
        if !isempty(md)
            md["depth"] = e.depth
            md["referenced_by"] = e.referenced_by
            write_metadata!(store, e.key, md)
        end
    end

    e.status = if res.ok
        :ok
    elseif job.on_fail === :skip
        # User-requested "don't retry, don't pile up pending records" —
        # mark the entry skipped so `sync` leaves it alone.
        :skipped
    elseif res.source === :deferred
        :pending   # network was off; sync will retry
    else
        :failed
    end
    # When the entry is skipped, reflect that in the persisted TOML too —
    # otherwise `fetch_paper!` has already written status=:pending or
    # :failed and `sync` would pick it up.
    if e.status === :skipped
        md = read_metadata(store, e.key)
        if !isempty(md)
            md["status"] = "skipped"
            write_metadata!(store, e.key, md)
        end
    end
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
    # :pending = deferred entries (no candidate or all network-level errors).
    # `sync` retries these automatically; distinguishing them from :failed
    # in the summary keeps the one-liner honest — earlier versions printed
    # `(ok=N failed=0)` even when ✗ symbols were rendered for deferred
    # refs. Matches `bibliofetch stats` vocabulary now.
    n_pending = count(e -> e.status === :pending, r.entries)
    summary = if n_fail == 0 && n_pending == 0
        "(ok=$(n_ok) failed=0)"   # backward-compat one-liner on full success
    else
        "(ok=$(n_ok) failed=$(n_fail) pending=$(n_pending))"
    end
    println(io, "BiblioFetch job '", r.job.name, "'")
    println(io, "  target   : ", r.job.target)
    println(io, "  log      : ", r.job.log_file)
    println(io, "  refs     : ", length(r.entries), "  ", summary)
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
