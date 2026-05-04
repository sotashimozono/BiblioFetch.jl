using BiblioFetch
using HTTP
using Sockets
using Test

# Local copies of the test harness (the helpers in test_http_mocks.jl /
# test_datacite.jl are file-scoped, so we inline a minimal pair here).

function _free_port_doaj()
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

function _with_mock_doaj(fn, handler)
    port = _free_port_doaj()
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

@testset "_doaj_to_crossref_shape: full bibjson record" begin
    bib = Dict{String,Any}(
        "title" => "A Vetted OA Paper",
        "author" => [Dict("name" => "Smith, Alice"), Dict("name" => "Jones, Bob")],
        "year" => "2023",
        "journal" => Dict("title" => "Open Journal of Examples"),
        "abstract" => "An abstract.",
        "link" => [
            Dict(
                "type" => "fulltext",
                "content_type" => "application/pdf",
                "url" => "https://oa.example/paper.pdf",
            ),
        ],
    )
    meta = BiblioFetch._doaj_to_crossref_shape(bib)
    @test meta["title"] == ["A Vetted OA Paper"]
    @test meta["author"] == [
        Dict("given" => "Alice", "family" => "Smith"),
        Dict("given" => "Bob", "family" => "Jones"),
    ]
    @test meta["container-title"] == ["Open Journal of Examples"]
    @test meta["issued"]["date-parts"] == [[2023]]
    @test meta["abstract"] == "An abstract."
end

@testset "_doaj_to_crossref_shape: author with mononym + missing year" begin
    bib = Dict{String,Any}(
        "title" => "Edge Cases", "author" => [
            Dict("name" => "Mononym"),
            Dict("name" => ""),                # skipped — empty
        ]
    )
    meta = BiblioFetch._doaj_to_crossref_shape(bib)
    @test meta["author"] == [Dict("given" => "", "family" => "Mononym")]
    @test meta["issued"]["date-parts"] == [Any[nothing]]
    @test meta["container-title"] == String[]
end

@testset "_doaj_to_crossref_shape: empty bibjson stays empty / null" begin
    meta = BiblioFetch._doaj_to_crossref_shape(Dict{String,Any}())
    @test meta["title"] == String[]
    @test meta["author"] == Dict{String,Any}[]
    @test meta["container-title"] == String[]
    @test meta["issued"]["date-parts"] == [Any[nothing]]
    @test !haskey(meta, "abstract")
end

@testset "_doaj_pdf_link: picks first pdf-typed link" begin
    bib = Dict{String,Any}(
        "link" => [
            Dict(
                "type" => "fulltext",
                "content_type" => "text/html",
                "url" => "https://oa.example/landing.html",
            ),
            Dict(
                "type" => "fulltext",
                "content_type" => "application/pdf",
                "url" => "https://oa.example/paper.pdf",
            ),
        ],
    )
    @test BiblioFetch._doaj_pdf_link(bib) == "https://oa.example/paper.pdf"
end

@testset "_doaj_pdf_link: falls back to .pdf URL suffix" begin
    bib = Dict{String,Any}(
        "link" => [
            Dict(
                "type" => "fulltext",
                "content_type" => "",
                "url" => "https://oa.example/paper.pdf",
            ),
        ],
    )
    @test BiblioFetch._doaj_pdf_link(bib) == "https://oa.example/paper.pdf"
end

@testset "_doaj_pdf_link: no pdf candidate → nothing" begin
    bib = Dict{String,Any}(
        "link" => [
            Dict(
                "type" => "fulltext",
                "content_type" => "text/html",
                "url" => "https://oa.example/landing.html",
            ),
        ],
    )
    @test BiblioFetch._doaj_pdf_link(bib) === nothing

    @test BiblioFetch._doaj_pdf_link(Dict{String,Any}()) === nothing
end

# --- DOAJ HTTP mocks ---

