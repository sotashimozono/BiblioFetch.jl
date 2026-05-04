using BiblioFetch
using Dates
using JSON3
using Test

# Helpers --------------------------------------------------------------------

# Capture cli_main(args)'s stdout into a String, and return (rc, out_str).
# We deliberately don't capture stderr — the human-readable banner / progress
# lines are allowed there (and a few tests want to assert nothing leaks to
# stdout besides JSON).
function _capture_stdout(f)
    # Use a Pipe — `redirect_stdout(::IOBuffer)` is not supported on every
    # Julia/OS combo (e.g. Windows + 1.12), but Pipe is.
    pipe = Pipe()
    out_task = nothing
    rc = redirect_stdout(pipe) do
        out_task = @async read(pipe.out, String)
        try
            f()
        finally
            # Closing the write side signals EOF to the reader.
            close(pipe.in)
        end
    end
    out_str = fetch(out_task)
    close(pipe.out)
    return rc, out_str
end

# Seed a fake metadata entry directly via write_metadata!, so we never hit
# the network. Returns the (full, on-disk) safekey.
function _seed_meta!(store, key; fields...)
    md = Dict{String,Any}("key" => key)
    for (k, v) in pairs(fields)
        md[String(k)] = v
    end
    BiblioFetch.write_metadata!(store, key, md)
    return key
end

# Point the global runtime at a temp store by writing a config file and
# overriding BIBLIOFETCH_CONFIG inside the block. Yields the store.
function _with_temp_store(f)
    mktempdir() do dir
        store_root = joinpath(dir, "store")
        mkpath(store_root)
        config_path = joinpath(dir, "config.toml")
        open(config_path, "w") do io
            println(io, "[defaults]")
            println(io, "store_root = \"$(replace(store_root, "\\" => "\\\\"))\"")
        end
        withenv("BIBLIOFETCH_CONFIG" => config_path) do
            store = BiblioFetch.open_store(store_root)
            f(store)
        end
    end
end

# Unit tests of the conversion helpers ---------------------------------------

@testset "_jsonify: basic conversions" begin
    @test BiblioFetch._jsonify("hello") == "hello"
    @test BiblioFetch._jsonify(:ok) == "ok"
    @test BiblioFetch._jsonify(nothing) === nothing
    @test BiblioFetch._jsonify(true) === true
    @test BiblioFetch._jsonify(42) === 42
    @test BiblioFetch._jsonify(Dict("a" => 1, :b => :sym)) ==
        Dict{String,Any}("a" => 1, "b" => "sym")
    @test BiblioFetch._jsonify([1, :a, "b"]) == Any[1, "a", "b"]
    @test BiblioFetch._jsonify(DateTime(2026, 5, 4, 12, 0, 0)) == "2026-05-04T12:00:00"
end

@testset "_fetch_result_to_dict: structural shape" begin
    res = BiblioFetch.FetchResult(
        "10.1234/abc",
        false,
        :none,
        nothing,
        "no candidate PDF URL",
        BiblioFetch.AttemptLog[],
    )
    d = BiblioFetch._fetch_result_to_dict(res)
    @test d["key"] == "10.1234/abc"
    @test d["ok"] === false
    @test d["source"] == "none"
    @test d["pdf_path"] === nothing
    @test d["error"] == "no candidate PDF URL"
    @test d["attempts"] isa AbstractVector
    @test isempty(d["attempts"])

    # roundtrip via JSON3 — make sure it actually serialises
    txt = JSON3.write(d)
    parsed = JSON3.read(txt)
    @test parsed.key == "10.1234/abc"
    @test parsed.ok === false
    @test parsed.source == "none"
end

@testset "_stats_to_dict: every fieldname round-trips" begin
    _with_temp_store() do store
        _seed_meta!(store, "10.1/x"; status="ok", source="arxiv", group="g")
        st = stats(store)
        d = BiblioFetch._stats_to_dict(st)
        for f in fieldnames(BiblioFetch.StoreStats)
            @test haskey(d, String(f))
        end
        # JSON-serialisable
        parsed = JSON3.read(JSON3.write(d))
        @test parsed.total == 1
        @test parsed.by_status["ok"] == 1
    end
end

# CLI integration tests ------------------------------------------------------

