using BiblioFetch
using JSON3
using Test

@testset "csl_entry: journal article" begin
    md = Dict{String,Any}(
        "key" => "10.1103/physrevb.99.214433",
        "title" => "Example paper",
        "authors" => ["John Smith", "Jane Doe"],
        "journal" => "Physical Review B",
        "year" => 2019,
    )
    e = csl_entry(md)
    @test e["id"] == "Smith2019"
    @test e["type"] == "article-journal"
    @test e["title"] == "Example paper"
    @test e["container-title"] == "Physical Review B"
    @test e["author"][1]["family"] == "Smith"
    @test e["author"][1]["given"] == "John"
    @test e["author"][2]["family"] == "Doe"
    # `issued.date-parts` is `[[year]]` per CSL — outer Vector{Vector{Int}}.
    @test e["issued"]["date-parts"][1][1] == 2019
    @test e["DOI"] == "10.1103/physrevb.99.214433"
    @test e["URL"] == "https://doi.org/10.1103/physrevb.99.214433"
    @test !haskey(e, "abstract")  # not in md → not emitted
end

@testset "csl_entry: arXiv preprint" begin
    md = Dict{String,Any}(
        "key" => "arxiv:1706.03762",
        "title" => "Attention Is All You Need",
        "authors" => ["Ashish Vaswani"],
        "year" => 2017,
        "abstract" => "We propose a new architecture.",
    )
    e = csl_entry(md)
    # Preprint → CSL "manuscript" (not "article-journal")
    @test e["type"] == "manuscript"
    @test e["author"][1]["family"] == "Vaswani"
    @test e["author"][1]["given"] == "Ashish"
    @test e["issued"]["date-parts"][1][1] == 2017
    @test !haskey(e, "DOI")            # arxiv key isn't a DOI
    @test !haskey(e, "URL")            # no DOI → no doi.org URL
    @test !haskey(e, "container-title")
    @test e["abstract"] == "We propose a new architecture."
end

@testset "csl_entry: explicit id override" begin
    md = Dict{String,Any}(
        "key" => "10.1/dummy", "authors" => ["Alice Brown"], "year" => 2020,
    )
    e = csl_entry(md; id="MyKey2020")
    @test e["id"] == "MyKey2020"
end

@testset "csl_entry: year-as-string is coerced to int in date-parts" begin
    md = Dict{String,Any}("authors" => ["Alice Brown"], "year" => "2022")
    e = csl_entry(md)
    @test e["issued"]["date-parts"][1][1] == 2022
end

@testset "csl_entry: doi fallback field when key isn't a DOI" begin
    md = Dict{String,Any}(
        "key" => "arxiv:1706.03762",
        "authors" => ["Ashish Vaswani"],
        "year" => 2017,
        "doi" => "10.99/fallback",
    )
    e = csl_entry(md)
    @test e["DOI"] == "10.99/fallback"
    @test e["URL"] == "https://doi.org/10.99/fallback"
end

@testset "write_csl: writes a JSON array, skips non-ok entries" begin
    mktempdir() do root
        store = open_store(root)

        # one journal article (ok), one arxiv preprint (ok), one failed (skip)
        BiblioFetch.write_metadata!(
            store,
            "10.1/a",
            Dict(
                "key" => "10.1/a",
                "authors" => ["John Smith"],
                "title" => "Paper A",
                "journal" => "Journal X",
                "year" => 2019,
                "status" => "ok",
            ),
        )
        BiblioFetch.write_metadata!(
            store,
            "arxiv:2020.0001",
            Dict(
                "key" => "arxiv:2020.0001",
                "authors" => ["Jane Doe"],
                "title" => "Preprint C",
                "year" => 2020,
                "status" => "ok",
            ),
        )
        BiblioFetch.write_metadata!(
            store,
            "10.1/dead",
            Dict(
                "key" => "10.1/dead",
                "authors" => ["Dead Author"],
                "title" => "Not downloaded",
                "year" => 2019,
                "status" => "failed",
            ),
        )

        out = joinpath(root, "refs.json")
        n = write_csl(store, out)
        @test n == 2

        parsed = JSON3.read(read(out))
        @test length(parsed) == 2
        ids = Set(String(p["id"]) for p in parsed)
        @test "Smith2019" in ids
        @test "Doe2020" in ids

        # spot-check that "Not downloaded" is absent (the failed entry was skipped)
        text = read(out, String)
        @test !occursin("Not downloaded", text)
        # journal article surfaces as article-journal, preprint as manuscript
        @test occursin("\"article-journal\"", text)
        @test occursin("\"manuscript\"", text)
    end
end

@testset "write_csl: collision suffixing matches BibTeX export" begin
    mktempdir() do root
        store = open_store(root)
        for k in ("10.1/a", "10.1/b")
            BiblioFetch.write_metadata!(
                store,
                k,
                Dict(
                    "key" => k,
                    "authors" => ["John Smith"],
                    "title" => "Paper " * k,
                    "journal" => "Journal X",
                    "year" => 2019,
                    "status" => "ok",
                ),
            )
        end
        out = joinpath(root, "refs.json")
        n = write_csl(store, out)
        @test n == 2
        parsed = JSON3.read(read(out))
        ids = sort([String(p["id"]) for p in parsed])
        @test ids == ["Smith2019", "Smith2019a"]
    end
end