function _doaj_handler(req::HTTP.Request)
    p = req.target
    # `doi:` literal stays unescaped; only DOI value is URI-encoded
    if occursin("doi:10.1234%2Foa-hit", p) || occursin("doi:10.1234/oa-hit", p)
        body = """
        {"results": [
          {"bibjson": {
            "title": "DOAJ Mock Paper",
            "author": [
              {"name": "Smith, Alice"},
              {"name": "Jones, Bob"}
            ],
            "year": "2023",
            "journal": {"title": "Open Mock Journal"},
            "abstract": "DOAJ-supplied abstract.",
            "link": [
              {"type": "fulltext", "content_type": "text/html",
               "url": "https://mock.example/landing"},
              {"type": "fulltext", "content_type": "application/pdf",
               "url": "https://mock.example/paper.pdf"}
            ]
          }}
        ]}
        """
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    elseif occursin("doi:10.1234%2Fno-pdf", p) || occursin("doi:10.1234/no-pdf", p)
        body = """
        {"results": [
          {"bibjson": {
            "title": "Landing Only",
            "link": [
              {"type": "fulltext", "content_type": "text/html",
               "url": "https://mock.example/landing"}
            ]
          }}
        ]}
        """
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    elseif occursin("doi:10.1234%2Fno-results", p) || occursin("doi:10.1234/no-results", p)
        return HTTP.Response(
            200, ["Content-Type" => "application/json"], """{"results": []}"""
        )
    elseif occursin("doi:10.1234%2F404", p) || occursin("doi:10.1234/404", p)
        return HTTP.Response(404, "not found")
    elseif occursin("doi:10.1234%2Fgarbage", p) || occursin("doi:10.1234/garbage", p)
        return HTTP.Response(200, ["Content-Type" => "application/json"], "{not json}")
    else
        return HTTP.Response(500, "unexpected $(p)")
    end
end

@testset "doaj_lookup: hit returns pdf URL + Crossref-shaped metadata" begin
    _with_mock_doaj(_doaj_handler) do base
        pdf, meta = BiblioFetch.doaj_lookup("10.1234/oa-hit"; base_url=base)
        @test pdf == "https://mock.example/paper.pdf"
        @test meta["title"] == ["DOAJ Mock Paper"]
        @test meta["author"][1]["family"] == "Smith"
        @test meta["author"][1]["given"] == "Alice"
        @test meta["container-title"] == ["Open Mock Journal"]
        @test meta["issued"]["date-parts"] == [[2023]]
        @test meta["abstract"] == "DOAJ-supplied abstract."
    end
end

@testset "doaj_lookup: hit but no pdf-typed link → (nothing, metadata)" begin
    _with_mock_doaj(_doaj_handler) do base
        pdf, meta = BiblioFetch.doaj_lookup("10.1234/no-pdf"; base_url=base)
        @test pdf === nothing
        @test meta["title"] == ["Landing Only"]
    end
end

@testset "doaj_lookup: empty results array → (nothing, Dict())" begin
    _with_mock_doaj(_doaj_handler) do base
        pdf, meta = BiblioFetch.doaj_lookup("10.1234/no-results"; base_url=base)
        @test pdf === nothing
        @test meta == Dict{String,Any}()
    end
end

@testset "doaj_lookup: 404 / garbage / unreachable → (nothing, Dict())" begin
    _with_mock_doaj(_doaj_handler) do base
        pdf404, meta404 = BiblioFetch.doaj_lookup("10.1234/404"; base_url=base)
        @test pdf404 === nothing
        @test meta404 == Dict{String,Any}()

        pdfg, metag = BiblioFetch.doaj_lookup("10.1234/garbage"; base_url=base)
        @test pdfg === nothing
        @test metag == Dict{String,Any}()
    end

    # Connection refused: point at a freed port. Disable retries for a fast test.
    dead_port = _free_port_doaj()
    pdf, meta = BiblioFetch.doaj_lookup(
        "10.1234/x"; base_url="http://127.0.0.1:$(dead_port)/", timeout=2, max_retries=0
    )
    @test pdf === nothing
    @test meta == Dict{String,Any}()
end
