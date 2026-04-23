using BiblioFetch
using Test

@testset "normalize_key" begin
    @test normalize_key("10.1103/PhysRevB.99.214433") == "10.1103/physrevb.99.214433"
    @test normalize_key("doi:10.1103/PhysRevB.99.214433") == "10.1103/physrevb.99.214433"
    @test normalize_key("https://doi.org/10.1103/PhysRevB.99.214433/") ==
        "10.1103/physrevb.99.214433"

    @test normalize_key("1706.03762") == "arxiv:1706.03762"
    @test normalize_key("arxiv:1706.03762") == "arxiv:1706.03762"
    @test normalize_key("ArXiv:1706.03762v2") == "arxiv:1706.03762v2"
    @test normalize_key("https://arxiv.org/abs/1706.03762") == "arxiv:1706.03762"

    # legacy arXiv ids
    @test normalize_key("cond-mat/0608208") == "arxiv:cond-mat/0608208"

    @test_throws ArgumentError normalize_key("not a doi or arxiv")
    @test_throws ArgumentError normalize_key("")
end

@testset "is_doi / is_arxiv" begin
    @test is_doi("10.1103/PhysRevB.99.214433")
    @test !is_doi("1706.03762")
    @test !is_doi("arxiv:1706.03762")

    @test is_arxiv("1706.03762")
    @test is_arxiv("arxiv:1706.03762")
    @test is_arxiv("cond-mat/0608208")
    @test !is_arxiv("10.1103/PhysRevB.99.214433")
end
