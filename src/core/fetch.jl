"""
    AttemptLog

One source attempt during a fetch — useful for diagnosing why a key failed.
`retry_count` is the number of retries burned inside this attempt (driven by
`retry_statuses` / exceptions in `_http_get_with_retry`); `retried_statuses`
is the list of HTTP statuses that triggered each retry. `0` inside
`retried_statuses` stands for a pre-server / exception retry (no response
arrived) — the request never reached HTTP. When a source completed on the
first try, `retry_count == 0` and `retried_statuses` is empty.
"""
struct AttemptLog
    source::Symbol                       # :unpaywall | :arxiv | :direct
    url::String
    ok::Bool
    http_status::Union{Int,Nothing}
    error::Union{String,Nothing}
    duration_s::Float64
    retry_count::Int
    retried_statuses::Vector{Int}
end

# Back-compat constructor for the old 6-arg form (no retry info). Used by
# job.jl's dummy AttemptLog[] fill and anywhere we don't have retry data.
function AttemptLog(source, url, ok, http_status, error, duration_s)
    return AttemptLog(source, url, ok, http_status, error, duration_s, 0, Int[])
end

"""
    FetchResult

Outcome of `fetch_paper!` on a single reference.

`source` is the *successful* route when `ok == true` (`:unpaywall` / `:arxiv`
/ `:direct` / `:cached`). When `ok == false` it encodes the *failure kind*:

  * `:none`     — tried, got real HTTP responses, nothing worked (paywall /
                  404 / landing page). A retry won't help until the world
                  changes.
  * `:deferred` — either no candidates could even be generated or every
                  attempt was a connection-level error. Likely cause: the
                  network / relevant API is down right now. `sync` will
                  retry these.
"""
struct FetchResult
    key::String
    ok::Bool
    source::Symbol
    pdf_path::Union{String,Nothing}
    error::Union{String,Nothing}
    attempts::Vector{AttemptLog}
end

# Sources enabled by default when a job doesn't specify `[fetch].sources`.
# `:s2` is opt-in because its rate limits are aggressive without an API key;
# adding it to a job is a two-keystroke job-file edit.
const DEFAULT_SOURCES = (:unpaywall, :arxiv, :direct)
# `:aps` = APS Harvest TDM API (needs Bearer token in APS_API_KEY).
# Like `:s2` it's opt-in; users who have institutional APS access turn it on
# in their job's `[fetch].sources`.
const KNOWN_SOURCES = (
    :unpaywall, :arxiv, :direct, :s2, :aps, :elsevier, :springer, :openalex, :doaj
)

# Source classification used by `source_policy`:
#
#   * PUBLISHER_SOURCES = routes that deliver the version-of-record. When
#     source_policy is :strict, only these are allowed to produce candidates.
#     `:unpaywall` is special — the Unpaywall API returns either a publisher-
#     hosted PDF (host_type = "publisher") or a repository preprint
#     (host_type = "repository"). In strict mode the candidate is only kept
#     when host_type is "publisher"; see the Unpaywall branch in fetch_paper!
#     for the gating.
#
#   * PREPRINT_SOURCES = routes that deliver preprints / aggregated copies.
#     Never produces a "strict" success; excluded outright in strict mode.
const PUBLISHER_SOURCES = (:unpaywall, :aps, :elsevier, :springer, :openalex, :doaj, :direct)
const PREPRINT_SOURCES = (:arxiv, :s2)

# source_policy: which sources count as a "true-source" fetch.
#   :strict   — only PUBLISHER_SOURCES (and unpaywall with host_type == "publisher")
#   :lenient  — any configured source. Current historical default.
const KNOWN_SOURCE_POLICIES = (:strict, :lenient)

# on_fail: what to do when a reference ends the cascade with no success.
#   :pending  — record status=:pending, `sync` retries it later. Default.
#   :skip     — record status=:skipped; excluded from sync's retry set.
#   :error    — throw after the run loop, exit code non-zero.
const KNOWN_ON_FAIL_POLICIES = (:pending, :skip, :error)

