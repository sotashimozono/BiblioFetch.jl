using PrecompileTools

@compile_workload begin
    # Key parsing — always exercised on every run
    normalize_key("10.1103/PhysRevB.99.214433")
    normalize_key("arxiv:1234.5678")
    is_doi("10.1103/PhysRevB.99.214433")
    is_arxiv("arxiv:1234.5678")

    # Config / environment (no network I/O; probe=false)
    rt = detect_environment(; probe=false)

    # Store round-trip through a temp dir
    store = open_store(mktempdir())
    queue_reference!(store, "10.1103/PhysRevB.99.214433")
    list_entries(store)

    # BibTeX key generation
    md = Dict{String,Any}(
        "key"     => "10.1103/PhysRevB.99.214433",
        "title"   => "Test Paper",
        "authors" => ["Doe, John"],
        "year"    => 2024,
        "status"  => "ok",
        "journal" => "Phys. Rev. B",
    )
    bibtex_entry(md)

    # Warm up the ls command (no network I/O)
    _cmd_list(String[])
end
