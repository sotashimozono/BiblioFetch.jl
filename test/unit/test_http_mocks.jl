using BiblioFetch
using HTTP
using Sockets
using Test

# --- small test harness: spin up HTTP.serve! on a free loopback port ---

function _free_port()
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
    error("could not find a free loopback port")
end

# Note: `fn` comes first so the `do base ... end` block is passed as `fn`
# (Julia's do-block syntax always prepends the anonymous function).
function _with_mock(fn, handler)
    port = _free_port()
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

# --- Crossref ---

function _crossref_handler(req::HTTP.Request)
    p = req.target
    if occursin("/works/10.1%2Fhit", p) || occursin("/works/10.1/hit", p)
        body = """
        {"status":"ok","message":{
            "DOI":"10.1/hit",
            "title":["A Mock Paper"],
            "container-title":["Mock Journal"],
            "author":[
                {"given":"Alice","family":"Aardvark"},
                {"given":"Bob","family":"Baker"}
            ],
            "issued":{"date-parts":[[2023]]}
        }}
        """
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    elseif occursin("/works/10.1%2Fmiss", p) || occursin("/works/10.1/miss", p)
        return HTTP.Response(404, "not found")
    elseif occursin("/works/10.1%2Fgarbage", p) || occursin("/works/10.1/garbage", p)
        return HTTP.Response(200, ["Content-Type" => "application/json"], "{not json}")
    elseif occursin("/works/10.1%2Fnomessage", p) || occursin("/works/10.1/nomessage", p)
        return HTTP.Response(200, ["Content-Type" => "application/json"], "{}")
    else
        return HTTP.Response(500, "unexpected path $(p)")
    end
end

@testset "crossref_lookup: mocked" begin
    _with_mock(_crossref_handler) do base
        cr = base * "/works/"

        md = BiblioFetch.crossref_lookup("10.1/hit"; base_url=cr)
        @test md["title"][1] == "A Mock Paper"
        @test md["container-title"][1] == "Mock Journal"
        @test md["issued"]["date-parts"][1][1] == 2023
        @test length(md["author"]) == 2
        @test md["author"][1]["family"] == "Aardvark"

        @test BiblioFetch.crossref_lookup("10.1/miss"; base_url=cr) == Dict{String,Any}()
        @test BiblioFetch.crossref_lookup("10.1/garbage"; base_url=cr) == Dict{String,Any}()

        # 200 with empty body -> JSON3.read will fail or message key missing; must not crash
        @test BiblioFetch.crossref_lookup("10.1/nomessage"; base_url=cr) ==
            Dict{String,Any}()
    end
end

# --- Unpaywall ---

function _unpaywall_handler(req::HTTP.Request)
    p = req.target
    if occursin("/v2/10.1%2Fboth", p) || occursin("/v2/10.1/both", p)
        # Full record: url_for_pdf wins over url
        body = """
        {"doi":"10.1/both","is_oa":true,
         "best_oa_location":{
            "url":"https://publisher.example/landing",
            "url_for_pdf":"https://publisher.example/paper.pdf",
            "host_type":"publisher"
         }}
        """
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    elseif occursin("/v2/10.1%2Furlonly", p) || occursin("/v2/10.1/urlonly", p)
        body = """
        {"doi":"10.1/urlonly","is_oa":true,
         "best_oa_location":{
            "url":"https://publisher.example/fallback"
         }}
        """
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    elseif occursin("/v2/10.1%2Fclosed", p) || occursin("/v2/10.1/closed", p)
        return HTTP.Response(
            200,
            ["Content-Type" => "application/json"],
            """{"doi":"10.1/closed","is_oa":false,"best_oa_location":null}""",
        )
    elseif occursin("/v2/10.1%2F404", p) || occursin("/v2/10.1/404", p)
        return HTTP.Response(404, "unknown DOI")
    else
        return HTTP.Response(500, "unexpected path $(p)")
    end
end

