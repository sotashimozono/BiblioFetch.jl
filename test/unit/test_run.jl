using BiblioFetch
using Test

# BiblioFetch.run end-to-end, deterministic offline:
# restrict sources to :direct and run with no proxy — the guard in fetch.jl
# (`rt.proxy !== nothing`) blocks any candidate URL, so every ref fails with
# "no candidate PDF URL" without touching the network. This verifies the full
# job plumbing: target layout, per-group metadata `group` field, log file,
# FetchJobResult aggregation.
@testset "run: offline failure path produces structured results" begin
    mktempdir() do dir
        target = joinpath(dir, "papers")
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(target)"

          [fetch]
          email   = "t@x"
          sources = ["direct"]

          [doi]
          list = ["10.1103/PhysRevB.99.214433"]

          [doi.grp]
          list = ["arxiv:1706.03762"]
      """,
            )
        end

        rt = withenv(
            "HTTP_PROXY" => nothing,
            "HTTPS_PROXY" => nothing,
            "http_proxy" => nothing,
            "https_proxy" => nothing,
        ) do
            detect_environment(probe=false)
        end
        # ensure proxy really is absent in our synthetic runtime
        @test rt.proxy === nothing

        result = BiblioFetch.run(job_path; verbose=false, runtime=rt)
        @test result isa FetchJobResult
        @test length(result.entries) == 2
        # sources=["direct"] with no proxy produces zero candidates, which is
        # classified as :pending (deferred — network unavailable) so sync will
        # retry when the relevant route comes back. See fetch.jl:network_deferred.
        @test all(e -> e.status === :pending, result.entries)
        @test all(e -> e.source === :deferred, result.entries)
        @test all(e -> isempty(e.attempts), result.entries)  # no candidate URL produced

        # per-entry metadata TOML written to target/.metadata/, with correct group
        md_dir = joinpath(target, BiblioFetch.METADATA_DIRNAME)
        @test isdir(md_dir)
        files = readdir(md_dir)
        @test "run.log" in files
        tomls = filter(f -> endswith(f, ".toml"), files)
        @test length(tomls) == 2
        # check group field round-tripped
        groups = String[]
        for f in tomls
            md = BiblioFetch.TOML.parsefile(joinpath(md_dir, f))
            @test md["status"] == "pending"
            @test occursin("no candidate PDF URL", md["error"])
            push!(groups, String(get(md, "group", "")))
        end
        @test sort(groups) == ["", "grp"]

        # log contains start/end markers
        log_txt = read(joinpath(md_dir, "run.log"), String)
        @test occursin("run start", log_txt)
        @test occursin("run end", log_txt)
        @test occursin("ok=0/2", log_txt)

        # Regression for #34 — the FetchJobResult summary must surface
        # pending entries so the one-liner matches what `bibliofetch stats`
        # would show. Before the fix, `(ok=0 failed=0)` was printed even
        # when every ref was deferred.
        summary = sprint(show, MIME("text/plain"), result)
        @test occursin("ok=0", summary)
        @test occursin("failed=0", summary)
        @test occursin("pending=2", summary)
    end
end

@testset "FetchJobResult show: full success keeps backward-compat one-liner" begin
    # On a fully-successful run neither pending nor failed is interesting,
    # so we collapse to `(ok=N failed=0)` rather than spamming `pending=0`.
    # Construct the result object directly — no network I/O needed.
    job = BiblioFetch.FetchJob(
        "t",                          # name
        "/tmp/none",                  # target
        nothing,                      # bibtex
        "/tmp/none/run.log",          # log_file
        nothing,                      # email
        nothing,                      # proxy
        1,                            # parallel
        false,                        # force
        [:arxiv],                     # sources
        false,                        # strict_duplicates
        :lenient,                     # source_policy
        :pending,                     # on_fail
        false,                        # also_arxiv
        false,                        # follow_references
        0,                            # max_depth
        50,                           # max_refs_per_paper
        BiblioFetch.FetchEntry[],     # refs
        NTuple{3,String}[],           # duplicates
    )
    entries = [
        BiblioFetch.FetchEntry("arxiv:1", "", "arxiv:1"),
        BiblioFetch.FetchEntry("arxiv:2", "", "arxiv:2"),
    ]
    for e in entries
        e.status = :ok
        e.source = :arxiv
    end
    result = BiblioFetch.FetchJobResult(job, entries, 1.0)
    summary = sprint(show, MIME("text/plain"), result)
    @test occursin("(ok=2 failed=0)", summary)
    @test !occursin("pending", summary)
end

@testset "run: bibtex file is written when [folder].bibtex is set" begin
    mktempdir() do dir
        target = joinpath(dir, "papers")
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(target)"
          bibtex = "refs.bib"

          [fetch]
          email   = "t@x"
          sources = ["direct"]

          [doi]
          list = ["10.1103/PhysRevB.99.214433"]
      """,
            )
        end
        rt = withenv(
            "HTTP_PROXY" => nothing,
            "HTTPS_PROXY" => nothing,
            "http_proxy" => nothing,
            "https_proxy" => nothing,
        ) do
            detect_environment(probe=false)
        end

        # Seed the store: metadata + a non-empty fake PDF so `has_pdf` returns true
        # → run hits the `:cached` fast path and preserves our title/authors/year.
        store = open_store(target)
        BiblioFetch.write_metadata!(
            store,
            "10.1103/physrevb.99.214433",
            Dict(
                "key" => "10.1103/physrevb.99.214433",
                "authors" => ["John Smith"],
                "title" => "Seed",
                "journal" => "PRB",
                "year" => 2019,
                "status" => "ok",
            ),
        )
        pdf = BiblioFetch.pdf_path(store, "10.1103/physrevb.99.214433")
        mkpath(dirname(pdf))
        open(pdf, "w") do io
            write(io, "dummy")
        end

        result = BiblioFetch.run(job_path; verbose=false, runtime=rt)
        bib_path = joinpath(target, "refs.bib")
        @test isfile(bib_path)
        txt = read(bib_path, String)
        @test occursin("@article{Smith2019,", txt)
        @test occursin("doi     = {10.1103/physrevb.99.214433}", txt)

        log_txt = read(result.job.log_file, String)
        @test occursin("bibtex written", log_txt)
    end
end

@testset "_attempts_to_dict round-trip via TOML" begin
    a1 = AttemptLog(:unpaywall, "https://example/1.pdf", false, 404, "not found", 1.234)
    a2 = AttemptLog(:arxiv, "https://arxiv.org/x", true, 200, nothing, 0.5)

    d1 = BiblioFetch._attempts_to_dict(a1)
    d2 = BiblioFetch._attempts_to_dict(a2)

    @test d1["source"] == "unpaywall"
    @test d1["ok"] == false
    @test d1["http_status"] == 404
    @test d1["error"] == "not found"
    @test d1["duration_s"] == 1.234

    # `error` key omitted when nothing
    @test !haskey(d2, "error")

    # must be TOML-serializable
    io = IOBuffer()
    BiblioFetch.TOML.print(io, Dict("attempts" => [d1, d2]))
    s = String(take!(io))
    @test occursin("source = \"unpaywall\"", s)
    @test occursin("http_status = 404", s)
end
