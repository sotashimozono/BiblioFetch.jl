# # arXiv versions
#
# Most papers on arXiv carry more than one version — the `v1` submitted
# to the archive and a few `v2`/`v3` revisions as referees weigh in.
# Usually the latest version is what you want, but occasionally the
# appendix / proof / data-table you're chasing only survives in a
# specific earlier revision.
#
# BiblioFetch supports three ways of referring to arXiv versions:
#
# | Ref form                       | Fetches                            |
# |--------------------------------|------------------------------------|
# | `arxiv:1706.03762`             | the latest published version       |
# | `arxiv:1706.03762v2`           | version 2 only                     |
# | `arxiv:1706.03762@all`         | every published version (v1..vN)   |
# | `arxiv:1706.03762@v1,v3`       | the listed versions only           |
#
# The first two are plain single-entry references — they go through the
# normal cascade. The `@all` and `@v1,v3` forms are *pseudo-refs*: the
# run loop expands them into one `FetchEntry` per version before calling
# `fetch_paper!`, so every version ends up in the store as an
# independent entry with its own TOML record and its own cached PDF.
#
# ## How `@all` discovers versions
#
# The arXiv Atom API answers `id_list=<id>` with the entry's canonical
# URL in `<id>`, and that URL always carries the current `vN` suffix.
# BiblioFetch parses `N` out, then materialises `1..N` — arXiv numbers
# versions sequentially, so no per-version probe is needed. One API
# call per `@all` pseudo-ref, regardless of version count.
#
# ## Example
#
# A job that grabs v1 *and* the latest published version of Vaswani et
# al.'s *Attention is All You Need* (for comparing changes between the
# initial preprint and the NeurIPS camera-ready):

using BiblioFetch

mktemp() do path, io
    write(
        io,
        """
[folder]
target = "papers"

[doi]
list = [
    "arxiv:1706.03762@v1,v7",
]
""",
    )
    close(io)
    job = BiblioFetch.load_job(path)
    (length(job.refs), job.refs[1].key)
end

# `load_job` is offline — `@`-pseudo-refs survive into `job.refs` as
# single entries and only get expanded once `BiblioFetch.run` starts.
# `length(job.refs) == 1` above confirms that.

# ## Running from the shell
#
# ```sh
# bibliofetch run examples/arxiv-versions-job.toml
# ```
#
# Each expanded version writes a distinct `.metadata/arxiv__<id>vN.toml`
# record and a distinct `<id>vN.pdf` under the store's target. The
# entries' `raw` field keeps the original `@…` spec, so
# `bibliofetch info` still tells you which pseudo-ref produced each
# concrete version.
#
# ## Running the probe from Julia
#
# If you want the version list without running a full job — say, to
# script "fetch only even-numbered revisions" — call the API helper
# directly:

## using BiblioFetch
## versions = BiblioFetch.arxiv_list_versions("1706.03762")   # e.g. [1, 2, 3, 4, 5, 6, 7]
## even_vs  = filter(iseven, versions)

# The helper accepts both bare ids (`"1706.03762"`) and `arxiv:`-prefixed
# ids, and strips any `vN` suffix before querying — so
# `arxiv_list_versions("arxiv:1706.03762v2")` returns the same list as
# `arxiv_list_versions("1706.03762")`.
#
# ## When to use which form
#
# - **Single latest version** — the default. No `@` anywhere.
# - **Historical diff** — use `@v1,v<latest>` to pull the two ends of a
#   paper's revision history and diff their PDFs.
# - **Archival sweep** — `@all` for a deep citation where the v1 and v2
#   differ enough to matter (common in tensor-network / DMRG papers
#   where appendices get rewritten).
# - **Known specific revision** — `arxiv:<id>v<N>` (no `@`) stays the
#   simplest way to pin a single non-latest version.
#
# Mixing forms in the same `[doi].list` is fine; each ref is parsed
# independently.
