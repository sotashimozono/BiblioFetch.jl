using BiblioFetch
using Dates
using Test

function _seed!(store, key::String; fields...)
    md = Dict{String,Any}("key" => key)
    for (k, v) in pairs(fields)
        md[String(k)] = v
    end
    BiblioFetch.write_metadata!(store, key, md)
end

# Create a non-empty PDF file at `pdf_path(store, key; group)`.
function _seed_pdf!(store, key; group="", bytes=rand(UInt8, 2048))
    p = BiblioFetch.pdf_path(store, key; group=group)
    mkpath(dirname(p))
    open(p, "w") do io
        ;
        write(io, bytes);
    end
    return p
end

@testset "stats: empty store → zero counters, nothing timestamps" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        st = stats(store)
        @test st.total == 0
        @test isempty(st.by_status)
        @test isempty(st.by_source)
        @test isempty(st.by_group)
        @test st.pdf_count == 0
        @test st.pdf_total_bytes == 0
        @test st.pdf_missing == 0
        @test st.duplicate_resolved == 0
        @test st.graph_expanded == 0
        @test st.oldest_fetch === nothing
        @test st.newest_fetch === nothing
    end
end

@testset "stats: counts by status / source / group" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed!(store, "10.1234/a"; status="ok", source="unpaywall", group="cond-mat")
        _seed!(store, "10.1234/b"; status="ok", source="arxiv", group="cond-mat")
        _seed!(store, "10.1234/c"; status="ok", source="unpaywall", group="ml")
        _seed!(store, "10.1234/d"; status="failed", group="ml")
        _seed!(store, "10.1234/e"; status="pending", group="")  # root group
        st = stats(store)

        @test st.total == 5
        @test st.by_status == Dict("ok" => 3, "failed" => 1, "pending" => 1)
        @test st.by_source == Dict("unpaywall" => 2, "arxiv" => 1)    # only ok entries
        @test st.by_group == Dict("cond-mat" => 2, "ml" => 2, "" => 1)
    end
end

@testset "stats: PDF count + size + missing detection" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        # Entry with real on-disk PDF
        _seed!(
            store,
            "10.1234/ok";
            status="ok",
            pdf_path=_seed_pdf!(store, "10.1234/ok"; bytes=zeros(UInt8, 3072)),
        )
        # Entry pointing at a PDF that was deleted
        _seed!(store, "10.1234/gone"; status="ok", pdf_path=joinpath(root, "gone.pdf"))
        # Entry with no pdf_path at all
        _seed!(store, "10.1234/nopath"; status="pending")

        st = stats(store)
        @test st.pdf_count == 1
        @test st.pdf_total_bytes == 3072
        @test st.pdf_missing == 1
    end
end

@testset "stats: graph_expanded and duplicate_resolved counters" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        _seed!(store, "10.1234/seed"; status="ok", depth=0)
        _seed!(store, "10.1234/child1"; status="ok", depth=1, referenced_by="10.1234/seed")
        _seed!(
            store, "10.1234/child2"; status="ok", depth=2, referenced_by="10.1234/child1"
        )
        _seed!(store, "10.1234/dup"; status="ok", duplicate_of="10.1234/seed")

        st = stats(store)
        @test st.graph_expanded == 2
        @test st.duplicate_resolved == 1
    end
end

@testset "stats: oldest_fetch / newest_fetch from metadata timestamps" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        t0 = DateTime(2026, 3, 1, 10, 0, 0)
        t1 = DateTime(2026, 4, 15, 14, 30, 0)
        t2 = DateTime(2026, 4, 23, 9, 0, 0)
        _seed!(store, "10.1234/a"; status="ok", fetched_at=string(t0))
        _seed!(store, "10.1234/b"; status="ok", fetched_at=string(t1))
        _seed!(store, "10.1234/c"; status="ok", fetched_at=string(t2))
        # Malformed timestamp must not crash or shift the window
        _seed!(store, "10.1234/d"; status="ok", fetched_at="not-a-date")

        st = stats(store)
        @test st.oldest_fetch == t0
        @test st.newest_fetch == t2
    end
end

@testset "stats: malformed metadata TOML is skipped" begin
    mktempdir() do root
        store = BiblioFetch.open_store(root)
        # Valid entry
        _seed!(store, "10.1234/good"; status="ok")
        # Malformed file directly in .metadata/
        bad_path = joinpath(root, BiblioFetch.METADATA_DIRNAME, "bad.toml")
        open(bad_path, "w") do io
            ;
            write(io, "not = valid = toml =");
        end

        st = stats(store)    # should not throw
        @test st.total == 1
        @test st.by_status == Dict("ok" => 1)
    end
end
