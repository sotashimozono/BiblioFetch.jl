# # Case study: DMRG foundations
#
# This example is the bibliography supporting a single recent paper on
# infinite-system finite-temperature MPS methods — twenty well-known
# papers BiblioFetch is asked to fetch in one run, with no publisher
# TDM keys configured. Think of it as the tool's dogfooding run: a
# realistic, mid-sized bibliography pulled with just the OA cascade.
#
# ## The job
#
# `examples/dmrg-foundations-job.toml` groups the twenty references by
# theme — `dmrg_origin`, `mps_review`, `infinite_mps`, `tdvp`,
# `finite_temperature`, `time_evolution`, plus the seed paper in its own
# `seed` group. Grouping keeps the store tidy (PDFs land in
# `<target>/<group>/` subdirectories) and `bibliofetch stats` reports
# per-group counts for free.
#
# ```toml
# [folder]
# target = "dmrg_foundations_papers"
#
# [fetch]
# sources = ["unpaywall", "arxiv", "s2", "direct"]
#
# [doi.seed]
# list = ["arxiv:2512.07923"]
#
# [doi.infinite_mps]
# list = [
#     "10.1103/PhysRevLett.98.070201", # Vidal (2007) iTEBD
#     "10.1103/PhysRevB.78.155117",    # Orús & Vidal (2008)
#     "arxiv:0804.2509",               # McCulloch (2008) iDMRG
#     "10.1103/PhysRevA.78.012356",    # Crosswhite & Bacon (2008)
#     "10.1103/PhysRevB.97.045145",    # Zauner-Stauber et al. (2018) VUMPS
# ]
#
# # ... see dmrg-foundations-job.toml for the full list
# ```
#
# `:s2` is added to `sources` mainly so Semantic Scholar's abstract
# field populates each metadata TOML — useful for later searching, and
# a meaningful side-benefit turned out to rescue two references whose
# APS-hosted Unpaywall URLs returned HTML landing pages instead of PDFs
# (see the *Friction* section below).
#
# ## Running from the shell
#
# ```sh
# bibliofetch run examples/dmrg-foundations-job.toml
# ```
#
# ## Running from Julia

using BiblioFetch

job_path = joinpath(@__DIR__, "dmrg-foundations-job.toml")
job = BiblioFetch.load_job(job_path)
length(job.refs), length(unique(r -> r.group, job.refs))

# ## Results from one real run
#
# Running the job from Todai (no proxy, no TDM keys — `oa_only` mode)
# fetched 18 of 20 references in 175 seconds. The two misses are the
# oldest papers in the list, both of which predate arXiv.
#
# | Group              | ok / total | Notes                                       |
# |--------------------|-----------:|---------------------------------------------|
# | `seed`             |       1/1  | arxiv route                                 |
# | `dmrg_origin`      |       0/2  | White 1992 / 1993 — no OA, no preprint      |
# | `mps_review`       |       3/3  | Unpaywall + arxiv                           |
# | `infinite_mps`     |       5/5  | Unpaywall + arxiv (iDMRG, from arXiv)       |
# | `tdvp`             |       2/2  | `:s2` saved both                            |
# | `finite_temperature`|      5/5  | Unpaywall                                   |
# | `time_evolution`   |       2/2  | Unpaywall                                   |
#
# Per successful source, the distribution was:
#
# | Source     | count |
# |------------|------:|
# | unpaywall  |    13 |
# | arxiv      |     3 |
# | s2         |     2 |
#
# 18 PDFs, 16.6 MB total.
#
# ## Where the cascade earned its keep
#
# Two observations from this run are worth calling out, both of which
# vindicate the "try several sources in order" design:
#
# ### 1. Title-search fallback on DOIs without `relation.has-preprint`
#
# For ten of the eleven successful APS references, Crossref's metadata
# did not include a `relation.has-preprint` arXiv link — the preprint
# id was recovered via the arXiv title+authors search fallback.
# Without that fallback, the run would have lost most of the APS-side
# bibliography to the "not a PDF (got HTML/landing)" path.
#
# ### 2. `:s2` as a second OA route
#
# Two TDVP papers by Haegeman et al. are open-access per Unpaywall, but
# the best_oa_location URL is APS's `link.aps.org/pdf/...` — which
# serves an HTML landing page unless the request comes from a
# subscribing IP. BiblioFetch correctly rejected those downloads (the
# `%PDF` magic-byte check caught the HTML) and moved on to `:s2`,
# which pointed at repository-hosted PDFs (UGent Biblio) that served
# the real articles.
#
# This is exactly the kind of failure the multi-source cascade exists
# to absorb.
#
# ## Friction surfaced
#
# Three issues for the project backlog came out of this run:
#
# 1. **The run summary under-counts deferred entries.** The one-line
#    summary reports `refs: 20 (ok=18 failed=0)` despite rendering `✗`
#    symbols next to the two deferred papers. `bibliofetch stats`
#    correctly shows `ok: 18, pending: 2` — the `run` summary needs to
#    gain the same third count.
#
# 2. ~~**`target` is cwd-relative, not job-file-relative.**~~ Fixed in
#    #37 — relative `target` now resolves against the job file's
#    directory, matching Cargo / npm / tox / pre-commit behavior. Every
#    `examples/*-job.toml` in this PR uses a plain relative target.
#
# 3. **Pre-arXiv papers without an OA alternative are unreachable
#    without a TDM key.** White's 1992 and 1993 DMRG papers are on
#    APS and have no preprint. Configuring `$APS_API_KEY` and adding
#    `:aps` to `sources` would recover them. That's an infrastructure
#    ask, not a tooling bug.
#
# ## Visualizing the store
#
# After the run, `bibliofetch stats` gives a per-group / per-source
# breakdown. `bibliofetch bib` exports a `.bib` file for LaTeX. Use
# `bibliofetch info <key>` to inspect the full attempt trail for any
# particular paper, including which routes the cascade tried and the
# HTTP status each returned.
