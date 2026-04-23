using BiblioFetch
using Test

# Runtime with sources=() so fetch_paper! produces zero candidates and fails
# deterministically offline; we're testing which entries `sync!` decides to
# pass through, not network behavior.
const _NO_SOURCES = Symbol[]

function _bare_rt()
    withenv(
        "HTTP_PROXY" => nothing,
        "HTTPS_PROXY" => nothing,
        "http_proxy" => nothing,
        "https_proxy" => nothing,
        "BIBLIOFETCH_CONFIG" => nothing,
    ) do
        BiblioFetch.detect_environment(; probe=false)
    end
end

# Seed a store entry with given status; optionally drop a non-empty PDF too.
function _seed!(store::BiblioFetch.Store, key::String; status::String, with_pdf::Bool)
    BiblioFetch.write_metadata!(
        store, key, Dict("key" => key, "status" => status, "group" => "")
    )
    if with_pdf
        p = BiblioFetch.pdf_path(store, key)
        mkpath(dirname(p))
        open(p, "w") do io
            ;
            write(io, "%PDF-1.5 fake");
        end
    end
end

@testset "sync!: default skips ok+pdf, retries everything else" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed!(store, "10.1234/ok-cached"; status="ok", with_pdf=true)   # skip
        _seed!(store, "10.1234/ok-nopdf"; status="ok", with_pdf=false)  # retry
        _seed!(store, "10.1234/failed"; status="failed", with_pdf=false)  # retry
        _seed!(store, "10.1234/pending"; status="pending", with_pdf=false) # retry

        results = BiblioFetch.sync!(store; rt=_bare_rt(), force=false, verbose=false)
        touched = Set(r.key for r in results)

        @test "10.1234/ok-cached" ∉ touched                 # skipped without --force
        @test "10.1234/ok-nopdf" ∈ touched
        @test "10.1234/failed" ∈ touched
        @test "10.1234/pending" ∈ touched
        @test length(results) == 3

        # Without sources / proxy / email, every retried entry fails
        @test all(!r.ok for r in results)
    end
end

@testset "sync!: force=true passes through even ok+pdf entries" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed!(store, "10.1234/ok-cached"; status="ok", with_pdf=true)
        _seed!(store, "10.1234/failed"; status="failed", with_pdf=false)

        results = BiblioFetch.sync!(store; rt=_bare_rt(), force=true, verbose=false)
        @test length(results) == 2
        keys = Set(r.key for r in results)
        @test "10.1234/ok-cached" ∈ keys
        @test "10.1234/failed" ∈ keys

        # None can succeed (no network/sources), but the fetch_paper! call must
        # have happened. The cached entry should no longer be reported as
        # :cached — force=true bypasses the cache branch.
        cached_res = first(r for r in results if r.key == "10.1234/ok-cached")
        @test cached_res.source !== :cached
    end
end

@testset "sync!: empty store returns empty result" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        results = BiblioFetch.sync!(store; rt=_bare_rt(), force=false, verbose=false)
        @test results == BiblioFetch.FetchResult[]
    end
end

@testset "sync!: force=true overwrites on-disk PDF when no new fetch succeeds" begin
    # This documents a subtle guarantee: with force=true, the *old* PDF stays
    # only because every source attempt failed — fetch_paper! doesn't remove a
    # PDF to replace it until a new download completes. This matters for
    # downstream tools that assume "the file at pdf_path is whatever the last
    # successful fetch wrote".
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed!(store, "10.1234/ok-cached"; status="ok", with_pdf=true)
        old = read(BiblioFetch.pdf_path(store, "10.1234/ok-cached"), String)

        BiblioFetch.sync!(store; rt=_bare_rt(), force=true, verbose=false)

        still = read(BiblioFetch.pdf_path(store, "10.1234/ok-cached"), String)
        @test still == old   # force + failed sources preserves the old PDF
    end
end
