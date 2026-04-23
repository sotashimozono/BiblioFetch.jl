using BiblioFetch
using Test

@testset "parse_bibtex: single @article with doi" begin
    text = """
    @article{Smith2019,
      author  = {John Smith and Jane Doe},
      title   = {Example paper},
      journal = {Physical Review B},
      year    = {2019},
      doi     = {10.1103/PhysRevB.99.214433}
    }
    """
    es = parse_bibtex(text)
    @test length(es) == 1
    e = es[1]
    @test e.type == "article"
    @test e.citekey == "Smith2019"
    @test e.fields["doi"] == "10.1103/PhysRevB.99.214433"
    @test e.fields["author"] == "John Smith and Jane Doe"
end

@testset "parse_bibtex: @misc with eprint + archivePrefix" begin
    text = """
    @misc{Vaswani2017,
      author        = {Ashish Vaswani and others},
      title         = {Attention Is All You Need},
      eprint        = {1706.03762},
      archivePrefix = {arXiv}
    }
    """
    es = parse_bibtex(text)
    @test length(es) == 1
    @test es[1].fields["eprint"] == "1706.03762"
    @test es[1].fields["archiveprefix"] == "arXiv"
end

@testset "parse_bibtex: multiple entries + unbalanced junk outside" begin
    text = """
    Some preamble that isn't a bib entry.
    @article{A, doi = {10.1/a}}
    @misc{B, eprint = {1234.5678}, archivePrefix = {arXiv}}
    % comment line
    @book{C, title = {Some title}}
    """
    es = parse_bibtex(text)
    citekeys = [e.citekey for e in es]
    @test "A" in citekeys
    @test "B" in citekeys
    @test "C" in citekeys
    @test length(es) == 3
end

@testset "parse_bibtex: tolerates nested braces inside field values" begin
    text = """
    @article{VanDerWaals2020,
      author = {J. D. {van der Waals} and A. B. {C}},
      title  = {{Van der Waals} forces},
      doi    = {10.1/vdw}
    }
    """
    es = parse_bibtex(text)
    @test length(es) == 1
    @test es[1].fields["doi"] == "10.1/vdw"
end

@testset "parse_bibtex: quoted string values also work" begin
    text = """
    @article{Quoted, doi = "10.1/quoted", title = "Quoted title"}
    """
    es = parse_bibtex(text)
    @test length(es) == 1
    @test es[1].fields["doi"] == "10.1/quoted"
    @test es[1].fields["title"] == "Quoted title"
end

@testset "bibentry_to_ref: doi wins over eprint / url" begin
    e = BibEntry(
        "article",
        "X",
        Dict(
            "doi" => "10.1/doi",
            "eprint" => "1234.5678",
            "archiveprefix" => "arXiv",
            "url" => "https://doi.org/10.1/some-other",
        ),
    )
    @test bibentry_to_ref(e) == "10.1/doi"
end

@testset "bibentry_to_ref: eprint alone yields arxiv: prefix" begin
    e = BibEntry("misc", "X", Dict("eprint" => "1706.03762", "archiveprefix" => "arXiv"))
    @test bibentry_to_ref(e) == "arxiv:1706.03762"
end

@testset "bibentry_to_ref: eprint without archivePrefix treated as arXiv" begin
    e = BibEntry("misc", "X", Dict("eprint" => "2001.02100"))
    @test bibentry_to_ref(e) == "arxiv:2001.02100"
end

@testset "bibentry_to_ref: url fallback parses doi.org / arxiv.org" begin
    e = BibEntry(
        "article", "X", Dict("url" => "https://doi.org/10.1103/PhysRevB.99.214433")
    )
    @test bibentry_to_ref(e) == "10.1103/PhysRevB.99.214433"

    e2 = BibEntry("misc", "X", Dict("url" => "https://arxiv.org/abs/2101.01234"))
    @test bibentry_to_ref(e2) == "arxiv:2101.01234"
end

@testset "bibentry_to_ref: nothing when no usable identifier" begin
    e = BibEntry("article", "X", Dict("title" => "Some title", "author" => "Someone"))
    @test bibentry_to_ref(e) === nothing
end

@testset "import_bib!: parses a real-ish .bib and queues refs" begin
    mktempdir() do dir
        bib = joinpath(dir, "refs.bib")
        open(bib, "w") do io
            write(
                io,
                """
      @article{Smith2019,
        author = {John Smith},
        doi    = {10.1103/PhysRevB.99.214433}
      }

      @misc{Vaswani2017,
        author        = {Ashish Vaswani},
        eprint        = {1706.03762},
        archivePrefix = {arXiv}
      }

      @article{NoIdent,
        author = {Missing Identifier},
        title  = {Unreachable paper}
      }

      @article{UrlOnly,
        author = {UrlAuthor},
        url    = {https://arxiv.org/abs/2001.02100}
      }
      """,
            )
        end
        store = BiblioFetch.open_store(joinpath(dir, "papers"))
        res = import_bib!(store, bib)

        @test length(res.added) == 3
        @test length(res.skipped) == 1
        @test res.skipped[1].citekey == "NoIdent"

        keys = Set(a.key for a in res.added)
        @test "10.1103/physrevb.99.214433" in keys     # normalized (lowercased)
        @test "arxiv:1706.03762" in keys
        @test "arxiv:2001.02100" in keys

        # All queued entries have status=pending on disk
        for a in res.added
            md = BiblioFetch.read_metadata(store, a.key)
            @test md["status"] == "pending"
        end
    end
end

@testset "import_bib!: non-existent path throws" begin
    @test_throws ArgumentError import_bib!(BiblioFetch.Store("/tmp"), "/nowhere/fake.bib")
end

@testset "import_bib!: malformed entry doesn't abort the whole import" begin
    mktempdir() do dir
        bib = joinpath(dir, "refs.bib")
        open(bib, "w") do io
            write(
                io,
                """
      @article{Good,
        doi = {10.1234/good}
      }

      @article{Broken, doi = {10.1/broken   <-- unbalanced brace below>
        author = {Whoops

      @misc{StillGood,
        eprint = {1111.2222}
      }
      """,
            )
        end
        store = BiblioFetch.open_store(joinpath(dir, "papers"))
        res = import_bib!(store, bib)
        # We expect to recover at least the Good entry; StillGood may or may not
        # parse depending on where the broken entry ends.
        keys = Set(a.key for a in res.added)
        @test "10.1234/good" in keys
    end
end
