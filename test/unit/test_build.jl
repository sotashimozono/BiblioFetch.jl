using BiblioFetch
using Test

# ---------------------------------------------------------------------------
# _guess_shell_rc
# ---------------------------------------------------------------------------
@testset "_guess_shell_rc: recognises common shells" begin
    @test withenv("SHELL" => "/bin/zsh") do
        BiblioFetch._guess_shell_rc()
    end == "~/.zshrc"

    @test withenv("SHELL" => "/usr/bin/fish") do
        BiblioFetch._guess_shell_rc()
    end == "~/.config/fish/config.fish"

    @test withenv("SHELL" => "/bin/bash") do
        BiblioFetch._guess_shell_rc()
    end == "~/.bashrc"

    # unknown shell falls back to bashrc
    @test withenv("SHELL" => "/usr/local/bin/dash") do
        BiblioFetch._guess_shell_rc()
    end == "~/.bashrc"
end

# ---------------------------------------------------------------------------
# _write_wrapper (Unix only — Windows path tested via Sys.iswindows() guard)
# ---------------------------------------------------------------------------
@testset "_write_wrapper: writes executable shell script" begin
    Sys.iswindows() && return nothing   # wrapper format differs; skip on Windows CI

    mktempdir() do bindir
        julia_bin = "/usr/local/bin/julia"
        sysimage_path = "/home/user/.local/share/bibliofetch/sys.so"
        wrapper = BiblioFetch._write_wrapper(bindir, julia_bin, sysimage_path)

        @test isfile(wrapper)
        @test basename(wrapper) == "bibliofetch"
        # executable bit set
        @test (stat(wrapper).mode & 0o111) != 0

        txt = read(wrapper, String)
        @test startswith(txt, "#!/bin/sh")
        @test occursin(julia_bin, txt)
        @test occursin(sysimage_path, txt)
        @test occursin("--sysimage", txt)
        @test occursin("--startup-file=no", txt)
        @test occursin("cli_main", txt)
    end
end

# ---------------------------------------------------------------------------
# build(): guard — refuses to overwrite without force=true
# ---------------------------------------------------------------------------
@testset "build: errors when sysimage exists and force=false" begin
    mktempdir() do dir
        sysimage_ext = Sys.iswindows() ? "dll" : (Sys.isapple() ? "dylib" : "so")
        sysimage_path = joinpath(dir, "sys." * sysimage_ext)
        touch(sysimage_path)   # fake existing sysimage

        @test_throws ErrorException BiblioFetch.build(;
            sysimage_dir=dir, bindir=dir, force=false
        )
    end
end

# ---------------------------------------------------------------------------
# clean()
# ---------------------------------------------------------------------------
@testset "clean: removes sysimage and wrapper" begin
    mktempdir() do sysimage_dir
        mktempdir() do bindir
            sysimage_ext = Sys.iswindows() ? "dll" : (Sys.isapple() ? "dylib" : "so")
            sysimage_path = joinpath(sysimage_dir, "sys." * sysimage_ext)
            wrapper = joinpath(bindir, Sys.iswindows() ? "bibliofetch.cmd" : "bibliofetch")

            touch(sysimage_path)
            touch(wrapper)
            @test isfile(sysimage_path)
            @test isfile(wrapper)

            BiblioFetch.clean(; sysimage_dir, bindir, verbose=false)

            @test !isfile(sysimage_path)
            @test !isfile(wrapper)
        end
    end
end

@testset "clean: no-op when nothing is installed" begin
    mktempdir() do sysimage_dir
        mktempdir() do bindir
            # should not throw even when there is nothing to remove
            @test_nowarn BiblioFetch.clean(; sysimage_dir, bindir, verbose=false)
        end
    end
end

@testset "clean: verbose prints removed paths" begin
    mktempdir() do sysimage_dir
        mktempdir() do bindir
            sysimage_ext = Sys.iswindows() ? "dll" : (Sys.isapple() ? "dylib" : "so")
            sysimage_path = joinpath(sysimage_dir, "sys." * sysimage_ext)
            wrapper = joinpath(bindir, Sys.iswindows() ? "bibliofetch.cmd" : "bibliofetch")
            touch(sysimage_path)
            touch(wrapper)

            buf = IOBuffer()
            BiblioFetch.clean(; sysimage_dir, bindir, verbose=true, io=buf)
            out = String(take!(buf))
            @test occursin("Removed", out)
            @test occursin("sys.", out)
            @test occursin("bibliofetch", out)
        end
    end
end

@testset "clean: verbose prints nothing-to-remove when empty" begin
    mktempdir() do sysimage_dir
        mktempdir() do bindir
            buf = IOBuffer()
            BiblioFetch.clean(; sysimage_dir, bindir, verbose=true, io=buf)
            out = String(take!(buf))
            @test occursin("Nothing to remove", out)
        end
    end
end
