# API Reference

```@meta
CurrentModule = BiblioFetch
```

## Environment detection

```@docs
detect_environment
effective_runtime
load_config
```

## References — parse / classify

```@docs
normalize_key
is_doi
is_arxiv
```

## Store

```@docs
Store
open_store
list_entries
entry_info
```

## Fetch

```@docs
fetch_paper!
sync!
AttemptLog
```

## Jobs

```@docs
load_job
run
FetchEntry
FetchJob
FetchJobResult
```

## BibTeX

```@docs
bibtex_entry
write_bibtex
```

## Deduplication

```@docs
find_duplicates
resolve_duplicates!
```

## CLI

```@docs
cli_main
```
