using BiblioFetch
using SHA
using Test

# Helper: seed an entry whose metadata has a sha256 and a real file on disk.
function _seed_with_hash!(
    store::BiblioFetch.Store, key::String, bytes::Vector{UInt8}; group::String=""
)
    BiblioFetch.write_metadata!(
        store,
        key,
        Dict(
            "key" => key,
            "status" => "ok",
            "group" => group,
            "sha256" => bytes2hex(sha256(bytes)),
        ),
    )
    p = BiblioFetch.pdf_path(store, key; group=group)
    mkpath(dirname(p))
    open(p, "w") do io
        ;
        write(io, bytes);
    end
    # Persist the path back into the metadata so find_duplicates / resolve can
    # locate the file without recomputing.
    md = BiblioFetch.read_metadata(store, key)
    md["pdf_path"] = p
    BiblioFetch.write_metadata!(store, key, md)
    return p
end

@testset "_sha256_file: streaming hash matches direct hash" begin
    mktempdir() do dir
        p = joinpath(dir, "x.pdf")
        data = rand(UInt8, 4096)
        open(p, "w") do io
            ;
            write(io, data);
        end
        @test BiblioFetch._sha256_file(p) == bytes2hex(sha256(data))
    end
end

@testset "find_duplicates: groups entries sharing a hash" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        A = rand(UInt8, 2048)
        B = rand(UInt8, 2048)
        _seed_with_hash!(store, "10.1234/a", A)
        _seed_with_hash!(store, "10.1234/b", A)         # dup of a
        _seed_with_hash!(store, "10.1234/c", A)         # dup of a
        _seed_with_hash!(store, "10.9999/lone", B)      # unique

        groups = BiblioFetch.find_duplicates(store)
        @test length(groups) == 1
        hash, keys = groups[1]
        @test hash == bytes2hex(sha256(A))
        @test keys == ["10.1234/a", "10.1234/b", "10.1234/c"]
    end
end

@testset "find_duplicates: empty store + entries without sha256" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        @test BiblioFetch.find_duplicates(store) == Pair{String,Vector{String}}[]

        # Entry with no sha256 field is skipped (can happen for :failed entries)
        BiblioFetch.write_metadata!(
            store, "10.1/nohash", Dict("key" => "10.1/nohash", "status" => "failed")
        )
        @test BiblioFetch.find_duplicates(store) == Pair{String,Vector{String}}[]
    end
end

@testset "resolve_duplicates!(; apply=false) is a dry run" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        A = rand(UInt8, 3072)
        pa = _seed_with_hash!(store, "10.1234/a", A)
        pb = _seed_with_hash!(store, "10.1234/b", A)

        res = BiblioFetch.resolve_duplicates!(store; apply=false)
        @test length(res.groups) == 1
        @test res.bytes_freed == length(A)
        @test res.canonicals == Dict("10.1234/b" => "10.1234/a")

        # Files still both present, metadata unchanged
        @test isfile(pa) && isfile(pb)
        mdb = BiblioFetch.read_metadata(store, "10.1234/b")
        @test !haskey(mdb, "duplicate_of")
    end
end

@testset "resolve_duplicates!(; apply=true) removes dup files + redirects pdf_path" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        A = rand(UInt8, 4096)
        pa = _seed_with_hash!(store, "10.1234/a", A)
        pb = _seed_with_hash!(store, "10.1234/b", A)
        pc = _seed_with_hash!(store, "10.1234/c", A)

        res = BiblioFetch.resolve_duplicates!(store; apply=true)
        @test res.bytes_freed == 2 * length(A)

        # canonical file untouched
        @test isfile(pa)
        @test read(pa) == A

        # dup files gone
        @test !isfile(pb)
        @test !isfile(pc)

        # dup metadata now redirects pdf_path to canonical + records duplicate_of
        for dup in ("10.1234/b", "10.1234/c")
            md = BiblioFetch.read_metadata(store, dup)
            @test md["duplicate_of"] == "10.1234/a"
            @test md["pdf_path"] == pa
        end

        # running again is idempotent — already-resolved duplicates are skipped
        res2 = BiblioFetch.resolve_duplicates!(store; apply=true)
        @test isempty(res2.groups)
        @test res2.bytes_freed == 0
    end
end

@testset "fetch_paper! :cached path backfills sha256 when missing" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        key = "10.1234/legacy"
        # Pre-dedup entry: no sha256 recorded, but a valid PDF exists
        BiblioFetch.write_metadata!(
            store, key, Dict("key" => key, "status" => "ok", "group" => "")
        )
        data = rand(UInt8, 2048)
        p = BiblioFetch.pdf_path(store, key)
        mkpath(dirname(p))
        open(p, "w") do io
            ;
            write(io, data);
        end

        rt = BiblioFetch.detect_environment(; probe=false)
        res = BiblioFetch.fetch_paper!(store, key; rt=rt, verbose=false)
        @test res.source === :cached

        md = BiblioFetch.read_metadata(store, key)
        @test md["sha256"] == bytes2hex(sha256(data))
    end
end
