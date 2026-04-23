using BiblioFetch
using HTTP
using Sockets
using Test

# Port / mock helpers (inlined — same pattern as test_http_mocks.jl)

function _free_port_s()
    for _ in 1:50
        port = rand(40000:60000)
        try
            sock = Sockets.listen(ip"127.0.0.1", port)
            close(sock)
            return port
        catch
            continue
        end
    end
    error("no free loopback port")
end

function _with_mock_s(fn, handler)
    port = _free_port_s()
    server = HTTP.serve!(handler, "127.0.0.1", port)
    try
        fn("http://127.0.0.1:$(port)")
    finally
        close(server)
        try
            wait(server)
        catch
        end
    end
end

# ---------- _do_probe: status classification ----------

@testset "_do_probe: 2xx and 4xx are reachable, 5xx and connection errors are not" begin
    _with_mock_s((req)->HTTP.Response(200, "ok")) do base
        r = BiblioFetch._do_probe(:x, base * "/", "Mock"; timeout=2)
        @test r.reachable
        @test r.http_status == 200
        @test r.error === nothing
    end

    _with_mock_s((req)->HTTP.Response(404, "nope")) do base
        r = BiblioFetch._do_probe(:x, base * "/missing", "Mock"; timeout=2)
        @test r.reachable              # server responded → reachable even if 404
        @test r.http_status == 404
    end

    _with_mock_s((req)->HTTP.Response(500, "boom")) do base
        r = BiblioFetch._do_probe(:x, base * "/", "Mock"; timeout=2)
        @test !r.reachable             # 5xx = server broken
        @test r.http_status == 500
    end

    # Connection refused: use an already-freed port
    dead = _free_port_s()
    r = BiblioFetch._do_probe(:x, "http://127.0.0.1:$(dead)/", "Mock"; timeout=2)
    @test !r.reachable
    @test r.http_status === nothing
    @test r.error !== nothing
end

# ---------- _effective_sources: derivation logic ----------

function _mkprobe(name, reachable)
    return BiblioFetch.ProbeResult(
        name, "http://x/", string(name), reachable, reachable ? 200 : nothing, 0.1, nothing
    )
end

function _mkrt(; email=nothing, proxy=nothing)
    BiblioFetch.Runtime(
        "test-host",
        "default",
        proxy,
        proxy === nothing ? :none : :profile,
        missing,
        "/tmp/store",
        email,
        :oa_only,
        nothing,
    )
end

@testset "_effective_sources: all reachable, email + proxy set → all 3" begin
    probes = [
        _mkprobe(:crossref, true),
        _mkprobe(:datacite, true),
        _mkprobe(:unpaywall, true),
        _mkprobe(:arxiv_api, true),
        _mkprobe(:arxiv_pdf, true),
        _mkprobe(:doi, true),
        _mkprobe(:proxy, true),
    ]
    rt = _mkrt(email="x@y", proxy="http://proxy.univ:8080")
    eff = BiblioFetch._effective_sources(probes, rt)
    @test Set(eff) == Set([:unpaywall, :arxiv, :direct])
end

@testset "_effective_sources: no email → unpaywall dropped" begin
    probes = [
        _mkprobe(:crossref, true),
        _mkprobe(:unpaywall, true),
        _mkprobe(:arxiv_api, true),
        _mkprobe(:arxiv_pdf, true),
        _mkprobe(:doi, true),
    ]
    rt = _mkrt(email=nothing)
    eff = BiblioFetch._effective_sources(probes, rt)
    @test :unpaywall ∉ eff
    @test :arxiv in eff
    @test :direct in eff
end

@testset "_effective_sources: arxiv needs BOTH api and pdf" begin
    probes = [
        _mkprobe(:unpaywall, true),
        _mkprobe(:arxiv_api, true),
        _mkprobe(:arxiv_pdf, false),
        _mkprobe(:doi, true),
    ]
    rt = _mkrt(email="x@y")
    eff = BiblioFetch._effective_sources(probes, rt)
    @test :arxiv ∉ eff   # arxiv_pdf down
end

@testset "_effective_sources: proxy configured but unreachable → direct skipped" begin
    probes = [_mkprobe(:doi, true), _mkprobe(:proxy, false)]
    rt = _mkrt(proxy="http://proxy.univ:8080")
    eff = BiblioFetch._effective_sources(probes, rt)
    @test :direct ∉ eff
end

@testset "_effective_sources: no proxy configured → direct OK via doi.org alone" begin
    probes = [_mkprobe(:doi, true)]
    rt = _mkrt()   # no proxy
    eff = BiblioFetch._effective_sources(probes, rt)
    @test :direct in eff
end

@testset "_effective_sources: nothing reachable → empty result" begin
    probes = [_mkprobe(:crossref, false), _mkprobe(:arxiv_api, false)]
    rt = _mkrt()
    @test BiblioFetch._effective_sources(probes, rt) == Symbol[]
end

# ---------- status(): end-to-end against a mock ----------

@testset "status: runs probes concurrently and classifies effective sources" begin
    # Handler routes by path prefix so we can simulate a mixed environment.
    handler = function (req::HTTP.Request)
        p = req.target
        if startswith(p, "/crossref") ||
            startswith(p, "/datacite") ||
            startswith(p, "/unpaywall") ||
            startswith(p, "/arxiv_api") ||
            startswith(p, "/arxiv_pdf")
            return HTTP.Response(200, "ok")
        elseif startswith(p, "/doi")
            return HTTP.Response(500, "boom")  # pretend doi.org is down
        else
            return HTTP.Response(404, "?")
        end
    end
    _with_mock_s(handler) do base
        probes = (
            (:crossref, base * "/crossref/x", "Crossref"),
            (:datacite, base * "/datacite/x", "DataCite"),
            (:unpaywall, base * "/unpaywall/x", "Unpaywall"),
            (:arxiv_api, base * "/arxiv_api", "arXiv API"),
            (:arxiv_pdf, base * "/arxiv_pdf", "arXiv PDF"),
            (:doi, base * "/doi/x", "doi.org"),
        )
        rt = _mkrt(email="x@y")
        t0 = time()
        ns = BiblioFetch.status(; rt=rt, timeout=2, probes=probes)
        dt = time() - t0
        @test length(ns.probes) == 6
        @test all(p -> p.name === :doi ? !p.reachable : p.reachable, ns.probes)
        @test Set(ns.effective_sources) == Set([:unpaywall, :arxiv])
        @test :direct ∉ ns.effective_sources    # because our mock doi probe returns 500
        # Parallel: even with 6 probes each capped at 2s timeout, total should be
        # well under 2s since they all return ~instantly.
        @test dt < 2.0
    end
end

# ---------- is_reachable predicate ----------

@testset "is_reachable: looks up by name; missing name → false" begin
    ns = BiblioFetch.NetworkStatus(
        "host",
        :oa_only,
        nothing,
        [_mkprobe(:crossref, true), _mkprobe(:arxiv_pdf, false)],
        [:unpaywall],
    )
    @test BiblioFetch.is_reachable(ns, :crossref)
    @test !BiblioFetch.is_reachable(ns, :arxiv_pdf)
    @test !BiblioFetch.is_reachable(ns, :never_probed)
end
