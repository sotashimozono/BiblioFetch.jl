const CLI_HELP = """
BiblioFetch — bulk literature fetcher (DOI / arXiv → local PDF store)

Usage:
  bibliofetch env                         Show detected runtime (hostname, proxy, mode)
  bibliofetch status [--timeout <s>]      Probe supported APIs; report what's reachable now
  bibliofetch run <job.toml>              Execute a job TOML (groups, parallel, log)
  bibliofetch bib <dir> [--out <path>]    Export BibTeX for all ok entries in a store root
  bibliofetch import <refs.bib>           Queue DOIs / arXiv ids from an existing .bib file
  bibliofetch dedup [<dir>] [--apply]     Report (or apply with --apply) PDF-hash duplicates
  bibliofetch doctor [<dir>] [--fix]      Report (or --fix) integrity issues (orphans, missing, .part)
  bibliofetch watch <job.toml>            Watch job file; re-run on each save (Ctrl+C to stop)
  bibliofetch add <ref> [<ref> …]         Queue refs into the global store
  bibliofetch add -f <file>               Queue from a file (one ref per line; '#' comments ok)
  bibliofetch sync [--force] [--quiet]    Fetch pending/failed entries; --force re-downloads even ok+pdf entries
  bibliofetch fetch <ref> [--force]       Fetch one reference; --force re-downloads even if the PDF is cached
  bibliofetch list [--all]                List global store entries
  bibliofetch search <q> [--field f]…     Substring-search title/authors/abstract/journal/key
  bibliofetch stats [<dir>]               Summary: counts by status/source/group + PDF size
  bibliofetch graph [--format dot|mermaid] [--out path] [--queued] [--all]   Citation-graph viz
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
    results = sync!(store; rt=rt, force=force, verbose=(!quiet))
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

# Word-wrap `text` to lines of at most `width` characters, with each line
# prefixed by `indent`. Returns a `Vector{String}` — one entry per line, no
# trailing newlines. Whitespace collapses: internal runs of whitespace become
# a single space (so TOML-preserved newlines inside an abstract don't cause
# weird double breaks).
function _wrap_paragraph(text::AbstractString, width::Int; indent::AbstractString="")
    words = split(text)
    isempty(words) && return String[]
    lines = String[]
    current = String(first(words))
    for w in words[2:end]
        if length(current) + 1 + length(w) <= width
            current *= " " * w
        else
            push!(lines, indent * current)
            current = String(w)
        end
    end
    push!(lines, indent * current)
    return lines
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

    # arXiv primary category (e.g., "cond-mat.str-el") — recorded by the arXiv
    # lookup path; handy for filtering by subject without re-reading the paper.
    row("category", get(md, "primary_category", ""))

    # Semantic Scholar's stable paper id — useful as a cross-tool reference
    # (S2 search, Connected Papers, etc.).
    row("s2_id", get(md, "s2_paper_id", ""))

    # citation graph provenance (present only when the entry was queued by an
    # expansion hop, not by the user directly)
    depth = get(md, "depth", 0)
    depth isa Integer && depth > 0 && row("depth", string(depth))
    ref_by = String(get(md, "referenced_by", ""))
    isempty(ref_by) || row("cited by", ref_by)

    ref_count = length(get(md, "referenced_dois", []))
    ref_count == 0 || row("cites", string(ref_count, " DOIs"))

    # dedup provenance
    dup_of = String(get(md, "duplicate_of", ""))
    isempty(dup_of) || row("duplicate of", dup_of)

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

    # Abstract — rendered as a wrapped paragraph block rather than a single
    # row because it's typically a few hundred chars. S2 is the only source
    # that provides these today; Crossref records don't carry them.
    abstract_str = String(get(md, "abstract", ""))
    if !isempty(abstract_str)
        println(io, "\n  abstract:")
        for line in _wrap_paragraph(abstract_str, 76; indent="    ")
            println(io, line)
        end
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

function Base.show(io::IO, ::MIME"text/plain", st::StoreStats)
    println(io, "BiblioFetch store statistics")
    println(io, "  root    : ", st.root)
    println(io, "  entries : ", st.total)

    function _section(title, d; label_fn=identity)
        isempty(d) && return nothing
        println(io, "\n  ", title)
        w = maximum(length(label_fn(k)) for k in keys(d))
        for k in sort!(collect(keys(d)))
            @printf(io, "    %-*s : %d\n", w, label_fn(k), d[k])
        end
    end

    _section("by status:", st.by_status)
    _section("by source (among ok entries):", st.by_source)
    _section("by group:", st.by_group; label_fn=(k -> isempty(k) ? "(root)" : k))

    if st.graph_expanded > 0 || st.duplicate_resolved > 0 || st.pdf_missing > 0
        println(io)
        st.graph_expanded > 0 && println(
            io,
            "  graph-expanded    : ",
            st.graph_expanded,
            "  (queued by citation hops, depth > 0)",
        )
        st.duplicate_resolved > 0 && println(
            io,
            "  duplicates linked : ",
            st.duplicate_resolved,
            "  (resolved via `dedup --apply`)",
        )
        st.pdf_missing > 0 && println(
            io,
            "  pdf_path missing  : ",
            st.pdf_missing,
            "  (metadata points at a file that's gone)",
        )
    end

    println(
        io, "\n  PDFs    : ", st.pdf_count, " files, ", _humanize_bytes(st.pdf_total_bytes)
    )

    if st.oldest_fetch !== nothing
        s = string(st.oldest_fetch)
        println(io, "  oldest  : ", s, "  (", _humanize_age(s), ")")
    end
    if st.newest_fetch !== nothing
        s = string(st.newest_fetch)
        println(io, "  newest  : ", s, "  (", _humanize_age(s), ")")
    end
end

function _cmd_graph(args)
    format = "dot"
    out_path = ""
    queued = false
    include_iso = false
    dir = nothing
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--format" && i < length(args)
            format = args[i + 1];
            i += 2
        elseif a == "--out" && i < length(args)
            out_path = args[i + 1];
            i += 2
        elseif a == "--queued"
            queued = true;
            i += 1
        elseif a == "--all"
            include_iso = true;
            i += 1
        elseif !startswith(a, "--")
            dir = a;
            i += 1
        else
            println(stderr, "graph: unknown flag $(a)");
            return 2
        end
    end
    format in ("dot", "mermaid") ||
        (println(stderr, "graph: --format must be dot or mermaid"); return 2)

    rt = detect_environment(; probe=false)
    store = open_store(dir === nothing ? rt.store_root : dir)
    txt = if format == "dot"
        to_dot(store; queued_only=queued, include_isolated=include_iso)
    else
        to_mermaid(store; queued_only=queued, include_isolated=include_iso)
    end
    if isempty(out_path)
        print(txt)
    else
        write(out_path, txt)
        println(stderr, "graph: wrote $(format) to $(out_path)")
    end
    return 0
end

function _cmd_stats(args)
    rt = detect_environment(; probe=false)
    dir = nothing
    for a in args
        startswith(a, "--") || (dir = a)
    end
    store = open_store(dir === nothing ? rt.store_root : dir)
    st = stats(store)
    show(stdout, MIME("text/plain"), st)
    println()
    return 0
end

function _cmd_search(args)
    isempty(args) && (println(stderr, "search: need a query"); return 2)
    # parse flags
    q_parts = String[]
    fields = Symbol[]
    group = ""
    status = ""
    case_sensitive = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--field" && i < length(args)
            push!(fields, Symbol(args[i + 1]));
            i += 2
        elseif a == "--group" && i < length(args)
            group = args[i + 1];
            i += 2
        elseif a == "--status" && i < length(args)
            status = args[i + 1];
            i += 2
        elseif a == "--case-sensitive" || a == "-c"
            case_sensitive = true;
            i += 1
        elseif startswith(a, "--")
            println(stderr, "search: unknown flag $(a)");
            return 2
        else
            push!(q_parts, a);
            i += 1
        end
    end
    query = join(q_parts, " ")
    fields_kw = isempty(fields) ? BiblioFetch._SEARCHABLE_FIELDS : Tuple(fields)

    rt = detect_environment(; probe=false)
    store = open_store(rt.store_root)
    matches = search_entries(
        store,
        query;
        fields=fields_kw,
        group=group,
        status=status,
        case_sensitive=case_sensitive,
    )
    show(stdout, MIME("text/plain"), matches)
    return isempty(matches) ? 1 : 0
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

function _cmd_status(args)
    timeout = 5.0
    i = 1
    while i <= length(args)
        if args[i] in ("--timeout", "-t") && i < length(args)
            tv = tryparse(Float64, args[i + 1])
            tv === nothing || (timeout = tv)
            i += 2
        else
            i += 1
        end
    end
    # probe=false here: status() does its own probes in parallel; the env-probe
    # would just duplicate that work, and under some HTTP.jl versions holding
    # a pre-existing connection pool interferes with the @async probe batch.
    rt = detect_environment(; probe=false)
    ns = status(; rt=rt, timeout=timeout)
    show(stdout, MIME("text/plain"), ns)
    return isempty(ns.effective_sources) ? 1 : 0
end

function _cmd_watch(args)
    isempty(args) && (println(stderr, "watch: need a job TOML path"); return 2)
    path = args[1]
    quiet = ("--quiet" in args) || ("-q" in args)
    rt = detect_environment()
    !quiet && (show(stdout, MIME("text/plain"), rt); println(); println())
    try
        watch(path; verbose=(!quiet), runtime=rt)
    catch e
        println(stderr, "watch: ", sprint(showerror, e))
        return 1
    end
    return 0
end

function _cmd_import(args)
    isempty(args) && (println(stderr, "import: need a .bib path"); return 2)
    path = args[1]
    dry = "--dry-run" in args || "-n" in args
    isfile(path) || (println(stderr, "import: not a file: $(path)"); return 2)

    rt = detect_environment(; probe=false)
    if dry
        text = read(path, String)
        entries = parse_bibtex(text)
        n_ok, n_skip = 0, 0
        for e in entries
            ref = bibentry_to_ref(e)
            if ref === nothing
                @printf("  ✗ %-30s  (no doi / eprint / url)\n", e.citekey)
                n_skip += 1
            else
                @printf("  ✓ %-30s  → %s\n", e.citekey, ref)
                n_ok += 1
            end
        end
        println("\n(dry run) would queue $(n_ok) entries, skip $(n_skip).")
        return 0
    end
    store = open_store(rt.store_root)
    res = import_bib!(store, path)
    for a in res.added
        @printf("  ✓ %-30s  → %s\n", a.citekey, a.key)
    end
    for s in res.skipped
        @printf("  ✗ %-30s  — %s\n", s.citekey, s.reason)
    end
    println(
        "\nimport: queued $(length(res.added)), skipped $(length(res.skipped)) → $(store.root)",
    )
    return 0
end

function Base.show(io::IO, ::MIME"text/plain", issues::AbstractVector{StoreIssue})
    if isempty(issues)
        println(io, "no issues found")
        return nothing
    end
    current_kind = nothing
    for iss in issues
        if iss.kind !== current_kind
            current_kind = iss.kind
            mark = if iss.kind === :pdf_missing
                "✗"
            elseif iss.kind === :orphan_pdf
                "?"
            elseif iss.kind === :incomplete_part
                "~"
            elseif iss.kind === :sha_mismatch
                "!"
            elseif iss.kind === :empty_pdf
                "∅"
            else
                "?"
            end
            cnt = count(x -> x.kind === iss.kind, issues)
            println(io, "\n  ", mark, " ", iss.kind, " (", cnt, ")")
        end
        if !isempty(iss.key)
            println(io, "      ", iss.key, "  — ", iss.detail)
            println(io, "        at ", iss.path)
        else
            println(io, "      ", iss.path, "  — ", iss.detail)
        end
    end
end

function _cmd_doctor(args)
    do_fix = "--fix" in args
    rt = detect_environment(; probe=false)
    dir = nothing
    for a in args
        startswith(a, "--") || (dir = a)
    end
    store = open_store(dir === nothing ? rt.store_root : dir)
    println("BiblioFetch store diagnostic")
    println("  root: ", store.root)
    issues = doctor(store)
    show(stdout, MIME("text/plain"), issues)
    if isempty(issues)
        return 0
    end
    if do_fix
        n = fix!(store, issues)
        println("\n\nfixed $(n) issue(s) (safe defaults: :incomplete_part, :pdf_missing).")
        println(
            "Re-run without --fix to confirm, or pass `BiblioFetch.fix!` in Julia with ",
            "explicit `kinds=(…)` to include orphans / sha_mismatch / empty_pdf.",
        )
    else
        println(
            "\n\n$(length(issues)) issue(s). Re-run with --fix to auto-clean " *
            ":incomplete_part + :pdf_missing.",
        )
    end
    return 0
end

function _cmd_dedup(args)
    apply = "--apply" in args
    rt = detect_environment(; probe=false)
    # Optional positional arg: a store directory; otherwise use global store
    dir = nothing
    for a in args
        startswith(a, "--") && continue
        dir = a
    end
    store = open_store(dir === nothing ? rt.store_root : dir)
    res = resolve_duplicates!(store; apply=apply)
    groups = res.groups
    if isempty(groups)
        println("no duplicate PDFs found in $(store.root)")
        return 0
    end
    println("found $(length(groups)) duplicate group(s) in $(store.root):")
    for (hash, keys) in groups
        canonical = first(keys)
        println("  ", hash[1:12], "…   kept: ", canonical)
        for dup in keys[2:end]
            println("                dup:  ", dup)
        end
    end
    freed_mb = res.bytes_freed / 1024^2
    if apply
        @printf(
            "\napplied: %.2f MB freed, %d entries linked to canonicals\n",
            freed_mb,
            length(res.canonicals)
        )
    else
        @printf(
            "\n(dry run) would free %.2f MB across %d duplicates. Re-run with --apply to commit.\n",
            freed_mb,
            length(res.canonicals)
        )
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
        elseif cmd == "status"
            _cmd_status(rest)
        elseif cmd == "run"
            _cmd_run(rest)
        elseif cmd == "bib"
            _cmd_bib(rest)
        elseif cmd == "import"
            _cmd_import(rest)
        elseif cmd == "dedup"
            _cmd_dedup(rest)
        elseif cmd == "doctor"
            _cmd_doctor(rest)
        elseif cmd == "watch"
            _cmd_watch(rest)
        elseif cmd == "add"
            _cmd_add(rest)
        elseif cmd == "sync"
            _cmd_sync(rest)
        elseif cmd == "fetch"
            _cmd_fetch(rest)
        elseif cmd == "list"
            _cmd_list(rest)
        elseif cmd == "search"
            _cmd_search(rest)
        elseif cmd == "stats"
            _cmd_stats(rest)
        elseif cmd == "graph"
            _cmd_graph(rest)
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
