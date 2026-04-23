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
parse_bibtex
bibentry_to_ref
import_bib!
BibEntry
```

## Deduplication

```@docs
find_duplicates
resolve_duplicates!
```

## Search

```@docs
search_entries
SearchMatch
```

## Statistics

```@docs
stats
StoreStats
```

## External metadata sources

```@docs
datacite_lookup
s2_lookup
```

## Publisher TDM (authenticated)

```@docs
aps_tdm_url
is_aps_doi
elsevier_tdm_url
is_elsevier_doi
elsevier_tdm_auth_headers
```

## Network status

```@docs
status
is_reachable
NetworkStatus
ProbeResult
```

## CLI

```@docs
cli_main
```