@testset "unpaywall_lookup: mocked" begin
    _with_mock(_unpaywall_handler) do base
        up = base * "/v2/"

        pdf, md = BiblioFetch.unpaywall_lookup("10.1/both"; email="t@x", base_url=up)
        @test pdf == "https://publisher.example/paper.pdf"
        @test md["is_oa"] === true

        pdf2, md2 = BiblioFetch.unpaywall_lookup("10.1/urlonly"; email="t@x", base_url=up)
        @test pdf2 == "https://publisher.example/fallback"

        # closed access: best_oa_location is null → pdf = nothing, metadata still returned
        pdf3, md3 = BiblioFetch.unpaywall_lookup("10.1/closed"; email="t@x", base_url=up)
        @test pdf3 === nothing
        @test md3["is_oa"] === false

        # 404: (nothing, Dict())
        pdf4, md4 = BiblioFetch.unpaywall_lookup("10.1/404"; email="t@x", base_url=up)
        @test pdf4 === nothing
        @test md4 == Dict{String,Any}()
    end
end

# --- arXiv ---

const _MOCK_ATOM_ONE = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/2301.00001v1</id>
    <published>2023-01-01T00:00:00Z</published>
    <title>Mock arXiv Paper</title>
    <author><name>Mock Author</name></author>
  </entry>
</feed>
"""

function _arxiv_handler(req::HTTP.Request)
    p = req.target
    if occursin("id_list=2301.00001", p)
        return HTTP.Response(
            200, ["Content-Type" => "application/atom+xml"], _MOCK_ATOM_ONE
        )
    elseif occursin("id_list=2301.99999", p)
        # empty-feed response (arXiv returns a valid feed with no <entry> for unknown ids)
        return HTTP.Response(
            200,
            ["Content-Type" => "application/atom+xml"],
            """<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"></feed>""",
        )
    elseif occursin("search_query=ti", p) && occursin("MockPaperTitle", p)
        return HTTP.Response(
            200,
            ["Content-Type" => "application/atom+xml"],
            """<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
                <entry><id>http://arxiv.org/abs/2101.01234v2</id><title>MockPaperTitle</title></entry>
               </feed>""",
        )
    elseif occursin("search_query=ti", p) && occursin("NothingMatches", p)
        return HTTP.Response(
            200,
            ["Content-Type" => "application/atom+xml"],
            """<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"></feed>""",
        )
    elseif occursin("errored=1", p)
        return HTTP.Response(500, "boom")
    else
        return HTTP.Response(404, "unexpected $(p)")
    end
end

@testset "arxiv_metadata: mocked" begin
    _with_mock(_arxiv_handler) do base
        m = BiblioFetch.arxiv_metadata("2301.00001"; base_url=base)
        @test m !== nothing
        @test m.title == "Mock arXiv Paper"
        @test m.authors == ["Mock Author"]
        @test m.year == 2023

        # Empty feed → nothing
        @test BiblioFetch.arxiv_metadata("2301.99999"; base_url=base) === nothing

        # Strips the `arxiv:` prefix before constructing the id_list URL.
        m2 = BiblioFetch.arxiv_metadata("arxiv:2301.00001"; base_url=base)
        @test m2 !== nothing
        @test m2.title == "Mock arXiv Paper"
    end
end

@testset "arxiv_search_by_title: mocked" begin
    _with_mock(_arxiv_handler) do base
        id = BiblioFetch.arxiv_search_by_title("MockPaperTitle"; base_url=base)
        @test id == "2101.01234"

        # No match → nothing
        @test BiblioFetch.arxiv_search_by_title("NothingMatches"; base_url=base) === nothing
    end
end

# --- error recovery (non-2xx + unreachable) ---

@testset "lookups return empty/nothing on 5xx / connection refused" begin
    # 5xx from a running server
    _with_mock((req)->HTTP.Response(500, "boom")) do base
        @test BiblioFetch.crossref_lookup("10.1/x"; base_url=base * "/works/") ==
            Dict{String,Any}()
        pdf, md = BiblioFetch.unpaywall_lookup(
            "10.1/x"; email="t@x", base_url=base * "/v2/"
        )
        @test pdf === nothing && md == Dict{String,Any}()
        @test BiblioFetch.arxiv_metadata("1234.5678"; base_url=base) === nothing
    end

    # Connection refused: point at a port we've already freed. Disable retries
    # so the test isn't multiplied by exponential backoff (the retry path is
    # exercised explicitly in the retry-specific testset below).
    dead_port = _free_port()
    dead_base = "http://127.0.0.1:$(dead_port)"
    @test BiblioFetch.crossref_lookup(
        "10.1/x"; base_url=dead_base * "/works/", timeout=2, max_retries=0
    ) == Dict{String,Any}()
    @test BiblioFetch.arxiv_metadata(
        "1234.5678"; base_url=dead_base, timeout=2, max_retries=0
    ) === nothing
