const CLI_HELP = """
BiblioFetch — bulk literature fetcher (DOI / arXiv → local PDF store)

Usage:
  bibliofetch env                         Show detected runtime (hostname, proxy, mode)
  bibliofetch run <job.toml>              Execute a job TOML (groups, parallel, log)
  bibliofetch add <ref> [<ref> …]         Queue refs into the global store
  bibliofetch add -f <file>               Queue from a file (one ref per line; '#' comments ok)
  bibliofetch sync [--force] [--quiet]    Fetch all pending/failed entries in the global store
  bibliofetch fetch <ref> [--force]       Fetch one reference into the global store
  bibliofetch list [--all]                List global store entries
  bibliofetch info <ref>                  Show stored metadata for one entry
  bibliofetch help                        Show this message

Reference forms:
  DOI          10.1103/PhysRevB.99.214433
  arXiv        arxiv:1905.07639   or   1905.07639
  URL          https://doi.org/10.1103/...     https://arxiv.org/abs/1905.07639

Environment overrides config file:
  HTTPS_PROXY / HTTP_PROXY       explicit proxy
  BIBLIOFETCH_CONFIG             path to config.toml (default ~/.config/bibliofetch/config.toml)
"""

function _read_refs_file(path::AbstractString)
    lines = String[]
    for raw in eachline(path)
        t = strip(raw)
        (isempty(t) || startswith(t, "#")) && continue
        push!(lines, String(t))
    end
    return lines
end

function _cmd_env(_args)
    rt = detect_environment()
    show(stdout, MIME("text/plain"), rt)
    println()
    # helpful hints
    if rt.config_path === nothing
        println("\nHint: no config file at $(DEFAULT_CONFIG_PATH). Example:")
        println("""
          [defaults]
          email = "souta.shimozono@gmail.com"
          store_root = "~/papers"

          [profiles.panza]
          proxy = "http://proxy.univ.example:8080"

          [profiles.remote_host]
          proxy = "http://localhost:18080"   # via  ssh -R 18080:proxy.univ:8080
        """)
    end
    if rt.email === nothing
        println("\nNote: email is unset — Unpaywall (OA lookup) will be skipped.")
    end
    return 0
end

function _cmd_add(args)
    refs = String[]
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "-f" || a == "--file"
            i += 1; i <= length(args) || (println(stderr, "add: -f needs a path"); return 2)
            append!(refs, _read_refs_file(args[i]))
        else
            push!(refs, a)
        end
        i += 1
    end
    isempty(refs) && (println(stderr, "add: no references given"); return 2)
    rt = detect_environment(probe = false)
    store = open_store(rt.store_root)
    n_added = 0
    for r in refs
        try
            key = queue_reference!(store, r)
            println(key)
            n_added += 1
        catch e
            println(stderr, "  skip $r → $(sprint(showerror, e))")
        end
    end
    println(stderr, "queued: $n_added → $(store.root)")
    return 0
end

function _cmd_sync(args)
    force = "--force" in args
    quiet = ("--quiet" in args) || ("-q" in args)
    rt = detect_environment()
    store = open_store(rt.store_root)
    !quiet && (show(stdout, MIME("text/plain"), rt); println(); println())
    results = sync!(store; rt = rt, only_pending = !force, verbose = !quiet)
    n_ok = count(r -> r.ok, results)
    println("\nsync: $(n_ok)/$(length(results)) succeeded")
    for r in results
        if !r.ok
            println(stderr, "  ✗ $(r.key) — $(r.error)")
        end
    end
    return n_ok == length(results) ? 0 : 1
end

function _cmd_fetch(args)
    isempty(args) && (println(stderr, "fetch: need a reference"); return 2)
    force = "--force" in args
    refs = filter(a -> !startswith(a, "--"), args)
    rt = detect_environment()
    store = open_store(rt.store_root)
    show(stdout, MIME("text/plain"), rt); println(); println()
    rc = 0
    for r in refs
        key = queue_reference!(store, r)
        res = fetch_paper!(store, key; rt = rt, force = force)
        if res.ok
            println("✓ $(res.key)  [$(res.source)]  → $(res.pdf_path)")
        else
            println(stderr, "✗ $(res.key) — $(res.error)")
            rc = 1
        end
    end
    return rc
end

function _cmd_list(args)
    show_all = "--all" in args
    rt = detect_environment(probe = false)
    store = open_store(rt.store_root)
    for safekey in list_entries(store)
        p = joinpath(store.root, METADATA_DIRNAME, safekey * ".toml")
        md = TOML.parsefile(p)
        status = get(md, "status", "?")
        show_all || status in ("pending", "failed") || continue
        key    = get(md, "key", safekey)
        title  = get(md, "title", "")
        title_short = length(title) > 60 ? title[1:57] * "…" : title
        @printf("  [%-7s] %-45s  %s\n", status, key, title_short)
    end
    return 0
end

function _cmd_info(args)
    isempty(args) && (println(stderr, "info: need a reference"); return 2)
    rt = detect_environment(probe = false)
    store = open_store(rt.store_root)
    for r in args
        key = try; normalize_key(r); catch; r; end
        md = read_metadata(store, key)
        if isempty(md)
            println(stderr, "  (not found) $key")
            continue
        end
        println("── $key ──")
        TOML.print(stdout, md; sorted = true)
        println()
    end
    return 0
end

function _cmd_run(args)
    isempty(args) && (println(stderr, "run: need a job TOML path"); return 2)
    path = args[1]
    quiet = ("--quiet" in args) || ("-q" in args)
    rt = detect_environment()
    !quiet && (show(stdout, MIME("text/plain"), rt); println(); println())
    result = run(path; verbose = !quiet, runtime = rt)
    show(stdout, MIME("text/plain"), result)
    println()
    n_ok = count(e -> e.status === :ok, result.entries)
    return n_ok == length(result.entries) ? 0 : 1
end

"""
    cli_main(args = ARGS) -> Int

Dispatch a `bibliofetch …` command line. Returns exit code.
"""
function cli_main(args::AbstractVector{<:AbstractString} = ARGS)
    if isempty(args) || args[1] in ("-h", "--help", "help")
        print(CLI_HELP); return 0
    end
    cmd, rest = args[1], args[2:end]
    try
        return cmd == "env"   ? _cmd_env(rest)   :
               cmd == "run"   ? _cmd_run(rest)   :
               cmd == "add"   ? _cmd_add(rest)   :
               cmd == "sync"  ? _cmd_sync(rest)  :
               cmd == "fetch" ? _cmd_fetch(rest) :
               cmd == "list"  ? _cmd_list(rest)  :
               cmd == "info"  ? _cmd_info(rest)  :
               (println(stderr, "unknown command: $cmd"); print(CLI_HELP); 2)
    catch e
        println(stderr, "bibliofetch: ", sprint(showerror, e))
        return 1
    end
end
