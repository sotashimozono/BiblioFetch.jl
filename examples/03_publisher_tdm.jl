# # Publisher TDM sources
#
# Three publisher APIs return paywalled PDFs directly when authenticated
# with a (free, academic) API key: APS Harvest, Elsevier ScienceDirect,
# and Springer Nature OpenAccess. This example runs one canonical DOI
# from each through the combined cascade.
#
# ## Getting the keys
#
# | Publisher   | Env var               | How to obtain                                  |
# |-------------|-----------------------|------------------------------------------------|
# | APS         | `APS_API_KEY`         | email apsombudsman@aps.org                     |
# | Elsevier    | `ELSEVIER_API_KEY`    | register at <https://dev.elsevier.com/>        |
# | Springer    | `SPRINGER_API_KEY`    | register at <https://dev.springernature.com/>  |
#
# Set whatever keys you have; missing keys make the corresponding source
# skip itself silently, so partial configurations are fine.
#
# ```sh
# export APS_API_KEY=…
# export ELSEVIER_API_KEY=…
# export SPRINGER_API_KEY=…
# ```
#
# ## The job file
#
# `examples/publisher-tdm-job.toml`:
#
# ```toml
# [folder]
# target = "tdm_papers"
#
# [fetch]
# sources = ["unpaywall", "arxiv", "aps", "elsevier", "springer", "direct"]
#
# [doi]
# list = [
#     "10.1103/PhysRevB.99.214433",           # APS — PRB
#     "10.1016/j.aop.2010.09.012",            # Elsevier — Annals of Physics
#     "10.1007/s11538-013-9822-9",            # Springer — Bull. Math. Biol.
# ]
# ```
#
# Sources order matters: BiblioFetch tries routes top-down and keeps the
# first successful PDF. With `:unpaywall` and `:arxiv` ahead of the
# publisher routes, green-OA copies are preferred — keys are only needed
# for papers that have no OA alternative.
#
# ## Running from the shell
#
# ```sh
# bibliofetch run examples/publisher-tdm-job.toml
# ```
#
# ## Per-DOI routing is automatic
#
# Each publisher source gates itself on the DOI prefix:
#
#   * `:aps`      → 10.1103/\*
#   * `:elsevier` → 10.1016/\*
#   * `:springer` → 10.1007/\*, 10.1038/\*, 10.1186/\*, 10.1140/\*
#
# So even though the job lists all three TDM sources, no cross-fire
# happens — each DOI only touches the route that can serve it.
#
# ## Running from Julia
#
# Inspecting what sources actually survived the load (keys unset filter
# out at run-time, not load-time — sources stay in the job object):

using BiblioFetch

job_path = joinpath(@__DIR__, "publisher-tdm-job.toml")
job = BiblioFetch.load_job(job_path)
job.sources

# To verify gating before you run:

for ref in job.refs
    verdicts = String[]
    if BiblioFetch.is_aps_doi(ref.key)
        push!(verdicts, "aps")
    end
    if BiblioFetch.is_elsevier_doi(ref.key)
        push!(verdicts, "elsevier")
    end
    if BiblioFetch.is_springer_doi(ref.key)
        push!(verdicts, "springer")
    end
    println(ref.key, "  →  ", isempty(verdicts) ? "(no TDM route)" : join(verdicts, ", "))
end

# ## When a run fails
#
# `bibliofetch info <DOI>` shows the full attempt trail after a fetch,
# including which routes were tried in order and the HTTP status each
# returned. That's the first thing to check when a publisher call
# unexpectedly hits a 401 / 403.
