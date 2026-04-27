# Usage Guide

```@meta
CurrentModule = BiblioFetch
```

## Global configuration

BiblioFetch looks up `~/.config/bibliofetch/config.toml` (or the path in the
`BIBLIOFETCH_CONFIG` env var) for settings that are *per-machine*, not
per-project:

```toml
[defaults]
email      = "you@example.com"     # used for Unpaywall OA lookups
store_root = "~/papers"             # fallback store for the `add`/`fetch` commands

[profiles.laptop]                   # matches gethostname() == "laptop"
proxy = "http://proxy.univ.example:8080"

[profiles.compute-node]             # ssh host — reaches the proxy via reverse tunnel
proxy = "http://localhost:18080"

[profiles.default]                  # hosts that match no profile fall here
# (omit `proxy` here to operate in `:oa_only` mode — Unpaywall + arXiv only)
```

Check what BiblioFetch thinks it is running on:

```bash
$ bibliofetch env
BiblioFetch runtime
  hostname        : panza
  profile         : laptop
  config          : /home/you/.config/bibliofetch/config.toml
  mode            : direct
  proxy           : http://proxy.univ.example:8080  [profile]
  reachable (via proxy): true
  store root      : /home/you/papers
  email           : you@example.com
```

`mode` is one of:

- `:direct` — proxy reachable, non-localhost host. All sources work (including
  paywalled direct `doi.org` landing).
- `:tunneled` — proxy is `localhost` / `127.0.0.1`. Assumed to be an
  `ssh -R`-style reverse tunnel.
- `:oa_only` — no proxy (or unreachable). Only Unpaywall + arXiv are tried.
  Paywalled articles are silently skipped because we have no route to them.

## Per-job TOML files

A job file tells `BiblioFetch.run` *what* to fetch, *where* to put it, and how
(which sources, how many in parallel, BibTeX or no). It has four sections:

```toml
[folder]
target = "./papers"             # REQUIRED. PDFs and .metadata/ go here.
bibtex = "./refs.bib"           # OPTIONAL. Generate a .bib after fetching.

[fetch]
email             = "you@example.com"    # overrides global config
parallel          = 4                     # concurrent downloads, default 1
force             = false                 # re-download even if already present
sources           = ["unpaywall", "arxiv", "direct"]
strict_duplicates = false                 # default: warn + keep first

[doi]                           # ungrouped — goes to {target}/
list = ["10.1103/PhysRevB.99.214433"]

[doi.condensed-matter]          # goes to {target}/condensed-matter/
list = [
    "arxiv:1106.6068",
    "10.1103/PhysRevLett.96.110404",
]

[doi.condensed-matter.haldane]  # nested — {target}/condensed-matter/haldane/
list = ["arxiv:cond-mat/0506438"]

[doi.ml]                        # {target}/ml/
list = ["arxiv:1706.03762"]
```

Running from the shell (auto-detects `job.toml` in cwd):

```bash
bibliofetch
```

or explicitly:

```bash
bibliofetch run job.toml
```

or from Julia:

```julia
result = BiblioFetch.run("job.toml")
```

### Reference forms

The `list` accepts any of:

| Form | Example |
| --- | --- |
| Bare DOI | `10.1103/PhysRevB.99.214433` |
| DOI URL | `https://doi.org/10.1103/PhysRevB.99.214433` |
| `doi:` prefix | `doi:10.1103/...` |
| New-style arXiv | `1706.03762`, `1706.03762v2`, `arxiv:1706.03762` |
| Legacy arXiv | `cond-mat/0608208` |
| arXiv URL | `https://arxiv.org/abs/1706.03762` |

`is_doi` and `is_arxiv` predicates are available in the API if you need them.

### Duplicate handling

If the same normalized key appears in two groups:

- Default (`strict_duplicates = false`): emit a warning and only fetch once,
  assigning it to the first group it appeared in. The `FetchJob.duplicates`
  field records every rejection.
- `strict_duplicates = true`: `load_job` throws `ArgumentError` before any
  network activity.

### Source filtering

`sources = [...]` restricts which routes are tried and in what order. Useful when:

- `["arxiv"]` — arXiv only. Good for a list of preprints.
- `["unpaywall", "arxiv"]` — legal OA only; skip the paywalled direct landing.
- `["direct"]` — force-test whether your proxy route works end-to-end.

## Vault — topic collections

A vault is a directory of topic TOML files, by default
`~/.config/bibliofetch/vault/` (override with `$BIBLIOFETCH_VAULT`). Each file
defines a named topic:

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

