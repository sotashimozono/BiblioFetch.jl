# ---------- Citation-graph visualization ----------
#
# After a citation-graph expansion run, the store holds two kinds of edges
# per paper:
#   * `referenced_dois`  — every DOI the paper cites (from Crossref / S2)
#   * `referenced_by`    — the parent key that queued this entry into the run
#
# `to_dot` and `to_mermaid` render either set of edges for viewing in
# Graphviz / rendered Markdown respectively. Labels are the same citekeys
# `bibliofetch bib` uses, so the graph stays consistent with the exported
# `.bib`.

# Mermaid node ids must be alphanumeric + underscore. Map the safe-key
# filename stem to a sanitised form, keep it stable across invocations.
_mermaid_id(safekey::AbstractString) = replace(String(safekey), r"[^A-Za-z0-9_]" => "_")

# DOT string escaping — double quotes, backslashes, newlines.
function _dot_escape(s::AbstractString)
    s = replace(String(s), "\\" => "\\\\")
    s = replace(s, "\"" => "\\\"")
    s = replace(s, "\n" => "\\n")
    return s
end

# Walk the store's metadata once, collecting the (safekey → node_info, key →
# safekey, key → metadata) maps we need to emit either format.
function _collect_graph_nodes(store::Store)
    nodes = Dict{String,NamedTuple}()   # safekey → (key, citekey, status, title)
    key_to_safekey = Dict{String,String}()
    md_by_key = Dict{String,Dict{String,Any}}()
    for safekey in list_entries(store)
        p = joinpath(store.root, METADATA_DIRNAME, safekey * ".toml")
        md = try
            TOML.parsefile(p)
        catch
            continue
        end
        key = String(get(md, "key", ""))
        isempty(key) && continue
        citekey = _bibtex_key(md)
        status = String(get(md, "status", ""))
        title = String(get(md, "title", ""))
        nodes[safekey] = (; key=key, citekey=citekey, status=status, title=title)
        key_to_safekey[key] = safekey
        md_by_key[key] = md
    end
    return nodes, key_to_safekey, md_by_key
end

# Collect the (from_safekey, to_safekey) pairs according to the requested
# edge policy.
function _collect_graph_edges(nodes, key_to_safekey, md_by_key; queued_only::Bool=false)
    edges = Tuple{String,String}[]   # (from_safekey, to_safekey)
    seen = Set{Tuple{String,String}}()
    push_edge!(a, b) = begin
        e = (a, b)
        e in seen || (push!(seen, e); push!(edges, e))
    end

    if queued_only
        # Expansion tree: parent → child from `referenced_by`
        for (safekey, info) in nodes
            md = md_by_key[info.key]
            parent = String(get(md, "referenced_by", ""))
            isempty(parent) && continue
            parent_sk = get(key_to_safekey, parent, nothing)
            parent_sk === nothing || push_edge!(parent_sk, safekey)
        end
    else
        # Full citation subgraph: X cites Y iff Y is in the store
        for (safekey, info) in nodes
            md = md_by_key[info.key]
            refs = get(md, "referenced_dois", String[])
            refs isa AbstractVector || continue
            for r in refs
                target = try
                    normalize_key(String(r))
                catch
                    continue
                end
                target_sk = get(key_to_safekey, target, nothing)
                target_sk === nothing || push_edge!(safekey, target_sk)
            end
        end
    end
    return edges
end

# Pick nodes to render. Default: only nodes that appear in at least one edge
# (reduces visual noise on large stores). `include_isolated=true` keeps every
# entry regardless.
function _visible_nodes(nodes, edges; include_isolated::Bool)
    include_isolated && return collect(keys(nodes))
    touched = Set{String}()
    for (a, b) in edges
        push!(touched, a)
        push!(touched, b)
    end
    return sort!(collect(touched))
end

