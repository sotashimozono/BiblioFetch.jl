using BiblioFetch
using HTTP
using Sockets
using Test

function _free_port_els()
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

function _with_mock_els(fn, handler)
    port = _free_port_els()
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

@testset "is_elsevier_doi: prefix match" begin
    @test BiblioFetch.is_elsevier_doi("10.1016/j.physletb.2023.01.001")
    @test BiblioFetch.is_elsevier_doi("10.1016/S0370-2693(98)00716-4")
    @test BiblioFetch.is_elsevier_doi("  10.1016/j.aop.2005.10.005  ")
    @test !BiblioFetch.is_elsevier_doi("10.1103/PhysRevB.99.214433")
    @test !BiblioFetch.is_elsevier_doi("10.1038/nature12345")
    @test !BiblioFetch.is_elsevier_doi("arxiv:1706.03762")
end

@testset "elsevier_tdm_url: DOI path preserved" begin
    u = BiblioFetch.elsevier_tdm_url("10.1016/j.physletb.2023.01.001")
    @test occursin("api.elsevier.com/content/article/doi/10.1016/j.physletb.2023.01.001", u)
end

@testset "elsevier_tdm_url: base_url override for testing" begin
    u = BiblioFetch.elsevier_tdm_url(
        "10.1016/j.aop.2005.10.005"; base_url="https://127.0.0.1/",
    )
    @test startswith(u, "https://127.0.0.1/10.1016/")
end

@testset "elsevier_tdm_auth_headers: API-key-only" begin
    withenv("ELSEVIER_API_KEY" => nothing, "ELSEVIER_INSTTOKEN" => nothing) do
        h = BiblioFetch.elsevier_tdm_auth_headers(; api_key="EXPLICIT")
        @test h == Pair{String,String}["X-ELS-APIKey" => "EXPLICIT"]
    end
end

@testset "elsevier_tdm_auth_headers: API key + insttoken" begin
    withenv("ELSEVIER_API_KEY" => nothing, "ELSEVIER_INSTTOKEN" => nothing) do
        h = BiblioFetch.elsevier_tdm_auth_headers(;
            api_key="EXPLICIT", insttoken="ITOK",
        )
        @test h == Pair{String,String}[
            "X-ELS-APIKey" => "EXPLICIT",
            "X-ELS-Insttoken" => "ITOK",
        ]
    end
end

@testset "elsevier_tdm_auth_headers: env fallback for both" begin
    withenv(
        "ELSEVIER_API_KEY" => "ENVKEY",
        "ELSEVIER_INSTTOKEN" => "ENVTOK",
    ) do
        h = BiblioFetch.elsevier_tdm_auth_headers()
        @test h == Pair{String,String}[
            "X-ELS-APIKey" => "ENVKEY",
            "X-ELS-Insttoken" => "ENVTOK",
        ]
    end
end

@testset "elsevier_tdm_auth_headers: no key → empty (fetch skips :elsevier)" begin
    withenv("ELSEVIER_API_KEY" => nothing, "ELSEVIER_INSTTOKEN" => nothing) do
        @test isempty(BiblioFetch.elsevier_tdm_auth_headers())
    end
    withenv("ELSEVIER_API_KEY" => "") do
        @test isempty(BiblioFetch.elsevier_tdm_auth_headers())
    end
end

@testset "_source_extra_headers: :elsevier → X-ELS headers when keyed" begin
    withenv(
        "ELSEVIER_API_KEY" => "K",
        "ELSEVIER_INSTTOKEN" => "T",
    ) do
        @test BiblioFetch._source_extra_headers(:elsevier) == Pair{String,String}[
            "X-ELS-APIKey" => "K",
            "X-ELS-Insttoken" => "T",
        ]
    end
    withenv("ELSEVIER_API_KEY" => nothing, "ELSEVIER_INSTTOKEN" => nothing) do
        @test isempty(BiblioFetch._source_extra_headers(:elsevier))
    end
    # And unrelated sources still return empty
    @test isempty(BiblioFetch._source_extra_headers(:direct))
end

@testset "_http_download_pdf: X-ELS-APIKey round-trips to server" begin
    seen_apikey = Ref("")
    seen_insttok = Ref("")
    handler = function (req::HTTP.Request)
        seen_apikey[] = HTTP.header(req, "X-ELS-APIKey", "")
        seen_insttok[] = HTTP.header(req, "X-ELS-Insttoken", "")
        body = "%PDF-1.5\n" * String(rand(UInt8, 2048))
        return HTTP.Response(200, ["Content-Type" => "application/pdf"], body)
    end
    _with_mock_els(handler) do base
        mktempdir() do dir
            dest = joinpath(dir, "out.pdf")
            r = BiblioFetch._http_download_pdf(
                base * "whatever", dest;
                extra_headers=Pair{String,String}[
                    "X-ELS-APIKey" => "MYKEY",
                    "X-ELS-Insttoken" => "MYTOK",
                ],
                timeout=5,
            )
            @test r.ok
            @test seen_apikey[] == "MYKEY"
            @test seen_insttok[] == "MYTOK"
        end
    end
end

@testset "load_job: :elsevier is a valid source" begin
    mktempdir() do dir
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(io, """
                [folder]
                target = "$(dir)/papers"
                [fetch]
                sources = ["unpaywall", "elsevier"]
                [doi]
                list = ["10.1016/j.physletb.2023.01.001"]
            """)
        end
        job = BiblioFetch.load_job(job_path)
        @test :elsevier in job.sources
    end
end

@testset "fetch gating: :elsevier candidate requires Elsevier DOI + API key" begin
    # Elsevier DOI + key → gating passes
    withenv("ELSEVIER_API_KEY" => "K") do
        @test BiblioFetch.is_elsevier_doi("10.1016/j.physletb.2023.01.001") &&
              !isempty(BiblioFetch.elsevier_tdm_auth_headers())
    end
    # Non-Elsevier DOI + key → gating blocks
    withenv("ELSEVIER_API_KEY" => "K") do
        @test !BiblioFetch.is_elsevier_doi("10.1103/PhysRevB.99.214433")
    end
    # Elsevier DOI + no key → gating blocks
    withenv("ELSEVIER_API_KEY" => nothing) do
        @test isempty(BiblioFetch.elsevier_tdm_auth_headers())
    end
end
