using BiblioFetch
using Dates
using Test

# Pidfile-based StoreLock — see issue #52. Two `bibliofetch run` invocations
# against the same store can race on the same metadata key, with
# last-writer-wins TOML truncation. The lock refuses concurrent runs at the
# store level (one pidfile per store, kept under <store.root>/.metadata/run.pid).

@testset "StoreLock: acquire is exclusive (second acquire throws)" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        a = BiblioFetch.StoreLock(store)
        BiblioFetch.acquire_store_lock!(a)
        @test isfile(a.path)

        b = BiblioFetch.StoreLock(store)
        @test_throws ErrorException BiblioFetch.acquire_store_lock!(b)

        BiblioFetch.release_store_lock!(a)
        @test !isfile(a.path)
    end
end

@testset "StoreLock: force=true reclaims a held lock" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        a = BiblioFetch.StoreLock(store)
        BiblioFetch.acquire_store_lock!(a)
        @test isfile(a.path)

        b = BiblioFetch.StoreLock(store)
        # Without force, this would throw; force=true lets us steal it.
        BiblioFetch.acquire_store_lock!(b; force=true)
        @test isfile(b.path)

        BiblioFetch.release_store_lock!(b)
    end
end

@testset "StoreLock: stale lock is auto-reclaimed" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        # Use a tiny stale window so we can age the lock with a back-dated
        # timestamp without sleeping in the test.
        a = BiblioFetch.StoreLock(store; stale_after_s=1)
        # Hand-write a stale pidfile (timestamp 1 hour ago).
        mkpath(dirname(a.path))
        old = Dates.now() - Dates.Hour(1)
        open(a.path, "w") do io
            println(io, "ghost-host")
            println(io, "999999")
            println(io, Dates.format(old, "yyyy-mm-ddTHH:MM:SS"))
        end
        @test isfile(a.path)

        # Stale → acquire succeeds without force, overwriting the file with
        # our own pid + current timestamp.
        BiblioFetch.acquire_store_lock!(a)
        lines = readlines(a.path)
        @test length(lines) >= 3
        @test strip(lines[2]) == string(getpid())

        BiblioFetch.release_store_lock!(a)
    end
end

@testset "with_store_lock: releases on exception inside the body" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        @test_throws ErrorException BiblioFetch.with_store_lock(store) do
            error("boom")
        end
        # The lock file must be cleaned up even though the body threw.
        lock = BiblioFetch.StoreLock(store)
        @test !isfile(lock.path)

        # And we must be able to re-acquire afterwards (no leftover state).
        BiblioFetch.with_store_lock(store) do
            @test isfile(lock.path)
        end
        @test !isfile(lock.path)
    end
end
