using BiblioFetch
using Test

@testset "_safe_key: distinct keys never collide" begin
    a = "10.1234/foo_bar"
    b = "10.1234/foo/bar"
    @test BiblioFetch._safe_key(a) != BiblioFetch._safe_key(b)
    @test BiblioFetch._legacy_safe_key(a) == BiblioFetch._legacy_safe_key(b)
end

@testset "_safe_key: SHA1 suffix shape" begin
    key = "10.1234/foo_bar"
    slug = BiblioFetch._safe_key(key)
    @test startswith(slug, BiblioFetch._legacy_safe_key(key) * "__")
    suffix = slug[(length(BiblioFetch._legacy_safe_key(key)) + 3):end]
    @test length(suffix) == 8
    @test all(c -> c in "0123456789abcdef", suffix)
end

@testset "queue_reference! + read_metadata round-trip with new slug" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        key = BiblioFetch.queue_reference!(store, "10.1234/foo_bar")
        @test BiblioFetch.has_metadata(store, key)
        md = BiblioFetch.read_metadata(store, key)
        @test md["key"] == key
        @test md["status"] == "pending"

        slug = BiblioFetch._safe_key(key)
        new_path = joinpath(root, BiblioFetch.METADATA_DIRNAME, slug * ".toml")
        @test isfile(new_path)
    end
end

@testset "two previously-colliding keys coexist on disk" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        a = BiblioFetch.queue_reference!(store, "10.1234/foo_bar")
        b = BiblioFetch.queue_reference!(store, "10.1234/foo/bar")
        @test a != b

        slug_a = BiblioFetch._safe_key(a)
        slug_b = BiblioFetch._safe_key(b)
        @test slug_a != slug_b

        path_a = joinpath(root, BiblioFetch.METADATA_DIRNAME, slug_a * ".toml")
        path_b = joinpath(root, BiblioFetch.METADATA_DIRNAME, slug_b * ".toml")
        @test isfile(path_a)
        @test isfile(path_b)

        @test BiblioFetch.read_metadata(store, a)["key"] == a
        @test BiblioFetch.read_metadata(store, b)["key"] == b
    end
end

@testset "backward compat: read legacy un-suffixed metadata file" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        key = "10.1234/foo_bar"
        legacy_slug = BiblioFetch._legacy_safe_key(key)
        legacy_path = joinpath(root, BiblioFetch.METADATA_DIRNAME, legacy_slug * ".toml")
        open(legacy_path, "w") do io
            write(io, """
            key = "10.1234/foo_bar"
            status = "ok"
            group = ""
            title = "legacy entry"
            """)
        end

        @test BiblioFetch.has_metadata(store, key)
        md = BiblioFetch.read_metadata(store, key)
        @test md["key"] == key
        @test md["status"] == "ok"
        @test md["title"] == "legacy entry"
    end
end

@testset "backward compat: read legacy un-suffixed PDF file" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        key = "10.1234/foo_bar"
        legacy_slug = BiblioFetch._legacy_safe_key(key)
        legacy_pdf = joinpath(root, legacy_slug * ".pdf")
        bytes = b"%PDF-1.4\nlegacy content"
        open(legacy_pdf, "w") do io
            write(io, bytes)
        end

        @test BiblioFetch.pdf_path(store, key) == legacy_pdf
        @test BiblioFetch.has_pdf(store, key)
    end
end

@testset "writes default to new-style slug even when legacy file exists" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        key = "10.1234/freshkey"
        new_slug = BiblioFetch._safe_key(key)
        new_path = joinpath(root, BiblioFetch.METADATA_DIRNAME, new_slug * ".toml")

        BiblioFetch.write_metadata!(store, key, Dict("key" => key, "status" => "ok"))
        @test isfile(new_path)
    end
end

@testset "doctor: _collect_pdf_paths handles new-style filenames" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        key = "10.1234/withpdf"
        bytes = rand(UInt8, 1024)
        p = BiblioFetch.pdf_path(store, key)
        mkpath(dirname(p))
        open(p, "w") do io
            write(io, bytes)
        end
        BiblioFetch.write_metadata!(
            store,
            key,
            Dict("key" => key, "status" => "ok", "group" => "", "pdf_path" => p),
        )

        collected = BiblioFetch._collect_pdf_paths(root)
        @test p in collected

        @test isempty(doctor(store))
    end
end
