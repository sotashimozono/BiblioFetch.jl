using BiblioFetch
using HTTP
using Sockets
using Test

# Reuse the free-port + serve! helper from test_http_mocks.jl by inlining
# small copies (the functions are test-scoped, not exported).
function _free_port_dc()
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

function _with_mock_dc(fn, handler)
    port = _free_port_dc()
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

@testset "_datacite_to_crossref_shape: full record" begin
    attr = Dict{String,Any}(
        "titles" => [Dict("title" => "A Simulation Dataset")],
        "creators" => [
            Dict("givenName" => "Alice", "familyName" => "Smith"),
            Dict("givenName" => "Bob",   "familyName" => "Jones"),
        ],
        "publisher" => "Zenodo",
        "publicationYear" => 2024,
        "types" => Dict("resourceTypeGeneral" => "Dataset"),
        "url" => "https://zenodo.org/record/1",
    )
    meta = BiblioFetch._datacite_to_crossref_shape(attr)
    @test meta["title"] == ["A Simulation Dataset"]
    @test meta["author"] == [
        Dict("given" => "Alice", "family" => "Smith"),
        Dict("given" => "Bob",   "family" => "Jones"),
    ]
    @test meta["container-title"] == ["Zenodo"]
    @test meta["issued"]["date-parts"] == [[2024]]
    @test meta["datacite-resource-type"] == "Dataset"
    @test meta["datacite-url"] == "https://zenodo.org/record/1"
end

@testset "_datacite_to_crossref_shape: creator fallbacks + unstructured name" begin
    attr = Dict{String,Any}(
        "titles" => [Dict("title" => "X")],
        "creators" => [
            Dict("name" => "Doe, John"),          # comma-separated
            Dict("name" => "Mononym"),            # single token
            Dict("givenName" => "", "familyName" => ""),   # nothing → skip
        ],
        "publicationYear" => "2020",              # string form
    )
    meta = BiblioFetch._datacite_to_crossref_shape(attr)
    @test meta["author"] == [
        Dict("given" => "John", "family" => "Doe"),
        Dict("given" => "",     "family" => "Mononym"),
    ]
    @test meta["issued"]["date-parts"] == [[2020]]
end

@testset "_datacite_to_crossref_shape: missing fields stay empty / null" begin
    meta = BiblioFetch._datacite_to_crossref_shape(Dict{String,Any}())
    @test meta["title"] == String[]
    @test meta["author"] == Dict{String,Any}[]
    @test meta["container-title"] == String[]
    @test meta["issued"]["date-parts"] == [Any[nothing]]
    @test !haskey(meta, "datacite-resource-type")
    @test !haskey(meta, "datacite-url")
end

function _dc_handler(req::HTTP.Request)
    p = req.target
    if occursin("/10.5281%2Fzenodo.1", p) || occursin("/10.5281/zenodo.1", p)
        body = """
        {"data": {
          "id": "10.5281/zenodo.1",
          "type": "dois",
          "attributes": {
            "doi": "10.5281/zenodo.1",
            "url": "https://zenodo.org/record/1",
            "titles": [{"title": "Sample Dataset"}],
            "creators": [
              {"givenName": "Alice", "familyName": "Smith"}
            ],
            "publisher": "Zenodo",
            "publicationYear": 2024,
            "types": {"resourceTypeGeneral": "Dataset"}
          }
        }}
        """
        return HTTP.Response(200, ["Content-Type" => "application/vnd.api+json"], body)
    elseif occursin("/10.5281%2Fzenodo.404", p) || occursin("/10.5281/zenodo.404", p)
        return HTTP.Response(404, "not found")
    elseif occursin("/10.5281%2Fzenodo.garbage", p) ||
        occursin("/10.5281/zenodo.garbage", p)
        return HTTP.Response(200, ["Content-Type" => "application/json"], "{not json}")
    else
        return HTTP.Response(500, "unexpected $(p)")
    end
end

@testset "datacite_lookup: mocked API returns Crossref-shape" begin
    _with_mock_dc(_dc_handler) do base
        meta = BiblioFetch.datacite_lookup("10.5281/zenodo.1"; base_url=base)
        @test meta["title"] == ["Sample Dataset"]
        @test meta["author"][1]["family"] == "Smith"
        @test meta["container-title"] == ["Zenodo"]
        @test meta["issued"]["date-parts"] == [[2024]]
    end
end

@testset "datacite_lookup: 404 / garbage → empty dict" begin
    _with_mock_dc(_dc_handler) do base
        @test BiblioFetch.datacite_lookup("10.5281/zenodo.404"; base_url=base) ==
              Dict{String,Any}()
        @test BiblioFetch.datacite_lookup("10.5281/zenodo.garbage"; base_url=base) ==
              Dict{String,Any}()
    end
end
