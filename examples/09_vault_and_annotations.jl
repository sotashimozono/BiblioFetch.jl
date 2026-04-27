# # Vault and annotations
#
# BiblioFetch has two layers of paper management:
#
# 1. **Project jobs** (`job.toml`) — per-project reference lists that fetch
#    into a local directory. Covered in earlier examples.
# 2. **Vault** — a directory of topic TOML files that acts as a canonical,
#    cross-project reference collection. This example covers the vault.
#
# ## Vault layout
#
# By default the vault lives at `~/.config/bibliofetch/vault/`. Each
# `.toml` file defines one topic:
#
# ```toml
# # ~/.config/bibliofetch/vault/mps-algorithms.toml
# [topic]
# name  = "MPS Algorithms"
# tags  = ["tensor-network", "dmrg"]
# notes = "Core MPS/DMRG references"
#
# [doi]
# list = [
#   "arxiv:cond-mat/0407066",
#   "10.1103/RevModPhys.93.045003",
# ]
# ```
#
# An optional `vault.toml` in the same directory pins the shared store path
# and topic order:
#
# ```toml
# # ~/.config/bibliofetch/vault/vault.toml
# topics = ["mps-algorithms.toml", "dmrg-foundations.toml"]
# store  = "~/papers/vault"
# ```
#
# ## Creating a vault in a tempdir (demo)
#
# The rest of this example creates a self-contained vault under a tempdir
# so it runs without touching your home directory.

using BiblioFetch
using TOML

mktempdir() do vault_dir
    # --- write two topic files ---
    open(joinpath(vault_dir, "tensor-networks.toml"), "w") do io
        TOML.print(
            io,
            Dict(
                "topic" => Dict("name" => "Tensor Networks", "tags" => ["mps", "dmrg"]),
                "doi" => Dict("list" => ["arxiv:cond-mat/0407066"]),
            ),
        )
    end
    open(joinpath(vault_dir, "quantum-info.toml"), "w") do io
        TOML.print(
            io,
            Dict(
                "topic" => Dict("name" => "Quantum Information"),
                "doi" => Dict("list" => ["arxiv:quant-ph/0301023"]),
            ),
        )
    end

    # --- load the index ---
    index = load_vault_index(vault_dir)
    topics = list_topics(index)
    (length(topics), [t.name for t in topics])
end

# `list_topics` returns one `VaultTopic` per file found in the directory.
#
# ## Adding a ref from the shell
#
# ```bash
# bibliofetch vault add arxiv:1706.03762 --topic tensor-networks
# ```
#
# Appends the ref to the topic TOML in place without touching other entries.
#
# ## Fetching
#
# The `vault_fetch!` function builds a synthetic `FetchJob` per topic and
# dispatches to the same fetch pipeline used by `BiblioFetch.run`:
#
# ```bash
# bibliofetch vault fetch                  # all topics
# bibliofetch vault fetch tensor-networks  # one topic
# ```
#
# From Julia:
#
# ```julia
# index = load_vault_index()
# vault_fetch!(index; verbose=true)
# ```
#
# ## Inheriting vault refs in a project job
#
# A project `job.toml` can import vault topics without duplicating PDFs:
#
# ```toml
# [vault]
# inherit = ["tensor-networks", "quantum-info"]
#
# [doi]
# list = ["10.1103/PhysRevB.99.214433"]   # project-specific only
# ```
#
# `bibliofetch bib` then outputs a single `.bib` covering both vault and
# project references. The vault PDFs stay in the vault store; only the
# metadata is merged for BibTeX generation.
#
# ## BibTeX export
#
# ```bash
# bibliofetch vault bib                    # all topics → vault.bib
# bibliofetch vault bib tensor-networks    # one topic
# bibliofetch vault bib --out ~/papers/combined.bib
# ```
#
# ## Annotations
#
# Every paper in the store — vault or project — carries editable annotation
# fields in its `.metadata/<safekey>.toml`:
#
# ```toml
# tags        = ["mps", "finite-temperature"]
# notes       = "Definition 2.3 is the key result."
# read_status = "read"    # unread | reading | read | skimmed
# starred     = true
# ```
#
# The `annotate` command opens `$EDITOR` on the metadata file directly:
#
# ```bash
# bibliofetch annotate 10.1103/PhysRevB.99.214433
# ```
#
# Filter the listing by annotation field:
#
# ```bash
# bibliofetch ls --tag mps
# bibliofetch ls --unread
# bibliofetch ls --starred
# ```
#
# ## Searching the vault
#
# Full-text search across all vault topics (delegates to `search_entries`
# on the vault store):
#
# ```bash
# bibliofetch vault search "DMRG finite temperature"
# ```
#
# From Julia:
#
# ```julia
# index = load_vault_index()
# matches = vault_search(index, "DMRG")
# for m in matches
#     println(m.key, "\t", m.title)
# end
# ```
