using BiblioFetch
using Test

@testset "crossref_references: extracts DOIs, lowercased, skips unstructured" begin
    meta = Dict{String,Any}(
        "reference" => [
            Dict("DOI" => "10.1103/PhysRevB.99.214433", "doi-asserted-by" => "publisher"),
            Dict("DOI" => "10.1038/NPHYS1234"),
            Dict("key" => "ref3", "unstructured" => "Foo et al. (2020)"),  # no DOI
            Dict("DOI" => "  10.1016/J.AOP.2005.10.005  "),                # whitespace
            Dict("DOI" => ""),                                              # empty skipped
        ],
    )
    @test BiblioFetch.crossref_references(meta) ==
        ["10.1103/physrevb.99.214433", "10.1038/nphys1234", "10.1016/j.aop.2005.10.005"]
end

@testset "crossref_references: no reference field returns empty" begin
    @test BiblioFetch.crossref_references(Dict()) == String[]
    @test BiblioFetch.crossref_references(Dict("reference" => "not-an-array")) == String[]
end

@testset "load_job: [graph] section defaults + overrides" begin
    mktempdir() do dir
        p = joinpath(dir, "job.toml")
        # defaults: follow_references=false, max_depth=1, max_refs_per_paper=50
        open(p, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [doi]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        job = BiblioFetch.load_job(p)
        @test job.follow_references == false
        @test job.max_depth == 1
        @test job.max_refs_per_paper == 50

        # overrides
        open(p, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [graph]
          follow_references = true
          max_depth = 3
          max_refs_per_paper = 10
          [doi]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        job2 = BiblioFetch.load_job(p)
        @test job2.follow_references == true
        @test job2.max_depth == 3
        @test job2.max_refs_per_paper == 10
    end
end

@testset "load_job: invalid [graph] values rejected" begin
    mktempdir() do dir
        p = joinpath(dir, "job.toml")
        open(p, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [graph]
          max_depth = -1
          [doi]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        @test_throws ArgumentError BiblioFetch.load_job(p)

        open(p, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [graph]
          max_refs_per_paper = 0
          [doi]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        @test_throws ArgumentError BiblioFetch.load_job(p)
    end
end

# Integration: seed the store so one "already-fetched" parent has two refs
# recorded in its metadata. Run the job with follow_references=true, sources=[]
# (offline failure path), and check the expansion queued exactly the expected
# children.
@testset "run: citation expansion queues children offline" begin
    mktempdir() do dir
        target = joinpath(dir, "papers")
        # Seed a fake "parent" entry that already has references recorded
        store = BiblioFetch.open_store(target)
        parent_key = "10.1234/parent"
        BiblioFetch.write_metadata!(
            store,
            parent_key,
            Dict(
                "key" => parent_key,
                "status" => "ok",
                "group" => "",
                "referenced_dois" => ["10.9999/child-a", "10.9999/child-b"],
            ),
        )
        # Fake PDF so sync's cache check lets the parent through as :cached
        pdf = BiblioFetch.pdf_path(store, parent_key)
        mkpath(dirname(pdf))
        open(pdf, "w") do io
            ;
            write(io, "%PDF-fake");
        end

        # Write a job that references the seeded parent with graph enabled
        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(target)"
          [fetch]
          sources = ["direct"]
          [graph]
          follow_references = true
          max_depth = 1
          [doi]
          list = ["$(parent_key)"]
      """,
            )
        end

        rt = withenv(
            "HTTP_PROXY" => nothing,
            "HTTPS_PROXY" => nothing,
            "http_proxy" => nothing,
            "https_proxy" => nothing,
            "BIBLIOFETCH_CONFIG" => nothing,
        ) do
            BiblioFetch.detect_environment(; probe=false)
        end

        result = BiblioFetch.run(job_path; verbose=false, runtime=rt)

        @test length(result.entries) == 3        # parent + 2 children
        keys = [e.key for e in result.entries]
        @test parent_key in keys
        @test "10.9999/child-a" in keys
        @test "10.9999/child-b" in keys

        # children: depth=1, referenced_by=parent
        for e in result.entries
            if e.key in ("10.9999/child-a", "10.9999/child-b")
                @test e.depth == 1
                @test e.referenced_by == parent_key
            else
                @test e.depth == 0
            end
        end
    end
end

@testset "run: max_refs_per_paper caps expansion" begin
    mktempdir() do dir
        target = joinpath(dir, "papers")
        store = BiblioFetch.open_store(target)
        parent_key = "10.1234/parent"
        big_refs = ["10.9999/child-$(i)" for i in 1:10]
        BiblioFetch.write_metadata!(
            store,
            parent_key,
            Dict(
                "key" => parent_key,
                "status" => "ok",
                "group" => "",
                "referenced_dois" => big_refs,
            ),
        )
        pdf = BiblioFetch.pdf_path(store, parent_key)
        mkpath(dirname(pdf))
        open(pdf, "w") do io
            ;
            write(io, "%PDF-fake");
        end

        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(target)"
          [fetch]
          sources = ["direct"]
          [graph]
          follow_references = true
          max_refs_per_paper = 3
          [doi]
          list = ["$(parent_key)"]
      """,
            )
        end

        rt = BiblioFetch.detect_environment(; probe=false)
        result = BiblioFetch.run(job_path; verbose=false, runtime=rt)
        # parent + 3 children (rather than 10)
        @test length(result.entries) == 4
        child_count = count(e -> e.depth == 1, result.entries)
        @test child_count == 3
    end
end

@testset "run: dedup across hops + no duplicate when child is already listed" begin
    mktempdir() do dir
        target = joinpath(dir, "papers")
        store = BiblioFetch.open_store(target)

        # Parent cites a DOI that the user ALSO lists directly
        parent_key = "10.1234/parent"
        already_listed = "10.1234/also-listed"
        BiblioFetch.write_metadata!(
            store,
            parent_key,
            Dict(
                "key" => parent_key,
                "status" => "ok",
                "group" => "",
                "referenced_dois" => [already_listed, "10.9999/new-child"],
            ),
        )
        pdf = BiblioFetch.pdf_path(store, parent_key)
        mkpath(dirname(pdf))
        open(pdf, "w") do io
            ;
            write(io, "%PDF-fake");
        end

        # Seed the user-listed one too (so it's :ok + cached)
        BiblioFetch.write_metadata!(
            store,
            already_listed,
            Dict("key" => already_listed, "status" => "ok", "group" => ""),
        )
        pdf2 = BiblioFetch.pdf_path(store, already_listed)
        open(pdf2, "w") do io
            ;
            write(io, "%PDF-fake2");
        end

        job_path = joinpath(dir, "job.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(target)"
          [fetch]
          sources = ["direct"]
          [graph]
          follow_references = true
          [doi]
          list = ["$(parent_key)", "$(already_listed)"]
      """,
            )
        end
        rt = BiblioFetch.detect_environment(; probe=false)
        result = BiblioFetch.run(job_path; verbose=false, runtime=rt)

        # parent + already_listed + one NEW child → 3, not 4
        @test length(result.entries) == 3
        @test Set(e.key for e in result.entries) ==
            Set([parent_key, already_listed, "10.9999/new-child"])
    end
end
