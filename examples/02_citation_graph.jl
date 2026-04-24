# # Citation-graph expansion
#
# A single seed paper becomes a small subgraph: BiblioFetch walks its
# reference list, queues each referenced DOI as a new entry, and fetches
# the bounded set in one run.
#
# ## The job file
#
# `examples/citation-graph-job.toml`:
#
# ```toml
# [folder]
# target = "graph_papers"
#
# [fetch]
# sources = ["unpaywall", "arxiv", "s2", "direct"]
#
# [graph]
# follow_references = true
# max_depth = 1
# max_refs_per_paper = 20
#
# [doi]
# list = [
#     "10.1016/j.aop.2010.09.012",   # Schollwöck's 2011 MPS review
# ]
# ```
#
# Two things to notice:
#
#   * `:s2` (Semantic Scholar) is added to `sources`. It contributes
#     reference lists that Crossref doesn't carry — arXiv-only preprints,
#     and some publishers whose Crossref records omit `reference` arrays.
#     Without `:s2`, the subgraph leaves many edges unexplored.
#
#   * `max_refs_per_paper = 20` caps fan-out. Review papers routinely
#     cite 200+ references; `20` keeps the run finite for a quick demo.
#     Bump it for a thorough citation survey, lower it for a sampling
#     pass.
#
# ## Running from the shell
#
# ```sh
# bibliofetch run examples/citation-graph-job.toml
# ```
#
# The run writes `examples/graph_papers/` containing the seed PDF plus
# every first-hop referenced DOI that BiblioFetch could reach. Entries
# that couldn't be fetched are recorded as `status = "failed"` or
# `status = "pending"` TOMLs in `.metadata/`.
#
# ## Visualizing the subgraph
#
# Once the run is done, render the captured edges:
#
# ```sh
# bibliofetch graph --format mermaid --out graph.mmd examples/graph_papers
# bibliofetch graph --format dot     --out graph.dot examples/graph_papers
# ```
#
# The mermaid output pastes straight into any Markdown renderer that
# understands ```` ```mermaid ```` fences. The DOT output renders with
# `dot -Tpng examples/graph.dot -o examples/graph.png`.
#
# ## Running from Julia
#
# When you want the entry list in-process (e.g., for post-run analysis):

using BiblioFetch

job_path = joinpath(@__DIR__, "citation-graph-job.toml")
job = BiblioFetch.load_job(job_path)
job.follow_references, job.max_depth, job.max_refs_per_paper

# The seed's references aren't resolved until `BiblioFetch.run` executes
# — `load_job` only parses the TOML. After a run, inspect the expanded
# set with `bibliofetch list` from the shell, or walk the metadata
# directory in Julia:
#
# ```julia
# store = BiblioFetch.open_store(job.target)
# for safekey in BiblioFetch.list_entries(store)
#     info = BiblioFetch.entry_info(store, safekey)
#     println(info.depth, "\t", info.key, "\t", info.title)
# end
# ```
