# BiblioFetch project

This directory was created from the BiblioFetch project skeleton. It
contains everything needed to manage one bibliography as a self-contained
folder.

## Layout

```
.
├── job.toml       # what to fetch + how
├── papers/        # created on first run — PDFs + .metadata/ TOML records
└── README.md      # this file
```

## Quick start

1. Edit `job.toml` — add DOIs / arXiv ids to `[doi].list`, set your email
   under `[fetch]` (or in the user-level `~/.config/bibliofetch/config.toml`).
2. Fetch:
   ```sh
   bibliofetch run job.toml
   ```
3. Inspect results:
   ```sh
   bibliofetch stats papers
   bibliofetch list
   bibliofetch info <DOI or arxiv id>
   ```

## Exporting BibTeX

```sh
bibliofetch bib papers --out refs.bib
```

## Citation-graph expansion

Uncomment `[graph]` in `job.toml` to follow references one hop from each
seed paper. `max_depth` and `max_refs_per_paper` bound the blast radius.

## Keeping the store consistent

```sh
bibliofetch doctor papers --fix      # surface + auto-resolve integrity issues
bibliofetch dedup papers --apply     # drop PDF-hash duplicates
```

See the user manual at https://sotashimozono.github.io/BiblioFetch.jl/
for the full command reference.
