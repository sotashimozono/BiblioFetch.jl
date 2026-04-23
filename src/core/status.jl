"""
    ProbeResult

One reachability probe record — which endpoint, did it respond, how fast, what
HTTP status came back. `reachable` treats HTTP 2xx-4xx as reachable (the server
is up, just may or may not have the thing we probed for); 5xx / connection
errors / timeouts are `false`.
"""
struct ProbeResult
    name::Symbol
    url::String
    label::String
    reachable::Bool
    http_status::Union{Int,Nothing}
    duration_s::Float64
    error::Union{String,Nothing}
end

"""
    NetworkStatus

Aggregate of all probe results + the derived `effective_sources` — which of
`(:unpaywall, :arxiv, :direct)` can actually do their job right now.

Useful to distinguish "at the university, full access" from "at home, OA only"
before kicking off a long job, and to gate live-network tests so they skip
cleanly on CI / offline machines.
"""
struct NetworkStatus
    hostname::String
    mode::Symbol
    proxy::Union{String,Nothing}
    probes::Vector{ProbeResult}
    effective_sources::Vector{Symbol}
end

# Probe a single endpoint with a short timeout. HTTP.jl's readtimeout /
# connect_timeout kwargs demand Int64 specifically — passing a Float64 throws
# `TypeError: expected Int64, got Float64` *inside* the request, which is
# caught and presented as "unreachable" with zero elapsed time, which is the
# worst possible diagnostic. So force the conversion here.
function _do_probe(
    name::Symbol, url::AbstractString, label::AbstractString; proxy=nothing, timeout::Real=5
)
    t0 = time()
    to = Int(round(timeout))
    try
        kw = (;
            headers=["User-Agent" => USER_AGENT],
            connect_timeout=to,
            readtimeout=to,
            status_exception=false,
            retry=false,
        )
        resp = proxy === nothing ? HTTP.get(url; kw...) : HTTP.get(url; proxy=proxy, kw...)
        dt = time() - t0
        reachable = 200 <= resp.status < 500
        return ProbeResult(name, url, label, reachable, Int(resp.status), dt, nothing)
    catch e
        dt = time() - t0
        return ProbeResult(name, url, label, false, nothing, dt, sprint(showerror, e))
    end
end

# Default probe set — one dummy request per supported endpoint. 4xx responses
# (e.g. "DOI not found" on a fake probe DOI) still count as reachable, which
# is why this doesn't need to know any real DOIs.
const _STATUS_PROBES = (
    (:crossref, "https://api.crossref.org/works/10.1234/probe", "Crossref metadata"),
    (:datacite, "https://api.datacite.org/dois/10.1234/probe", "DataCite metadata"),
    (
        :unpaywall,
        "https://api.unpaywall.org/v2/10.1234/probe?email=probe@bibliofetch",
        "Unpaywall OA lookup",
    ),
    (:arxiv_api, "http://export.arxiv.org/api/query?max_results=0", "arXiv API"),
    (:arxiv_pdf, "https://arxiv.org/", "arXiv PDF downloads"),
    (:s2, "https://api.semanticscholar.org/graph/v1/paper/DOI:10.1234/probe", "Semantic Scholar"),
    (:doi, "https://doi.org/", "publisher direct (doi.org)"),
)

function _effective_sources(probes::AbstractVector{ProbeResult}, rt::Runtime)
    byname = Dict(p.name => p for p in probes)
    reach(n) = haskey(byname, n) && byname[n].reachable
    out = Symbol[]
    # unpaywall: lookup API reachable AND email configured (API requires it)
    reach(:unpaywall) && rt.email !== nothing && push!(out, :unpaywall)
    # arxiv: both the metadata API and the PDF host must work
    reach(:arxiv_api) && reach(:arxiv_pdf) && push!(out, :arxiv)
    # direct: doi.org always required; when a proxy is configured, also require
    # the proxy be reachable (otherwise paywalled landing pages fail anyway)
    if reach(:doi) && (rt.proxy === nothing || reach(:proxy))
        push!(out, :direct)
    end
    # s2: reachable means the Semantic Scholar API responded; effective even
    # without an API key (public rate limits are slow but real).
    reach(:s2) && push!(out, :s2)
    return out
end

"""
    status(; rt = detect_environment(), timeout = 5.0, probes = _STATUS_PROBES)
        -> NetworkStatus

Probe every supported metadata / PDF endpoint concurrently (`@async` + `fetch`)
and report which ones respond from the current network. Total wall time is
roughly `timeout` plus a small fixed cost, not `#probes × timeout`.

Exposed so user code (and live-network tests) can ask "is Crossref reachable
from here?" before queueing work. The `probes` kwarg is overridable so
integration tests can point it at a local mock server.
"""
function status(;
    rt::Runtime=detect_environment(), timeout::Real=5.0, probes=_STATUS_PROBES
)
    tasks = [
        @async _do_probe(n, u, l; proxy=rt.proxy, timeout=timeout) for (n, u, l) in probes
    ]
    results = ProbeResult[fetch(t) for t in tasks]
    if rt.proxy !== nothing
        push!(results, _do_probe(:proxy, rt.proxy, "proxy"; timeout=timeout))
    end
    effective = _effective_sources(results, rt)
    return NetworkStatus(rt.hostname, rt.mode, rt.proxy, results, effective)
end

"""
    is_reachable(status, source) -> Bool

Quick predicate for test-gating code: `is_reachable(status, :crossref)` returns
`true` iff the corresponding probe succeeded.
"""
function is_reachable(ns::NetworkStatus, source::Symbol)
    for p in ns.probes
        p.name === source && return p.reachable
    end
    return false
end

function Base.show(io::IO, ::MIME"text/plain", ns::NetworkStatus)
    println(io, "BiblioFetch network status")
    println(io, "  hostname : ", ns.hostname, "    mode: ", ns.mode)
    ns.proxy === nothing || println(io, "  proxy    : ", ns.proxy)
    println(io)
    for p in ns.probes
        mark = p.reachable ? "✓" : "✗"
        tail = p.http_status === nothing ? "" : "  ($(p.http_status))"
        @printf(
            io,
            "  %s %-10s %-32s %5.2fs%s\n",
            mark,
            string(p.name),
            p.label,
            p.duration_s,
            tail,
        )
    end
    println(io)
    if isempty(ns.effective_sources)
        println(io, "  effective sources: (none reachable)")
    else
        println(io, "  effective sources: ", join(string.(ns.effective_sources), ", "))
    end
end
