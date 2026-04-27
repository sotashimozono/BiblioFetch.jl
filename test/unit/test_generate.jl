using BiblioFetch
using Test

# Files the generator is required to drop into a fresh project. Kept
# explicit so a future template addition is a one-line update here — and
# a missing template file becomes a failing test rather than silent drift.
const _EXPECTED_SKELETON_FILES = ("job.toml", "README.md")

@testset "generate: creates a new directory + expected files" begin
    mktempdir() do parent
        dest = joinpath(parent, "new-project")
        @test !isdir(dest)
        returned = BiblioFetch.generate(dest)
        @test returned == abspath(dest)
        @test isdir(dest)
        for f in _EXPECTED_SKELETON_FILES
            @test isfile(joinpath(dest, f))
        end
    end
end

@testset "generate: populates an existing empty directory" begin
    mktempdir() do dest
        # mktempdir creates `dest`; it's empty. Generator should accept that.
        returned = BiblioFetch.generate(dest)
        @test returned == abspath(dest)
        for f in _EXPECTED_SKELETON_FILES
            @test isfile(joinpath(dest, f))
        end
    end
end

@testset "generate: refuses to populate a non-empty directory without force" begin
    mktempdir() do dest
        open(joinpath(dest, "unrelated.txt"), "w") do io
            write(io, "preexisting file")
        end
        @test_throws ArgumentError BiblioFetch.generate(dest)
        # The preexisting file must stay untouched even after the refusal.
        @test isfile(joinpath(dest, "unrelated.txt"))
        # None of the template files should have been written either.
        for f in _EXPECTED_SKELETON_FILES
            @test !isfile(joinpath(dest, f))
        end
    end
end

@testset "generate: force=true overwrites existing files" begin
    mktempdir() do dest
        # Pre-seed a job.toml with junk — generate(force=true) must clobber it.
        open(joinpath(dest, "job.toml"), "w") do io
            write(io, "# junk content from a prior attempt\n")
        end
        BiblioFetch.generate(dest; force=true)
        content = read(joinpath(dest, "job.toml"), String)
        @test !occursin("junk content", content)
        # The real template includes a `[folder].target` key — assert that
        # to prove the overwrite landed the actual template file rather than
        # leaving the junk in place.
        @test occursin("[folder]", content)
        @test occursin("target", content)
    end
end

@testset "generate: output byte-for-byte matches config/template/" begin
    tmpl_dir = joinpath(pkgdir(BiblioFetch), "config", "template")
    mktempdir() do dest
        BiblioFetch.generate(dest)
        for f in _EXPECTED_SKELETON_FILES
            src_path = joinpath(tmpl_dir, f)
            dst_path = joinpath(dest, f)
            @test isfile(src_path)
            @test isfile(dst_path)
            @test read(src_path) == read(dst_path)
        end
    end
end

@testset "generate: the produced job.toml loads via load_job" begin
    # The generated skeleton should be a valid starting point — even
    # with an empty [doi].list, load_job must accept it so new users
    # don't hit parse errors before adding their first ref.
    mktempdir() do dest
        BiblioFetch.generate(dest)
        job_path = joinpath(dest, "job.toml")
        job = load_job(job_path)
        @test job.refs == BiblioFetch.FetchEntry[]
        # Template declares a relative target, which must resolve
        # against the generated directory per the #35 fix.
        @test startswith(job.target, abspath(dest))
    end
end

@testset "generate: ~-prefixed path is expanded" begin
    # Redirect $HOME so a ~-prefixed path resolves under a tempdir.
    mktempdir() do fake_home
        withenv("HOME" => fake_home) do
            dest = BiblioFetch.generate("~/bf-test-skeleton")
            @test dest == abspath(joinpath(fake_home, "bf-test-skeleton"))
            @test isfile(joinpath(dest, "job.toml"))
        end
    end
end
