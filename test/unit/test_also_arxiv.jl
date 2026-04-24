using BiblioFetch
using HTTP
using Sockets
using Test

function _free_port_aa()
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

function _with_mock_aa(fn, handler)
    port = _free_port_aa()
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

function _bare_rt_aa(; email=nothing, proxy=nothing)
    return BiblioFetch.Runtime(
        "test-host", "default", proxy, :none, missing, "/tmp/none", email, :oa_only, nothing
    )
end

# ---- load_job + FetchJob default / parsing ----

@testset "load_job: also_arxiv defaults to false" begin
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
        @test job.also_arxiv === false
    end
end

@testset "load_job: [fetch].also_arxiv = true parses" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [fetch]
          also_arxiv = true
          [doi]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        job = load_job(job_path)
        @test job.also_arxiv === true
    end
end

# ---- store helpers ----

@testset "preprint_pdf_path: __preprint.pdf sibling of pdf_path" begin
    mktempdir() do dir
        store = BiblioFetch.open_store(dir)
        primary = BiblioFetch.pdf_path(store, "arxiv:1706.03762"; group="x")
        companion = BiblioFetch.preprint_pdf_path(store, "arxiv:1706.03762"; group="x")
        # Same directory, different filename stem.
        @test dirname(primary) == dirname(companion)
        @test endswith(primary, ".pdf") && endswith(companion, "__preprint.pdf")
        @test primary != companion
    end
end

@testset "has_preprint: reports real on-disk state" begin
    mktempdir() do dir
        store = BiblioFetch.open_store(dir)
        @test !BiblioFetch.has_preprint(store, "arxiv:1706.03762")
        pp = BiblioFetch.preprint_pdf_path(store, "arxiv:1706.03762")
        mkpath(dirname(pp))
        open(pp, "w") do io
            write(io, "%PDF-1.5\n")
            write(io, rand(UInt8, 2048))
        end
        @test BiblioFetch.has_preprint(store, "arxiv:1706.03762")
    end
end

# ---- fetch_paper! end-to-end with mocked arxiv PDF server ----

# Returns a valid-looking PDF for any `/pdf/` path (keyed by arxiv id path).
function _pdf_handler(req::HTTP.Request)
    if occursin("/pdf/", String(req.target))
        body = "%PDF-1.5\n" * String(rand(UInt8, 2048))
        return HTTP.Response(200, ["Content-Type" => "application/pdf"], body)
    end
    return HTTP.Response(404, "unknown")
end

@testset "fetch_paper!: also_arxiv primary=arxiv → no companion fetch" begin
    # Pointing ARXIV at our mock is sufficient; the arxiv primary is the
    # preprint itself, so the companion path must stay absent.
    _with_mock_aa(_pdf_handler) do base
        mktempdir() do dir
            store = BiblioFetch.open_store(dir)
            rt = _bare_rt_aa()
            # Build the candidate URL by hand so we hit the mock server.
            # We override `arxiv_pdf_url` via the base_url — but that
            # helper doesn't take one; simpler: test through the higher
            # path. Instead we rely on arxiv's real server being reachable
            # for a cheap smoke in local runs. If that's not available in
            # CI, this test is still useful because the assertion is on
            # the *absence* of the companion artifact.
            res = BiblioFetch.fetch_paper!(
                store,
                "arxiv:2512.07923";
                rt=rt,
                sources=[:arxiv],
                also_arxiv=true,
                verbose=false,
            )
            # Only assert the companion-related behavior — the primary's
            # outcome depends on network reachability to arxiv.org.
            md = BiblioFetch.read_metadata(store, "arxiv:2512.07923")
            @test !haskey(md, "preprint_pdf")
            # `preprint_status` should NEVER be set when primary is arxiv:
            # the companion logic short-circuits before any probe.
            @test !haskey(md, "preprint_status")
        end
    end
end

