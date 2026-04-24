# BiblioFetch.jl

[![docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://codes.sota-shimozono.com/BiblioFetch.jl/stable/)
[![docs: dev](https://img.shields.io/badge/docs-dev-purple.svg)](https://codes.sota-shimozono.com/BiblioFetch.jl/dev/)
[![Julia](https://img.shields.io/badge/julia-v1.10+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)

<a id="badge-top"></a>
[![codecov](https://codecov.io/gh/sotashimozono/BiblioFetch.jl/graph/badge.svg)](https://codecov.io/gh/sotashimozono/BiblioFetch.jl)
[![Build Status](https://github.com/sotashimozono/BiblioFetch.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/sotashimozono/BiblioFetch.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A bulk literature fetcher for Julia: feed it a list of DOIs or arXiv ids,
get back a local PDF store with TOML metadata. Designed to work identically
on a laptop with a university proxy and on an ssh'd compute host that reaches
the same proxy via reverse tunnel.

## Why

- Feed a `refs.txt` of DOIs / arXiv ids, get PDFs on disk in one step.
- Open-access articles are resolved through **Unpaywall**; physics preprints fall
  back to **arXiv**; paywalled articles go through a user-supplied **proxy**.
- Same command line on a laptop and on an ssh-reached compute host — detection
  picks the right route per host.

## Install

```julia
julia> using Pkg; Pkg.add("BiblioFetch")
```

Or for the CLI launcher, clone and use `bin/bibliofetch`:

```bash
git clone https://github.com/sotashimozono/BiblioFetch.jl.git
cd BiblioFetch.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
./bin/bibliofetch env
```

## Usage

```bash
# See what environment the tool detected (hostname / proxy / mode)
bibliofetch env

# Queue DOIs / arXiv ids (raw args or -f for a file; '#' comments allowed)
bibliofetch add 10.1103/PhysRevB.99.214433 arxiv:1905.07639
bibliofetch add -f refs.txt

# Fetch everything still pending
bibliofetch sync

# One-shot
bibliofetch fetch 10.21468/SciPostPhys.1.1.001
```

Or from Julia directly:

```julia
using BiblioFetch
rt    = detect_environment()
store = open_store(rt.store_root)
fetch_paper!(store, "arxiv:1706.03762"; rt)
```

## Fetch strategy

Given a DOI or arXiv id, BiblioFetch tries in order:

1. **Unpaywall** — queries the OA-lookup API (needs `email` in config); accepts
   the `best_oa_location` PDF URL if present.
2. **arXiv** — if the reference *is* an arXiv id, or if Crossref metadata
   points at an arXiv preprint (`relation.has-preprint`), or if a title search
   finds a match, the PDF is pulled from `arxiv.org/pdf/<id>.pdf`.
3. **Direct landing** — `https://doi.org/<doi>` through the configured proxy,
   but only when that proxy is reachable. HTML landing pages are detected via
   `%PDF` header check and rejected as failures rather than silently saved.

Every downloaded file is verified by magic bytes; you won't end up with a
directory full of HTML files pretending to be PDFs.

## Environment detection

`detect_environment()` auto-configures the fetch route:

- `gethostname()` selects a profile from `~/.config/bibliofetch/config.toml`
  (env var `BIBLIOFETCH_CONFIG` overrides the path).
- `HTTPS_PROXY` / `HTTP_PROXY` env variables override the profile's proxy.
- The selected proxy (or direct route if none) is probed against Crossref.
- Mode is classified as:
  - `:direct` — proxy reachable, non-localhost host.
  - `:tunneled` — proxy is `localhost` / `127.0.0.1` (assumed ssh reverse tunnel).
  - `:oa_only` — no proxy, or unreachable; only Unpaywall + arXiv paths are tried.

### Config example

A commented template ships at [`config/config.toml`](config/config.toml). Copy it once:

```bash
mkdir -p ~/.config/bibliofetch
cp "$(julia -e 'using BiblioFetch; print(pkgdir(BiblioFetch))')/config/config.toml" \
   ~/.config/bibliofetch/config.toml
```

The template covers both `[defaults]` and per-host `[profiles.<hostname>]`
examples (proxy, reverse-tunnel, store_root overrides). `bibliofetch env`
points at it when no config is found.

### Examples

Runnable demo jobs ship in [`examples/`](examples/) and are published as
narrated walkthroughs in the docs:

- [`minimal-job.toml`](examples/minimal-job.toml) — one DOI, all defaults
- [`citation-graph-job.toml`](examples/citation-graph-job.toml) — seed + one-hop reference graph
- [`publisher-tdm-job.toml`](examples/publisher-tdm-job.toml) — APS / Elsevier / Springer routes

```bash
bibliofetch run examples/minimal-job.toml
```

### SSH reverse tunnel

If your compute host can't reach the university proxy directly, forward it
from your laptop:

```bash
ssh -R 18080:proxy.univ.example:8080 compute-node
# Or persistently via ~/.ssh/config:
#   Host compute-node
#     RemoteForward 18080 proxy.univ.example:8080
```

The `compute-node` profile above then transparently routes fetches through
your laptop's proxy connection for the duration of the ssh session.

## Store layout

```
<target>/
  <safekey>.pdf              # PDFs for ungrouped entries live at the root
  <group>/<safekey>.pdf      # grouped entries land in their subdirectory
  <group>/<sub>/<safekey>.pdf  # arbitrary nesting via [doi.group.sub]
  refs.bib                   # optional, when [folder].bibtex is set
  .metadata/<safekey>.toml   # one hidden TOML per paper (status, source, attempts)
  .metadata/run.log          # append-only run log
```

The metadata store is plain TOML so rsync, grep, git, and manual edits all
Just Work. There's no SQLite / binary index to corrupt.

Metadata fields populated after a successful Crossref lookup:

```toml
key        = "10.1103/physrevresearch.1.033027"
title      = "Excitation of a uniformly moving atom through vacuum fluctuations"
authors    = ["Anatoly A. Svidzinsky"]
journal    = "Physical Review Research"
year       = 2019
source     = "unpaywall"      # which route succeeded
pdf_path   = "…"
status     = "ok"
is_oa      = true
fetched_at = "2026-04-23T…"
```

## Roadmap

- [x] `env` / `add` / `sync` / `fetch` / `list` / `info` CLI commands
- [x] Unpaywall + arXiv + proxy direct-landing cascade with `%PDF` verification
- [x] Per-host profile config; env var override
- [x] BibTeX export
- [x] Citation graph traversal (Crossref `reference` / `is-referenced-by-count`)
- [x] Publisher TDM APIs (APS, Elsevier, Springer OA) — legal bulk endpoints
- [ ] `BiblioFetch.generate(path)` — onboarding helper that drops the `template/` skeleton into a new project directory

---

## Repository setup reminders

1. **GitHub Repository Settings**
    * [ ] **Actions Permissions**: `Settings > Actions > General` → **"Read and write permissions"** (required for Documenter / TagBot).
    * [ ] **Allow Auto-merge**: (Recommended) Enable **"Allow auto-merge"** in `Settings > General`.
2. **Testing & Code Quality**
    * [ ] **Codecov**: Register repo at [Codecov](https://app.codecov.io/), add `CODECOV_TOKEN` secret, update badge above.
3. **Documentation (optional)**
    * [x] Rename `.github/workflows/Documentation.yml.disabled` → `.yml` to enable doc builds.
    * [ ] Set GitHub Pages source to `gh-pages` branch after first successful build (required once the workflow first succeeds).
4. **Personalization**
    * [x] LICENSE year/name
    * [x] Badge URLs point to `sotashimozono/BiblioFetch.jl`