end

# --- retry + backoff ---

# Handler that returns `status` on the first N calls, then the success body.
# Call-count state lives in a Ref so the handler closure can increment it.
function _flaky_then_success(flakes::Ref{Int}, status::Int, body::String)
    return function (_req::HTTP.Request)
        flakes[] -= 1
        if flakes[] >= 0
            return HTTP.Response(status, [], "retry me")
        end
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    end
end

@testset "retry: 429 then 200 eventually succeeds" begin
    flakes = Ref(2)   # two 429s, then the real payload
    body = """{"status":"ok","message":{"title":["Hit After Retry"]}}"""
    _with_mock(_flaky_then_success(flakes, 429, body)) do base
        md = BiblioFetch.crossref_lookup(
            "10.1/hit";
            base_url=base * "/works/",
            base_delay=0.01,          # ~30 ms total
            sleep_fn=(_)->nothing,    # actually skip the wall-clock sleep
        )
        @test md["title"][1] == "Hit After Retry"
        @test flakes[] == -1          # 2 retried flakes + 1 success
    end
end

@testset "retry: 429 forever gives up after max_retries" begin
    call_count = Ref(0)
    handler = function (_req::HTTP.Request)
        call_count[] += 1
        HTTP.Response(429, [], "throttled")
    end
    _with_mock(handler) do base
        md = BiblioFetch.crossref_lookup(
            "10.1/hit";
            base_url=base * "/works/",
            max_retries=2,
            base_delay=0.01,
            sleep_fn=(_)->nothing,
        )
        @test md == Dict{String,Any}()
        @test call_count[] == 3        # initial attempt + 2 retries
    end
end

@testset "retry: honors Retry-After header (seconds form)" begin
    slept_with = Float64[]
    flakes = Ref(1)
    handler = function (_req::HTTP.Request)
        flakes[] -= 1
        if flakes[] >= 0
            return HTTP.Response(429, ["Retry-After" => "7"], "throttled")
        end
        return HTTP.Response(
            200,
            ["Content-Type" => "application/json"],
            """{"message":{"title":["After wait"]}}""",
        )
    end
    _with_mock(handler) do base
        md = BiblioFetch.crossref_lookup(
            "10.1/hit";
            base_url=base * "/works/",
            base_delay=1.0,
            sleep_fn=d -> push!(slept_with, Float64(d)),
        )
        @test md["title"][1] == "After wait"
        @test slept_with == [7.0]       # Retry-After value used verbatim, not 2^attempt
    end
end

@testset "retry: non-retriable status (404) returns immediately" begin
    call_count = Ref(0)
    handler = function (_req::HTTP.Request)
        call_count[] += 1
        HTTP.Response(404, [], "nope")
    end
    _with_mock(handler) do base
        md = BiblioFetch.crossref_lookup(
            "10.1/hit";
            base_url=base * "/works/",
            max_retries=5,
            base_delay=0.01,
            sleep_fn=(_)->nothing,
        )
        @test md == Dict{String,Any}()
        @test call_count[] == 1
    end
end

@testset "retry: _parse_retry_after" begin
    r1 = HTTP.Response(429, ["Retry-After" => "12"], "")
    @test BiblioFetch._parse_retry_after(r1) == 12.0

    r2 = HTTP.Response(429, ["retry-after" => "3.5"], "")   # case-insensitive
    @test BiblioFetch._parse_retry_after(r2) == 3.5

    r3 = HTTP.Response(429, ["Retry-After" => "Wed, 21 Oct 2015 07:28:00 GMT"], "")
    @test BiblioFetch._parse_retry_after(r3) === nothing    # HTTP-date form skipped

    r4 = HTTP.Response(200, [], "")
    @test BiblioFetch._parse_retry_after(r4) === nothing    # no header
end
