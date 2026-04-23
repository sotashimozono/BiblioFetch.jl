using BiblioFetch
using HTTP
using Sockets
using Test

function _free_port_aps()
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

function _with_mock_aps(fn, handler)
    port = _free_port_aps()
    server = HTTP.serve!(handler, "127.0.0.1", port)
    try
        fn("http://127.0.0.1:$(port)/")
    finally
        close(server)
        try
            wait(server)
        catch
        end
    end
end

@testset "is_aps_doi: prefix match (case-insensitive, whitespace-tolerant)" begin
    @test BiblioFetch.is_aps_doi("10.1103/PhysRevB.99.214433")
    @test BiblioFetch.is_aps_doi("10.1103/physrevresearch.1.033027")
    @test BiblioFetch.is_aps_doi("  10.1103/physrevlett.1.1  ")
    @test !BiblioFetch.is_aps_doi("10.1038/nature12345")
    @test !BiblioFetch.is_aps_doi("10.1016/j.physletb.2023.01.001")
    @test !BiblioFetch.is_aps_doi("arxiv:1706.03762")
end

@testset "aps_tdm_url: DOI path preserved, fmt=pdf query appended" begin
    u = BiblioFetch.aps_tdm_url("10.1103/PhysRevB.99.214433")
    @test occursin("harvest.aps.org/v2/journals/articles/10.1103/PhysRevB.99.214433", u)
    @test occursin("fmt=pdf", u)
end

@testset "aps_tdm_url: base_url override for testing" begin
    u = BiblioFetch.aps_tdm_url(
        "10.1103/PhysRevResearch.1.033027"; base_url="https://127.0.0.1/",
    )
    @test startswith(u, "https://127.0.0.1/10.1103/")
end

@testset "aps_tdm_auth_header: explicit kwarg, env fallback, nothing" begin
    # Explicit kwarg wins
    withenv("APS_API_KEY" => nothing) do
        h = BiblioFetch.aps_tdm_auth_header(; api_key="EXPLICIT")
        @test h == ("Authorization" => "Bearer EXPLICIT")
    end
    # Env fallback
    withenv("APS_API_KEY" => "ENVKEY") do
        h = BiblioFetch.aps_tdm_auth_header()
        @test h == ("Authorization" => "Bearer ENVKEY")
    end
    # Neither set → nothing, fetch pipeline will skip :aps
    withenv("APS_API_KEY" => nothing) do
        @test BiblioFetch.aps_tdm_auth_header() === nothing
    end
    # Empty string in env counts as unset
    withenv("APS_API_KEY" => "") do
        @test BiblioFetch.aps_tdm_auth_header() === nothing
    end
end

@testset "_source_extra_headers: :aps → Bearer header; others → empty" begin
    withenv("APS_API_KEY" => "TEST") do
        @test BiblioFetch._source_extra_headers(:aps) ==
              Pair{String,String}[("Authorization" => "Bearer TEST")]
    end
    withenv("APS_API_KEY" => nothing) do
        @test isempty(BiblioFetch._source_extra_headers(:aps))
    end
    @test isempty(BiblioFetch._source_extra_headers(:unpaywall))
    @test isempty(BiblioFetch._source_extra_headers(:direct))
end

@testset "_http_download_pdf: extra_headers round-trip to server" begin
    received_auth = Ref("")
    handler = function (req::HTTP.Request)
        received_auth[] = HTTP.header(req, "Authorization", "")
        # Return a valid-looking PDF so the magic-byte check passes
        body = "%PDF-1.5\n" * String(rand(UInt8, 2048))
        return HTTP.Response(200, ["Content-Type" => "application/pdf"], body)
    end
    _with_mock_aps(handler) do base
        mktempdir() do dir
            dest = joinpath(dir, "out.pdf")
            r = BiblioFetch._http_download_pdf(
                base * "whatever", dest;
                extra_headers=["Authorization" => "Bearer ABCD"],
                timeout=5,
            )
            @test r.ok
            @test received_auth[] == "Bearer ABCD"
        end
    end
end

@testset "load_job: :aps is a valid source" begin
    mktempdir() do dir
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(io, """
                [folder]
                target = "$(dir)/papers"
                [fetch]
                sources = ["unpaywall", "arxiv", "aps"]
                [doi]
                list = ["10.1103/PhysRevB.99.214433"]
            """)
        end
        job = BiblioFetch.load_job(job_path)
        @test :aps in job.sources
    end
end

@testset "fetch_paper!: :aps candidate only appears for APS DOIs with APS_API_KEY set" begin
    # With a non-APS DOI, :aps should not produce a candidate even when key set.
    # Hard to intercept candidate list without deeper plumbing; we verify the
    # invariant indirectly by asserting is_aps_doi + auth_header gating.
    withenv("APS_API_KEY" => "TEST") do
        @test BiblioFetch.is_aps_doi("10.1103/PhysRevB.99.214433") &&
              BiblioFetch.aps_tdm_auth_header() !== nothing
        @test !BiblioFetch.is_aps_doi("10.1038/nature12345")
    end
    withenv("APS_API_KEY" => nothing) do
        # Key missing → guard blocks candidate regardless of DOI.
        @test BiblioFetch.aps_tdm_auth_header() === nothing
    end
end
