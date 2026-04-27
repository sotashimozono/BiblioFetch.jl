# BiblioFetch.jl

[![docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://codes.sota-shimozono.com/BiblioFetch.jl/stable/)
[![docs: dev](https://img.shields.io/badge/docs-dev-purple.svg)](https://codes.sota-shimozono.com/BiblioFetch.jl/dev/)
[![Julia](https://img.shields.io/badge/julia-v1.10+-9558b2.svg)](https://julialang.org)
[![Build Status](https://github.com/sotashimozono/BiblioFetch.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/sotashimozono/BiblioFetch.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![codecov](https://codecov.io/gh/sotashimozono/BiblioFetch.jl/graph/badge.svg)](https://codecov.io/gh/sotashimozono/BiblioFetch.jl)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)

Bulk literature fetcher for Julia: give it a list of DOIs or arXiv ids, get
back a local PDF store with TOML metadata, BibTeX export, and a citation graph.
Designed to work identically on a laptop with a university proxy and on an
SSH'd compute host that tunnels through the same proxy.

---

## Table of Contents

- [Installation](#installation)
  - [As a Julia library](#as-a-julia-library)
  - [As a native CLI command](#as-a-native-cli-command)
- [Quick start](#quick-start)
- [Project-based workflow](#project-based-workflow)
- [Vault — topic collections](#vault--topic-collections)
- [Fetch strategy](#fetch-strategy)
- [Environment detection & config](#environment-detection--config)
- [Store layout](#store-layout)
- [Metadata fields](#metadata-fields)
- [SSH reverse tunnel](#ssh-reverse-tunnel)

---

## Installation

### As a Julia library

```julia
using Pkg
Pkg.add("BiblioFetch")
```

### As a native CLI command

`BiblioFetch.build()` compiles the package into a sysimage and installs a
`bibliofetch` wrapper script so the command starts in **under a second**.

```julia
using Pkg
Pkg.add("BiblioFetch")
Pkg.add("PackageCompiler")          # needed once for the build step only

using BiblioFetch
BiblioFetch.build()                  # takes ~2–4 min on first run
```

After the build completes:

```text
BiblioFetch.build()  [sysimage mode]
  package   : ~/.julia/packages/BiblioFetch/…
  sysimage  : ~/.local/share/bibliofetch/sys.so   (~360 MB)
  bindir    : ~/.local/bin
  precompile: yes
…
Done. Try it:
    bibliofetch --help
```

Make sure `~/.local/bin` is on your `PATH` (add to `~/.zshrc` / `~/.bashrc` if
not):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Rebuild after `Pkg.update("BiblioFetch")`:

```julia
BiblioFetch.build(force=true)
```

To remove the sysimage and wrapper script from your system:

```julia
BiblioFetch.clean()
```

**`build` options:**

| Keyword | Default | Description |
| --- | --- | --- |
| `sysimage_dir` | `~/.local/share/bibliofetch` | Where `sys.so` is written |
| `bindir` | `~/.local/bin` | Where the `bibliofetch` script is installed |
| `force` | `false` | Overwrite existing sysimage |

**`clean` options:** same `sysimage_dir` and `bindir` keywords — pass the same
values you used at build time if you customised them.

---

## Quick start

```bash
# See detected runtime (hostname, proxy, mode)
bibliofetch env

# Queue single references
bibliofetch add 10.1103/PhysRevB.99.214433
bibliofetch add arxiv:1905.07639

# Queue from a file (one ref per line; # comments ok)
bibliofetch add -f refs.txt

# Download everything queued
bibliofetch sync

# One-shot fetch
bibliofetch fetch 10.21468/SciPostPhys.1.1.001

# List papers in store
bibliofetch ls
bibliofetch ls --tag dmrg
bibliofetch ls --unread
bibliofetch ls --starred

# Add tags / notes / read status interactively
bibliofetch annotate 10.1103/PhysRevB.99.214433

# Export BibTeX
bibliofetch bib
bibliofetch bib --out ~/papers/project.bib

# Search
bibliofetch search "tensor network"
bibliofetch search Vidal --field authors
```

Or from Julia:

```julia
using BiblioFetch
rt    = detect_environment()
store = open_store(rt.store_root)
fetch_paper!(store, "arxiv:1706.03762"; rt)
```

---

## Project-based workflow

Create a project skeleton with `bibliofetch init`, fill in the DOIs, then
run — PDFs land in the configured directory, grouped by sub-topic.

```bash
bibliofetch init ~/projects/FiniteTemperature
```

This writes:

```text
~/projects/FiniteTemperature/
  job.toml   ← edit this
  README.md
```

Edit `job.toml`:

```toml
[folder]
target = "papers"          # relative to this file
bibtex = "refs.bib"        # auto-generated after each run

[fetch]
email = "you@example.com"  # for Unpaywall

[doi]
list = [
  "10.1103/PhysRevB.99.214433",
  "arxiv:2301.00001",
]

[doi.foundations]
list = [
  "arxiv:cond-mat/0407066",
]
```

Run from any directory:

```bash
cd ~/projects/FiniteTemperature
bibliofetch                   # auto-detects job.toml in cwd

# or explicitly
bibliofetch run job.toml
```

### Inheriting from a vault

If you maintain a vault of canonical references (see below), a project can
pull them in without duplicating them on disk:

```toml
[vault]
inherit = ["mps-algorithms", "quantum-stat-mech"]

[doi]
list = ["10.1103/PhysRevB.99.214433"]   # project-specific only
```

`bibliofetch bib` then outputs a single `.bib` covering both vault and project
references.

---

## Vault — topic collections

A vault is a set of topic TOML files living at
`~/.config/bibliofetch/vault/` (override with `$BIBLIOFETCH_VAULT`).
Each file defines a named topic:

```toml
# ~/.config/bibliofetch/vault/mps-algorithms.toml
[topic]
name  = "MPS Algorithms"
tags  = ["tensor-network", "dmrg"]
notes = "Core MPS/DMRG references"

[doi]
list = [
  "arxiv:cond-mat/0407066",
  "10.1103/RevModPhys.93.045003",
]
```

An optional `vault.toml` pins the shared store path and topic order:

```toml
# ~/.config/bibliofetch/vault/vault.toml
topics = ["mps-algorithms.toml", "dmrg-foundations.toml"]
store  = "~/papers/vault"
```

**Vault CLI:**

```bash
bibliofetch vault ls                         # list all topics
bibliofetch vault add arxiv:1234.5678 --topic mps-algorithms
bibliofetch vault fetch                      # fetch all topics
bibliofetch vault fetch mps-algorithms       # fetch one topic
bibliofetch vault bib                        # export all as vault.bib
bibliofetch vault bib mps-algorithms         # export one topic
bibliofetch vault search "DMRG"              # search across all vault papers
```

---

## Fetch strategy

For each DOI or arXiv id, BiblioFetch tries sources in order until a valid PDF
is obtained:

1. **Unpaywall** — OA-lookup API (requires `email` in config). Accepts the
   `best_oa_location` PDF URL if present.
2. **arXiv** — if the ref is an arXiv id, or Crossref metadata links a
   preprint, or a title search finds a match.
3. **Semantic Scholar** — alternative OA PDF set.
4. **Direct landing** — `https://doi.org/<doi>` through the configured proxy
   (only when the proxy is reachable).
5. **Publisher TDM APIs** — APS Harvest, Elsevier ScienceDirect, Springer
   Nature OA (each requires an API key in config).

Every downloaded file is verified by `%PDF` magic bytes — HTML landing pages
are detected and rejected rather than silently saved as broken PDFs.

**Citation graph expansion**: set `[graph] follow_references = true` in
`job.toml` to automatically queue referenced DOIs up to `max_depth` hops.

---

## Environment detection & config

`detect_environment()` auto-configures the fetch route based on hostname and
proxy reachability.

Copy the annotated config template once:

```bash
mkdir -p ~/.config/bibliofetch
cp "$(julia -e 'using BiblioFetch; print(pkgdir(BiblioFetch))')/config/config.toml" \
   ~/.config/bibliofetch/config.toml
```

Example `config.toml`:

```toml
[defaults]
email      = "you@university.edu"
store_root = "~/papers"

[profiles.mylaptop]
proxy      = "http://proxy.univ.example:8080"

[profiles.computehost]
proxy      = "http://localhost:18080"   # reverse SSH tunnel
store_root = "~/scratch/papers"
```

`bibliofetch env` shows the detected profile and reachability status.

**Detected modes:**

| Mode | Meaning |
|---|---|
| `:direct` | Proxy reachable, non-localhost |
| `:tunneled` | Proxy is `localhost` / `127.0.0.1` (SSH tunnel) |
| `:oa_only` | No proxy or unreachable — Unpaywall + arXiv only |

---

## Store layout

```text
<target>/
  <safekey>.pdf                    # ungrouped PDFs at root
  <group>/<safekey>.pdf            # grouped PDFs
  <group>/<sub>/<safekey>.pdf      # nested groups via [doi.group.sub]
  <safekey>__preprint.pdf          # arXiv preprint alongside publisher PDF
  refs.bib                         # BibTeX (when [folder].bibtex is set)
  .metadata/<safekey>.toml         # one TOML per paper (editable)
  .metadata/run.log                # append-only run log
```

The metadata store is plain TOML — rsync, grep, git, and manual edits all
work without any special tooling.

---

## Metadata fields

```toml
key        = "10.1103/physrevresearch.1.033027"
title      = "Excitation of a uniformly moving atom through vacuum fluctuations"
authors    = ["Anatoly A. Svidzinsky"]
journal    = "Physical Review Research"
year       = 2019
status     = "ok"           # pending | ok | failed | skipped
source     = "unpaywall"    # which route succeeded
pdf_path   = "/home/…/10_1103_physrevresearch.1.033027.pdf"
is_oa      = true
fetched_at = "2026-04-23T12:34:56"
sha256     = "abcd1234…"

# Annotation fields (set via `bibliofetch annotate`)
tags        = ["quantum-optics", "vacuum-fluctuations"]
notes       = "Key result in Eq. (15); cf. Fulling–Davies–Unruh effect."
read_status = "read"        # unread | reading | read | skimmed
starred     = false
```

---

## SSH reverse tunnel

Forward your university proxy to a compute host:

```bash
ssh -R 18080:proxy.univ.example:8080 computehost
```

Or persistently in `~/.ssh/config`:

```text
Host computehost
  RemoteForward 18080 proxy.univ.example:8080
```

Set `proxy = "http://localhost:18080"` in the `computehost` profile. BiblioFetch
detects the localhost proxy and classifies the mode as `:tunneled` automatically.