# Compute a hex-encoded SHA-256 of a file's byte stream. Used to dedup PDFs
# that arrive via multiple DOI aliases (arxiv preprint DOI vs journal DOI).
function _sha256_file(path::AbstractString)
    ctx = SHA.SHA2_256_CTX()
    open(path, "r") do io
        buf = Vector{UInt8}(undef, 64 * 1024)
        while !eof(io)
            n = readbytes!(io, buf)
            SHA.update!(ctx, view(buf, 1:n))
        end
    end
    return bytes2hex(SHA.digest!(ctx))
end

# ---- PDF download helpers ----

function _looks_like_pdf(path::AbstractString)
    filesize(path) > 1024 || return false
    open(path, "r") do io
        header = read(io, 5)
        return length(header) >= 4 && header[1:4] == UInt8[0x25, 0x50, 0x44, 0x46]  # "%PDF"
    end
end

# Per-source authentication headers (empty for sources that need none).
# Separated from candidate construction so the fetch loop can always treat
# candidates as (source, url) pairs.
function _source_extra_headers(source::Symbol)
    if source === :aps
        h = aps_tdm_auth_header()
        return h === nothing ? Pair{String,String}[] : Pair{String,String}[h]
    elseif source === :elsevier
        return elsevier_tdm_auth_headers()
    end
    return Pair{String,String}[]
end

# HTTP.jl-based streaming PDF downloader. Returns a NamedTuple with enough
# info for AttemptLog. Unlike the buffered `_http_get_with_retry` (which is
# fine for small JSON / XML metadata bodies), this path uses `HTTP.open` so
# the PDF is written directly to the temp file in fixed-size chunks. A
# Springer book chapter or APS supplemental can be hundreds of MB; buffering
# `resp.body` would hold the whole thing in RAM. Memory profile here is
# bounded by the stream chunk size regardless of file size.
#
# Mirrors the retry / Retry-After / status semantics of `_http_get_with_retry`
# rather than calling it — kept inline so the streaming write happens inside
# the `HTTP.open` block while the connection is still live.
function _http_download_pdf(
    url::AbstractString,
    dest::AbstractString;
    proxy=nothing,
    timeout=60,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
    extra_headers::AbstractVector{<:Pair}=Pair{String,String}[],
)
    mkpath(dirname(dest))
    tmp = dest * ".part"

    headers = Pair{String,String}[
        "User-Agent" => user_agent(), "Accept" => "application/pdf,*/*"
    ]
    append!(headers, extra_headers)

    retried_statuses = Int[]
    last_err::Union{String,Nothing} = nothing

    for attempt in 0:max_retries
        status::Union{Int,Nothing} = nothing
        retry_after::Union{Float64,Nothing} = nothing
        try
            # status_exception=false so non-2xx returns the response instead
            # of throwing — we want to inspect the status and (for 429/5xx)
            # back off before deciding to give up. retry=false because we
            # implement backoff at this layer.
            open_kwargs = (;
                headers=headers,
                connect_timeout=timeout,
                readtimeout=timeout * 2,
                redirect=true,
                redirect_limit=10,
                status_exception=false,
                retry=false,
            )
            opener = if proxy === nothing
                (f) -> HTTP.open(f, "GET", url; open_kwargs...)
            else
                (f) -> HTTP.open(f, "GET", url; proxy=proxy, open_kwargs...)
            end

            opener() do http
                HTTP.startread(http)
                status = Int(http.message.status)
                if status in DEFAULT_RETRY_STATUSES
                    retry_after = _parse_retry_after(http.message)
                end
                if 200 <= status < 300
                    open(tmp, "w") do io
                        while !eof(http)
                            write(io, readavailable(http))
                        end
                    end
                else
                    # Drain the body so the connection can be released back
                    # to the pool. We don't write it anywhere.
                    while !eof(http)
                        read(http, 8192)
                    end
                end
            end
        catch e
            last_err = sprint(showerror, e)
            isfile(tmp) && rm(tmp; force=true)
            if attempt >= max_retries
                return (
                    ok=false,
                    http_status=nothing,
                    error="http: $(last_err)",
                    retry_count=length(retried_statuses),
                    retried_statuses=retried_statuses,
                )
            end
            push!(retried_statuses, 0)   # 0 = exception / pre-server retry
            sleep_fn(base_delay * 2.0^attempt)
            continue
        end

        # Connection completed cleanly. Decide based on `status` what to do.
        if status === nothing
            # Shouldn't happen — HTTP.open's callback must have run, which
            # sets `status` after startread. Treat as a transport failure.
            isfile(tmp) && rm(tmp; force=true)
            if attempt >= max_retries
                return (
                    ok=false,
                    http_status=nothing,
                    error="http: no status (transport-level)",
                    retry_count=length(retried_statuses),
                    retried_statuses=retried_statuses,
                )
            end
            push!(retried_statuses, 0)
            sleep_fn(base_delay * 2.0^attempt)
            continue
        end

        if status in DEFAULT_RETRY_STATUSES && attempt < max_retries
            isfile(tmp) && rm(tmp; force=true)
            push!(retried_statuses, status)
            delay = retry_after === nothing ? base_delay * 2.0^attempt : retry_after
            sleep_fn(delay)
            continue
        end

        if !(200 <= status < 300)
            isfile(tmp) && rm(tmp; force=true)
            return (
                ok=false,
                http_status=status,
                error="http status $(status)",
                retry_count=length(retried_statuses),
                retried_statuses=retried_statuses,
            )
        end

        if !_looks_like_pdf(tmp)
            isfile(tmp) && rm(tmp; force=true)
            return (
                ok=false,
                http_status=status,
                error="not a PDF (got HTML/landing)",
                retry_count=length(retried_statuses),
                retried_statuses=retried_statuses,
            )
        end

        mv(tmp, dest; force=true)
        return (
            ok=true,
            http_status=status,
            error=nothing,
            retry_count=length(retried_statuses),
            retried_statuses=retried_statuses,
        )
    end

    # Loop fell through without returning — every attempt was a retriable
    # status that exhausted the budget. Surface the last status as an error.
    return (
        ok=false,
        http_status=nothing,
        error=last_err === nothing ? "http: retries exhausted" : "http: $(last_err)",
        retry_count=length(retried_statuses),
        retried_statuses=retried_statuses,
    )
