using BiblioFetch
using Test

# Seed three papers forming a small citation graph:
#
#   a  cites  b  cites  c
#
# a is the user's seed; b and c were queued by citation expansion (b queued by
# a, c queued by b). Every paper has status=ok so the full-citation and queued
# edge sets are both non-empty.
function _seed_graph_fixture(store::BiblioFetch.Store)
    BiblioFetch.write_metadata!(
        store, "10.1234/a",
        Dict(
            "key" => "10.1234/a",
            "status" => "ok",
            "authors" => ["Alice Alpha"],
            "year" => 2020,
            "title" => "Paper A",
            "referenced_dois" => ["10.1234/b"],
        ),
    )
    BiblioFetch.write_metadata!(
        store, "10.1234/b",
        Dict(
            "key" => "10.1234/b",
            "status" => "pending",     # pending on purpose — exercises style path
            "authors" => ["Bob Beta"],
            "year" => 2019,
            "title" => "Paper B",
            "referenced_dois" => ["10.1234/c"],
            "referenced_by" => "10.1234/a",
            "depth" => 1,
        ),
    )
    BiblioFetch.write_metadata!(
        store, "10.1234/c",
        Dict(
            "key" => "10.1234/c",
            "status" => "failed",
            "authors" => ["Carol Gamma"],
            "year" => 2018,
            "title" => "Paper C",
            "referenced_by" => "10.1234/b",
            "depth" => 2,
        ),
    )
end

@testset "to_dot: full-citation subgraph emits digraph header + expected edges" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed_graph_fixture(store)

        d = to_dot(store)
        @test startswith(d, "digraph BiblioFetch {\n")
        @test occursin("rankdir=LR", d)

        # citekey labels (shared with bibtex export)
        @test occursin("Alpha2020", d)
        @test occursin("Beta2019", d)
        @test occursin("Gamma2018", d)

        # edges a → b → c (full-citation mode follows referenced_dois)
        safekey_a = BiblioFetch._safe_key("10.1234/a")
        safekey_b = BiblioFetch._safe_key("10.1234/b")
        safekey_c = BiblioFetch._safe_key("10.1234/c")
        @test occursin("\"$(safekey_a)\" -> \"$(safekey_b)\"", d)
        @test occursin("\"$(safekey_b)\" -> \"$(safekey_c)\"", d)

        # Trailing brace
        @test occursin("}\n", d)
    end
end

@testset "to_dot: per-status node styles" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed_graph_fixture(store)
        d = to_dot(store)
        # ok / pending / failed pick up different fill colors
        @test occursin("fillcolor=\"#e0f0ff\"", d)   # ok (Alpha)
        @test occursin("dashed",                d)   # pending (Beta)
        @test occursin("fillcolor=\"#ffe0e0\"", d)   # failed (Gamma)
    end
end

@testset "to_dot: queued_only only renders expansion-tree edges" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        # Add a "cross citation" that is NOT part of the queue tree: b ALSO
        # cites a (stored back-reference), which should appear only in full
        # mode, not in queued mode.
        _seed_graph_fixture(store)
        mdb = BiblioFetch.read_metadata(store, "10.1234/b")
        mdb["referenced_dois"] = ["10.1234/c", "10.1234/a"]
        BiblioFetch.write_metadata!(store, "10.1234/b", mdb)

        # queued_only: a → b → c (from referenced_by chain). No b → a.
        d_q = to_dot(store; queued_only=true)
        safekey_a = BiblioFetch._safe_key("10.1234/a")
        safekey_b = BiblioFetch._safe_key("10.1234/b")
        @test occursin("\"$(safekey_a)\" -> \"$(safekey_b)\"", d_q)
        @test !occursin("\"$(safekey_b)\" -> \"$(safekey_a)\"", d_q)

        # full: both a→b and b→a present
        d_f = to_dot(store; queued_only=false)
        @test occursin("\"$(safekey_a)\" -> \"$(safekey_b)\"", d_f)
        @test occursin("\"$(safekey_b)\" -> \"$(safekey_a)\"", d_f)
    end
end

@testset "to_dot: isolated nodes hidden by default, include_isolated=true keeps them" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed_graph_fixture(store)
        # Add a lonely paper that's in the store but has no edges in or out
        BiblioFetch.write_metadata!(
            store, "10.1234/lonely",
            Dict("key" => "10.1234/lonely", "status" => "ok",
                 "authors" => ["Solo"], "year" => 2024, "title" => "No refs"),
        )

        d_default = to_dot(store)
        @test !occursin("Solo2024", d_default)

        d_all = to_dot(store; include_isolated=true)
        @test occursin("Solo2024", d_all)
    end
end

@testset "to_dot: edges pointing at DOIs that aren't in the store are dropped" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        BiblioFetch.write_metadata!(
            store, "10.1234/seed",
            Dict(
                "key" => "10.1234/seed", "status" => "ok",
                "authors" => ["Seed"], "year" => 2020, "title" => "Seed",
                # Points at a DOI the store doesn't have → no dangling edge
                "referenced_dois" => ["10.9999/external-only"],
            ),
        )
        d = to_dot(store)
        @test !occursin("10.9999", d)
        # The seed itself should ALSO not render (no edge → isolated, hidden by
        # default). Flip to --all to see it.
        @test !occursin("Seed2020", d)
        d_all = to_dot(store; include_isolated=true)
        @test occursin("Seed2020", d_all)
    end
end

@testset "to_mermaid: `graph LR` header + sanitised ids + class attachments" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed_graph_fixture(store)
        m = to_mermaid(store)

        @test startswith(m, "graph LR\n")
        @test occursin("classDef ok",      m)
        @test occursin("classDef pending", m)
        @test occursin("classDef failed",  m)

        # Mermaid ids are alphanumeric-only (safekey uses `__` and `.` which
        # become underscores).
        safekey_a = BiblioFetch._safe_key("10.1234/a")
        id_a = BiblioFetch._mermaid_id(safekey_a)
        @test occursin(id_a * "[\"Alpha2020\"]", m)

        # Class lines applied per status
        @test occursin(" ok;", m)       # Alpha
        @test occursin(" pending;", m)  # Beta
        @test occursin(" failed;", m)   # Gamma

        # Edge syntax
        @test occursin("-->", m)
    end
end

@testset "to_mermaid: empty store → header + class defs but no node / edge lines" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        m = to_mermaid(store)
        @test startswith(m, "graph LR")
        @test occursin("classDef ok", m)
        @test !occursin("-->", m)
    end
end

@testset "_mermaid_id sanitisation" begin
    @test BiblioFetch._mermaid_id("arxiv__1706.03762") == "arxiv__1706_03762"
    @test BiblioFetch._mermaid_id("10.1103_physrevb.99.214433") ==
          "10_1103_physrevb_99_214433"
    @test BiblioFetch._mermaid_id("simple") == "simple"
end

@testset "_dot_escape: quotes / backslashes / newlines" begin
    @test BiblioFetch._dot_escape("plain") == "plain"
    @test BiblioFetch._dot_escape("a \"quoted\" b") == "a \\\"quoted\\\" b"
    @test BiblioFetch._dot_escape("line1\nline2") == "line1\\nline2"
    @test BiblioFetch._dot_escape("back\\slash") == "back\\\\slash"
end
