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
            write(io, """
                [folder]
                target = "$(target)"

                [fetch]
                email   = "t@x"
                sources = ["direct"]

                [doi]
                list = ["10.1103/PhysRevB.99.214433"]

                [doi.grp]
                list = ["arxiv:1706.03762"]
            """)
        end

        rt = withenv("HTTP_PROXY" => nothing, "HTTPS_PROXY" => nothing,
                     "http_proxy" => nothing, "https_proxy" => nothing) do
            detect_environment(probe = false)
        end
        # ensure proxy really is absent in our synthetic runtime
        @test rt.proxy === nothing

        result = BiblioFetch.run(job_path; verbose = false, runtime = rt)
        @test result isa FetchJobResult
        @test length(result.entries) == 2
        @test all(e -> e.status === :failed, result.entries)
        @test all(e -> e.source  === :none,  result.entries)
        @test all(e -> isempty(e.attempts),   result.entries)  # no candidate URL produced

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
            @test md["status"] == "failed"
            @test md["error"]  == "no candidate PDF URL"
            push!(groups, String(get(md, "group", "")))
        end
        @test sort(groups) == ["", "grp"]

        # log contains start/end markers
        log_txt = read(joinpath(md_dir, "run.log"), String)
        @test occursin("run start", log_txt)
        @test occursin("run end",   log_txt)
        @test occursin("ok=0/2",    log_txt)
    end
end

@testset "_attempts_to_dict round-trip via TOML" begin
    a1 = AttemptLog(:unpaywall, "https://example/1.pdf", false, 404, "not found", 1.234)
    a2 = AttemptLog(:arxiv,     "https://arxiv.org/x",   true,  200, nothing,     0.5)

    d1 = BiblioFetch._attempts_to_dict(a1)
    d2 = BiblioFetch._attempts_to_dict(a2)

    @test d1["source"] == "unpaywall"
    @test d1["ok"]     == false
    @test d1["http_status"] == 404
    @test d1["error"]  == "not found"
    @test d1["duration_s"] == 1.234

    # `error` key omitted when nothing
    @test !haskey(d2, "error")

    # must be TOML-serializable
    io = IOBuffer()
    BiblioFetch.TOML.print(io, Dict("attempts" => [d1, d2]))
    s = String(take!(io))
    @test occursin("source = \"unpaywall\"", s)
    @test occursin("http_status = 404",      s)
end
