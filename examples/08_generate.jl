# # Creating a new project
#
# `BiblioFetch.generate(path)` drops a ready-to-edit project skeleton
# at `path` — the matching `template/` directory inside the package is
# the single source of truth for what that skeleton contains. It's the
# one-liner version of "copy the config, write a job.toml, remember
# what fields go where" — instead you run:
#
# ```sh
# bibliofetch init ~/my-bibliography
# ```
#
# or from Julia:
#
# ```julia
# julia> BiblioFetch.generate("~/my-bibliography")
# ```
#
# Either form produces:
#
# ```
# ~/my-bibliography/
#   job.toml       # edit the [doi].list, optionally tune [fetch] and [graph]
#   README.md      # 30-line per-project how-to
# ```
#
# After the skeleton is in place:
#
# ```sh
# bibliofetch run ~/my-bibliography/job.toml
# ```
#
# runs the job. Relative `[folder].target` values in the skeleton
# resolve against the project directory (see PR #37 / `load_job`), so
# the PDFs land right next to the `job.toml` regardless of the shell's
# cwd.
#
# ## Guard rails
#
# `generate` refuses to populate a non-empty directory unless
# `force=true`. That protects you from overwriting an in-progress
# project by typo, while still letting you re-seed a clean copy on top
# of old leftovers when you really mean it:
#
# ```julia
# BiblioFetch.generate("existing-dir"; force=true)
# ```
#
# Passing `--force` on the CLI does the same thing:
#
# ```sh
# bibliofetch init existing-dir --force
# ```
#
# ## Trying it from Julia
#
# The example below creates a throwaway project under a tempdir, just
# so the docs build has a self-contained runnable demonstration.

using BiblioFetch

mktempdir() do parent
    dest = joinpath(parent, "demo-bibliography")
    BiblioFetch.generate(dest)
    (isdir(dest), sort(readdir(dest)))
end

# ## Customising the skeleton
#
# The `template/` directory inside the installed package is read
# verbatim — no placeholder substitution happens, so what's on disk
# over there is exactly what the user gets. Extending the skeleton is
# a one-file PR: drop a new file into `template/`, optionally update
# `template/README.md` to mention it, and every subsequent
# `generate()` call picks it up. No code changes required.
#
# ## The onboarding loop end-to-end
#
# ```sh
# # 1. Copy the machine-wide config template (if you haven't already)
# cp "$(julia -e 'using BiblioFetch; print(pkgdir(BiblioFetch))')/config/config.toml" \
#    ~/.config/bibliofetch/config.toml
# # → edit email / store_root / any per-host [profiles.*]
#
# # 2. Create a per-project skeleton
# bibliofetch init ~/research/dmrg-bibliography
# cd ~/research/dmrg-bibliography
# # → edit job.toml: add DOIs / arxiv ids to [doi].list
#
# # 3. Run
# bibliofetch run job.toml
# ```
#
# That's the full onboarding story — three shell commands and two edit
# sessions from zero to a first PDF in hand.
