module BiblioFetch

using Dates
using Downloads
using HTTP
using JSON3
using Logging
using Printf
using SHA
using TOML
using URIs

include("env.jl")
include("sources.jl")
include("store.jl")
include("fetch.jl")
include("job.jl")
include("cli.jl")

export detect_environment, load_config, effective_runtime
export Store, open_store, list_entries, entry_info
export normalize_key, is_doi, is_arxiv
export fetch_paper!, sync!
export FetchEntry, FetchJob, FetchJobResult, AttemptLog, load_job
export cli_main
# NOTE: `run` is intentionally not exported — call as `BiblioFetch.run(path)` to
# avoid shadowing `Base.run`.

end # module BiblioFetch
