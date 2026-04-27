"""
    build(; destdir, bindir, force) -> String

Compile BiblioFetch into a standalone native app using PackageCompiler.jl,
then symlink (or copy) the resulting `bibliofetch` binary into `bindir`.

After a successful build, `bibliofetch` starts in under a second.

# Arguments
- `destdir`: where the compiled app bundle is written.
  Default: `~/.local/share/bibliofetch-app`
- `bindir`: where to install the `bibliofetch` symlink.
  Default: `~/.local/bin` (already on PATH for most Linux / macOS setups)
- `force`: pass `true` to overwrite an existing build. Default: `false`

# Example
```julia
using BiblioFetch
BiblioFetch.build()          # first-time setup, takes ~3–5 min
BiblioFetch.build(force=true) # rebuild after updating the package
```
"""
function build(;
    destdir::AbstractString=joinpath(homedir(), ".local", "share", "bibliofetch-app"),
    bindir::AbstractString=joinpath(homedir(), ".local", "bin"),
    force::Bool=false,
)
    # --- require PackageCompiler -------------------------------------------
    try
        @eval Main using PackageCompiler
    catch
        error("""
PackageCompiler.jl is not installed. Install it first:

    using Pkg; Pkg.add("PackageCompiler")

then retry:

    BiblioFetch.build()
""")
    end

    destdir = expanduser(string(destdir))
    bindir = expanduser(string(bindir))

    if isdir(destdir) && !force
        error("""
Build directory already exists: $destdir

Pass `force=true` to overwrite:
    BiblioFetch.build(force=true)
""")
    end

    pkg_dir = pkgdir(BiblioFetch)
    precompile_file = joinpath(pkg_dir, "src", "precompile_workload.jl")

    println("BiblioFetch.build()")
    println("  package  : ", pkg_dir)
    println("  destdir  : ", destdir)
    println("  bindir   : ", bindir)
    println("  precompile: ", isfile(precompile_file) ? precompile_file : "(none)")
    println()
    println("Compiling … this takes 3–5 minutes on first run.")
    flush(stdout)

    t0 = time()
    kw = if isfile(precompile_file)
        (; precompile_execution_file=precompile_file, force=force)
    else
        (; force=force)
    end
    @eval Main PackageCompiler.create_app($pkg_dir, $destdir; $kw...)
    elapsed = round(time() - t0; digits=1)
    println("\nCompilation done in $(elapsed)s.")

    # --- install symlink / copy -------------------------------------------
    app_bin = if Sys.iswindows()
        joinpath(destdir, "bin", "bibliofetch.exe")
    else
        joinpath(destdir, "bin", "bibliofetch")
    end

    isfile(app_bin) || error("Expected binary not found at: $app_bin")

    mkpath(bindir)
    link = joinpath(bindir, Sys.iswindows() ? "bibliofetch.exe" : "bibliofetch")

    if islink(link) || isfile(link)
        rm(link)
    end

    if Sys.iswindows()
        cp(app_bin, link)
    else
        symlink(app_bin, link)
    end
    println("Installed: ", link, " → ", app_bin)

    # --- PATH hint -----------------------------------------------------------
    path_dirs = split(get(ENV, "PATH", ""), Sys.iswindows() ? ';' : ':')
    if bindir ∉ path_dirs
        shell_rc = _guess_shell_rc()
        println()
        println("⚠  $bindir is not on your PATH.")
        println("   Add this line to $(shell_rc):")
        println()
        println("       export PATH=\"$bindir:\$PATH\"")
        println()
        println("   Then reload your shell:  source $(shell_rc)")
    else
        println()
        println("All done!  Try it:")
        println("    bibliofetch --help")
    end

    return link
end

function _guess_shell_rc()
    shell = basename(get(ENV, "SHELL", ""))
    if shell == "zsh"
        return "~/.zshrc"
    elseif shell == "fish"
        return "~/.config/fish/config.fish"
    else
        return "~/.bashrc"
    end
end
