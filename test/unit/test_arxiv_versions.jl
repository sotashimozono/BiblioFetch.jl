using BiblioFetch
using HTTP
using Sockets
using Test

function _free_port_v()
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

function _with_mock_v(fn, handler)
    port = _free_port_v()
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

# ---- classifier + parser ----

@testset "is_arxiv_versions: positive + negative" begin
    @test is_arxiv_versions("arxiv:1706.03762@all")
    @test is_arxiv_versions("arxiv:1706.03762@v1,v3")
    @test is_arxiv_versions("arxiv:1706.03762@1,3")
    @test is_arxiv_versions("1706.03762@all")
    @test is_arxiv_versions("cond-mat/0608208@all")
    # Not a version-spec ref
    @test !is_arxiv_versions("arxiv:1706.03762")
    @test !is_arxiv_versions("arxiv:1706.03762v2")
    @test !is_arxiv_versions("10.1103/PhysRevB.99.214433")
    # Spec part must not be empty
    @test !is_arxiv_versions("arxiv:1706.03762@")
    @test !is_arxiv_versions("arxiv:1706.03762@v")
end

@testset "parse_arxiv_version_spec: @all and explicit lists" begin
    base, spec = parse_arxiv_version_spec("arxiv:1706.03762@all")
    @test base == "arxiv:1706.03762"
    @test spec === :all

    base, spec = parse_arxiv_version_spec("arxiv:1706.03762@v1,v3")
    @test base == "arxiv:1706.03762"
    @test spec == [1, 3]

    # Tolerant of either `vN` or bare `N`; result is sorted + unique.
    base, spec = parse_arxiv_version_spec("arxiv:1706.03762@3,v1,1")
    @test base == "arxiv:1706.03762"
    @test spec == [1, 3]

    # Legacy slash id
    base, spec = parse_arxiv_version_spec("cond-mat/0608208@v2")
    @test base == "arxiv:cond-mat/0608208"
    @test spec == [2]
end

@testset "parse_arxiv_version_spec: rejects non-@ refs" begin
    @test_throws ArgumentError parse_arxiv_version_spec("arxiv:1706.03762")
    @test_throws ArgumentError parse_arxiv_version_spec("10.1103/x.y")
end

@testset "normalize_key: preserves @-suffix, lowercases id and spec" begin
    @test normalize_key("arxiv:1706.03762@ALL") == "arxiv:1706.03762@all"
    @test normalize_key("1706.03762@v2,v1") == "arxiv:1706.03762@v2,v1"
    @test normalize_key("https://arxiv.org/abs/1706.03762@v1") == "arxiv:1706.03762@v1"
end

# ---- arxiv_latest_version + arxiv_list_versions (mocked) ----

const _ATOM_LATEST_V3 = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/2301.00123v3</id>
    <title>A Mock Three-Version Paper</title>
  </entry>
</feed>
"""

const _ATOM_NO_V_SUFFIX = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/2301.00123</id>
    <title>Version-less</title>
  </entry>
</feed>
"""

const _ATOM_EMPTY = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"></feed>
"""

function _arxiv_v_handler(req::HTTP.Request)
    p = req.target
    if occursin("id_list=2301.00123", p)
        return HTTP.Response(
            200, ["Content-Type" => "application/atom+xml"], _ATOM_LATEST_V3
        )
    elseif occursin("id_list=2301.99999", p)
        return HTTP.Response(200, ["Content-Type" => "application/atom+xml"], _ATOM_EMPTY)
    elseif occursin("id_list=2301.00456", p)
        return HTTP.Response(
            200, ["Content-Type" => "application/atom+xml"], _ATOM_NO_V_SUFFIX
        )
    else
        return HTTP.Response(500, "unexpected path $(p)")
    end
end

@testset "arxiv_latest_version: parses vN from <id> tag" begin
    _with_mock_v(_arxiv_v_handler) do base
        @test BiblioFetch.arxiv_latest_version("2301.00123"; base_url=base) == 3
        # Strips `arxiv:` prefix and any trailing v-suffix before the query
        @test BiblioFetch.arxiv_latest_version("arxiv:2301.00123v2"; base_url=base) == 3
    end
end

@testset "arxiv_latest_version: empty feed → nothing" begin
    _with_mock_v(_arxiv_v_handler) do base
        @test BiblioFetch.arxiv_latest_version("2301.99999"; base_url=base) === nothing
    end
end

@testset "arxiv_latest_version: <id> without vN suffix defaults to v1" begin
    _with_mock_v(_arxiv_v_handler) do base
        @test BiblioFetch.arxiv_latest_version("2301.00456"; base_url=base) == 1
    end
end

@testset "arxiv_list_versions: materializes 1..latest" begin
    _with_mock_v(_arxiv_v_handler) do base
        @test BiblioFetch.arxiv_list_versions("2301.00123"; base_url=base) == [1, 2, 3]
        @test BiblioFetch.arxiv_list_versions("2301.99999"; base_url=base) == Int[]
    end
end

# ---- load_job accepts @-specs and preserves them ----

@testset "load_job: @-spec refs survive parsing (no network)" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [doi]
          list = ["arxiv:2301.00123@all", "arxiv:2301.00456@v1,v3"]
      """,
            )
        end
        job = load_job(job_path)
        keys_ = [e.key for e in job.refs]
        @test "arxiv:2301.00123@all" in keys_
        @test "arxiv:2301.00456@v1,v3" in keys_
    end
end

# ---- end-to-end expansion via run ----

@testset "run: @v1,v3 expands to 2 FetchEntries with correct versioned keys" begin
    # Use a fake arxiv API by running the full pipeline with ARXIV_API_URL
    # pointed at the mock, but note that `fetch_paper!` itself uses the real
    # ARXIV_API_URL for metadata + PDF. The expansion path we're testing
    # only needs arxiv_list_versions for `@all`; explicit lists bypass it.
    # So for `@v1,v3` we can smoke the expansion without any arXiv network
    # call at all — as long as fetch_paper! also doesn't try to hit arxiv.
    #
    # Trick: use a bogus id so arxiv_latest_version never fires (explicit
    # list path), and sources=["s2"] with no key so no candidates get
    # generated. We only care about the per-version FetchEntry shape.
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
          sources = ["s2"]   # no key → lookup short-circuits → no candidates
          [doi]
          list = ["arxiv:2301.00123@v1,v3"]
      """,
            )
        end
        rt = withenv("HTTP_PROXY" => nothing, "HTTPS_PROXY" => nothing) do
            BiblioFetch.detect_environment(; probe=false)
        end
        result = BiblioFetch.run(job_path; verbose=false, runtime=rt)
        @test length(result.entries) == 2
        keys_ = sort([e.key for e in result.entries])
        @test keys_ == ["arxiv:2301.00123v1", "arxiv:2301.00123v3"]
        # `raw` stays the original @-spec so the provenance is visible
        @test all(e -> e.raw == "arxiv:2301.00123@v1,v3", result.entries)
    end
end
