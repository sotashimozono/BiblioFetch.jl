using BiblioFetch
using Test

@testset "M1: chopprefix-based arxiv: stripping" begin
    # The case-insensitive prefix path goes through normalize_key, which
    # lowercases the result. Both upper- and lower-case prefixes must end
    # up as `arxiv:<id>`.
    @test BiblioFetch.normalize_key("ARXIV:1706.03762") == "arxiv:1706.03762"
    @test BiblioFetch.normalize_key("arxiv:1706.03762") == "arxiv:1706.03762"
    @test BiblioFetch.normalize_key("ArXiv:1706.03762v2") == "arxiv:1706.03762v2"
    # Legacy slash form preserved
    @test BiblioFetch.normalize_key("arxiv:cond-mat/0608208") == "arxiv:cond-mat/0608208"
    # Version-spec pseudo-ref (separate code path through chopprefix)
    @test BiblioFetch.normalize_key("ARXIV:1706.03762@all") == "arxiv:1706.03762@all"
end

@testset "M2: extra URL prefixes in normalize_key" begin
    # New DOI URL prefixes
    for src in (
        "https://www.doi.org/10.1234/abc",
        "https://dx.doi.org/10.1234/abc",
        "http://dx.doi.org/10.1234/abc",
        "doi:10.1234/abc",
    )
        @test BiblioFetch.normalize_key(src) == "10.1234/abc"
    end
    # New arXiv URL prefixes
    @test BiblioFetch.normalize_key("arxiv.org/abs/1706.03762") == "arxiv:1706.03762"
    @test BiblioFetch.normalize_key("http://arxiv.org/pdf/1706.03762") == "arxiv:1706.03762"
    # Existing prefixes still work (regression)
    @test BiblioFetch.normalize_key("https://arxiv.org/abs/1706.03762") ==
        "arxiv:1706.03762"
    @test BiblioFetch.normalize_key("https://doi.org/10.1234/abc") == "10.1234/abc"
end

@testset "M3: NFKD-asciification of surnames" begin
    @test BiblioFetch._surname_ascii("Hans Müller") == "Muller"
    @test BiblioFetch._surname_ascii("Sergio François") == "Francois"
    @test BiblioFetch._surname_ascii("Lars Hörmander") == "Hormander"
    # Unchanged for plain ASCII
    @test BiblioFetch._surname_ascii("John Smith") == "Smith"
    # Hyphenated last token still drops the hyphen (regex strips non-letters)
    @test BiblioFetch._surname_ascii("Klaus von Klitzing") == "Klitzing"
    # Empty input is well-defined
    @test BiblioFetch._surname_ascii("") == ""
    @test BiblioFetch._surname_ascii("   ") == ""
end

@testset "M7: parallel job loads with parallel > 1" begin
    # Indirect smoke test: ensure the Channel-gated parallel scheduler is
    # reachable through the normal job-loading path. The end-to-end run is
    # exercised by test_run.jl / test_job.jl with the existing test fixtures;
    # here we just confirm the new gate doesn't break job construction.
    mktempdir() do dir
        target = replace(joinpath(dir, "papers"), '\\' => '/')
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
            write(
                io,
                """
                [folder]
                target = "$(target)"

                [fetch]
                email = "test@example.com"
                parallel = 3

                [doi]
                list = ["10.1234/x", "10.1234/y", "10.1234/z", "10.1234/w"]
                """,
            )
        end
        job = load_job(job_path)
        @test job.parallel == 3
        @test length(job.refs) == 4
    end
end
