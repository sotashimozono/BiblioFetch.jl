"""
    StoreIssue

One integrity problem [`doctor`](@ref) found. `kind` is one of:

  * `:pdf_missing`     — metadata lists a `pdf_path` whose file is gone
  * `:orphan_pdf`      — a PDF on disk isn't referenced by any metadata entry
  * `:incomplete_part` — a `.part` leftover from an interrupted download
  * `:sha_mismatch`    — metadata has a `sha256` that no longer matches the
                         file on disk (PDF was replaced / corrupted)
  * `:empty_pdf`       — `pdf_path` exists but the file is 0 bytes

`key` identifies the metadata entry the issue belongs to, if any; orphan
disk files have `key == ""`.
"""
struct StoreIssue
    kind::Symbol
    key::String
    path::String
    detail::String
end

# Walk a directory tree and collect PDF paths, skipping the hidden .metadata
# subdirectory (which holds TOMLs, not PDFs).
function _collect_pdf_paths(root::AbstractString)
    out = String[]
    for (dir, _subdirs, files) in walkdir(root)
        # skip the metadata dir wholesale; keeps doctor fast on large stores
        occursin("/" * METADATA_DIRNAME, dir) && continue
        endswith(dir, METADATA_DIRNAME) && continue
        basename(dir) == METADATA_DIRNAME && continue
        for f in files
            endswith(f, ".pdf") && push!(out, joinpath(dir, f))
            endswith(f, ".pdf.part") && push!(out, joinpath(dir, f))
        end
    end
    return out
end

"""
    doctor(store) -> Vector{StoreIssue}

Inventory the store for operational problems:

  * cross-reference metadata `pdf_path` vs on-disk files (missing / orphan)
  * flag `.part` leftover files from interrupted downloads
  * flag 0-byte PDFs
  * when a metadata entry records a `sha256`, verify the on-disk file still
    hashes to the same value (`:sha_mismatch`)

One pass, no network. Returns a flat list sorted first by `kind`, then by
`key` / `path`.
"""
function doctor(store::Store)
    issues = StoreIssue[]
    referenced_paths = Set{String}()

    # 1) walk metadata — flag pdf_missing / empty_pdf / sha_mismatch
    for safekey in list_entries(store)
        p = joinpath(store.root, METADATA_DIRNAME, safekey * ".toml")
        md = try
            TOML.parsefile(p)
        catch
            continue
        end
        key = String(get(md, "key", ""))
        isempty(key) && continue
        pdf = String(get(md, "pdf_path", ""))
        isempty(pdf) && continue

        if !isfile(pdf)
            push!(
                issues,
                StoreIssue(
                    :pdf_missing,
                    key,
                    pdf,
                    "metadata points at a file that is no longer there",
                ),
            )
            continue
        end

        push!(referenced_paths, abspath(pdf))

        if filesize(pdf) == 0
            push!(issues, StoreIssue(:empty_pdf, key, pdf, "pdf exists but is 0 bytes"))
            continue
        end

        recorded_hash = String(get(md, "sha256", ""))
        if !isempty(recorded_hash)
            actual = try
                _sha256_file(pdf)
            catch
                ""
            end
            if !isempty(actual) && actual != recorded_hash
                push!(
                    issues,
                    StoreIssue(
                        :sha_mismatch,
                        key,
                        pdf,
                        "sha256 on disk ($(actual[1:min(12,end)])…) differs from metadata ($(recorded_hash[1:min(12,end)])…)",
                    ),
                )
            end
        end
    end

    # 2) walk files on disk — flag orphans and .part leftovers
    for f in _collect_pdf_paths(store.root)
        if endswith(f, ".part")
            push!(
                issues,
                StoreIssue(
                    :incomplete_part, "", f, "leftover from an interrupted download"
                ),
            )
            continue
        end
        abspath(f) in referenced_paths && continue
        push!(
            issues, StoreIssue(:orphan_pdf, "", f, "not referenced by any .metadata/ entry")
        )
    end

    sort!(issues; by=i -> (string(i.kind), i.key, i.path))
    return issues
end

"""
    fix!(store, issues; kinds = (:incomplete_part,)) -> Int

Apply safe auto-fixes to a subset of `issues`. Returns the number of issues
acted on. Safe defaults:

  * `:incomplete_part` — remove the `.part` file unconditionally
  * `:pdf_missing`     — clear `pdf_path` from the metadata entry; don't
                         touch the metadata's other fields, so a subsequent
                         `bibliofetch sync --force` can re-fetch

Other kinds (`:orphan_pdf`, `:sha_mismatch`, `:empty_pdf`) are opt-in —
pass their symbol in `kinds` to include them. Orphan removal in particular
is destructive and should be reviewed first.
"""
function fix!(
    store::Store, issues::AbstractVector{StoreIssue}; kinds=(:incomplete_part, :pdf_missing)
)
    n = 0
    for iss in issues
        iss.kind in kinds || continue
        if iss.kind === :incomplete_part
            isfile(iss.path) && rm(iss.path; force=true)
            n += 1
        elseif iss.kind === :pdf_missing
            md = read_metadata(store, iss.key)
            if !isempty(md)
                md["pdf_path"] = ""
                write_metadata!(store, iss.key, md)
                n += 1
            end
        elseif iss.kind === :orphan_pdf
            isfile(iss.path) && rm(iss.path; force=true)
            n += 1
        elseif iss.kind === :empty_pdf
            isfile(iss.path) && rm(iss.path; force=true)
            md = read_metadata(store, iss.key)
            if !isempty(md)
                md["pdf_path"] = ""
                write_metadata!(store, iss.key, md)
            end
            n += 1
        elseif iss.kind === :sha_mismatch
            # The safe thing: just clear the stale hash and let the next
            # fetch or dedup recompute. Don't remove the file — its current
            # contents may be the intentional replacement.
            md = read_metadata(store, iss.key)
            if !isempty(md)
                md["sha256"] = ""
                write_metadata!(store, iss.key, md)
                n += 1
            end
        end
    end
    return n
end