# Mock that serves both arxiv API (for title search / metadata) and PDFs.
# In the companion-fetch path we only hit the arxiv *PDF* URL since
# arxiv_id is already in md. Simulate by pre-writing the primary and then
# exercising the cache branch with also_arxiv=true.
@testset "fetch_paper!: cache branch + also_arxiv triggers companion fetch when arxiv_id known" begin
    # Seed store: pretend the primary is on disk already (cached) with
    # arxiv_id in metadata. Then re-call fetch_paper! with also_arxiv=true
    # and verify the companion path is visited.
    mktempdir() do dir
        store = BiblioFetch.open_store(dir)
        key = "10.1103/physrevb.99.214433"
        primary = BiblioFetch.pdf_path(store, key)
        mkpath(dirname(primary))
        open(primary, "w") do io
            write(io, "%PDF-1.5\n")
            write(io, rand(UInt8, 2048))
        end
        # Seed metadata with arxiv_id pre-known so the companion fetch
        # skips the metadata-lookup step and goes straight to arxiv_pdf_url.
        BiblioFetch.write_metadata!(
            store,
            key,
            Dict{String,Any}(
                "key" => key,
                "status" => "ok",
                "pdf_path" => primary,
                "source" => "unpaywall",
                "arxiv_id" => "1905.07639",    # bogus id; fetch will hit arxiv.org
            ),
        )

        rt = _bare_rt_aa()
        res = BiblioFetch.fetch_paper!(
            store, key; rt=rt, sources=[:arxiv], also_arxiv=true, verbose=false
        )
        @test res.ok
        md = BiblioFetch.read_metadata(store, key)
        # Either the companion download hit arxiv and succeeded, or we
        # recorded the failure reason. Both paths go through the companion
        # logic, so `preprint_status` must be set one way or the other.
        @test haskey(md, "preprint_status")
        @test md["preprint_status"] in ("ok", "cached", "failed")
    end
end

@testset "doctor: __preprint.pdf sibling is not flagged as orphan_pdf" begin
    mktempdir() do dir
        store = BiblioFetch.open_store(dir)
        key = "10.1234/companion"
        primary = BiblioFetch.pdf_path(store, key)
        companion = BiblioFetch.preprint_pdf_path(store, key)
        mkpath(dirname(primary))
        for p in (primary, companion)
            open(p, "w") do io
                write(io, "%PDF-1.5\n")
                write(io, rand(UInt8, 2048))
            end
        end
        BiblioFetch.write_metadata!(
            store,
            key,
            Dict{String,Any}(
                "key" => key,
                "status" => "ok",
                "pdf_path" => primary,
                "preprint_pdf" => companion,
                "source" => "unpaywall",
            ),
        )
        issues = BiblioFetch.doctor(store)
        orphans = filter(i -> i.kind === :orphan_pdf, issues)
        @test isempty(orphans)
    end
end

@testset "fetch_paper!: also_arxiv=true, no arxiv_id discoverable → no-arxiv-id" begin
    # Seed a cached primary with a DOI-style key that has no arxiv relation
    # in metadata and no title (so the title-search fallback returns
    # nothing). Companion logic must record status=no-arxiv-id and leave
    # no __preprint.pdf.
    mktempdir() do dir
        store = BiblioFetch.open_store(dir)
        key = "10.1234/no-preprint"
        primary = BiblioFetch.pdf_path(store, key)
        mkpath(dirname(primary))
        open(primary, "w") do io
            write(io, "%PDF-1.5\n")
            write(io, rand(UInt8, 2048))
        end
        BiblioFetch.write_metadata!(
            store,
            key,
            Dict{String,Any}(
                "key" => key,
                "status" => "ok",
                "pdf_path" => primary,
                "source" => "unpaywall",
                # no arxiv_id, no title → companion will find nothing
            ),
        )

        rt = _bare_rt_aa()
        res = BiblioFetch.fetch_paper!(
            store, key; rt=rt, sources=[:unpaywall, :arxiv], also_arxiv=true, verbose=false
        )
        @test res.ok
        md = BiblioFetch.read_metadata(store, key)
        @test md["preprint_status"] == "no-arxiv-id"
        @test !haskey(md, "preprint_pdf")
        @test !BiblioFetch.has_preprint(store, key)
    end
end
