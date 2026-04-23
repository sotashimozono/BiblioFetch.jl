using BiblioFetch
using HTTP
using Sockets
using Test

# Shared mock helpers (inlined — the helpers in other test files aren't exported)
function _free_port_s2()
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

function _with_mock_s2(fn, handler)
    port = _free_port_s2()
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

# ---------- _s2_key / _extract_s2_fields ----------

@testset "_s2_key: DOI + arXiv + invalid" begin
    @test BiblioFetch._s2_key("10.1103/physrevb.99.214433") ==
        "DOI:10.1103/physrevb.99.214433"
    @test BiblioFetch._s2_key("arxiv:1706.03762") == "ARXIV:1706.03762"
    @test_throws ArgumentError BiblioFetch._s2_key("not-a-key")
end

@testset "_extract_s2_fields: full record" begin
    obj = Dict{String,Any}(
        "paperId" => "abc123",
        "title" => "Attention Is All You Need",
        "authors" => [Dict("name" => "Ashish Vaswani"), Dict("name" => "Noam Shazeer")],
        "year" => 2017,
        "abstract" => "We propose a new simple network architecture...",
        "journal" => Dict("name" => "NeurIPS"),
        "openAccessPdf" =>
            Dict("url" => "https://arxiv.org/pdf/1706.03762.pdf", "status" => "GREEN"),
    )
    out = BiblioFetch._extract_s2_fields(obj)
    @test out["title"] == "Attention Is All You Need"
    @test out["authors"] == ["Ashish Vaswani", "Noam Shazeer"]
    @test out["year"] == 2017
    @test startswith(out["abstract"], "We propose")
    @test out["journal"] == "NeurIPS"
    @test out["oa_pdf_url"] == "https://arxiv.org/pdf/1706.03762.pdf"
    @test out["s2_paper_id"] == "abc123"
end

@testset "_extract_s2_fields: closed access paper → no oa_pdf_url key" begin
    obj = Dict{String,Any}(
        "title" => "Closed",
        "authors" => [Dict("name" => "Someone")],
        "year" => 2020,
        "openAccessPdf" => nothing,
    )
    out = BiblioFetch._extract_s2_fields(obj)
    @test out["title"] == "Closed"
    @test !haskey(out, "oa_pdf_url")
end

@testset "_extract_s2_fields: references (DOI + arXiv mix)" begin
    obj = Dict{String,Any}(
        "paperId" => "p",
        "title" => "With references",
        "references" => [
            Dict("externalIds" => Dict("DOI" => "10.1103/PhysRevB.99.214433")),
            Dict("externalIds" => Dict("ArXiv" => "1706.03762")),
            Dict("externalIds" => Dict(), "title" => "unknown ref"),
            Dict("externalIds" => Dict("DOI" => "  10.1038/NATURE12345  ")),
            Dict("externalIds" => Dict("DOI" => "")),       # empty → skip
            "not a dict",                                   # malformed → skip
        ],
    )
    out = BiblioFetch._extract_s2_fields(obj)
    @test out["references"] ==
        ["10.1103/physrevb.99.214433", "arxiv:1706.03762", "10.1038/nature12345"]
end

@testset "_extract_s2_fields: DOI wins over ArXiv when both present in one ref" begin
    obj = Dict{String,Any}(
        "title" => "X",
        "references" => [
            Dict("externalIds" =>
                    Dict("DOI" => "10.1234/primary", "ArXiv" => "1234.5678")),
        ],
    )
    out = BiblioFetch._extract_s2_fields(obj)
    @test out["references"] == ["10.1234/primary"]
end

@testset "_extract_s2_fields: absent references field → no references key" begin
    out = BiblioFetch._extract_s2_fields(Dict{String,Any}("title" => "Lone"))
    @test !haskey(out, "references")
end

@testset "_extract_s2_fields: year as string, missing abstract, null journal" begin
    obj = Dict{String,Any}(
        "title" => "X",
        "year" => "2018",           # S2 very rarely returns string year; be safe
        "journal" => nothing,
    )
    out = BiblioFetch._extract_s2_fields(obj)
    @test out["year"] == 2018
    @test !haskey(out, "abstract")
    @test !haskey(out, "journal")
