using BiblioFetch
using Documenter
using Downloads
using Literate

assets_dir = joinpath(@__DIR__, "src", "assets")
mkpath(assets_dir)
favicon_path = joinpath(assets_dir, "favicon.ico")
logo_path = joinpath(assets_dir, "logo.png")

Downloads.download("https://github.com/sotashimozono.png", favicon_path)
Downloads.download("https://github.com/sotashimozono.png", logo_path)

# Run Literate over every `examples/NN_*.jl` source. Output lands in
# `docs/src/examples/NN_*.md` and is regenerated on every build (the
# directory is git-ignored — see docs/.gitignore). Each `.jl` is authored
# in Literate's flavored-markdown style: `# …` comment lines become
# prose, code between is kept as a Julia block.
examples_src = joinpath(@__DIR__, "..", "examples")
examples_out = joinpath(@__DIR__, "src", "examples")
rm(examples_out; force=true, recursive=true)
mkpath(examples_out)
example_pages = Pair{String,String}[]
for entry in sort(readdir(examples_src))
    endswith(entry, ".jl") || continue
    startswith(entry, "_") && continue
    Literate.markdown(
        joinpath(examples_src, entry), examples_out; documenter=true, credit=false
    )
    base = splitext(entry)[1]
    title = titlecase(replace(replace(base, r"^[0-9]+_" => ""), "_" => " "))
    push!(example_pages, title => joinpath("examples", base * ".md"))
end
# Copy the sibling `.toml` job files next to the generated `.md`. Each
# Literate-authored example calls `load_job(joinpath(@__DIR__, "…toml"))`,
# and `@example` blocks in Documenter evaluate that against the built
# docs directory — the TOMLs need to live alongside the markdown there.
for entry in readdir(examples_src)
    endswith(entry, ".toml") || continue
    cp(joinpath(examples_src, entry), joinpath(examples_out, entry); force=true)
end

makedocs(;
    sitename="BiblioFetch.jl",
    format=Documenter.HTML(;
        canonical="https://codes.sota-shimozono.com/BiblioFetch.jl/stable/",
        prettyurls=get(ENV, "CI", "false") == "true",
        mathengine=MathJax3(
            Dict(
                :tex => Dict(
                    :inlineMath => [["\$", "\$"], ["\\(", "\\)"]],
                    :tags => "ams",
                    :packages => ["base", "ams", "autoload", "physics"],
                ),
            ),
        ),
        assets=["assets/favicon.ico", "assets/custom.css"],
    ),
    modules=[BiblioFetch],
    pages=[
        "Home" => "index.md",
        "Usage Guide" => "guide.md",
        "Examples" => example_pages,
        "API Reference" => "api.md",
    ],
    checkdocs=:exports,
)

deploydocs(; repo="github.com/sotashimozono/BiblioFetch.jl.git", devbranch="main")
