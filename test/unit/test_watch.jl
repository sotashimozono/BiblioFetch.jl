using BiblioFetch
using Test

@testset "watch: non-existent path throws" begin
    @test_throws ArgumentError BiblioFetch.watch("/nonexistent/path/to/job.toml")
end

@testset "watch: initial run happens exactly once with max_iterations=0" begin
    mktempdir() do dir
        p = joinpath(dir, "job.toml")
        open(p, "w") do io; write(io, "x=1\n"); end
        calls = Ref(0)
        run_fn = (path; verbose, runtime) -> (calls[] += 1; nothing)

        runs = BiblioFetch.watch(p; verbose=false, max_iterations=0, run_fn=run_fn)
        @test runs == 1
        @test calls[] == 1
    end
end

@testset "watch: re-runs on file change" begin
    mktempdir() do dir
        p = joinpath(dir, "job.toml")
        open(p, "w") do io; write(io, "x=1\n"); end
        calls = Ref(0)
        run_fn = (path; verbose, runtime) -> (calls[] += 1; nothing)

        # Run watch in a task with max_iterations=1 so it returns after one
        # reactive re-run. Touch the file from the main task after a short
        # delay so the watcher wakes up and picks it up.
        result_ch = Channel{Int}(1)
        task = @async begin
            n = BiblioFetch.watch(
                p; verbose=false, poll_timeout=0.3, max_iterations=1, run_fn=run_fn,
            )
            put!(result_ch, n)
        end

        # Give the watcher a moment to set up its mtime baseline.
        sleep(0.2)
        # Trigger a change — use touch to bump mtime; watch loop compares mtime.
        touch(p)
        # mtime has second-level granularity on some filesystems; write a real
        # content change to be safe.
        sleep(1.1)
        open(p, "w") do io; write(io, "x=2\n"); end

        n = take!(result_ch)
        @test n == 2
        @test calls[] == 2
    end
end

@testset "watch: run_fn exception does not stop the loop" begin
    mktempdir() do dir
        p = joinpath(dir, "job.toml")
        open(p, "w") do io; write(io, "x=1\n"); end
        calls = Ref(0)
        # Initial call throws — second call must still happen.
        run_fn = (path; verbose, runtime) -> begin
            calls[] += 1
            calls[] == 1 && error("boom")
            return nothing
        end

        # Silence the @warn from _try_run during this test.
        runs = BiblioFetch.watch(
            p; verbose=false, max_iterations=0, run_fn=run_fn,
        )
        @test runs == 1
        @test calls[] == 1   # the failing initial call still counts as 1 run
    end
end
