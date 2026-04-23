"""
    watch(path; verbose = true, runtime = nothing,
          poll_timeout = 5.0, max_iterations = typemax(Int),
          run_fn = run) -> Int

Watch a job TOML file and re-run `run_fn(path; verbose, runtime)` each time the
file is saved. Returns the number of `run_fn` invocations (1 initial + N
reactive runs).

The block-until-change primitive is `FileWatching.watch_file`, which uses OS
file events when supported and falls back to polling otherwise. `poll_timeout`
bounds how long `watch_file` waits before cycling — if the editor replaces the
file (rename-over-write pattern) and the kernel handle goes stale, we still
notice on the next cycle.

Behaves well with Ctrl+C: `InterruptException` is caught and reported as a
normal stop, not propagated.

`run_fn` and `max_iterations` are injectable so the watch loop can be tested
without starting a real BiblioFetch job.
"""
function watch(
    path::AbstractString;
    verbose::Bool=true,
    runtime::Union{Runtime,Nothing}=nothing,
    poll_timeout::Real=5.0,
    max_iterations::Integer=typemax(Int),
    run_fn=run,
)
    isfile(path) || throw(ArgumentError("watch: file not found: $(path)"))
    verbose && @info "watch: starting" path

    # Initial run
    _try_run(run_fn, path, verbose, runtime)
    runs = 1
    last_mtime = mtime(path)

    try
        while runs < max_iterations + 1
            FileWatching.watch_file(path, Float64(poll_timeout))
            # After wake-up, decide whether a real change happened. watch_file
            # also returns on timeout without any event, so gate on mtime.
            isfile(path) || continue
            m = mtime(path)
            m == last_mtime && continue
            last_mtime = m
            verbose && @info "watch: change detected, re-running" path
            _try_run(run_fn, path, verbose, runtime)
            runs += 1
        end
    catch e
        e isa InterruptException || rethrow()
        verbose && @info "watch: interrupted, stopping"
    end
    return runs
end

function _try_run(run_fn, path, verbose, runtime)
    try
        return run_fn(path; verbose=verbose, runtime=runtime)
    catch e
        @warn "watch: run failed, continuing" exception=e
        return nothing
    end
end
