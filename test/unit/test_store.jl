using BiblioFetch
using Test

@testset "store lifecycle" begin
    mktempdir() do root
        store = open_store(root)
        @test isdir(joinpath(root, BiblioFetch.METADATA_DIRNAME))

        key = BiblioFetch.queue_reference!(store, "10.1103/PhysRevB.99.214433")
        @test key == "10.1103/physrevb.99.214433"
        @test BiblioFetch.has_metadata(store, key)
        @test !BiblioFetch.has_pdf(store, key)

        md = BiblioFetch.read_metadata(store, key)
        @test md["key"]    == key
        @test md["status"] == "pending"
        @test md["group"]  == ""

        info = entry_info(store, key)
        @test info.key    == key
        @test info.status == "pending"

        @test key in list_entries(store) ||
              BiblioFetch._safe_key(key) in list_entries(store)
    end
end

@testset "group-aware pdf_path" begin
    mktempdir() do root
        store = open_store(root)
        key = "arxiv:1706.03762"
        @test BiblioFetch.pdf_path(store, key) == joinpath(root, "arxiv__1706.03762.pdf")
        @test BiblioFetch.pdf_path(store, key; group = "ml") ==
              joinpath(root, "ml", "arxiv__1706.03762.pdf")
        @test BiblioFetch.pdf_path(store, key; group = "/cond-mat/haldane/") ==
              joinpath(root, "cond-mat", "haldane", "arxiv__1706.03762.pdf")

        # metadata path is always flat under .metadata/
        @test BiblioFetch.metadata_path(store, key) ==
              joinpath(root, BiblioFetch.METADATA_DIRNAME, "arxiv__1706.03762.toml")

        # reject path traversal
        @test_throws ArgumentError BiblioFetch.pdf_path(store, key; group = "../evil")
    end
end

@testset "PDF magic bytes" begin
    mktempdir() do dir
        ok_path = joinpath(dir, "ok.pdf")
        open(ok_path, "w") do io
            write(io, "%PDF-1.5\n")
            write(io, rand(UInt8, 2048))
        end
        @test BiblioFetch._looks_like_pdf(ok_path)

        html_path = joinpath(dir, "html.pdf")
        open(html_path, "w") do io
            write(io, "<!DOCTYPE html><html><body>login page</body></html>")
            write(io, rand(UInt8, 2048))
        end
        @test !BiblioFetch._looks_like_pdf(html_path)

        short_path = joinpath(dir, "tiny.pdf")
        open(short_path, "w") do io; write(io, "%PDF-tiny"); end
        @test !BiblioFetch._looks_like_pdf(short_path)
    end
end
