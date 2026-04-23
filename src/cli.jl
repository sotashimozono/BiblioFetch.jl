const CLI_HELP = """
BiblioFetch — bulk literature fetcher (DOI / arXiv → local PDF store)

Usage:
  bibliofetch env                         Show detected runtime (hostname, proxy, mode)
  bibliofetch run <job.toml>              Execute a job TOML (groups, parallel, log)
  bibliofetch bib <dir> [--out <path>]    Export BibTeX for all ok entries in a store root
  bibliofetch add <ref> [<ref> …]         Queue refs into the global store
  bibliofetch add -f <file>               Queue from a file (one ref per line; '#' comments ok)
  bibliofetch sync [--force] [--quiet]    Fetch all pending/failed entries in the global store
  bibliofetch fetch <ref> [--force]       Fetch one reference into the global store
  bibliofetch list [--all]                List global store entries
  bibliofetch info <ref> [--raw]          Show stored metadata (pretty; --raw for TOML dump)
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
            i += 1;
            i <= length(args) || (println(stderr, "add: -f needs a path"); return 2)
            append!(refs, _read_refs_file(args[i]))
        else
            push!(refs, a)
        end
        i += 1
    end
    isempty(refs) && (println(stderr, "add: no references given"); return 2)
    rt = detect_environment(; probe=false)
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
    results = sync!(store; rt=rt, only_pending=(!force), verbose=(!quiet))
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
    show(stdout, MIME("text/plain"), rt);
    println();
    println()
    rc = 0
    for r in refs
        key = queue_reference!(store, r)
        res = fetch_paper!(store, key; rt=rt, force=force)
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
    rt = detect_environment(; probe=false)
    store = open_store(rt.store_root)
    for safekey in list_entries(store)
        p = joinpath(store.root, METADATA_DIRNAME, safekey * ".toml")
        md = TOML.parsefile(p)
        status = get(md, "status", "?")
        show_all || status in ("pending", "failed") || continue
        key = get(md, "key", safekey)
        title = get(md, "title", "")
        title_short = length(title) > 60 ? title[1:57] * "…" : title
        @printf("  [%-7s] %-45s  %s\n", status, key, title_short)
    end
    return 0
end

function _humanize_bytes(n::Integer)
    n < 1024 && return string(n, " B")
    n < 1024^2 && return @sprintf("%.1f KB", n / 1024)
    n < 1024^3 && return @sprintf("%.1f MB", n / 1024^2)
    return @sprintf("%.1f GB", n / 1024^3)
end

function _humanize_age(ts_str::AbstractString; now_dt::Dates.DateTime=Dates.now())
    isempty(ts_str) && return ""
    t = try
        Dates.DateTime(ts_str)
    catch
        return ""
    end
    ms = (now_dt - t).value
    ms < 0 && return "in the future"
    secs = ms / 1000
    secs < 5 && return "just now"
    secs < 60 && return @sprintf("%ds ago", round(Int, secs))
    secs < 3600 && return @sprintf("%dm ago", round(Int, secs / 60))
    secs < 86400 && return @sprintf("%.1fh ago", secs / 3600)
    days = secs / 86400
    days < 365 && return @sprintf("%.1fd ago", days)
    return @sprintf("%.1fy ago", days / 365)
end

function _truncate(s::AbstractString, maxlen::Int)
    length(s) <= maxlen ? String(s) : String(s[1:(maxlen - 1)]) * "…"
end

"""
    _format_info_entry(md) -> String

