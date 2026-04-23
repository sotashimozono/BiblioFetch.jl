"""
    StoreStats

Aggregate counts and sizes for a store, one walk of `.metadata/` away. Used by
`bibliofetch stats` for a daily-review dashboard and by any caller who wants
to know "what's actually in here?" without enumerating entries by hand.
"""
struct StoreStats
    root::String
    total::Int
    by_status::Dict{String,Int}
    by_source::Dict{String,Int}           # among status=ok entries only
    by_group::Dict{String,Int}
    pdf_count::Int
    pdf_total_bytes::Int
    pdf_missing::Int                       # pdf_path set but file is gone
    duplicate_resolved::Int                # entries with duplicate_of set
    graph_expanded::Int                    # entries with depth > 0 (citation hop)
    oldest_fetch::Union{Dates.DateTime,Nothing}
    newest_fetch::Union{Dates.DateTime,Nothing}
end

"""
    stats(store) -> StoreStats

Walk the store's `.metadata/` directory once and aggregate:
  * per-status / per-source / per-group counts
  * PDF file count and total byte size (counts only files that exist)
  * `pdf_missing` — entries whose metadata lists a `pdf_path` that's gone
  * `duplicate_resolved` — entries linked to a canonical by [`resolve_duplicates!`](@ref)
  * `graph_expanded` — entries queued by a citation hop (`depth > 0`)
  * `oldest_fetch` / `newest_fetch` — earliest and latest `fetched_at`
    timestamps, `nothing` when the store has no successful fetches yet

One pass, no network. Safe to call on huge stores; per-entry cost is
dominated by `TOML.parsefile` on the metadata file.
"""
function stats(store::Store)
    by_status = Dict{String,Int}()
    by_source = Dict{String,Int}()
    by_group = Dict{String,Int}()
    pdf_count = 0
    pdf_total_bytes = 0
    pdf_missing = 0
    duplicate_resolved = 0
    graph_expanded = 0
    oldest = nothing
    newest = nothing
    total = 0

    for safekey in list_entries(store)
        p = joinpath(store.root, METADATA_DIRNAME, safekey * ".toml")
        md = try
            TOML.parsefile(p)
        catch
            continue
        end
        total += 1

        status = String(get(md, "status", "unknown"))
        by_status[status] = get(by_status, status, 0) + 1

        if status == "ok"
            src = String(get(md, "source", ""))
            isempty(src) || (by_source[src] = get(by_source, src, 0) + 1)
        end

        grp = String(get(md, "group", ""))
        by_group[grp] = get(by_group, grp, 0) + 1

        pdf = String(get(md, "pdf_path", ""))
        if !isempty(pdf)
            if isfile(pdf)
                pdf_count += 1
                pdf_total_bytes += filesize(pdf)
            else
                pdf_missing += 1
            end
        end

        isempty(String(get(md, "duplicate_of", ""))) || (duplicate_resolved += 1)

        depth = get(md, "depth", 0)
        depth isa Integer && depth > 0 && (graph_expanded += 1)

        fetched = String(get(md, "fetched_at", ""))
        if !isempty(fetched)
            dt = try
                Dates.DateTime(fetched)
            catch
                nothing
            end
            if dt !== nothing
                oldest = (oldest === nothing || dt < oldest) ? dt : oldest
                newest = (newest === nothing || dt > newest) ? dt : newest
            end
        end
    end

    return StoreStats(
        store.root,
        total,
        by_status,
        by_source,
        by_group,
        pdf_count,
        pdf_total_bytes,
        pdf_missing,
        duplicate_resolved,
        graph_expanded,
        oldest,
        newest,
    )
end