end

# ---- orchestration ----

"""
    fetch_paper!(store, key; rt, group = "", force = false,
                 sources = DEFAULT_SOURCES, source_policy = :lenient,
                 verbose = true) -> FetchResult

Resolve `key` (DOI or `arxiv:…`) and try the configured `sources` in order:

  1. `:unpaywall` → OA PDF (requires `rt.email`)
  2. `:arxiv`     → arXiv preprint (always OA)
  3. `:direct`    → `doi.org/<doi>` through proxy (only when proxy is reachable)

`source_policy` controls which sources are allowed to produce candidates:

  * `:lenient` (default) — every source listed in `sources` is eligible.
  * `:strict`            — only `PUBLISHER_SOURCES` produce candidates;
    preprint routes (`:arxiv`, `:s2`) are silently dropped, and `:unpaywall`
    is only kept when its best_oa_location has `host_type = "publisher"`.

`also_arxiv` (default `false`) — after a successful primary fetch whose
source is not already `:arxiv`, BiblioFetch does a companion download of
the arXiv preprint (if an arXiv id was discovered from Crossref
`relation.has-preprint` or the title-search fallback) into
`preprint_pdf_path(store, key; group)`. Records `preprint_*` fields in
the entry's metadata TOML. Silently no-ops when no arXiv id exists.

The PDF is stored at `pdf_path(store, key; group)` — i.e. in `store.root/<group>/`.
Per-attempt diagnostics are recorded in the returned `FetchResult.attempts`.
"""
function fetch_paper!(
    store::Store,
    key::AbstractString;
    rt::Runtime=detect_environment(probe=false),
    group::AbstractString="",
    force::Bool=false,
    sources=DEFAULT_SOURCES,
    source_policy::Symbol=:lenient,
    also_arxiv::Bool=false,
    verbose::Bool=true,
)
    source_policy in KNOWN_SOURCE_POLICIES || throw(
        ArgumentError(
            "unknown source_policy $(source_policy); allowed: $(KNOWN_SOURCE_POLICIES)"
        ),
    )
    key = normalize_key(key)
    group = _normalize_group(group)
    md = read_metadata(store, key);
    isempty(md) && (md["key"] = key)
    md["group"] = group
    dest = pdf_path(store, key; group=group)

    attempts = AttemptLog[]

    if !force && has_pdf(store, key; group=group)
        md["status"] = "ok"
        md["pdf_path"] = dest
        # Backfill sha256 for entries stored before dedup support existed, so
        # `bibliofetch dedup` can find duplicates without a separate rehash step.
        isempty(String(get(md, "sha256", ""))) && (md["sha256"] = _sha256_file(dest))
        # Cache hit — the primary is already on disk. If also_arxiv is set
        # and the companion preprint isn't yet present, attempt the
        # companion fetch anyway. `cached_source` from md tells us whether
        # to even bother (don't re-fetch the arxiv preprint on top of an
        # arxiv-originated cache hit).
        cached_source = Symbol(get(md, "source", "cached"))
        if also_arxiv && cached_source !== :arxiv
            _maybe_fetch_preprint_companion!(
                store, key, group, md, rt; verbose=verbose, force=force
            )
        end
        write_metadata!(store, key, md)
        return FetchResult(key, true, :cached, dest, nothing, attempts)
    end

    doi = is_doi(key) ? key : nothing
    arxiv = startswith(key, "arxiv:") ? String(chopprefix(key, "arxiv:")) : nothing

    meta = doi === nothing ? Dict{String,Any}() : crossref_lookup(doi; proxy=rt.proxy)
    # DataCite fallback: Crossref doesn't know dataset DOIs (Zenodo, Figshare,
    # institutional DataCite clients). Each DOI has exactly one registration
    # agency, so we never double-hit for a single paper.
    if isempty(meta) && doi !== nothing
        meta = datacite_lookup(doi; proxy=rt.proxy)
    end
    if !isempty(meta)
        md["title"] = string(get(meta, "title", [get(md, "title", "")])[1])
        md["journal"] = string(get(get(meta, "container-title", [""]), 1, ""))
        md["year"] = let dp = get(get(meta, "issued", Dict()), "date-parts", [[nothing]])
            length(dp) >= 1 && length(dp[1]) >= 1 ? dp[1][1] : nothing
        end
        authors = get(meta, "author", [])
        md["authors"] = [
            string(get(a, "given", "")) * " " * string(get(a, "family", "")) for
            a in authors
        ]
        if arxiv === nothing
            ax = arxiv_id_from_crossref(meta)
            ax !== nothing && (md["arxiv_id"]=ax; arxiv=ax)
        end
        # Record citation graph edges. The expansion step in BiblioFetch.run
        # reads this field back to decide which references to queue as new
        # entries.
        refs_out = crossref_references(meta)
        isempty(refs_out) || (md["referenced_dois"] = refs_out)
    end

    # Fallback enrichment: when Crossref gave us nothing but we have an arXiv
    # id (primary arxiv entry, or Crossref `relation.has-preprint` hit),
    # ask the arXiv API for title / authors / year / journal_ref.
    if arxiv !== nothing && isempty(get(md, "title", ""))
        verbose && @info "→ arXiv metadata lookup" arxiv
        ax_meta = arxiv_metadata(arxiv; proxy=rt.proxy)
        if ax_meta !== nothing
            md["title"] = ax_meta.title
            isempty(ax_meta.authors) || (md["authors"] = ax_meta.authors)
            ax_meta.year === nothing || (md["year"] = ax_meta.year)
            ax_meta.journal === nothing || (md["journal"] = ax_meta.journal)
            ax_meta.primary_category === nothing ||
                (md["primary_category"] = ax_meta.primary_category)
        end
    end

    candidates = Tuple{Symbol,String}[]  # (source, url)
    # `want(s)` gates whether the source is even tried at lookup/candidate
    # time. `:strict` source_policy drops preprint routes up front — the
    # network call itself is skipped, not just the candidate pushed.
    want(s) =
        let
            configured = s in sources
            if !configured
                false
            elseif source_policy === :strict && !(s in PUBLISHER_SOURCES)
                false
            else
                true
            end
        end

    # 1) Unpaywall
    if want(:unpaywall) && doi !== nothing && rt.email !== nothing
        verbose && @info "→ Unpaywall lookup" doi
        pdf, upmeta = unpaywall_lookup(doi; email=rt.email, proxy=rt.proxy)
        # Tri-state: only persist `is_oa` when Unpaywall actually returned a
        # value. Omitting the key (vs writing `false`) lets downstream readers
        # use `get(md, "is_oa", missing)` to distinguish "Unpaywall said
        # closed-access" from "Unpaywall couldn't be reached".
        if !isempty(upmeta) && haskey(upmeta, "is_oa")
            md["is_oa"] = upmeta["is_oa"]
        end
        if pdf !== nothing
            # Strict mode: Unpaywall's best_oa_location may be a repository
            # preprint (host_type = "repository"); keep the candidate only
            # when it's explicitly publisher-hosted. An unknown/missing
            # host_type gets rejected under :strict — the whole point of
            # the mode is to refuse ambiguous provenance.
            host_type = let loc = get(upmeta, "best_oa_location", nothing)
                loc === nothing ? "" : String(get(loc, "host_type", ""))
            end
            allow_up = source_policy !== :strict || host_type == "publisher"
            allow_up && push!(candidates, (:unpaywall, pdf))
        end
    end

    # 1b) Semantic Scholar (opt-in; good for abstracts + an alternate OA PDF set)
    if want(:s2) && (doi !== nothing || arxiv !== nothing)
        verbose && @info "→ Semantic Scholar lookup" key
        s2key = arxiv !== nothing ? "arxiv:" * String(arxiv) : String(doi)
        s2 = s2_lookup(s2key; proxy=rt.proxy)
        if !isempty(s2)
            # Abstract is S2's unique contribution to the metadata record —
            # Crossref doesn't include it.
            isempty(String(get(s2, "abstract", ""))) ||
                (md["abstract"] = String(s2["abstract"]))
            # Prefer title / year / journal when we still don't have them
            isempty(get(md, "title", "")) &&
                haskey(s2, "title") &&
                (md["title"] = String(s2["title"]))
            (get(md, "year", nothing) in (nothing, "")) &&
                haskey(s2, "year") &&
                (md["year"] = Int(s2["year"]))
            isempty(String(get(md, "journal", ""))) &&
                haskey(s2, "journal") &&
                (md["journal"] = String(s2["journal"]))
            haskey(s2, "s2_paper_id") && (md["s2_paper_id"] = String(s2["s2_paper_id"]))
            haskey(s2, "oa_pdf_url") && push!(candidates, (:s2, String(s2["oa_pdf_url"])))
            # Citation-graph supplement: S2 carries references for arXiv-only
            # preprints and for publishers whose Crossref records don't include
            # reference lists. Merge with anything already recorded from
            # `crossref_references` (above), dedupe, preserve order.
            if haskey(s2, "references")
                s2_refs = String.(s2["references"])
                existing = String.(get(md, "referenced_dois", String[]))
                merged = copy(existing)
                seen = Set(existing)
                for r in s2_refs
                    r in seen || (push!(merged, r); push!(seen, r))
                end
                isempty(merged) || (md["referenced_dois"] = merged)
            end
        end
    end

    # 1c) OpenAlex (opt-in; metadata superset + alternate OA PDF set)
    if want(:openalex) && (doi !== nothing || arxiv !== nothing)
        verbose && @info "→ OpenAlex lookup" key
        oa_ref = arxiv !== nothing ? "arxiv:$(arxiv)" : "doi:$(doi)"
        pdf, oa_meta = openalex_lookup(oa_ref; mailto=rt.email, proxy=rt.proxy)
        if !isempty(oa_meta)
            # Backfill metadata only if earlier sources didn't already provide it.
            # Mirrors the :s2 branch's pattern: title / year / journal / authors /
            # abstract, each guarded against overwriting non-empty values.
            isempty(get(md, "title", "")) &&
                haskey(oa_meta, "title") &&
                !isempty(oa_meta["title"]) &&
                (md["title"] = string(oa_meta["title"][1]))
            if isempty(String(get(md, "journal", "")))
                ct = get(oa_meta, "container-title", String[])
                isempty(ct) || (md["journal"] = string(ct[1]))
            end
            if get(md, "year", nothing) in (nothing, "")
                dp = get(get(oa_meta, "issued", Dict()), "date-parts", [[nothing]])
                y = length(dp) >= 1 && length(dp[1]) >= 1 ? dp[1][1] : nothing
                y === nothing || (md["year"] = y)
            end
            if isempty(get(md, "authors", String[]))
                authors_oa = get(oa_meta, "author", [])
                if !isempty(authors_oa)
                    md["authors"] = [
                        strip(
                            string(get(a, "given", "")) * " " * string(get(a, "family", ""))
                        ) for a in authors_oa
                    ]
                end
            end
            isempty(String(get(md, "abstract", ""))) &&
                haskey(oa_meta, "abstract") &&
                (md["abstract"] = String(oa_meta["abstract"]))
        end
        pdf === nothing || push!(candidates, (:openalex, pdf))
    end

    # 1d) DOAJ — vetted gold-OA journal index. Surfaces journal-hosted PDFs
    # for smaller / non-English / regional titles Unpaywall doesn't index.
    # Opt-in via `[fetch].sources`.
    if want(:doaj) && doi !== nothing
        verbose && @info "→ DOAJ lookup" doi
        pdf, doaj_meta = doaj_lookup(doi; proxy=rt.proxy)
        if !isempty(doaj_meta)
            isempty(get(md, "title", "")) &&
                !isempty(get(doaj_meta, "title", String[])) &&
                (md["title"] = String(doaj_meta["title"][1]))
            isempty(String(get(md, "journal", ""))) &&
                !isempty(get(doaj_meta, "container-title", String[])) &&
                (md["journal"] = String(doaj_meta["container-title"][1]))
            if get(md, "year", nothing) in (nothing, "")
                dp = get(get(doaj_meta, "issued", Dict()), "date-parts", [[nothing]])
                if length(dp) >= 1 && length(dp[1]) >= 1 && dp[1][1] !== nothing
                    md["year"] = dp[1][1]
                end
            end
            if isempty(get(md, "authors", String[]))
                doaj_authors = get(doaj_meta, "author", Dict{String,Any}[])
                if !isempty(doaj_authors)
                    md["authors"] = [
                        string(get(a, "given", "")) * " " * string(get(a, "family", "")) for
                        a in doaj_authors
                    ]
                end
            end
            isempty(String(get(md, "abstract", ""))) &&
                haskey(doaj_meta, "abstract") &&
                (md["abstract"] = String(doaj_meta["abstract"]))
        end
        pdf === nothing || push!(candidates, (:doaj, pdf))
    end

    # 2) arXiv
    if want(:arxiv)
        if arxiv !== nothing
            push!(candidates, (:arxiv, arxiv_pdf_url(arxiv)))
        elseif doi !== nothing && !isempty(get(md, "title", ""))
            verbose && @info "→ arXiv title search fallback" title=md["title"]
            ax = arxiv_search_by_title(
                string(md["title"]);
                authors=String.(get(md, "authors", String[])),
                proxy=rt.proxy,
            )
            if ax !== nothing
                md["arxiv_id"] = ax
                push!(candidates, (:arxiv, arxiv_pdf_url(ax)))
            end
        end
    end

    # 3) direct landing — only meaningful when proxy is reachable
    if want(:direct) && doi !== nothing && rt.proxy !== nothing && rt.reachable !== false
        push!(candidates, (:direct, doi_landing_url(doi)))
    end

    # 4) APS Harvest TDM — institutional/authenticated access to APS PDFs.
    # Only sensible for 10.1103/* DOIs and only when APS_API_KEY is configured.
    if want(:aps) && doi !== nothing && is_aps_doi(doi) && aps_tdm_auth_header() !== nothing
        push!(candidates, (:aps, aps_tdm_url(doi)))
    end

    # 5) Elsevier TDM — 10.1016/* DOIs routed through api.elsevier.com. Same
    # gating principle as APS: only fires for Elsevier DOIs and only when an
    # API key is configured (else every attempt would 401 and burn quota).
    if want(:elsevier) &&
        doi !== nothing &&
        is_elsevier_doi(doi) &&
        !isempty(elsevier_tdm_auth_headers())
        push!(candidates, (:elsevier, elsevier_tdm_url(doi)))
    end

    # 6) Springer Nature OA — 10.1007/*, 10.1038/*, 10.1186/*, 10.1140/*.
    # Two-step: the OA API gates whether this DOI is actually OA (the Nature
    # portfolio is mixed), and returns the canonical link.springer.com PDF
    # URL on hit. Springer's auth is via `?api_key=` query param on the
    # lookup, so _source_extra_headers stays empty for :springer.
    if want(:springer) &&
        doi !== nothing &&
        is_springer_doi(doi) &&
        _springer_api_key(nothing) !== nothing
        verbose && @info "→ Springer OA lookup" doi
        sp_url, _ = springer_oa_lookup(doi; proxy=rt.proxy)
        sp_url === nothing || push!(candidates, (:springer, sp_url))
    end

    used_source = :none
    for (src, url) in candidates
        verbose && @info "   try $src" url
        t0 = time()
        extra = _source_extra_headers(src)
        r = _http_download_pdf(url, dest; proxy=rt.proxy, extra_headers=extra)
        dt = time() - t0
        push!(
            attempts,
            AttemptLog(
                src,
                url,
                r.ok,
                r.http_status,
                r.error,
                dt,
                r.retry_count,
                r.retried_statuses,
            ),
        )
        if r.ok
            used_source = src
            break
        else
            verbose && @info "     failed: $(r.error)"
        end
    end

    last_err = used_source === :none && !isempty(attempts) ? attempts[end].error : nothing

    if used_source === :none
        # :pending vs :failed split — if we never reached a server at all (no
        # attempts, or every attempt was a connection-level error with no HTTP
        # status), treat it as deferred. `sync` will retry :pending entries
        # automatically next time the network comes back; that's exactly the
        # laptop-at-home → back-to-university flow.
        network_deferred =
            isempty(attempts) || all(a -> a.http_status === nothing, attempts)
        md["status"] = network_deferred ? "pending" : "failed"
        md["error"] = if isempty(candidates)
            "no candidate PDF URL (no reachable source)"
        elseif last_err === nothing
            "unknown"
        else
            last_err
        end
        md["last_attempt_at"] = string(Dates.now())
        md["attempts"] = _attempts_to_dict.(attempts)
        write_metadata!(store, key, md)
        return FetchResult(
            key, false, network_deferred ? :deferred : :none, nothing, md["error"], attempts
        )
    else
        md["status"] = "ok"
        md["source"] = String(used_source)
        md["pdf_path"] = dest
        md["fetched_at"] = string(Dates.now())
        haskey(md, "error") && delete!(md, "error")
        md["attempts"] = _attempts_to_dict.(attempts)
        md["sha256"] = _sha256_file(dest)
        # Companion preprint fetch — only when the primary came from a
        # non-arxiv source. Arxiv-source primaries already *are* the
        # preprint, so a second download would be redundant.
        if also_arxiv && used_source !== :arxiv
            _maybe_fetch_preprint_companion!(
                store, key, group, md, rt; verbose=verbose, force=force
            )
        end
        write_metadata!(store, key, md)
        return FetchResult(key, true, used_source, dest, nothing, attempts)
    end
