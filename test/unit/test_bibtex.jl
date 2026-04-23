using BiblioFetch
using Test

@testset "_bibtex_escape" begin
    @test BiblioFetch._bibtex_escape("plain text") == "plain text"
    @test BiblioFetch._bibtex_escape("A & B") == "A \\& B"
    @test BiblioFetch._bibtex_escape("50%") == "50\\%"
    @test BiblioFetch._bibtex_escape("a_b") == "a\\_b"
    @test BiblioFetch._bibtex_escape("{\$x\$}") == "\\{\\\$x\\\$\\}"
    @test BiblioFetch._bibtex_escape("a\\b") == "a\\textbackslash{}b"
    # Unicode passes through (biber/biblatex-friendly)
    @test BiblioFetch._bibtex_escape("Müller Schrödinger") == "Müller Schrödinger"
end

@testset "_bibtex_key generation" begin
    md = Dict{String,Any}(
        "authors" => ["John Smith", "Jane Doe"],
        "year" => 2019,
        "key" => "10.1103/physrevb.99.214433",
    )
    @test BiblioFetch._bibtex_key(md) == "Smith2019"

    # Last-word of name = surname (handles Western convention)
    md2 = Dict{String,Any}("authors" => ["Hans-Peter Müller"], "year" => 2021)
    @test BiblioFetch._bibtex_key(md2) == "Mller2021"  # ASCII-only sanitization

    # No authors → fall back to sanitized key
    md3 = Dict{String,Any}("year" => 2020, "key" => "arxiv:1706.03762")
    @test BiblioFetch._bibtex_key(md3) == "arxiv170603762" * "" ||
        startswith(BiblioFetch._bibtex_key(md3), "arxiv17060376")

    # No year → "nodate"
    md4 = Dict{String,Any}("authors" => ["Alice Brown"])
    @test BiblioFetch._bibtex_key(md4) == "Brownnodate"

    # Year as string
    md5 = Dict{String,Any}("authors" => ["Alice Brown"], "year" => "2022")
    @test BiblioFetch._bibtex_key(md5) == "Brown2022"
end

@testset "bibtex_entry: journal article" begin
    md = Dict{String,Any}(
        "key" => "10.1103/physrevb.99.214433",
        "title" => "Example paper",
        "authors" => ["John Smith", "Jane Doe"],
        "journal" => "Physical Review B",
        "year" => 2019,
    )
    s = BiblioFetch.bibtex_entry(md; key="Smith2019")
    @test startswith(s, "@article{Smith2019,")
    @test occursin("author  = {John Smith and Jane Doe}", s)
    @test occursin("title   = {Example paper}", s)
    @test occursin("journal = {Physical Review B}", s)
    @test occursin("year    = {2019}", s)
    @test occursin("doi     = {10.1103/physrevb.99.214433}", s)
    @test occursin("url     = {https://doi.org/10.1103/physrevb.99.214433}", s)
    @test endswith(strip(s), "}")
end

@testset "bibtex_entry: arXiv preprint" begin
    md = Dict{String,Any}(
        "key" => "arxiv:1706.03762",
        "title" => "Attention Is All You Need",
        "authors" => ["Ashish Vaswani"],
        "year" => 2017,
    )
    s = BiblioFetch.bibtex_entry(md; key="Vaswani2017")
    @test startswith(s, "@misc{Vaswani2017,")
    @test occursin("eprint  = {1706.03762}", s)
    @test occursin("archivePrefix = {arXiv}", s)
    @test !occursin("journal", s)
    @test !occursin("doi", s)
end

@testset "bibtex_entry: arxiv_id alongside DOI" begin
    # Paper has a DOI *and* a known arXiv preprint (Crossref relation.has-preprint)
    md = Dict{String,Any}(
        "key" => "10.21468/scipostphys.1.1.001",
        "title" => "Q quenches",
        "authors" => ["Lorenzo Piroli"],
        "journal" => "SciPost Physics",
        "year" => 2016,
        "arxiv_id" => "1604.08141",
    )
    s = BiblioFetch.bibtex_entry(md; key="Piroli2016")
    @test startswith(s, "@article{")
    @test occursin("doi     = {10.21468/scipostphys.1.1.001}", s)
    @test occursin("eprint  = {1604.08141}", s)
    @test occursin("archivePrefix = {arXiv}", s)
end

@testset "bibtex_entry: escaping in fields" begin
    md = Dict{String,Any}(
        "key" => "10.1/dummy",
        "title" => "Black & Scholes: 50% of the theory",
        "authors" => ["Alice_Surname"],
        "journal" => "J. of {Weird} Chars",
        "year" => 2000,
    )
    s = BiblioFetch.bibtex_entry(md; key="test")
    @test occursin("Black \\& Scholes: 50\\% of the theory", s)
    @test occursin("Alice\\_Surname", s)
    @test occursin("J. of \\{Weird\\} Chars", s)
end

@testset "write_bibtex: iterates ok entries + collision suffixing" begin
    mktempdir() do root
        store = open_store(root)

        # Three entries: two by Smith2019 (collision), one by Doe2020; one failed (skip)
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
            "10.1/b",
            Dict(
                "key" => "10.1/b",
                "authors" => ["John Smith"],
                "title" => "Paper B",
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

        bib_path = joinpath(root, "refs.bib")
        n = BiblioFetch.write_bibtex(store, bib_path)
        @test n == 3                       # failed entry skipped
        text = read(bib_path, String)

        @test occursin("@article{Smith2019,", text)
        @test occursin("@article{Smith2019a,", text)
        @test occursin("@misc{Doe2020,", text)
        @test !occursin("Not downloaded", text)
    end
end