Render the metadata dict for one entry as a human-readable block — column-
aligned key/value rows, followed by an attempts trace if the entry has one.
Unknown or empty fields are skipped rather than shown as blank rows.
"""
function _format_info_entry(md::AbstractDict; now_dt::Dates.DateTime=Dates.now())
    io = IOBuffer()
    key = String(get(md, "key", ""))
    println(io, "── ", isempty(key) ? "(no key)" : key, " ──")

    rows = Pair{String,String}[]
    function row(label, val)
        s = val === nothing ? "" : String(val)
        isempty(s) || push!(rows, label => s)
    end

    row("title", get(md, "title", ""))

    authors = get(md, "authors", nothing)
    if authors isa AbstractVector && !isempty(authors)
        row("authors", _truncate(join(String.(authors), ", "), 80))
    end

    row("journal", get(md, "journal", ""))

    y = get(md, "year", "")
    row("year", y isa Integer ? string(y) : String(y))

    row("status", get(md, "status", ""))
    row("source", get(md, "source", ""))

    g = get(md, "group", "")
    isempty(String(g)) || row("group", g)

    is_oa = get(md, "is_oa", nothing)
    is_oa === nothing || row("is_oa", string(is_oa))

    # citekey via the same function BibTeX export uses, so the user sees
    # exactly what would end up in refs.bib.
    row("citekey", _bibtex_key(md))

    pdf = String(get(md, "pdf_path", ""))
    if !isempty(pdf)
        if isfile(pdf)
            row("pdf", string(pdf, "  (", _humanize_bytes(filesize(pdf)), ")"))
        else
            row("pdf", string(pdf, "  (missing!)"))
        end
    end

    fetched_at = String(get(md, "fetched_at", ""))
    if !isempty(fetched_at)
        age = _humanize_age(fetched_at; now_dt=now_dt)
        row("fetched", isempty(age) ? fetched_at : string(fetched_at, "  (", age, ")"))
    end

    last_att = String(get(md, "last_attempt_at", ""))
    if !isempty(last_att) && get(md, "status", "") == "failed"
        age = _humanize_age(last_att; now_dt=now_dt)
        row("last try", isempty(age) ? last_att : string(last_att, "  (", age, ")"))
    end

    err = String(get(md, "error", ""))
    isempty(err) || row("error", err)

    # column-align the labels
    width = isempty(rows) ? 0 : maximum(length(p.first) for p in rows)
    for (label, val) in rows
        @printf(io, "  %-*s : %s\n", width, label, val)
    end

    attempts = get(md, "attempts", nothing)
    if attempts isa AbstractVector && !isempty(attempts)
        println(io, "\n  attempts:")
        src_w = maximum(length(String(get(a, "source", ""))) for a in attempts)
        for a in attempts
            src = String(get(a, "source", "?"))
            url = String(get(a, "url", ""))
            ok = Bool(get(a, "ok", false))
            status = get(a, "http_status", nothing)
            dur = Float64(get(a, "duration_s", 0.0))
            aerr = String(get(a, "error", ""))
            mark = ok ? "✓" : "✗"
            parts = String[]
            isempty(url) || push!(parts, _truncate(url, 60))
            status === nothing || push!(parts, string("(", Int(status), ")"))
            push!(parts, @sprintf("%.2fs", dur))
            ok || isempty(aerr) || push!(parts, aerr)
            @printf(io, "    %s %-*s %s\n", mark, src_w, src, join(parts, "  "))
        end
    end

    return String(take!(io))
end

function _cmd_info(args)
    isempty(args) && (println(stderr, "info: need a reference"); return 2)
    raw = "--raw" in args
    refs = filter(a -> !startswith(a, "--"), args)
    rt = detect_environment(; probe=false)
    store = open_store(rt.store_root)
    for r in refs
        key = try
            normalize_key(r)
        catch
            r
        end
        md = read_metadata(store, key)
        if isempty(md)
            println(stderr, "  (not found) $key")
            continue
        end
        if raw
            println("── $key ──")
            TOML.print(stdout, md; sorted=true)
            println()
        else
            print(_format_info_entry(md))
            println()
        end
    end
    return 0
end

function _cmd_bib(args)
    isempty(args) && (println(stderr, "bib: need a store directory"); return 2)
    dir = args[1]
    out = joinpath(dir, "refs.bib")
    i = 2
    while i <= length(args)
        if args[i] in ("--out", "-o")
            i += 1
            i <= length(args) || (println(stderr, "bib: --out needs a path"); return 2)
            out = args[i]
        end
        i += 1
    end
    isdir(dir) || (println(stderr, "bib: not a directory: $(dir)"); return 2)
    store = open_store(dir)
    n = write_bibtex(store, out)
    println("wrote $n entries → $(out)")
    return 0
end

function _cmd_run(args)
    isempty(args) && (println(stderr, "run: need a job TOML path"); return 2)
    path = args[1]
    quiet = ("--quiet" in args) || ("-q" in args)
    rt = detect_environment()
    !quiet && (show(stdout, MIME("text/plain"), rt); println(); println())
    result = run(path; verbose=(!quiet), runtime=rt)
    show(stdout, MIME("text/plain"), result)
    println()
    n_ok = count(e -> e.status === :ok, result.entries)
    return n_ok == length(result.entries) ? 0 : 1
end

"""
    cli_main(args = ARGS) -> Int

Dispatch a `bibliofetch …` command line. Returns exit code.
"""
function cli_main(args::AbstractVector{<:AbstractString}=ARGS)
    if isempty(args) || args[1] in ("-h", "--help", "help")
        print(CLI_HELP);
        return 0
    end
    cmd, rest = args[1], args[2:end]
    try
        return if cmd == "env"
            _cmd_env(rest)
        elseif cmd == "run"
            _cmd_run(rest)
        elseif cmd == "bib"
            _cmd_bib(rest)
        elseif cmd == "add"
            _cmd_add(rest)
        elseif cmd == "sync"
            _cmd_sync(rest)
        elseif cmd == "fetch"
            _cmd_fetch(rest)
        elseif cmd == "list"
            _cmd_list(rest)
        elseif cmd == "info"
            _cmd_info(rest)
        else
            (println(stderr, "unknown command: $cmd"); print(CLI_HELP); 2)
        end
    catch e
        println(stderr, "bibliofetch: ", sprint(showerror, e))
        return 1
    end
end
