const DEFAULT_CONFIG_PATH = joinpath(homedir(), ".config", "bibliofetch", "config.toml")
const DEFAULT_STORE_ROOT = joinpath(homedir(), "papers")

struct Runtime
    hostname::String
    profile::String
    proxy::Union{String,Nothing}
    proxy_source::Symbol        # :env | :profile | :none
    reachable::Union{Bool,Missing}   # can we reach an OA API through the chosen route?
    store_root::String
    email::Union{String,Nothing}
    mode::Symbol                # :direct | :tunneled | :oa_only | :unknown
    config_path::Union{String,Nothing}
end

function _read_config(path::AbstractString)
    isfile(path) || return Dict{String,Any}()
    try
        return TOML.parsefile(path)
    catch e
        @warn "BiblioFetch: failed to parse config" path exception=e
        return Dict{String,Any}()
    end
end

"""
    load_config(; path = ENV["BIBLIOFETCH_CONFIG"] or default)
        -> (config::Dict, path_or_nothing)

Read and parse the global BiblioFetch config TOML. Returns `(Dict(), nothing)`
when no file is present at `path`. The default location is
`~/.config/bibliofetch/config.toml`; `\$BIBLIOFETCH_CONFIG` overrides it.
"""
function load_config(;
    path::AbstractString=get(ENV, "BIBLIOFETCH_CONFIG", DEFAULT_CONFIG_PATH)
)
    cfg = _read_config(path)
    return cfg, (isfile(path) ? path : nothing)
end

function _pick_profile(cfg::AbstractDict, hostname::AbstractString)
    profiles = get(cfg, "profiles", Dict{String,Any}())
    haskey(profiles, hostname) && return hostname, profiles[hostname]
    # Allow short-prefix match (e.g. hostname "panza.example" against profile "panza")
    for (name, body) in profiles
        if startswith(hostname, string(name) * ".")
            return String(name), body
        end
    end
    return "default", get(cfg, "defaults", Dict{String,Any}())
end

function _env_proxy()
    for k in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy")
        v = get(ENV, k, "")
        isempty(v) || return v
    end
    return nothing
end

"""
    probe_proxy(proxy; url = "https://api.crossref.org/works?rows=0", timeout = 5)

Return `true` if a GET through `proxy` to `url` succeeds within `timeout` seconds.
Also usable with `proxy === nothing` to probe direct reachability.
"""
function probe_proxy(
    proxy::Union{AbstractString,Nothing};
    url::AbstractString="https://api.crossref.org/works?rows=0",
    timeout::Real=5,
)
    try
        kw = (;
            connect_timeout=timeout,
            readtimeout=timeout,
            retry=false,
            status_exception=false,
        )
        resp = proxy === nothing ? HTTP.get(url; kw...) : HTTP.get(url; proxy=proxy, kw...)
        return 200 <= resp.status < 400
    catch
        return false
    end
end

function _classify_mode(proxy, proxy_source, reachable)
    proxy === nothing && return :oa_only
    reachable === false && return :oa_only
    # localhost / 127.0.0.1 proxy strongly suggests reverse-tunnel setup
    try
        host = URIs.URI(proxy).host
        if host in ("localhost", "127.0.0.1", "::1") || startswith(host, "127.")
            return :tunneled
        end
    catch
    end
    return :direct
end

"""
    detect_environment(; probe = true) -> Runtime

Detect hostname, applicable config profile, effective proxy (env > profile),
optionally probe reachability, and classify the operating mode.
"""
function detect_environment(; probe::Bool=true)
    cfg, cfg_path = load_config()
    host = gethostname()
    profile_name, profile = _pick_profile(cfg, host)

    env_px = _env_proxy()
    profile_px = get(profile, "proxy", nothing)
    if profile_px === ""
        ;
        profile_px = nothing;
    end

    proxy, source = if env_px !== nothing
        (env_px, :env)
    elseif profile_px !== nothing
        (string(profile_px), :profile)
    else
        (nothing, :none)
    end

    reachable = probe ? probe_proxy(proxy) : missing
    mode = _classify_mode(proxy, source, reachable)

    defaults = get(cfg, "defaults", Dict{String,Any}())
    store_root = expanduser(
        string(get(profile, "store_root", get(defaults, "store_root", DEFAULT_STORE_ROOT)))
    )
    email = let e = get(profile, "email", get(defaults, "email", nothing))
        e === nothing || e == "" ? nothing : string(e)
    end

    return Runtime(
        host, profile_name, proxy, source, reachable, store_root, email, mode, cfg_path
    )
end

"""
    effective_runtime(; probe = true) -> Runtime

Alias for `detect_environment`; kept as the public "what should I use right now?" accessor.
"""
effective_runtime(; kwargs...) = detect_environment(; kwargs...)

function Base.show(io::IO, ::MIME"text/plain", rt::Runtime)
    route = rt.proxy === nothing ? "direct" : "via proxy"
    println(io, "BiblioFetch runtime")
    println(io, "  hostname        : ", rt.hostname)
    println(io, "  profile         : ", rt.profile)
    println(
        io, "  config          : ", rt.config_path === nothing ? "(none)" : rt.config_path
    )
    println(io, "  mode            : ", rt.mode)
    println(
        io,
        "  proxy           : ",
        rt.proxy === nothing ? "(none)" : rt.proxy,
        "  [",
        rt.proxy_source,
        "]",
    )
    println(io, "  reachable ($(route)): ", rt.reachable)
    println(io, "  store root      : ", rt.store_root)
    print(
        io,
        "  email           : ",
        rt.email === nothing ? "(unset — Unpaywall will be skipped)" : rt.email,
    )
end
