module BiblioFetch

using Dates
using Downloads
using FileWatching
using HTTP
using JSON3
using Logging
using Printf
using SHA
using TOML
using URIs

include("core/env.jl")
include("sources/http.jl")        # retry helper + URL consts + _to_plain
include("sources/refs.jl")        # DOI/arXiv parsing + ref→URL helpers
include("sources/crossref.jl")
include("sources/unpaywall.jl")
include("sources/arxiv.jl")
include("core/store.jl")
include("core/fetch.jl")
include("core/dedup.jl")          # depends on store + sha256 from fetch
include("io/bibtex.jl")
include("core/job.jl")            # depends on fetch + store + bibtex
include("core/watch.jl")          # depends on job.run
include("cli.jl")

export detect_environment, load_config, effective_runtime
export Store, open_store, list_entries, entry_info
export normalize_key, is_doi, is_arxiv
export fetch_paper!, sync!
export FetchEntry, FetchJob, FetchJobResult, AttemptLog, load_job
export bibtex_entry, write_bibtex
export find_duplicates, resolve_duplicates!
export cli_main
# NOTE: `run` is intentionally not exported — call as `BiblioFetch.run(path)` to
# avoid shadowing `Base.run`.

end # module BiblioFetch
