"""
    build(; sysimage_dir, bindir, force) -> String

Compile BiblioFetch into a sysimage using PackageCompiler.jl (`create_sysimage`
with `incremental=true`), then write a thin shell wrapper into `bindir`.

Using a sysimage (rather than `create_app`) avoids the isolated-build errors
that `create_app` triggers for packages with binary C extensions (HTTP →
MbedTLS). It also produces a much smaller artefact (~40 MB vs ~300 MB) because
the Julia runtime is not bundled — the system-installed `julia` is reused.

After a successful build, `bibliofetch` starts in under a second.

# Arguments
- `sysimage_dir`: directory where `sys.so` (Linux/macOS) or `sys.dll` (Windows)
  is written. Default: `~/.local/share/bibliofetch`
- `bindir`: where the `bibliofetch` wrapper script is installed.
  Default: `~/.local/bin`
- `force`: overwrite an existing sysimage. Default: `false`

# Example
```julia
using Pkg; Pkg.add("PackageCompiler")   # once
using BiblioFetch
BiblioFetch.build()                      # ~2–4 min, run once per Julia version
BiblioFetch.build(force=true)            # rebuild after Pkg.update()
```
"""
function build(;
    sysimage_dir::AbstractString=joinpath(homedir(), ".local", "share", "bibliofetch"),
    bindir::AbstractString=joinpath(homedir(), ".local", "bin"),
    force::Bool=false,
)
    # --- require PackageCompiler (soft dependency) -------------------------
    try
        @eval Main using PackageCompiler
    catch
        error("""
PackageCompiler.jl is not installed. Add it first:

    using Pkg; Pkg.add("PackageCompiler")

then retry:

    BiblioFetch.build()
""")
    end

    sysimage_dir = expanduser(string(sysimage_dir))
    bindir = expanduser(string(bindir))
    sysimage_ext = Sys.iswindows() ? "dll" : (Sys.isapple() ? "dylib" : "so")
    sysimage_path = joinpath(sysimage_dir, "sys." * sysimage_ext)

    if isfile(sysimage_path) && !force
        error("""
Sysimage already exists: $sysimage_path

Pass `force=true` to rebuild:
    BiblioFetch.build(force=true)
""")
    end

    pkg_dir = pkgdir(BiblioFetch)
    precompile_file = joinpath(pkg_dir, "src", "precompile_workload.jl")

    println("BiblioFetch.build()  [sysimage mode]")
    println("  package   : ", pkg_dir)
    println("  sysimage  : ", sysimage_path)
    println("  bindir    : ", bindir)
    println("  precompile: ", isfile(precompile_file) ? "yes" : "none")
    println()
    println("Compiling … this takes 2–4 minutes on first run.")
    flush(stdout)

    mkpath(sysimage_dir)

    t0 = time()
    # incremental=true (default) builds on top of the existing sysimage, so
    # binary-extension packages like MbedTLS/HTTP are already compiled and the
    # isolated-build failure that plagues create_app does not occur.
    if isfile(precompile_file)
        @eval Main PackageCompiler.create_sysimage(
            [:BiblioFetch];
            sysimage_path=($sysimage_path),
            project=($pkg_dir),
            precompile_execution_file=($precompile_file),
        )
    else
        @eval Main PackageCompiler.create_sysimage(
            [:BiblioFetch]; sysimage_path=($sysimage_path), project=($pkg_dir)
        )
    end
    elapsed = round(time() - t0; digits=1)
    println(
        "\nSysimage written in $(elapsed)s  ($(round(filesize(sysimage_path)/1024^2; digits=1)) MB).",
    )

    # --- write wrapper script ---------------------------------------------
    mkpath(bindir)
    julia_bin = joinpath(Sys.BINDIR, "julia")
    wrapper = _write_wrapper(bindir, julia_bin, sysimage_path)
    println("Wrapper  : ", wrapper)

    # --- PATH hint --------------------------------------------------------
    path_dirs = split(get(ENV, "PATH", ""), Sys.iswindows() ? ';' : ':')
    if bindir ∉ path_dirs
        rc = _guess_shell_rc()
        println()
        println("⚠  $bindir is not on your PATH.")
        println("   Add to $(rc):")
        println()
        println("       export PATH=\"$bindir:\$PATH\"")
        println()
        println("   Then: source $(rc)")
    else
        println()
        println("Done. Try it:")
        println("    bibliofetch --help")
    end

    return wrapper
end

"""
    clean(; sysimage_dir, bindir, verbose) -> Nothing

Remove the sysimage and wrapper script installed by [`build`](@ref).

Deletes:
- `sysimage_dir/sys.{so,dylib,dll}` — the compiled sysimage
- `bindir/bibliofetch` (or `bibliofetch.cmd` on Windows) — the wrapper script

The directories themselves are left in place. Silently skips files that do
not exist unless `verbose=true`.

# Example
```julia
using BiblioFetch
BiblioFetch.clean()                 # remove default installation
BiblioFetch.clean(verbose=true)     # print each file removed
```
"""
function clean(;
    sysimage_dir::AbstractString=joinpath(homedir(), ".local", "share", "bibliofetch"),
    bindir::AbstractString=joinpath(homedir(), ".local", "bin"),
    verbose::Bool=true,
    io::IO=stdout,
)
    sysimage_dir = expanduser(string(sysimage_dir))
    bindir = expanduser(string(bindir))
    sysimage_ext = Sys.iswindows() ? "dll" : (Sys.isapple() ? "dylib" : "so")

    removed = String[]

    sysimage_path = joinpath(sysimage_dir, "sys." * sysimage_ext)
    if isfile(sysimage_path)
        rm(sysimage_path)
        push!(removed, sysimage_path)
    end

    wrapper = joinpath(bindir, Sys.iswindows() ? "bibliofetch.cmd" : "bibliofetch")
    if isfile(wrapper)
        rm(wrapper)
        push!(removed, wrapper)
    end

    if verbose
        if isempty(removed)
            println(io, "Nothing to remove — no BiblioFetch build artefacts found.")
        else
            for f in removed
                println(io, "Removed: ", f)
            end
            println(io, "Done.")
        end
    end

    return nothing
end

function _guess_shell_rc()
    shell = basename(get(ENV, "SHELL", ""))
    shell == "zsh" && return "~/.zshrc"
    shell == "fish" && return "~/.config/fish/config.fish"
    return "~/.bashrc"
end

# Write the thin shell wrapper that invokes julia with the sysimage.
# Extracted so it can be tested without invoking PackageCompiler.
function _write_wrapper(bindir::AbstractString, julia_bin::AbstractString, sysimage_path::AbstractString)
    wrapper = joinpath(bindir, "bibliofetch")
    if Sys.iswindows()
        wrapper *= ".cmd"
        open(wrapper, "w") do io
            println(io, "@echo off")
            println(
                io,
                "\"$(julia_bin)\" --sysimage \"$(sysimage_path)\" --startup-file=no -e \"using BiblioFetch; exit(cli_main(ARGS))\" -- %*",
            )
        end
    else
        open(wrapper, "w") do io
            println(io, "#!/bin/sh")
            println(io, "exec \"$(julia_bin)\" --sysimage \"$(sysimage_path)\" \\")
            println(io, "     --startup-file=no \\")
            println(io, "     -e 'using BiblioFetch; exit(cli_main(ARGS))' -- \"\$@\"")
        end
        chmod(wrapper, 0o755)
    end
    return wrapper
end
