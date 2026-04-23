using BiblioFetch
using Test

@testset "load_job: flat list" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"

          [fetch]
          email = "test@example.com"
          parallel = 2

          [doi]
          list = ["10.1103/PhysRevB.99.214433", "arxiv:1706.03762"]
      """,
            )
        end
        job = load_job(job_path)
        @test job.target == abspath(joinpath(dir, "papers"))
        @test job.email == "test@example.com"
        @test job.parallel == 2
        @test job.sources == collect(BiblioFetch.DEFAULT_SOURCES)
        @test length(job.refs) == 2
        @test job.refs[1].key == "10.1103/physrevb.99.214433"
        @test job.refs[1].group == ""
        @test job.refs[2].key == "arxiv:1706.03762"
    end
end

@testset "load_job: groups and nested groups" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"

          [fetch]
          email = "t@x"

          [doi]
          list = ["10.1103/PhysRevB.99.214433"]

          [doi.cond-mat]
          list = ["arxiv:1106.6068"]

          [doi.cond-mat.haldane]
          list = ["arxiv:cond-mat/0608208"]

          [doi.ml]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        job = load_job(job_path)
        bygroup = Dict(e.group => e.key for e in job.refs)
        @test bygroup[""] == "10.1103/physrevb.99.214433"
        @test bygroup["cond-mat"] == "arxiv:1106.6068"
        @test bygroup["cond-mat/haldane"] == "arxiv:cond-mat/0608208"
        @test bygroup["ml"] == "arxiv:1706.03762"
    end
end

@testset "load_job: duplicate handling" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        content = """
            [folder]
            target = "$(dir)/papers"

            [fetch]
            email = "t@x"

            [doi.a]
            list = ["arxiv:1706.03762"]

            [doi.b]
            list = ["arxiv:1706.03762"]
        """

        # default: lenient, warn, keep first
        open(job_path, "w") do io
            ;
            write(io, content);
        end
        job = @test_logs (:warn, r"same DOI has appeared") load_job(job_path)
        @test length(job.refs) == 1
        @test job.refs[1].group == "a"
        @test length(job.duplicates) == 1
        @test job.duplicates[1] == ("arxiv:1706.03762", "a", "b")

        # strict mode: error
        open(job_path, "w") do io
            write(io, content)
            write(io, "\n[fetch]\nstrict_duplicates = true\n")
        end
        # actually we need strict_duplicates under [fetch], but the above writes
        # a second [fetch] table which TOML.parsefile will reject. Rewrite cleanly:
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"

          [fetch]
          email = "t@x"
          strict_duplicates = true

          [doi.a]
          list = ["arxiv:1706.03762"]

          [doi.b]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        @test_throws ArgumentError load_job(job_path)
    end
end

@testset "load_job: invalid ref" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"
          [doi]
          list = ["not-a-valid-ref"]
      """,
            )
        end
        @test_throws ArgumentError load_job(job_path)
    end
end

@testset "load_job: unknown source rejected" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [folder]
          target = "$(dir)/papers"

          [fetch]
          sources = ["unpaywall", "scihub"]

          [doi]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        @test_throws ArgumentError load_job(job_path)
    end
end

@testset "load_job: missing target" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
            write(
                io,
                """
          [doi]
          list = ["arxiv:1706.03762"]
      """,
            )
        end
        @test_throws ArgumentError load_job(job_path)
    end
end

@testset "load_job: log file defaults" begin
    mktempdir() do dir
        job_path = joinpath(dir, "bibliofetch.toml")
        open(job_path, "w") do io
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
        job = load_job(job_path)
        @test job.log_file == joinpath(job.target, BiblioFetch.METADATA_DIRNAME, "run.log")
    end
end
