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
is_arxiv_versions
parse_arxiv_version_spec
```

## arXiv version discovery

```@docs
arxiv_latest_version
arxiv_list_versions
```

## Store

```@docs
Store
open_store
list_entries
entry_info
```

## Project skeleton

```@docs
generate
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

## Citation graph visualization

```@docs
to_dot
to_mermaid
```

## Deduplication

```@docs
find_duplicates
resolve_duplicates!
```

## Doctor (store integrity)

```@docs
doctor
fix!
StoreIssue
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
springer_oa_lookup
is_springer_doi
```

## Network status

```@docs
status
is_reachable
NetworkStatus
ProbeResult
```

## Vault (topic-based collection)

```@docs
VaultTopic
VaultIndex
load_vault_index
list_topics
topic_refs
vault_add_ref!
vault_fetch!
vault_bib
vault_search
```

## CLI

```@docs
cli_main
julia_main
```

## Native app build

```@docs
build
clean
```
