# BiblioFetch.jl

```@meta
CurrentModule = BiblioFetch
```

A bulk literature fetcher for Julia: feed it a list of DOIs or arXiv ids, get
back a local PDF store with TOML metadata and (optionally) a BibTeX file.

BiblioFetch is designed to work identically on a laptop with a university
proxy and on an ssh-reached compute host that reaches the same proxy via
reverse tunnel — the same command line auto-detects which mode it is in.

- **Sources tried in order**: [Unpaywall](https://unpaywall.org) (legal OA
  lookup) → arXiv → direct `doi.org` through a proxy.
- **Magic-byte verified**: HTML landing pages are rejected rather than saved
  as bogus PDFs.
- **Group-aware**: job files can bucket references into subdirectories.
- **Metadata-rich**: each fetched paper produces a TOML file with title,
  authors, year, journal, per-source attempt log, and optional
  `primary_category`.

## Install

From the Julia REPL:

```julia
julia> using Pkg; Pkg.add("BiblioFetch")
```

Or, for the CLI launcher, clone the repo:

```bash
git clone https://github.com/sotashimozono/BiblioFetch.jl.git
cd BiblioFetch.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
./bin/bibliofetch env
```

## A 30-second tour

**One-shot fetch** from the Julia REPL:

```julia
using BiblioFetch
rt    = detect_environment()
store = open_store(rt.store_root)
fetch_paper!(store, "arxiv:1706.03762"; rt)
```

**Batch run** via a job file (`bibliofetch.toml`):

```toml
[folder]
target = "./papers"
bibtex = "refs.bib"

[fetch]
email    = "you@example.com"
parallel = 4

[doi.transformer]
list = ["arxiv:1706.03762"]

[doi.condensed-matter]
list = [
    "10.1103/PhysRevResearch.1.033027",
    "10.21468/SciPostPhys.1.1.001",
]
```

```julia
julia> result = BiblioFetch.run("bibliofetch.toml")
BiblioFetch job 'my-project'
  target   : /.../papers
  refs     : 3  (ok=3 failed=0)
  elapsed  : 6.0s
  ── condensed-matter  2/2
      ✓ 10.1103/physrevresearch.1.033027  [unpaywall]
      ✓ 10.21468/scipostphys.1.1.001      [unpaywall]
  ── transformer  1/1
      ✓ arxiv:1706.03762                  [arxiv]
```

## Where to next

- [Usage Guide](@ref) — full walkthrough, job-file reference, SSH reverse
  tunnel setup.
- [API Reference](@ref) — every public function with signatures.
