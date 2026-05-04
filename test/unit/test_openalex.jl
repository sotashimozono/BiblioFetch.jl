using BiblioFetch
using HTTP
using Sockets
using Test

# Inline copies of the free-port + serve! helpers so this file stays
# self-contained (the helpers in test_http_mocks.jl are file-scoped, not
# exported). Mirrors test_datacite.jl's pattern.
function _free_port_oa()
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

function _with_mock_oa(fn, handler)
    port = _free_port_oa()
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

@testset "_openalex_abstract_from_inverted_index" begin
    # Out-of-order inverted index: tokens at positions 0, 1, 2, 3, 4
    idx = Dict{String,Any}(
        "Recent" => [0],
        "advances" => [1],
        "in" => [2],
        "machine" => [3],
        "learning" => [4],
    )
    @test BiblioFetch._openalex_abstract_from_inverted_index(idx) ==
        "Recent advances in machine learning"

    # Token appearing twice
    idx2 = Dict{String,Any}("the" => [0, 3], "cat" => [1], "and" => [2], "dog" => [4])
    @test BiblioFetch._openalex_abstract_from_inverted_index(idx2) == "the cat and the dog"

    # Empty / missing inputs return ""
    @test BiblioFetch._openalex_abstract_from_inverted_index(nothing) == ""
    @test BiblioFetch._openalex_abstract_from_inverted_index(Dict{String,Any}()) == ""
end

@testset "_split_openalex_name" begin
    @test BiblioFetch._split_openalex_name("Jane Doe") == ("Jane", "Doe")
    @test BiblioFetch._split_openalex_name("Jane Q. Doe") == ("Jane Q.", "Doe")
    @test BiblioFetch._split_openalex_name("Mononym") == ("", "Mononym")
    @test BiblioFetch._split_openalex_name("") == ("", "")
end

@testset "_openalex_to_crossref_shape: full record" begin
    work = Dict{String,Any}(
        "title" => "A Mock OpenAlex Paper",
        "publication_year" => 2024,
        "primary_location" => Dict{String,Any}(
            "source" => Dict{String,Any}("display_name" => "Mock Journal"),
        ),
        "authorships" => [
            Dict{String,Any}(
                "author" => Dict{String,Any}("display_name" => "Alice Aardvark")
            ),
            Dict{String,Any}(
                "author" => Dict{String,Any}("display_name" => "Bob Q. Baker")
            ),
        ],
        "abstract_inverted_index" => Dict{String,Any}(
            "Hello" => [0], "world" => [1]
        ),
    )
    meta = BiblioFetch._openalex_to_crossref_shape(work)
    @test meta["title"] == ["A Mock OpenAlex Paper"]
    @test meta["container-title"] == ["Mock Journal"]
    @test meta["issued"]["date-parts"] == [[2024]]
    @test length(meta["author"]) == 2
    @test meta["author"][1]["given"] == "Alice"
    @test meta["author"][1]["family"] == "Aardvark"
    @test meta["author"][2]["given"] == "Bob Q."
    @test meta["author"][2]["family"] == "Baker"
    @test meta["abstract"] == "Hello world"
end

@testset "_openalex_to_crossref_shape: missing fields stay empty / null" begin
    meta = BiblioFetch._openalex_to_crossref_shape(Dict{String,Any}())
    @test meta["title"] == String[]
    @test meta["author"] == Dict{String,Any}[]
    @test meta["container-title"] == String[]
    @test meta["issued"]["date-parts"] == [Any[nothing]]
    @test !haskey(meta, "abstract")
end

@testset "_openalex_pdf_url: prefers oa_url, falls back to best_oa_location.pdf_url" begin
    w1 = Dict{String,Any}(
        "open_access" => Dict{String,Any}("oa_url" => "https://ex.org/oa.pdf"),
        "best_oa_location" => Dict{String,Any}("pdf_url" => "https://ex.org/best.pdf"),
    )
    @test BiblioFetch._openalex_pdf_url(w1) == "https://ex.org/oa.pdf"

    w2 = Dict{String,Any}(
        "open_access" => Dict{String,Any}(),
        "best_oa_location" => Dict{String,Any}("pdf_url" => "https://ex.org/best.pdf"),
    )
    @test BiblioFetch._openalex_pdf_url(w2) == "https://ex.org/best.pdf"

    @test BiblioFetch._openalex_pdf_url(Dict{String,Any}()) === nothing
end

# --- mock HTTP handler ---