end

# Download the arXiv preprint companion into preprint_pdf_path. Uses the
# `arxiv_id` already stored in `md` by the primary metadata lookup (or a
# fallback title-search if needed). Mutates `md` with `preprint_pdf` /
# `preprint_sha256` / `preprint_fetched_at` on success, `preprint_error` on
# failure. No-op when no arxiv id can be found — the primary fetch is the
# authoritative outcome; the companion is a best-effort add-on.
function _maybe_fetch_preprint_companion!(
    store::Store,
    key::AbstractString,
    group::AbstractString,
    md::AbstractDict,
    rt::Runtime;
    verbose::Bool=true,
    force::Bool=false,
)
    # Resolve the arxiv id. Priority: (1) already in md (from crossref
    # relation.has-preprint), (2) inferred from key if it's itself arxiv:…,
    # (3) title-search fallback.
    arxiv_id = let ax = String(get(md, "arxiv_id", ""))
        if !isempty(ax)
            ax
        elseif startswith(key, "arxiv:")
            String(chopprefix(key, "arxiv:"))
        elseif !isempty(get(md, "title", ""))
            verbose && @info "→ preprint: arXiv title search" title=md["title"]
            found = arxiv_search_by_title(
                string(md["title"]);
                authors=String.(get(md, "authors", String[])),
                proxy=rt.proxy,
            )
            found === nothing ? "" : String(found)
        else
            ""
        end
    end
    if isempty(arxiv_id)
        # Nothing to fetch — not a failure, just a no-op. Make the
        # provenance visible in metadata so a user running `bibliofetch
        # info` knows the companion flag was honored but had no target.
        md["preprint_status"] = "no-arxiv-id"
        return nothing
    end
    md["arxiv_id"] = arxiv_id

    pp_dest = preprint_pdf_path(store, key; group=group)
    if !force && has_preprint(store, key; group=group)
        md["preprint_pdf"] = pp_dest
        isempty(String(get(md, "preprint_sha256", ""))) &&
            (md["preprint_sha256"] = _sha256_file(pp_dest))
        md["preprint_status"] = "cached"
        return nothing
    end

    url = arxiv_pdf_url(arxiv_id)
    verbose && @info "→ preprint: downloading companion arXiv PDF" url
    r = _http_download_pdf(url, pp_dest; proxy=rt.proxy)
    if r.ok
        md["preprint_pdf"] = pp_dest
        md["preprint_source"] = "arxiv"
        md["preprint_sha256"] = _sha256_file(pp_dest)
        md["preprint_fetched_at"] = string(Dates.now())
        md["preprint_status"] = "ok"
        haskey(md, "preprint_error") && delete!(md, "preprint_error")
    else
        md["preprint_status"] = "failed"
        md["preprint_error"] = r.error === nothing ? "unknown" : String(r.error)
        haskey(md, "preprint_pdf") && delete!(md, "preprint_pdf")
    end
    return nothing
