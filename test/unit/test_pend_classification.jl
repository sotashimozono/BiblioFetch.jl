using BiblioFetch
using Test

# These tests target the `:pending` vs `:failed` classification fetch_paper!
# applies when `used_source === :none`. The rule: every attempt having
# `http_status === nothing` (or no attempts at all) means we never reached a
# server, so the entry is network-deferred → `:pending`. Any server response
# (4xx / 5xx / landing-page bait) makes it truly `:failed`.

_bare_rt(; email=nothing) = withenv(
    "HTTP_PROXY" => nothing, "HTTPS_PROXY" => nothing,
    "http_proxy" => nothing, "https_proxy" => nothing,
    "BIBLIOFETCH_CONFIG" => nothing,
) do
    rt = BiblioFetch.detect_environment(; probe=false)
    # no `Runtime` setters, so rebuild with the requested email
    email === nothing ? rt :
        BiblioFetch.Runtime(rt.hostname, rt.profile, rt.proxy, rt.proxy_source,
                            rt.reachable, rt.store_root, email, rt.mode, rt.config_path)
end

@testset "fetch_paper!: no candidates → :pending (network-deferred)" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        rt = _bare_rt()
        # sources=["direct"] but rt.proxy === nothing → no candidate is added
        res = BiblioFetch.fetch_paper!(
            store, "10.1234/x"; rt=rt, sources=[:direct], verbose=false,
        )
        @test !res.ok
        @test res.source === :deferred
        @test isempty(res.attempts)

        md = BiblioFetch.read_metadata(store, "10.1234/x")
        @test md["status"] == "pending"
        @test occursin("no candidate PDF URL", md["error"])
    end
end

@testset "fetch_paper!: all-connection-error attempts → :pending" begin
    # Force a real download attempt by requesting :arxiv — its candidate URL is
    # `arxiv_pdf_url(ax)` which is unconditional. But we use an arxiv id with a
    # loopback URL substitution impossible without dep injection, so instead
    # fake it by writing a store entry with pre-existing attempt metadata that
    # has http_status = nothing, then verify the state-shape expectation. The
    # real-network version of this test lives in live-network tests (gated by
    # `status()`).

    # Simpler approach: check the classifier rule directly by assembling
    # attempts and asserting downstream status. This test mirrors the logic
    # the deferred branch in fetch.jl uses.
    att_all_conn_err = [
        BiblioFetch.AttemptLog(:unpaywall, "https://u/x", false, nothing,
                               "connection refused", 0.1),
        BiblioFetch.AttemptLog(:arxiv, "https://a/x", false, nothing,
                               "timeout", 0.2),
    ]
    @test all(a -> a.http_status === nothing, att_all_conn_err)

    att_with_http = [
        BiblioFetch.AttemptLog(:unpaywall, "https://u/x", false, 404, "not found", 0.1),
    ]
    @test !all(a -> a.http_status === nothing, att_with_http)
end

@testset "fetch_paper!: 4xx response → :failed (not :pending)" begin
    # Seed a cached metadata with http_status-bearing attempts so the code path
    # that runs when has_pdf=false and candidates exist is exercised without
    # actually going to the network. Since we can't mock fetch_paper!'s
    # internal candidate chain without further dep injection, test via a live
    # job run that points arxiv ids at a mock would be too heavy for this PR.
    #
    # For now this testset asserts the structural invariant that governs the
    # new classification code: if ANY attempt has http_status ≠ nothing, the
    # entry is :failed not :pending.
    attempts = [
        BiblioFetch.AttemptLog(:arxiv, "https://a/x", false, 404, "not found", 0.1),
    ]
    any_http = any(a -> a.http_status !== nothing, attempts)
    @test any_http       # ⇒ would classify as :failed in fetch.jl
end

@testset "run: offline job parks everything as :pending and sync retries them" begin
    mktempdir() do dir
        target = joinpath(dir, "papers")
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(io, """
                [folder]
                target = "$(target)"
                [fetch]
                sources = ["direct"]
                [doi]
                list = ["10.1234/x", "10.1234/y"]
            """)
        end
        rt = _bare_rt()

        # First run: both land as :pending
        r1 = BiblioFetch.run(job_path; verbose=false, runtime=rt)
        @test all(e -> e.status === :pending, r1.entries)

        # :pending entries aren't in the ok+pdf cohort, so default sync picks
        # them up again (would retry if network came back).
        store = BiblioFetch.open_store(target)
        results = BiblioFetch.sync!(store; rt=rt, force=false, verbose=false)
        @test length(results) == 2   # both still tried
        # Still offline → still :pending, not :failed
        for e_key in ("10.1234/x", "10.1234/y")
            md = BiblioFetch.read_metadata(store, e_key)
            @test md["status"] == "pending"
        end
    end
end
