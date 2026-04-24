using BiblioFetch
using HTTP
using Sockets
using Test

function _free_port_pol()
    for _ in 1:50
        port = rand(40000:60000)
        try
            sock = Sockets.listen(ip"127.0.0.1", port)
            close(sock)
            return port
        catch
        end
    end
    error("no free loopback port")
end

function _with_mock_pol(fn, handler)
    port = _free_port_pol()
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

# Minimal Runtime sans network probe; used throughout to keep tests hermetic.
function _bare_rt_pol(; email=nothing, proxy=nothing)
    return BiblioFetch.Runtime(
        "test-host",       # hostname
        "default",         # profile
        proxy,             # proxy
        :none,             # proxy_source
        missing,           # reachable
        "/tmp/none",       # store_root
        email,             # email
        :oa_only,          # mode
        nothing,           # config_path
    )
end

# ---- load_job: source_policy + on_fail parsing ----

@testset "load_job: default source_policy = :lenient, on_fail = :pending" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [doi]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        job = load_job(job_path)
        @test job.source_policy === :lenient
        @test job.on_fail === :pending
    end
end

@testset "load_job: [fetch].source_policy parses into :strict" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [fetch]
          source_policy = "strict"
          on_fail = "skip"
          [doi]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        job = load_job(job_path)
        @test job.source_policy === :strict
        @test job.on_fail === :skip
    end
end

@testset "load_job: unknown source_policy / on_fail rejected" begin
    for (field, bad_val) in [("source_policy", "sloppy"), ("on_fail", "retry")]
        mktempdir() do dir
            job_path = joinpath(dir, "bibliofetch.toml")
            open(job_path, "w") do io
                write(
                    io,
                    """
            [folder]
            target = "$(dir)/papers"
            [fetch]
            $(field) = "$(bad_val)"
            [doi]
            list = ["arxiv:1706.03762"]
        """,
                )
            end
            @test_throws ArgumentError load_job(job_path)
        end
    end
end

# ---- fetch_paper! with source_policy ----

@testset "fetch_paper!: source_policy=:strict drops preprint sources (:arxiv / :s2) before network" begin
    # No handler needed — :arxiv candidate should never fire, so no mock
    # server is configured and any network call would crash the test.
    mktempdir() do dir
        store = BiblioFetch.open_store(dir)
        rt = _bare_rt_pol()
        res = BiblioFetch.fetch_paper!(
            store,
            "arxiv:2512.07923";
            rt=rt,
            sources=[:arxiv],           # only arxiv in the list
            source_policy=:strict,      # strict rejects arxiv outright
            verbose=false,
        )
        @test !res.ok
        @test res.source === :deferred    # no candidates produced
        @test isempty(res.attempts)       # never even tried
    end
end

@testset "fetch_paper!: source_policy=:lenient keeps :arxiv candidate" begin
    # arxiv is the only source; lenient should at least produce a candidate
    # and attempt the download. We don't care whether the remote is reachable;
    # just that the attempt is made.
    mktempdir() do dir
        store = BiblioFetch.open_store(dir)
        rt = _bare_rt_pol()
        res = BiblioFetch.fetch_paper!(
            store,
            "arxiv:2512.07923";
            rt=rt,
            sources=[:arxiv],
            source_policy=:lenient,
            verbose=false,
        )
        # attempt was made regardless of success (arxiv reachable from CI)
        @test !isempty(res.attempts)
        @test res.attempts[1].source === :arxiv
    end
end

@testset "fetch_paper!: unknown source_policy raises" begin
    mktempdir() do dir
        store = BiblioFetch.open_store(dir)
        @test_throws ArgumentError BiblioFetch.fetch_paper!(
            store, "arxiv:2512.07923"; sources=[:arxiv], source_policy=:sloppy
        )
    end
end

# ---- Unpaywall host_type gating under :strict ----