end

# ---------- s2_lookup: mocked HTTP ----------

function _s2_handler(req::HTTP.Request)
    p = req.target
    if occursin("DOI%3A10.1103%2Fphysrevb.1", p) || occursin("DOI:10.1103/physrevb.1", p)
        body = """
        {"paperId":"mock1",
         "title":"Mock physical-review paper",
         "authors":[{"name":"Alice Q. Aardvark"}],
         "year":2021,
         "abstract":"Short abstract.",
         "journal":{"name":"Physical Review B"},
         "openAccessPdf":{"url":"https://journals.aps.org/prb/pdf/x","status":"BRONZE"}}
        """
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    elseif occursin("DOI%3A10.1103%2Fphysrevb.404", p) ||
        occursin("DOI:10.1103/physrevb.404", p)
        return HTTP.Response(404, "not found")
    elseif occursin("DOI%3A10.1103%2Fphysrevb.closed", p) ||
        occursin("DOI:10.1103/physrevb.closed", p)
        body = """
        {"paperId":"mock2","title":"Closed-access","authors":[{"name":"X"}],
         "year":2019,"openAccessPdf":null}
        """
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    elseif occursin("DOI%3A10.1103%2Fphysrevb.auth", p) ||
        occursin("DOI:10.1103/physrevb.auth", p)
        # Verify the api_key header round-trips via the x-api-key header.
        key = HTTP.header(req, "x-api-key", "")
        return HTTP.Response(
            200,
            ["Content-Type" => "application/json"],
            """{"paperId":"mock3","title":"auth ok, key was: $(key)"}""",
        )
    else
        return HTTP.Response(500, "unexpected path $(p)")
    end
end

@testset "s2_lookup: full record" begin
    _with_mock_s2(_s2_handler) do base
        md = BiblioFetch.s2_lookup("10.1103/physrevb.1"; base_url=base)
        @test md["title"] == "Mock physical-review paper"
        @test md["year"] == 2021
        @test md["abstract"] == "Short abstract."
        @test md["journal"] == "Physical Review B"
        @test md["oa_pdf_url"] == "https://journals.aps.org/prb/pdf/x"
        @test md["s2_paper_id"] == "mock1"
    end
end

@testset "s2_lookup: 404 → empty Dict" begin
    _with_mock_s2(_s2_handler) do base
        @test BiblioFetch.s2_lookup("10.1103/physrevb.404"; base_url=base) ==
            Dict{String,Any}()
    end
end

@testset "s2_lookup: closed access → no oa_pdf_url" begin
    _with_mock_s2(_s2_handler) do base
        md = BiblioFetch.s2_lookup("10.1103/physrevb.closed"; base_url=base)
        @test md["title"] == "Closed-access"
        @test !haskey(md, "oa_pdf_url")
    end
end

@testset "s2_lookup: api_key → x-api-key header sent to server" begin
    _with_mock_s2(_s2_handler) do base
        md = BiblioFetch.s2_lookup(
            "10.1103/physrevb.auth"; base_url=base, api_key="SECRET123"
        )
        @test occursin("SECRET123", md["title"])
    end
end

@testset "s2_lookup: env var SEMANTIC_SCHOLAR_API_KEY picked up" begin
    _with_mock_s2(_s2_handler) do base
        md = withenv("SEMANTIC_SCHOLAR_API_KEY" => "FROMENV") do
            BiblioFetch.s2_lookup("10.1103/physrevb.auth"; base_url=base)
        end
        @test occursin("FROMENV", md["title"])
    end
end

# ---------- load_job: :s2 accepted in sources list ----------

@testset "load_job: :s2 is a valid source" begin
    mktempdir() do dir
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [fetch]
          sources = ["unpaywall", "s2", "arxiv"]
          [doi]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        job = BiblioFetch.load_job(job_path)
        @test Set(job.sources) == Set([:unpaywall, :s2, :arxiv])
    end
end
