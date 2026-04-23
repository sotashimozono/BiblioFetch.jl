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

[log]
file = "./run.log"              # OPTIONAL. Default: {target}/.metadata/run.log

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

Given the file above, running

```julia
result = BiblioFetch.run("bibliofetch.toml")
```

produces this tree:

```
papers/
├── 10.1103_physrevb.99.214433.pdf
├── condensed-matter/
│   ├── arxiv__1106.6068.pdf
│   ├── 10.1103_physrevlett.96.110404.pdf
│   └── haldane/
│       └── arxiv__cond-mat_0506438.pdf
├── ml/
│   └── arxiv__1706.03762.pdf
├── refs.bib
└── .metadata/
    ├── 10.1103_physrevb.99.214433.toml
    ├── arxiv__1106.6068.toml
    ├── ...
    └── run.log
```

### Reference forms

The `list` accepts any of:

| Form | Example |
|---|---|
| Bare DOI | `10.1103/PhysRevB.99.214433` |
| DOI URL | `https://doi.org/10.1103/PhysRevB.99.214433` |
| `doi:` prefix | `doi:10.1103/...` |
| New-style arXiv | `1706.03762`, `1706.03762v2`, `arxiv:1706.03762` |
| Legacy arXiv | `cond-mat/0608208` |
| arXiv URL | `https://arxiv.org/abs/1706.03762` |

`is_doi` and `is_arxiv` predicates are available in the API if you need them.

### Duplicate handling

If the same normalized key appears in two groups:

- Default (`strict_duplicates = false`): emit a warning like
  `same DOI has appeared; keeping first occurrence key=... kept=A rejected=B`
  and only fetch once, assigning it to the first group (alphabetical) it
  appeared in. The `FetchJob.duplicates` field records every rejection.
- `strict_duplicates = true`: `load_job` throws `ArgumentError` before any
  network activity.

### Source filtering

`sources = [...]` restricts which of the three routes are tried and in what
order. Useful when:

- `["arxiv"]` — arXiv only. Skips Crossref / Unpaywall entirely. Good for a
  list of preprints where you already know DOIs aren't assigned.
- `["unpaywall", "arxiv"]` — legal OA only. Even on a machine with proxy
  reachable, skip the direct paywalled landing attempt.
- `["direct"]` — force-test whether your proxy route works end-to-end.

## SSH reverse tunnel — running on a compute node

You have proxy access on your laptop but your actual compute is on an ssh
host that cannot reach the university proxy directly. Forward it:

```bash
# ~/.ssh/config
Host compute-node
    HostName     compute.internal
    User         you
    RemoteForward 18080 proxy.univ.example:8080
```

Now when you `ssh compute-node`, the compute host sees `localhost:18080` as a
proxy that is really your laptop's connection to the university.

On `compute-node`, put this in `~/.config/bibliofetch/config.toml`:

```toml
[defaults]
email = "you@example.com"

[profiles.compute-node]
proxy = "http://localhost:18080"
```

The next time you run `bibliofetch run …` on `compute-node`, it transparently
routes paywalled fetches through your laptop's proxy. Close the ssh session
and the tunnel closes with it; BiblioFetch falls back to `:oa_only` mode on
the compute host until you reconnect.

## Programmatic use

```julia
using BiblioFetch

# Build a Store manually (same layout, no job file)
rt    = detect_environment()
store = open_store(rt.store_root)

# Fetch one paper into a subdirectory
fetch_paper!(store, "arxiv:1706.03762"; rt=rt, group="ml")

# Or load a job + inspect before running
job    = load_job("bibliofetch.toml")
result = BiblioFetch.run(job; verbose=false)
for e in result.entries
    e.status === :failed || continue
    println(e.key, ": ", e.error)
    for a in e.attempts
        println("  ", a.source, " (", a.duration_s, "s): ",
                a.error === nothing ? "ok" : a.error)
    end
end
```

## CLI cheatsheet

```
bibliofetch env                         # show detected runtime
bibliofetch run <job.toml>              # execute a job
bibliofetch bib <dir> [--out path]      # regenerate refs.bib for a store dir
bibliofetch add <ref>...                # queue into the global store
bibliofetch sync [--force]              # fetch pending/failed in the global store
bibliofetch fetch <ref> [--force]       # one-shot into the global store
bibliofetch list [--all]                # list global store entries
bibliofetch info <ref>                  # show stored metadata
```
