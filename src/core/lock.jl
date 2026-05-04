"""
    StoreLock(store::Store; stale_after_s = 600)

Best-effort exclusive lock for write operations on a store. Implemented as a
pidfile at `<store.root>/.metadata/run.pid` containing hostname + pid +
ISO timestamp. A lock older than `stale_after_s` (default 10 min) is treated
as abandoned and reclaimed.

Use via [`with_store_lock`](@ref).
"""
struct StoreLock
    path::String
    stale_after_s::Int
end

function StoreLock(store::Store; stale_after_s::Integer=600)
    StoreLock(joinpath(store.root, METADATA_DIRNAME, "run.pid"), Int(stale_after_s))
end

function _read_lock(lock::StoreLock)
    isfile(lock.path) || return nothing
    try
        lines = readlines(lock.path)
        length(lines) >= 3 || return nothing
        host = strip(lines[1])
        pid_str = strip(lines[2])
        ts_str = strip(lines[3])
        pid = tryparse(Int, pid_str)
        pid === nothing && return nothing
        ts = try
            Dates.DateTime(ts_str)
        catch
            return nothing
        end
        return (; host=String(host), pid, ts)
    catch
        return nothing
    end
end

function _is_stale(lock::StoreLock, info)
    info === nothing && return true
    age = Dates.value(Dates.now() - info.ts) / 1000
    return age > lock.stale_after_s
end

function acquire_store_lock!(lock::StoreLock; force::Bool=false)
    mkpath(dirname(lock.path))
    info = _read_lock(lock)
    if info !== nothing && !_is_stale(lock, info) && !force
        throw(
            ErrorException(
                "store is in use by host=$(info.host) pid=$(info.pid) since $(info.ts). " *
                "If that process is no longer running, retry with --force-lock or remove $(lock.path).",
            ),
        )
    end
    open(lock.path, "w") do io
        println(io, gethostname())
        println(io, getpid())
        println(io, Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS"))
    end
    return lock
end

function release_store_lock!(lock::StoreLock)
    try
        isfile(lock.path) && rm(lock.path; force=true)
    catch
        # best effort
    end
    return nothing
end

"""
    with_store_lock(fn, store::Store; force = false, stale_after_s = 600)

Run `fn()` while holding an exclusive [`StoreLock`](@ref) on `store`. Releases
the lock on normal return or exception. Pass `force=true` to override an
existing live lock (useful for known-dead processes).
"""
function with_store_lock(fn, store::Store; force::Bool=false, stale_after_s::Integer=600)
    lock = StoreLock(store; stale_after_s=stale_after_s)
    acquire_store_lock!(lock; force=force)
    try
        return fn()
    finally
        release_store_lock!(lock)
    end
end