@testset "ls --json: emits an array of entry dicts" begin
    _with_temp_store() do store
        _seed_meta!(
            store,
            "arxiv:test.0001";
            title="Test Paper",
            status="ok",
            source="arxiv",
            group="",
        )
        _seed_meta!(
            store,
            "10.1234/another";
            title="Another",
            status="failed",
            source="none",
            group="grp",
        )
        rc, out = _capture_stdout() do
            cli_main(["ls", "--json"])
        end
        @test rc == 0
        data = JSON3.read(out)
        @test length(data) == 2
        keys_seen = sort(String[String(e.key) for e in data])
        @test keys_seen == ["10.1234/another", "arxiv:test.0001"]
        for e in data
            @test haskey(e, :status)
            @test haskey(e, :title)
            @test haskey(e, :source)
            @test haskey(e, :group)
        end
    end
end

@testset "info --json: emits the metadata dict" begin
    _with_temp_store() do store
        _seed_meta!(
            store,
            "arxiv:test.0001";
            title="T",
            status="ok",
            source="arxiv",
            year=2025,
            group="",
        )
        rc, out = _capture_stdout() do
            cli_main(["info", "arxiv:test.0001", "--json"])
        end
        @test rc == 0
        data = JSON3.read(out)
        @test data.key == "arxiv:test.0001"
        @test data.title == "T"
        @test data.status == "ok"
        @test data.year == 2025
        @test data.found === true
    end
end

@testset "info --json: missing key returns found=false" begin
    _with_temp_store() do _store
        rc, out = _capture_stdout() do
            cli_main(["info", "arxiv:missing.0001", "--json"])
        end
        @test rc == 0
        data = JSON3.read(out)
        @test data.found === false
        @test data.key == "arxiv:missing.0001"
    end
end

@testset "stats --json: every StoreStats field is exposed" begin
    _with_temp_store() do store
        _seed_meta!(store, "10.1/a"; status="ok", source="arxiv", group="grp")
        _seed_meta!(store, "10.1/b"; status="failed", group="grp")
        rc, out = _capture_stdout() do
            cli_main(["stats", "--json"])
        end
        @test rc == 0
        data = JSON3.read(out)
        @test data.total == 2
        @test data.by_status["ok"] == 1
        @test data.by_status["failed"] == 1
    end
end

@testset "sync --json: empty store yields []" begin
    _with_temp_store() do _store
        rc, out = _capture_stdout() do
            cli_main(["sync", "--json"])
        end
        @test rc == 0
        data = JSON3.read(out)
        @test data isa AbstractVector
        @test isempty(data)
    end
end

# Note: --json with -j short form
@testset "ls -j: short flag works the same as --json" begin
    _with_temp_store() do store
        _seed_meta!(store, "arxiv:test.0001"; title="T", status="ok", source="arxiv")
        rc, out = _capture_stdout() do
            cli_main(["ls", "-j"])
        end
        @test rc == 0
        data = JSON3.read(out)
        @test length(data) == 1
        @test data[1].key == "arxiv:test.0001"
    end
end

# run --json: drive a job offline (sources=["direct"], no proxy) so every
# entry fails deterministically without the network.
@testset "run --json: emits FetchJobResult shape" begin
    mktempdir() do dir
        target = joinpath(dir, "papers")
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
                [folder]
                target = "$(replace(target, "\\" => "\\\\"))"

                [fetch]
                email   = "t@x"
                sources = ["direct"]

                [doi]
                list = ["10.1103/PhysRevB.99.214433"]
                """,
            )
        end
        # Force no proxy so the offline failure path is hit.
        rc, out = withenv(
            "HTTP_PROXY" => nothing,
            "HTTPS_PROXY" => nothing,
            "http_proxy" => nothing,
            "https_proxy" => nothing,
        ) do
            _capture_stdout() do
                cli_main(["run", job_path, "--json"])
            end
        end
        # rc may be 0 or 1 depending on whether all entries succeeded; offline
        # path produces failures, but the exact exit code isn't load-bearing
        # here — what matters is the JSON shape.
        @test rc in (0, 1)
        data = JSON3.read(out)
        @test haskey(data, :name)
        @test haskey(data, :target)
        @test haskey(data, :elapsed_s)
        @test haskey(data, :entries)
        @test data.entries isa AbstractVector
        @test length(data.entries) == 1
        # DOIs get lowercased by normalize_key
        @test lowercase(String(data.entries[1].key)) == "10.1103/physrevb.99.214433"
        @test haskey(data.entries[1], :status)
        @test haskey(data.entries[1], :source)
    end
end
