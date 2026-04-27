# BiblioFetch.jl

```@meta
CurrentModule = BiblioFetch
```

A bulk literature fetcher for Julia: feed it a list of DOIs or arXiv ids, get
back a local PDF store with TOML metadata, BibTeX export, and an optional
citation graph.

BiblioFetch is designed to work identically on a laptop with a university
proxy and on an SSH'd compute host that reaches the same proxy via a reverse
tunnel — the same command auto-detects which mode it is in.

- **Sources tried in order**: Unpaywall (legal OA lookup) → arXiv → Semantic
  Scholar → direct `doi.org` through a proxy → publisher TDM APIs.
- **Magic-byte verified**: HTML landing pages are rejected rather than saved as
  bogus PDFs.
- **Group-aware**: job files can bucket references into subdirectories.
- **Vault**: a topic-TOML collection at `~/.config/bibliofetch/vault/` holds
  canonical per-topic reference sets; projects can inherit from it without
  duplicating files on disk.
- **Annotations**: every paper carries editable tags, notes, read status, and
  a starred flag — queryable via `bibliofetch ls --tag` / `--unread` /
  `--starred`.

## Install

```julia
julia> using Pkg; Pkg.add("BiblioFetch")
```

### Instant CLI (optional)

Compile a sysimage once so `bibliofetch` starts in under a second:

```julia
using Pkg
Pkg.add("PackageCompiler")   # needed only for this step

using BiblioFetch
BiblioFetch.build()          # ~2–4 min; writes ~/.local/bin/bibliofetch
```

Make sure `~/.local/bin` is on your `PATH`, then:

```bash
bibliofetch --help
```

Rebuild after `Pkg.update("BiblioFetch")`:

```julia
BiblioFetch.build(force=true)
```

## A 30-second tour

**One-shot fetch** from the Julia REPL:

```julia
using BiblioFetch
rt    = detect_environment()
store = open_store(rt.store_root)
fetch_paper!(store, "arxiv:1706.03762"; rt=rt)
```

**Batch run** via a job file:

```toml
# job.toml
[folder]
target = "./papers"
bibtex = "refs.bib"

[fetch]
email = "you@example.com"

[doi.transformer]
list = ["arxiv:1706.03762"]

[doi.condensed-matter]
list = [
    "10.1103/PhysRevResearch.1.033027",
    "10.21468/SciPostPhys.1.1.001",
]
```

```bash
bibliofetch          # auto-detects job.toml in cwd
```

or from Julia:

```julia
result = BiblioFetch.run("job.toml")
```

**Vault** — a topic collection living outside any single project:

```bash
bibliofetch vault fetch mps-algorithms   # fetch all refs in a vault topic
bibliofetch vault bib                    # export combined vault.bib
```

**Annotations** — tagging and reading status:

```bash
bibliofetch annotate 10.1103/PhysRevB.99.214433   # opens $EDITOR
bibliofetch ls --tag dmrg
bibliofetch ls --unread
```

## Where to next

- [Usage Guide](@ref) — full walkthrough, job-file reference, vault,
  annotations, SSH tunnel setup.
- [API Reference](@ref) — every public function with signatures.
- Examples — runnable Literate notebooks (see sidebar).
