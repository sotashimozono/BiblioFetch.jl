using BiblioFetch
using Test

# Seed a trio of entries: two condensed-matter papers (one quantum-related),
# one ML paper. Fields used as search haystacks are deliberately distinct
# across the three so field filters can be asserted.
function _seed_search_fixtures(store::BiblioFetch.Store)
    BiblioFetch.write_metadata!(
        store, "10.1103/physrevb.99.214433",
        Dict(
            "key" => "10.1103/physrevb.99.214433",
            "status" => "ok",
            "group" => "condensed-matter",
            "title" => "Haldane gap in a quantum spin chain",
            "authors" => ["Alice Smith", "Bob Jones"],
            "journal" => "Physical Review B",
            "year" => 2019,
            "abstract" => "We observe a finite gap in the spectrum.",
        ),
    )
    BiblioFetch.write_metadata!(
        store, "10.21468/scipostphys.1.1.001",
        Dict(
            "key" => "10.21468/scipostphys.1.1.001",
            "status" => "ok",
            "group" => "condensed-matter",
            "title" => "Quantum quenches to the attractive Bose gas",
            "authors" => ["Lorenzo Piroli"],
            "journal" => "SciPost Physics",
            "year" => 2016,
            "abstract" => "Exact results for quantum quenches.",
        ),
    )
    BiblioFetch.write_metadata!(
        store, "arxiv:1706.03762",
        Dict(
            "key" => "arxiv:1706.03762",
            "status" => "pending",
            "group" => "ml",
            "title" => "Attention Is All You Need",
            "authors" => ["Ashish Vaswani"],
            "abstract" => "We propose a new simple network architecture.",
        ),
    )
    return store
end

@testset "search_entries: substring across default fields, case-insensitive" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed_search_fixtures(store)

        r = search_entries(store, "quantum")
        keys = [m.key for m in r]
        @test "10.1103/physrevb.99.214433" in keys
        @test "10.21468/scipostphys.1.1.001" in keys
        @test "arxiv:1706.03762" ∉ keys

        # Case-insensitivity by default
        @test [m.key for m in search_entries(store, "HALDANE")] ==
              ["10.1103/physrevb.99.214433"]

        # Case-sensitive flag: matching capitalisation must be exact
        @test isempty(search_entries(store, "HALDANE"; case_sensitive=true))
    end
end

@testset "search_entries: field filter" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed_search_fixtures(store)

        # "quantum" is in BOTH the title and abstract of the SciPost paper,
        # and in the title (only) of the PRB paper. Restrict to abstract to
        # keep only the SciPost hit.
        r = search_entries(store, "quantum"; fields=(:abstract,))
        @test [m.key for m in r] == ["10.21468/scipostphys.1.1.001"]

        r2 = search_entries(store, "Piroli"; fields=(:authors,))
        @test length(r2) == 1
        @test r2[1].key == "10.21468/scipostphys.1.1.001"
        @test r2[1].matched_fields == [:authors]
    end
end

@testset "search_entries: group + status filters" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed_search_fixtures(store)

        # Empty query + group filter = enumerate everything in that group
        r = search_entries(store, ""; group="condensed-matter")
        @test length(r) == 2
        @test all(m -> startswith(m.group, "condensed-matter"), r)

        # status filter
        r2 = search_entries(store, ""; status="pending")
        @test length(r2) == 1
        @test r2[1].key == "arxiv:1706.03762"

        # Combined: only the ML pending entry matches both
        r3 = search_entries(store, "Attention"; group="ml", status="pending")
        @test length(r3) == 1
        @test r3[1].matched_fields ⊇ [:title]
    end
end

@testset "search_entries: sort by number of matched fields desc, then key asc" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        # Entry A matches title + abstract (2 fields)
        # Entry B matches title only (1 field)
        BiblioFetch.write_metadata!(
            store, "10.1234/b-only-title",
            Dict("key" => "10.1234/b-only-title", "title" => "alpha something",
                 "abstract" => ""),
        )
        BiblioFetch.write_metadata!(
            store, "10.1234/a-both",
            Dict("key" => "10.1234/a-both", "title" => "alpha entry",
                 "abstract" => "some alpha keyword"),
        )
        r = search_entries(store, "alpha")
        @test r[1].key == "10.1234/a-both"         # more matched fields → first
        @test r[2].key == "10.1234/b-only-title"
    end
end

@testset "search_entries: snippet shows ±window context" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        BiblioFetch.write_metadata!(
            store, "10.1234/snip",
            Dict("key" => "10.1234/snip",
                 "abstract" => "one two three four FIVE six seven eight nine"),
        )
        r = search_entries(store, "FIVE")
        @test length(r) == 1
        @test occursin("FIVE", r[1].snippet)
        @test occursin("three four", r[1].snippet)
        @test occursin("six seven", r[1].snippet)
    end
end

@testset "search_entries: empty result on no match" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed_search_fixtures(store)
        @test isempty(search_entries(store, "nothinglikethis"))
    end
end

@testset "_snippet: empty needle, missing needle, ends-of-string" begin
    @test BiblioFetch._snippet("hello world", "") == ""
    @test BiblioFetch._snippet("hello world", "missing") == ""
    @test occursin("hello", BiblioFetch._snippet("hello world", "hello"))
    # Matches near string boundaries don't overflow
    @test !isempty(BiblioFetch._snippet("hello", "hello"))
end
