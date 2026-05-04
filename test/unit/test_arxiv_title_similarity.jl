using BiblioFetch
using HTTP
using Sockets
using Test

# Spin up HTTP.serve! on a free loopback port (mirrors test_http_mocks.jl).

function _free_port_ats()
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
    return error("could not find a free loopback port")
end

function _with_mock_ats(fn, handler)
    port = _free_port_ats()
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

# --- _title_similarity helper ---

@testset "_title_similarity: identical titles → 1.0" begin
    @test BiblioFetch._title_similarity(
        "Attention Is All You Need", "Attention Is All You Need"
    ) == 1.0
end

@testset "_title_similarity: case-insensitive (Quantum Hall effect)" begin
    @test BiblioFetch._title_similarity("Quantum Hall effect", "QUANTUM HALL EFFECT") == 1.0
end

@testset "_title_similarity: completely different titles → low score" begin
    sim = BiblioFetch._title_similarity(
        "Anyons in an exactly solved model and beyond",
        "Reply to comment on Erratum random subject",
    )
    @test sim < 0.2
end

@testset "_title_similarity: empty input → 0.0" begin
    @test BiblioFetch._title_similarity("", "anything") == 0.0
    @test BiblioFetch._title_similarity("anything", "") == 0.0
end

@testset "_title_similarity: punctuation is stripped before tokenizing" begin
    @test BiblioFetch._title_similarity(
        "Title: A Sub-title (with parens)!", "title a sub title with parens"
    ) == 1.0
end

@testset "_title_similarity: partial overlap is between 0 and 1" begin
    sim = BiblioFetch._title_similarity(
        "Quantum Hall effect in graphene", "Quantum Hall effect in topological insulators"
    )
    @test 0.0 < sim < 1.0
end

# --- _surname_overlaps helper ---

@testset "_surname_overlaps: matches last token case-insensitively" begin
    @test BiblioFetch._surname_overlaps("Alexei Kitaev", ["Alexei Y. KITAEV"]) == true
    @test BiblioFetch._surname_overlaps("Bob Baker", ["Alice Aardvark", "Bob Baker"]) ==
        true
    @test BiblioFetch._surname_overlaps("Bob Baker", ["Alice Aardvark", "Carol Carter"]) ==
        false
    @test BiblioFetch._surname_overlaps("", ["Alice Aardvark"]) == false
    @test BiblioFetch._surname_overlaps("Bob Baker", String[]) == false
end

# --- mocked arxiv_search_by_title scenarios ---

# Synthetic arXiv Atom payloads. Ids and author names are all fictitious.

const _ATS_BODY_WRONG = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/9999.99999v1</id>
    <published>2024-01-01T00:00:00Z</published>
    <title>Reply to Comment on Erratum: random unrelated topic</title>
    <author><name>Random Person</name></author>
  </entry>
</feed>
"""

const _ATS_BODY_EXACT = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/2200.12345v1</id>
    <published>2022-03-04T00:00:00Z</published>
    <title>Quantum Hall effect in graphene</title>
    <author><name>Some Author</name></author>
  </entry>
</feed>
"""

# Title is *related but not identical*: bigram Jaccard sits below 0.8.
# We give the candidate a matching first-author surname so the rescue path
# fires.
const _ATS_BODY_AUTHOR_RESCUE = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/2300.55555v3</id>
    <published>2023-06-01T00:00:00Z</published>
    <title>Topological insulators: a comprehensive textbook chapter</title>
    <author><name>Alice Authority</name></author>
    <author><name>Bob Backup</name></author>
  </entry>
</feed>
"""

function _ats_handler(req::HTTP.Request)
    p = req.target
    if occursin("Anyons", p)
        return HTTP.Response(
            200, ["Content-Type" => "application/atom+xml"], _ATS_BODY_WRONG
        )
    elseif occursin("Quantum", p) && occursin("graphene", p)
        return HTTP.Response(
            200, ["Content-Type" => "application/atom+xml"], _ATS_BODY_EXACT
        )
    elseif occursin("Topological", p)
        return HTTP.Response(
            200, ["Content-Type" => "application/atom+xml"], _ATS_BODY_AUTHOR_RESCUE
        )
    else
        return HTTP.Response(404, "unexpected $(p)")
    end
end

@testset "arxiv_search_by_title: rejects when candidate title is very different" begin
    _with_mock_ats(_ats_handler) do base
        # We ask for "Anyons in an exactly solved model and beyond" but the
        # mock returns a "Reply to Comment on Erratum…" paper. No author
        # was supplied → no rescue path → must return nothing.
        result = BiblioFetch.arxiv_search_by_title(
            "Anyons in an exactly solved model and beyond"; base_url=base
        )
        @test result === nothing
    end
end

@testset "arxiv_search_by_title: returns id when titles match exactly" begin
    _with_mock_ats(_ats_handler) do base
        id = BiblioFetch.arxiv_search_by_title(
            "Quantum Hall effect in graphene"; base_url=base
        )
        @test id == "2200.12345"
    end
end

@testset "arxiv_search_by_title: author-surname rescue when title score is low" begin
    _with_mock_ats(_ats_handler) do base
        # Wanted vs returned title share at most one token → bigram Jaccard
        # falls below 0.8. But the queried first author "Alice Authority"
        # matches a candidate author surname → rescue path returns the id.
        id = BiblioFetch.arxiv_search_by_title(
            "Topological insulators review"; authors=["Alice Authority"], base_url=base
        )
        @test id == "2300.55555"

        # Same title but no author hint → no rescue → nothing.
        id2 = BiblioFetch.arxiv_search_by_title(
            "Topological insulators review"; base_url=base
        )
        @test id2 === nothing

        # Author whose surname doesn't overlap → no rescue → nothing.
        id3 = BiblioFetch.arxiv_search_by_title(
            "Topological insulators review"; authors=["Charlie Outsider"], base_url=base
        )
        @test id3 === nothing
    end
end