# Per-status DOT attributes — pending / failed look distinct so you can spot
# gaps in the graph.
function _dot_node_attrs(status::AbstractString)
    if status == "ok"
        return "shape=box, style=\"rounded,filled\", fillcolor=\"#e0f0ff\""
    elseif status == "pending"
        return "shape=box, style=\"rounded,filled,dashed\", fillcolor=\"#f6f6f6\", color=gray"
    elseif status == "failed"
        return "shape=box, style=\"rounded,filled\", fillcolor=\"#ffe0e0\", color=\"#cc0000\""
    else
        return "shape=box, style=rounded"
    end
end

"""
    to_dot(store; queued_only = false, include_isolated = false) -> String

Render the store's citation graph as a Graphviz DOT source string. Pipe
through `dot -Tpng > graph.png` (or `-Tsvg`) to view.

  * `queued_only = true`   — show only the expansion tree (edges from
                             `referenced_by`), not the full citation fabric.
  * `include_isolated = true` — keep entries that aren't part of any edge
                             (default: hide them so the graph stays readable).

Node labels are the same citekeys `bibliofetch bib` emits; node colour/style
reflects `status` (ok / pending / failed).
"""
function to_dot(store::Store; queued_only::Bool=false, include_isolated::Bool=false)
    nodes, key_to_safekey, md_by_key = _collect_graph_nodes(store)
    edges = _collect_graph_edges(nodes, key_to_safekey, md_by_key; queued_only=queued_only)
    visible = _visible_nodes(nodes, edges; include_isolated=include_isolated)

    io = IOBuffer()
    println(io, "digraph BiblioFetch {")
    println(io, "  rankdir=LR;")
    println(io, "  node [fontname=\"Helvetica\", fontsize=10];")
    println(io, "  edge [color=\"#888888\", arrowsize=0.7];")
    for sk in sort(visible)
        n = nodes[sk]
        label = if isempty(n.title)
            n.citekey
        else
            "$(n.citekey)\\n$(_dot_escape(n.title)[1:min(40,end)])"
        end
        attrs = _dot_node_attrs(n.status)
        println(io, "  \"", sk, "\" [label=\"", label, "\", ", attrs, "];")
    end
    println(io)
    for (a, b) in edges
        println(io, "  \"", a, "\" -> \"", b, "\";")
    end
    println(io, "}")
    return String(take!(io))
end

# Per-status Mermaid style class — defined once, applied per-node.
const _MERMAID_CLASSES = """
classDef ok      fill:#e0f0ff,stroke:#4a90d9,stroke-width:1px;
classDef pending fill:#f6f6f6,stroke:#888888,stroke-dasharray: 4 4;
classDef failed  fill:#ffe0e0,stroke:#cc0000;
"""

function _mermaid_class(status::AbstractString)
    status == "ok" && return "ok"
    status == "pending" && return "pending"
    status == "failed" && return "failed"
    return ""
end

"""
    to_mermaid(store; queued_only = false, include_isolated = false) -> String

Render the store's citation graph as Mermaid (`graph LR`) source, ready to
paste into a Markdown fence on GitHub / Obsidian / Docusaurus. Same
edge-policy and filter flags as [`to_dot`](@ref).
"""
function to_mermaid(store::Store; queued_only::Bool=false, include_isolated::Bool=false)
    nodes, key_to_safekey, md_by_key = _collect_graph_nodes(store)
    edges = _collect_graph_edges(nodes, key_to_safekey, md_by_key; queued_only=queued_only)
    visible = _visible_nodes(nodes, edges; include_isolated=include_isolated)

    io = IOBuffer()
    println(io, "graph LR")
    for line in split(rstrip(_MERMAID_CLASSES, '\n'), '\n')
        println(io, "  ", line)
    end
    println(io)
    for sk in sort(visible)
        n = nodes[sk]
        id = _mermaid_id(sk)
        # Mermaid allows double-quoted labels; escape backticks / pipes conservatively.
        label = replace(n.citekey, "\"" => "#34;")
        println(io, "  ", id, "[\"", label, "\"]")
        cls = _mermaid_class(n.status)
        isempty(cls) || println(io, "  class ", id, " ", cls, ";")
    end
    println(io)
    for (a, b) in edges
        println(io, "  ", _mermaid_id(a), " --> ", _mermaid_id(b))
    end
    return String(take!(io))
end