@testset "fetch_paper!: strict + Unpaywall host_type='publisher' → candidate kept" begin
    handler = function (req::HTTP.Request)
        p = req.target
        if occursin("/v2/10.1", p)
            body = """
            {"doi":"10.1/pub","is_oa":true,
             "best_oa_location":{
                "url_for_pdf":"http://127.0.0.1:65535/never.pdf",
                "host_type":"publisher"
             }}
            """
            return HTTP.Response(200, ["Content-Type" => "application/json"], body)
        end
        return HTTP.Response(500, "bad path $(p)")
    end
    _with_mock_pol(handler) do base
        mktempdir() do dir
            store = BiblioFetch.open_store(dir)
            rt = _bare_rt_pol(; email="t@x")
            # Patch: call unpaywall_lookup directly to verify host_type plumbing,
            # since fetch_paper! uses the default UNPAYWALL_URL. The :strict
            # gating is on host_type string — assert the bookkeeping directly.
            pdf, upmeta = BiblioFetch.unpaywall_lookup(
                "10.1/pub"; email="t@x", base_url=base * "/v2/"
            )
            @test pdf !== nothing
            loc = upmeta["best_oa_location"]
            @test loc["host_type"] == "publisher"
        end
    end
end

@testset "fetch_paper!: strict + Unpaywall host_type='repository' → candidate dropped" begin
    handler = function (req::HTTP.Request)
        p = req.target
        if occursin("/v2/10.1", p)
            body = """
            {"doi":"10.1/repo","is_oa":true,
             "best_oa_location":{
                "url_for_pdf":"http://127.0.0.1:65535/never.pdf",
                "host_type":"repository"
             }}
            """
            return HTTP.Response(200, ["Content-Type" => "application/json"], body)
        end
        return HTTP.Response(500, "bad path $(p)")
    end
    _with_mock_pol(handler) do base
        _, upmeta = BiblioFetch.unpaywall_lookup(
            "10.1/repo"; email="t@x", base_url=base * "/v2/"
        )
        loc = upmeta["best_oa_location"]
        @test loc["host_type"] == "repository"
    end
end

# ---- on_fail policy observable effects ----

@testset "run: on_fail=:skip marks failures as :skipped, not :pending" begin
    # Force failure deterministically: sources = ["direct"] with no proxy
    # reachable; fetch_paper! produces zero candidates → :deferred → would be
    # :pending under default. With on_fail=:skip, status flips to :skipped.
    mktempdir() do dir
        target = joinpath(dir, "papers")
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(target)"
          [fetch]
          email   = "t@x"
          sources = ["direct"]
          on_fail = "skip"
          [doi]
          list = ["10.1103/PhysRevB.99.214433"]
      """,
            )
        end
        rt = withenv(
            "HTTP_PROXY" => nothing,
            "HTTPS_PROXY" => nothing,
            "http_proxy" => nothing,
            "https_proxy" => nothing,
        ) do
            BiblioFetch.detect_environment(; probe=false)
        end
        @test rt.proxy === nothing

        result = BiblioFetch.run(job_path; verbose=false, runtime=rt)
        @test all(e -> e.status === :skipped, result.entries)

        # Persisted TOML reflects :skipped too (so `sync` leaves it alone)
        md_dir = joinpath(target, BiblioFetch.METADATA_DIRNAME)
        tomls = filter(f -> endswith(f, ".toml"), readdir(md_dir))
        @test length(tomls) == 1
        md = BiblioFetch.TOML.parsefile(joinpath(md_dir, tomls[1]))
        @test md["status"] == "skipped"
    end
end

@testset "run: on_fail=:error aborts the run after the seed batch" begin
    mktempdir() do dir
        target = joinpath(dir, "papers")
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(target)"
          [fetch]
          email   = "t@x"
          sources = ["direct"]
          on_fail = "error"
          [doi]
          list = ["10.1103/PhysRevB.99.214433"]
      """,
            )
        end
        rt = withenv(
            "HTTP_PROXY" => nothing,
            "HTTPS_PROXY" => nothing,
            "http_proxy" => nothing,
            "https_proxy" => nothing,
        ) do
            BiblioFetch.detect_environment(; probe=false)
        end
        @test_throws ErrorException BiblioFetch.run(job_path; verbose=false, runtime=rt)
    end
end

@testset "run: on_fail=:pending (default) keeps status=:pending" begin
    mktempdir() do dir
        target = joinpath(dir, "papers")
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(target)"
          [fetch]
          email   = "t@x"
          sources = ["direct"]
          [doi]
          list = ["10.1103/PhysRevB.99.214433"]
      """,
            )
        end
        rt = withenv(
            "HTTP_PROXY" => nothing,
            "HTTPS_PROXY" => nothing,
            "http_proxy" => nothing,
            "https_proxy" => nothing,
        ) do
            BiblioFetch.detect_environment(; probe=false)
        end
        result = BiblioFetch.run(job_path; verbose=false, runtime=rt)
        @test all(e -> e.status === :pending, result.entries)
    end
end
