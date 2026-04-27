# ---------- Project-skeleton generator ----------
#
# `BiblioFetch.generate(path)` materialises a new project directory from
# the `config/template/` shipped alongside the package. The template is the
# source of truth for what a minimal BiblioFetch project looks like —
# keep content there, not here — so changes to the skeleton land by
# editing `config/template/` rather than modifying this function.

"""
    generate(path; force = false) -> String

Create a BiblioFetch project skeleton under `path`. Copies every file
in the package's `config/template/` directory (job.toml + README.md at
present) into `path`, creating intermediate directories as needed.

  * `path` — absolute or `~`-prefixed; expanded before use. If it's
    relative, it's resolved against `pwd()`.
  * `force` — when `false` (default) and `path` already exists and is
    non-empty, `generate` refuses with an `ArgumentError`. `true`
    overwrites any clashing file unconditionally.

Returns the absolute path of the created project, ready to pass to
`bibliofetch run <path>/job.toml` (with relative-target resolution
— see `load_job`).
"""
function generate(path::AbstractString; force::Bool=false)
    dest = abspath(expanduser(String(path)))
    if isdir(dest) && !force && !isempty(readdir(dest))
        throw(
            ArgumentError(
                "refusing to populate non-empty directory $(dest); pass force = true to overwrite",
            ),
        )
    end
    mkpath(dest)

    src = joinpath(pkgdir(BiblioFetch), "config", "template")
    isdir(src) || throw(
        ErrorException(
            "config/template directory missing from package install: $(src) — file a bug"
        ),
    )

    # Walk the template tree with a BFS so output listing reads top-down.
    for walk_entry in walkdir(src)
        root = walk_entry[1]
        files = walk_entry[3]
        rel = relpath(root, src)
        target_root = rel == "." ? dest : joinpath(dest, rel)
        mkpath(target_root)
        for f in sort(files)
            source = joinpath(root, f)
            target = joinpath(target_root, f)
            if isfile(target) && !force
                throw(
                    ArgumentError(
                        "file already exists: $(target); pass force = true to overwrite"
                    ),
                )
            end
            cp(source, target; force=true)
        end
    end
    return dest
end
