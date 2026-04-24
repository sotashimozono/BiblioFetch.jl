# # Minimal job
#
# The smallest possible BiblioFetch job: one DOI, every other setting
# defaulted. Use this as the starting point for any new project.
#
# ## The job file
#
# `examples/minimal-job.toml`:
#
# ```toml
# [folder]
# target = "papers"
#
# [doi]
# list = [
#     "arxiv:1008.3477",
# ]
# ```
#
# Two sections only: where PDFs go (`[folder]`) and what to fetch
# (`[doi]`). Everything under `[fetch]` falls back to built-in defaults —
# the standard `unpaywall / arxiv / direct` cascade.
#
# Relative `target` values resolve against the TOML file's directory
# (not the caller's cwd), so running from anywhere drops PDFs next to
# the job.
#
# ## Running from the shell
#
# ```sh
# bibliofetch run examples/minimal-job.toml
# ```
#
# A fresh `examples/papers/` directory appears on first run containing
# the fetched PDF and a parallel `.metadata/` folder of per-entry TOML
# records.
#
# ## Running from Julia
#
# Loading a job parses and validates the TOML without performing any
# network I/O. `BiblioFetch.run` then executes it and returns a
# `FetchJobResult`.

using BiblioFetch

job_path = joinpath(@__DIR__, "minimal-job.toml")
job = BiblioFetch.load_job(job_path)

# `job.refs` is the parsed reference list — confirm it before hitting the
# network.

length(job.refs), first(job.refs).key

# Uncomment the next line to actually fetch. The doc build skips it so
# CI doesn't hit the real APS archive.

## result = BiblioFetch.run(job_path)

# ## What's next
#
# Once `minimal-job.toml` succeeds, the next two examples show how to
# grow the job: [citation-graph expansion](02_citation_graph.md) and
# [publisher-TDM sources](03_publisher_tdm.md).
