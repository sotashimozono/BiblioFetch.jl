using BiblioFetch
using SHA
using Test

# Seed: writes metadata and (optionally) a matching PDF. If `hash=true`,
# records the sha256 of the PDF bytes in metadata too.
function _seed_ok!(store, key::String, bytes::Vector{UInt8}; group="", hash::Bool=true)
    p = BiblioFetch.pdf_path(store, key; group=group)
    mkpath(dirname(p))
    open(p, "w") do io
        write(io, bytes)
    end
    md = Dict{String,Any}(
        "key" => key, "status" => "ok", "group" => group, "pdf_path" => p,
    )
    hash && (md["sha256"] = bytes2hex(sha256(bytes)))
    BiblioFetch.write_metadata!(store, key, md)
    return p
end

@testset "doctor: clean store → no issues" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed_ok!(store, "10.1234/a", rand(UInt8, 2048))
        @test isempty(doctor(store))
    end
end

@testset "doctor: flags missing pdf (file removed after fetch)" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        p = _seed_ok!(store, "10.1234/gone", rand(UInt8, 1024))
        rm(p)                       # simulate user deleting the PDF
        issues = doctor(store)
        @test length(issues) == 1
        @test issues[1].kind === :pdf_missing
        @test issues[1].key == "10.1234/gone"
    end
end

@testset "doctor: flags orphan PDFs (file present, no metadata)" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        # Drop a PDF directly into the root that no metadata knows about
        orphan = joinpath(root, "stranger.pdf")
        open(orphan, "w") do io; write(io, "%PDF-1.5 fake"); end
        issues = doctor(store)
        @test length(issues) == 1
        @test issues[1].kind === :orphan_pdf
        @test issues[1].path == orphan
        @test isempty(issues[1].key)
    end
end

@testset "doctor: flags .part leftovers" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        part = joinpath(root, "interrupted.pdf.part")
        open(part, "w") do io; write(io, "partial"); end
        issues = doctor(store)
        @test length(issues) == 1
        @test issues[1].kind === :incomplete_part
        @test issues[1].path == part
    end
end

@testset "doctor: flags sha mismatch when PDF was replaced" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        p = _seed_ok!(store, "10.1234/swapped", rand(UInt8, 2048); hash=true)
        # Replace the file — sha256 in metadata now stale
        open(p, "w") do io; write(io, rand(UInt8, 4096)); end
        issues = doctor(store)
        @test length(issues) == 1
        @test issues[1].kind === :sha_mismatch
        @test issues[1].key == "10.1234/swapped"
    end
end

@testset "doctor: flags empty (0-byte) PDF" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        p = _seed_ok!(store, "10.1234/empty", UInt8[]; hash=false)
        @test filesize(p) == 0
        issues = doctor(store)
        @test any(i -> i.kind === :empty_pdf && i.key == "10.1234/empty", issues)
    end
end

@testset "doctor: metadata without recorded hash doesn't trigger sha_mismatch" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed_ok!(store, "10.1234/unhashed", rand(UInt8, 2048); hash=false)
        issues = doctor(store)
        @test !any(i -> i.kind === :sha_mismatch, issues)
    end
end

@testset "fix!(:incomplete_part): removes .part, returns count" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        a = joinpath(root, "a.pdf.part")
        b = joinpath(root, "b.pdf.part")
        open(a, "w") do io; write(io, "x"); end
        open(b, "w") do io; write(io, "y"); end
        issues = doctor(store)
        @test length(issues) == 2
        n = BiblioFetch.fix!(store, issues)
        @test n == 2
        @test !isfile(a)
        @test !isfile(b)
    end
end

@testset "fix!(:pdf_missing): clears pdf_path in metadata, leaves the rest" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        p = _seed_ok!(store, "10.1234/gone", rand(UInt8, 1024))
        rm(p)
        issues = doctor(store)
        @test any(i -> i.kind === :pdf_missing, issues)
        BiblioFetch.fix!(store, issues)
        md = BiblioFetch.read_metadata(store, "10.1234/gone")
        @test md["pdf_path"] == ""
        @test md["status"] == "ok"       # left as-is; user decides whether to re-fetch
    end
end

@testset "fix!: orphan/empty/sha_mismatch are opt-in via `kinds`" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        orphan = joinpath(root, "stranger.pdf")
        open(orphan, "w") do io; write(io, "%PDF-fake"); end
        issues = doctor(store)
        @test any(i -> i.kind === :orphan_pdf, issues)

        # Default kinds don't touch orphans
        BiblioFetch.fix!(store, issues)
        @test isfile(orphan)

        # Explicit opt-in removes
        BiblioFetch.fix!(store, issues; kinds=(:orphan_pdf,))
        @test !isfile(orphan)
    end
end

@testset "fix!(:sha_mismatch): clears hash, leaves file" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        p = _seed_ok!(store, "10.1234/swap", rand(UInt8, 2048); hash=true)
        new_bytes = rand(UInt8, 4096)
        open(p, "w") do io; write(io, new_bytes); end
        issues = doctor(store)
        @test any(i -> i.kind === :sha_mismatch, issues)

        BiblioFetch.fix!(store, issues; kinds=(:sha_mismatch,))
        md = BiblioFetch.read_metadata(store, "10.1234/swap")
        @test md["sha256"] == ""        # stale hash cleared
        @test isfile(p) && read(p) == new_bytes   # file untouched
    end
end