end

function _attempts_to_dict(a::AttemptLog)
    d = Dict{String,Any}(
        "source" => String(a.source),
        "url" => a.url,
        "ok" => a.ok,
        "duration_s" => round(a.duration_s; digits=3),
    )
    a.http_status === nothing || (d["http_status"] = a.http_status)
    a.error === nothing || (d["error"] = a.error)
    # Keep the TOML lean on the common happy path — only serialize retry
    # info when something actually retried.
    if a.retry_count > 0
        d["retry_count"] = a.retry_count
        isempty(a.retried_statuses) || (d["retried_statuses"] = a.retried_statuses)
    end
    return d
end

"""
    sync!(store; rt = detect_environment(), force = false, verbose = true)
        -> Vector{FetchResult}

Walk the store's metadata directory and (re)fetch entries, preserving each
entry's stored `group`.

  * **default** (`force = false`): skip entries that already have `status = "ok"`
    *and* a PDF on disk. Everything else — pending, failed, or status-ok with a
    missing PDF — is fetched. Useful for resuming a partial run.
  * **`force = true`**: every tracked entry is re-downloaded, even ones already
    on disk. `force = true` is propagated to `fetch_paper!`, so its cached
    fast-path is bypassed and the PDF is overwritten.
"""
function sync!(
    store::Store; rt::Runtime=detect_environment(), force::Bool=false, verbose::Bool=true
)
    results = FetchResult[]
    for safekey in list_entries(store)
        p = joinpath(store.root, METADATA_DIRNAME, safekey * ".toml")
        md = TOML.parsefile(p)
        key = get(md, "key", "")
        isempty(key) && continue
        status = get(md, "status", "pending")
        group = String(get(md, "group", ""))
        # Without --force, skip entries that are clearly already done.
        if !force && status == "ok" && has_pdf(store, key; group=group)
            continue
        end
        verbose && @info "syncing" key status group force
        push!(
            results,
            fetch_paper!(store, key; rt=rt, group=group, force=force, verbose=verbose),
        )
    end
    return results
end
