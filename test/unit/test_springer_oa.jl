using BiblioFetch
using HTTP
using JSON3
using Sockets
using Test

function _free_port_sp()
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

function _with_mock_sp(fn, handler)
    port = _free_port_sp()
    server = HTTP.serve!(handler, "127.0.0.1", port)
    try
        fn("http://127.0.0.1:$(port)/openaccess/json")
    finally
        close(server)
        try
            wait(server)
        catch
        end
    end
end

@testset "is_springer_doi: prefix match (Springer + Nature + BMC + EPJ)" begin
    @test BiblioFetch.is_springer_doi("10.1007/s11538-013-9822-9")
    @test BiblioFetch.is_springer_doi("10.1038/nature12345")
    @test BiblioFetch.is_springer_doi("10.1186/s12859-020-3414-0")
    @test BiblioFetch.is_springer_doi("10.1140/epjc/s10052-020-8276-0")
    @test BiblioFetch.is_springer_doi("  10.1007/BF01234567  ")
    # Non-Springer prefixes stay out of the gate
    @test !BiblioFetch.is_springer_doi("10.1103/PhysRevB.99.214433")
    @test !BiblioFetch.is_springer_doi("10.1016/j.physletb.2023.01.001")
    @test !BiblioFetch.is_springer_doi("arxiv:1706.03762")
end

@testset "springer_oa_lookup: no API key → no network call, returns (nothing, Dict())" begin
    withenv("SPRINGER_API_KEY" => nothing) do
        # base_url intentionally points at a non-routable host; if the function
        # respected the env-unset branch it must return without touching HTTP.
        pdf, meta = BiblioFetch.springer_oa_lookup(
            "10.1007/s11538-013-9822-9"; base_url="http://127.0.0.1:1/oa"
        )
        @test pdf === nothing
        @test isempty(meta)
    end
    withenv("SPRINGER_API_KEY" => "") do
        pdf, meta = BiblioFetch.springer_oa_lookup(
            "10.1007/s11538-013-9822-9"; base_url="http://127.0.0.1:1/oa"
        )
        @test pdf === nothing
        @test isempty(meta)
    end
end

@testset "springer_oa_lookup: OA hit → canonical link.springer.com PDF URL" begin
    seen_query = Ref("")
    handler = function (req::HTTP.Request)
        seen_query[] = String(HTTP.URI(req.target).query)
        body = JSON3.write(
            Dict(
                "records" => [
                    Dict(
                        "doi" => "10.1007/s11538-013-9822-9",
                        "title" => "Sample OA Article",
                        "publisher" => "Springer",
                    ),
                ],
            ),
        )
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    end
    _with_mock_sp(handler) do base
        withenv("SPRINGER_API_KEY" => nothing) do
            pdf, meta = BiblioFetch.springer_oa_lookup(
                "10.1007/s11538-013-9822-9"; api_key="TESTKEY", base_url=base
            )
            @test pdf ==
                "https://link.springer.com/content/pdf/10.1007/s11538-013-9822-9.pdf"
            @test length(meta["records"]) == 1
            # DOI + key round-tripped through the query string
            @test occursin("api_key=TESTKEY", seen_query[])
            @test occursin("doi%3A10.1007", seen_query[])
        end
    end
end

@testset "springer_oa_lookup: env fallback for api_key" begin
    handler = function (req::HTTP.Request)
        q = String(HTTP.URI(req.target).query)
        @test occursin("api_key=ENVKEY", q)
        body = JSON3.write(Dict("records" => [Dict("doi" => "10.1038/nature00001")]))
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    end
    _with_mock_sp(handler) do base
        withenv("SPRINGER_API_KEY" => "ENVKEY") do
            pdf, _ = BiblioFetch.springer_oa_lookup("10.1038/nature00001"; base_url=base)
            @test pdf == "https://link.springer.com/content/pdf/10.1038/nature00001.pdf"
        end
    end
end

@testset "springer_oa_lookup: empty records (paywalled Nature article) → nothing" begin
    handler = function (req::HTTP.Request)
        body = JSON3.write(Dict("records" => []))
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    end
    _with_mock_sp(handler) do base
        withenv("SPRINGER_API_KEY" => nothing) do
            pdf, meta = BiblioFetch.springer_oa_lookup(
                "10.1038/nature99999"; api_key="K", base_url=base
            )
            @test pdf === nothing
            @test meta isa Dict
            @test isempty(meta["records"])
        end
    end
end

@testset "springer_oa_lookup: non-200 response → (nothing, Dict())" begin
    handler = function (req::HTTP.Request)
        return HTTP.Response(403, "forbidden")
    end
    _with_mock_sp(handler) do base
        withenv("SPRINGER_API_KEY" => nothing) do
            pdf, meta = BiblioFetch.springer_oa_lookup(
                "10.1007/s11538-013-9822-9"; api_key="BADKEY", base_url=base
            )
            @test pdf === nothing
            @test isempty(meta)
        end
    end
end

@testset "springer_oa_lookup: malformed JSON → (nothing, Dict())" begin
    handler = function (req::HTTP.Request)
        return HTTP.Response(200, ["Content-Type" => "application/json"], "not json {")
    end
    _with_mock_sp(handler) do base
        withenv("SPRINGER_API_KEY" => nothing) do
            pdf, meta = BiblioFetch.springer_oa_lookup(
                "10.1007/s11538-013-9822-9"; api_key="K", base_url=base
            )
            @test pdf === nothing
            @test isempty(meta)
        end
    end
end

@testset "_source_extra_headers(:springer) → always empty (auth via query param)" begin
    # Springer doesn't use per-request headers — its api_key lives in the
    # lookup URL, not the PDF download. So _source_extra_headers must stay
    # empty for :springer regardless of SPRINGER_API_KEY state.
    withenv("SPRINGER_API_KEY" => "K") do
        @test isempty(BiblioFetch._source_extra_headers(:springer))
    end
    withenv("SPRINGER_API_KEY" => nothing) do
        @test isempty(BiblioFetch._source_extra_headers(:springer))
    end
end

@testset "load_job: :springer is a valid source" begin
    mktempdir() do dir
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [fetch]
          sources = ["unpaywall", "springer"]
          [doi]
          list = ["10.1007/s11538-013-9822-9"]
      """,
            )
        end
        job = BiblioFetch.load_job(job_path)
        @test :springer in job.sources
    end
end

@testset "fetch gating: :springer candidate requires Springer DOI + API key" begin
    # Springer DOI + key → gating passes
    withenv("SPRINGER_API_KEY" => "K") do
        @test BiblioFetch.is_springer_doi("10.1007/s11538-013-9822-9") &&
            BiblioFetch._springer_api_key(nothing) !== nothing
    end
    # Non-Springer DOI + key → gating blocks on DOI
    withenv("SPRINGER_API_KEY" => "K") do
        @test !BiblioFetch.is_springer_doi("10.1103/PhysRevB.99.214433")
    end
    # Springer DOI + no key → gating blocks on key
    withenv("SPRINGER_API_KEY" => nothing) do
        @test BiblioFetch._springer_api_key(nothing) === nothing
    end
end
