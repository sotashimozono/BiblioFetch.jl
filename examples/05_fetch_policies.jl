# # Source + failure policies
#
# Two orthogonal knobs under `[fetch]` let you control how strict BiblioFetch
# is about what it fetches and how it reacts when a reference can't be
# satisfied:
#
# | Knob             | Values                            | Default     |
# |------------------|-----------------------------------|-------------|
# | `source_policy`  | `"strict"` · `"lenient"`          | `"lenient"` |
# | `on_fail`        | `"pending"` · `"skip"` · `"error"`| `"pending"` |
#
# Together they span a 2 × 3 = 6-cell matrix — pick the cell that matches
# what you're trying to produce.
#
# ## source_policy
#
# Controls which sources count as a "successful" fetch.
#
# * **`lenient`** (default) — every source listed in `[fetch].sources` is
#   eligible. The cascade is greedy: whatever pulls down a valid PDF first
#   wins, regardless of whether it came from the publisher or a preprint
#   server. This is the historical behavior.
#
# * **`strict`** — only publisher / version-of-record sources (`:aps`,
#   `:elsevier`, `:springer`, `:direct`) are allowed to produce candidates.
#   `:arxiv` and `:s2` are dropped before the network call is even made.
#   `:unpaywall` is kept only when `best_oa_location.host_type == "publisher"`
#   — repository-hosted preprints that Unpaywall would otherwise serve are
#   rejected too. If no strict source can reach the paper, the run records
#   the ref as not-fetched and falls through to the `on_fail` behavior below.
#
# ## on_fail
#
# What to do when a reference ends the cascade with no success:
#
# * **`pending`** (default) — record `status = :pending`. `bibliofetch sync`
#   will retry the ref next time it's invoked. Good for "I'm offline now,
#   sync from the office later" flows.
#
# * **`skip`** — record `status = :skipped`. `sync` won't retry skipped
#   entries. Useful when you know a ref isn't available through the configured
#   sources (e.g., no TDM key for a paywalled APS paper) and you don't want
#   a pile of pending entries clogging up future runs.
#
# * **`error`** — abort the whole run after the current batch finishes.
#   Exits with an exception so a wrapping shell script / CI job sees the
#   failure. Use this when the bibliography is supposed to be reproducibly
#   fetchable and you want CI to flag regressions.
#
# ## The 6 combinations in plain English
#
# | `source_policy` / `on_fail` | `pending`              | `skip`                | `error`             |
# |-----------------------------|------------------------|-----------------------|---------------------|
# | `lenient`                   | default: try anything, retry misses later | try anything, drop misses | try anything, abort on any miss |
# | `strict`                    | journal-only, misses retryable (e.g., waiting on a TDM key) | journal-only, misses ignored | journal-only, abort on any miss (the "reproducible build" cell) |
#
# ## Example TOML
#
# A job that insists on publisher-hosted PDFs and treats missing ones as a
# hard failure:
#
# ```toml
# [folder]
# target = "papers"
#
# [fetch]
# source_policy = "strict"
# on_fail       = "error"
# sources       = ["unpaywall", "aps", "elsevier", "springer", "direct"]
#
# [doi]
# list = [
#     "10.1103/PhysRevLett.98.070201",
#     "10.1016/j.aop.2010.09.012",
# ]
# ```
#
# A job that aggressively takes whatever it can get and discards anything
# that doesn't work on the first pass:
#
# ```toml
# [fetch]
# source_policy = "lenient"
# on_fail       = "skip"
# sources       = ["unpaywall", "arxiv", "s2", "direct"]
# ```
#
# ## Running the policy checks from Julia
#
# `load_job` validates the values at parse time, so bad strings fail fast
# without any network I/O.

using BiblioFetch

mktemp() do path, io
    write(
        io,
        """
[folder]
target = "papers"

[fetch]
source_policy = "strict"
on_fail       = "error"
sources       = ["unpaywall", "aps", "elsevier", "springer", "direct"]

[doi]
list = ["10.1103/PhysRevLett.98.070201"]
""",
    )
    close(io)
    job = BiblioFetch.load_job(path)
    job.source_policy, job.on_fail, job.sources
end

# Unknown values are rejected at load time:

try
    mktemp() do path, io
        write(
            io,
            """
[folder]
target = "papers"
[fetch]
source_policy = "sloppy"
[doi]
list = ["arxiv:1"]
""",
        )
        close(io)
        BiblioFetch.load_job(path)
    end
catch err
    err
end

# ## Which cell should I pick?
#
# - **Personal bibliography, laptop workflow** — keep the defaults
#   (`lenient` + `pending`). You get every paper you can reach and missing
#   ones re-try when you're next on a reachable network.
# - **Journal-club / course reading list** — `lenient` + `skip`. One-shot
#   runs, don't care if a few fail.
# - **Reproducible project bibliography with a TDM setup** — `strict` +
#   `error`. The run either pulls every paper from an authorized source
#   or it fails loudly.
# - **Archival run where version-of-record matters but some are missing** —
#   `strict` + `pending`. Sync retries later when TDM keys / proxies come
#   back.