function _oa_handler(req::HTTP.Request)
    p = req.target
    if occursin("/works/doi%3A10.1%2Fhit", p) || occursin("/works/doi:10.1/hit", p)
        body = """
        {
            "id": "https://openalex.org/W1",
            "title": "Sample OpenAlex Paper",
            "publication_year": 2023,
            "primary_location": {
                "source": {"display_name": "Sample Journal"}
            },
            "authorships": [
                {"author": {"display_name": "Alice Aardvark"}},
                {"author": {"display_name": "Bob Baker"}}
            ],
            "abstract_inverted_index": {
                "Mock": [0], "abstract": [1], "text": [2]
            },
            "open_access": {
                "is_oa": true,
                "oa_url": "https://publisher.example/paper.pdf"
            },
            "best_oa_location": {
                "pdf_url": "https://repo.example/paper.pdf"
            }
        }
        """
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    elseif occursin("/works/arxiv%3A2301.00001", p) ||
        occursin("/works/arxiv:2301.00001", p)
        body = """
        {
            "id": "https://openalex.org/W2",
            "title": "ArXiv-keyed Work",
            "publication_year": 2023,
            "authorships": [],
            "open_access": {"oa_url": "https://arxiv.example/2301.00001.pdf"}
        }
        """
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    elseif occursin("/works/doi%3A10.1%2Fclosed", p) ||
        occursin("/works/doi:10.1/closed", p)
        # Metadata present, but no OA PDF URL anywhere.
        body = """
        {
            "id": "https://openalex.org/W3",
            "title": "Closed-Access Work",
            "publication_year": 2022,
            "authorships": [{"author": {"display_name": "Carol Cat"}}],
            "open_access": {"is_oa": false, "oa_url": null},
            "best_oa_location": null
        }
        """
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    elseif occursin("/works/doi%3A10.1%2F404", p) || occursin("/works/doi:10.1/404", p)
        return HTTP.Response(404, "not found")
    elseif occursin("/works/doi%3A10.1%2Fgarbage", p) ||
        occursin("/works/doi:10.1/garbage", p)
        return HTTP.Response(200, ["Content-Type" => "application/json"], "{not json}")
    else
        return HTTP.Response(500, "unexpected $(p)")
    end
end

@testset "openalex_lookup: DOI hit returns PDF URL + Crossref-shaped metadata" begin
    _with_mock_oa(_oa_handler) do base
        pdf, meta = BiblioFetch.openalex_lookup("doi:10.1/hit"; base_url=base * "works/")
        @test pdf == "https://publisher.example/paper.pdf"
        @test meta["title"] == ["Sample OpenAlex Paper"]
        @test meta["container-title"] == ["Sample Journal"]
        @test meta["issued"]["date-parts"] == [[2023]]
        @test length(meta["author"]) == 2
        @test meta["author"][1]["family"] == "Aardvark"
        @test meta["abstract"] == "Mock abstract text"
    end
end

@testset "openalex_lookup: arXiv-keyed lookup also works" begin
    _with_mock_oa(_oa_handler) do base
        pdf, meta = BiblioFetch.openalex_lookup(
            "arxiv:2301.00001"; base_url=base * "works/"
        )
        @test pdf == "https://arxiv.example/2301.00001.pdf"
        @test meta["title"] == ["ArXiv-keyed Work"]
    end
end

@testset "openalex_lookup: closed-access record returns metadata, pdf=nothing" begin
    _with_mock_oa(_oa_handler) do base
        pdf, meta = BiblioFetch.openalex_lookup(
            "doi:10.1/closed"; base_url=base * "works/"
        )
        @test pdf === nothing
        @test meta["title"] == ["Closed-Access Work"]
        @test meta["author"][1]["family"] == "Cat"
    end
end

@testset "openalex_lookup: 404 / garbage JSON return (nothing, Dict())" begin
    _with_mock_oa(_oa_handler) do base
        @test BiblioFetch.openalex_lookup("doi:10.1/404"; base_url=base * "works/") ==
            (nothing, Dict{String,Any}())
        @test BiblioFetch.openalex_lookup("doi:10.1/garbage"; base_url=base * "works/") ==
            (nothing, Dict{String,Any}())
    end
end

@testset "openalex_lookup: network error (dead port) -> (nothing, Dict())" begin
    dead_port = _free_port_oa()
    dead_base = "http://127.0.0.1:$(dead_port)/works/"
    @test BiblioFetch.openalex_lookup(
        "doi:10.1/x"; base_url=dead_base, timeout=2, max_retries=0
    ) == (nothing, Dict{String,Any}())
end

@testset "openalex_lookup: mailto kwarg is appended to URL (polite-pool)" begin
    seen_target = Ref{String}("")
    handler = function (req::HTTP.Request)
        seen_target[] = req.target
        return HTTP.Response(200, ["Content-Type" => "application/json"], "{}")
    end
    _with_mock_oa(handler) do base
        BiblioFetch.openalex_lookup(
            "doi:10.1/hit"; mailto="t@x.org", base_url=base * "works/"
        )
        @test occursin("mailto=", seen_target[])
    end
end

@testset "wired into KNOWN_SOURCES + PUBLISHER_SOURCES" begin
    @test :openalex in BiblioFetch.KNOWN_SOURCES
    @test :openalex in BiblioFetch.PUBLISHER_SOURCES
    # Opt-in: must NOT be in DEFAULT_SOURCES (mirrors :s2 behavior).
    @test !(:openalex in BiblioFetch.DEFAULT_SOURCES)
end