### Vault CLI

```bash
bibliofetch vault ls                          # list all topics
bibliofetch vault add arxiv:1234.5678 --topic mps-algorithms
bibliofetch vault fetch                       # fetch all topics
bibliofetch vault fetch mps-algorithms        # fetch one topic
bibliofetch vault bib                         # export all as vault.bib
bibliofetch vault bib mps-algorithms          # export one topic
bibliofetch vault search "DMRG"               # search across all vault papers
```

### Inheriting vault refs in a project

A project `job.toml` can pull in vault topics without duplicating files on
disk:

```toml
[vault]
inherit = ["mps-algorithms", "quantum-stat-mech"]

[doi]
list = ["10.1103/PhysRevB.99.214433"]   # project-specific only
```

`bibliofetch bib` then outputs a single `.bib` covering both vault and project
references.

## Annotations

Every paper in the store can carry tags, notes, reading status, and a starred
flag. These live in `.metadata/<safekey>.toml` alongside the fetch metadata:

```toml
tags        = ["mps", "finite-temperature"]
notes       = "Definition 2.3 is the key result; see Eq. (15)."
read_status = "read"    # unread | reading | read | skimmed
starred     = true
```

Edit them with:

```bash
bibliofetch annotate 10.1103/PhysRevB.99.214433   # opens $EDITOR
```

Filter the listing by annotation:

```bash
bibliofetch ls --tag mps
bibliofetch ls --unread
bibliofetch ls --starred
```

## SSH reverse tunnel — running on a compute node

Forward your university proxy to a compute host that cannot reach it directly:

```bash
# ~/.ssh/config
Host compute-node
    HostName     compute.internal
    User         you
    RemoteForward 18080 proxy.univ.example:8080
```

On `compute-node`, put this in `~/.config/bibliofetch/config.toml`:

```toml
[defaults]
email = "you@example.com"

[profiles.compute-node]
proxy = "http://localhost:18080"
```

BiblioFetch detects the localhost proxy and classifies the mode as `:tunneled`
automatically. Close the ssh session and the tunnel closes with it; BiblioFetch
falls back to `:oa_only` mode until you reconnect.

## Programmatic use

```julia
using BiblioFetch

# Build a Store manually (same layout, no job file)
rt    = detect_environment()
store = open_store(rt.store_root)

# Fetch one paper into a subdirectory
fetch_paper!(store, "arxiv:1706.03762"; rt=rt, group="ml")

# Load a job + inspect before running
job    = load_job("job.toml")
result = BiblioFetch.run(job; verbose=false)
for e in result.entries
    e.status === :failed || continue
    println(e.key, ": ", e.error)
    for a in e.attempts
        println("  ", a.source, " (", a.duration_s, "s): ",
                a.error === nothing ? "ok" : a.error)
    end
end

# Vault programmatic access
using BiblioFetch: load_vault_index, vault_fetch!, vault_bib
index = load_vault_index()
vault_fetch!(index; verbose=true)
vault_bib(index; out="vault.bib")
```

## CLI cheatsheet

**Common:**

```bash
bibliofetch                              # run job.toml in cwd
bibliofetch run <job.toml>              # explicit job file
bibliofetch add <ref>                   # queue into the global store
bibliofetch sync                        # fetch pending refs in global store
bibliofetch fetch <ref>                 # one-shot into global store
bibliofetch ls                          # list all entries
bibliofetch ls --tag <tag>              # filter by tag
bibliofetch ls --unread                 # filter by read_status
bibliofetch ls --starred                # filter starred papers
bibliofetch annotate <ref>              # edit tags/notes/status in $EDITOR
bibliofetch bib [--out path]            # regenerate refs.bib
bibliofetch search <query>              # full-text search
bibliofetch env                         # show detected runtime
```

**Vault:**

```bash
bibliofetch vault ls                    # list topics
bibliofetch vault fetch [<topic>]       # fetch all or one topic
bibliofetch vault bib [<topic>]         # BibTeX for all or one topic
bibliofetch vault add <ref> --topic <t> # add ref to a topic
bibliofetch vault search <query>        # search across vault
```

**Advanced:**

```bash
bibliofetch info <ref>                  # show stored metadata
bibliofetch graph [--format dot|mermaid] <dir>
bibliofetch stats [<dir>]
bibliofetch dedup [--resolve] <dir>
bibliofetch doctor [--fix] <dir>
bibliofetch init <path>                 # create project skeleton
```
