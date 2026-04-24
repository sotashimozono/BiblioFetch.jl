# # Companion arXiv preprints (`also_arxiv`)
#
# **Option B** from the reference-policy design. When `[fetch].also_arxiv
# = true`, every reference whose primary fetch succeeded via a publisher
# route (`:unpaywall` / `:aps` / `:elsevier` / `:springer` / `:direct`)
# triggers a *second* download: the arXiv preprint of the same paper,
# saved alongside as `<key>__preprint.pdf`.
#
# The use case is comparative: appendices that only survive in a
# specific preprint revision, diffs between v1 and the journal camera-
# ready, archival runs that want both versions of record on disk.
# Plain-arxiv primaries skip the companion step — the primary *is* the
# preprint.
#
# ## Storage layout
#
# For a DOI whose arXiv preprint is `arxiv:1008.3477`:
#
# ```
# papers/
#   10.1016_j.aop.2010.09.012.pdf               ← primary (publisher PDF)
#   10.1016_j.aop.2010.09.012__preprint.pdf     ← companion (arXiv preprint)
#   .metadata/
#     10.1016_j.aop.2010.09.012.toml            ← single metadata TOML
# ```
#
# The single metadata TOML gains five `preprint_*` fields:
#
# | Field                    | Meaning                              |
# |--------------------------|--------------------------------------|
# | `preprint_pdf`           | on-disk path of the companion        |
# | `preprint_source`        | always `"arxiv"` for now             |
# | `preprint_sha256`        | hash of the companion PDF            |
# | `preprint_fetched_at`    | timestamp of companion download      |
# | `preprint_status`        | `"ok"` / `"cached"` / `"failed"` / `"no-arxiv-id"` |
# | `preprint_error`         | error message when status = `"failed"` |
#
# ## The job file
#
# ```toml
# [folder]
# target = "papers"
#
# [fetch]
# also_arxiv = true
#
# [doi]
# list = [
#     "10.1016/j.aop.2010.09.012",   # Schollwöck → arxiv:1008.3477
#     "10.1103/PhysRevB.99.214433",  # → arxiv:1905.07639 (via title search)
#     "arxiv:1706.03762",             # primary already arxiv — no companion
# ]
# ```
#
# `load_job` doesn't care about `also_arxiv` at parse time — it's
# surfaced as a boolean field on `FetchJob` and threaded into
# `fetch_paper!` during the run.

using BiblioFetch

mktemp() do path, io
    write(
        io,
        """
[folder]
target = "papers"

[fetch]
also_arxiv = true

[doi]
list = ["10.1016/j.aop.2010.09.012"]
""",
    )
    close(io)
    job = BiblioFetch.load_job(path)
    job.also_arxiv
end

# ## When the companion fetch fires
#
# The companion is attempted iff **all** of these hold:
#
# 1. `also_arxiv = true` in the job config.
# 2. The primary fetch succeeded.
# 3. The primary's source symbol is not `:arxiv` (arxiv-sourced
#    primaries already *are* the preprint).
# 4. An arXiv id is discoverable — preferring in order:
#    * `md["arxiv_id"]` populated by the Crossref `relation.has-preprint`
#      lookup (most common path),
#    * a title + first-author search against the arXiv API,
#    * the ref itself if it's already `arxiv:…` (though that path hits
#      condition 3 first and short-circuits).
#
# If step 4 finds nothing, `preprint_status` is set to `"no-arxiv-id"`
# so `bibliofetch info` tells you the flag was honored but had no
# target. The primary's `status` is unaffected — the companion is
# strictly best-effort.
#
# ## Cache behavior
#
# On a re-run without `--force`:
#
# * Primary cached + `also_arxiv` off  — the run is a no-op, as before.
# * Primary cached + `also_arxiv` on + companion **missing** — the
#   companion is fetched now (retroactively upgrading an existing
#   store).
# * Primary cached + companion cached — both file presences are
#   confirmed and hashes backfilled if they weren't recorded.
# * `--force` — both PDFs re-downloaded.
#
# ## Real-run smoke
#
# From a Todai shell, `bibliofetch run` of the one-DOI job above
# produced these two PDFs with the expected `preprint_status = "ok"`
# in metadata:
#
# ```
# $ ls papers/
# 10.1016_j.aop.2010.09.012.pdf
# 10.1016_j.aop.2010.09.012__preprint.pdf
# ```
#
# ## Downstream integration
#
# * `bibliofetch info <key>` renders the `preprint_*` fields alongside
#   the primary trail.
# * `bibliofetch doctor` recognises `__preprint.pdf` siblings as
#   non-orphans (they're expected artifacts, not stray files).
# * BibTeX export ignores the companion — the export cites the primary
#   DOI / arxiv id, not both artifacts of the same reference.
