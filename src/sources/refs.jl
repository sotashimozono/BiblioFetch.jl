# ---------- reference-string classification and URL construction ----------
#
# Pure helpers: no network, no state. Used by both `core/` (fetch logic needs
# `is_doi` to decide which adapter to call) and `io/bibtex.jl` (citekey
# construction also looks at the reference shape).

const _DOI_RE = r"^10\.\d{4,9}/\S+$"i
const _ARXIV_RE = r"^(arxiv:)?(\d{4}\.\d{4,5}(v\d+)?|[a-z\-]+(\.[A-Z]{2})?/\d{7}(v\d+)?)$"i
# Multi-version-spec pseudo-ref: `arxiv:<id>@all` or `arxiv:<id>@v1,v3` /
# `arxiv:<id>@1,3`. The base id must not carry a version suffix — the @-spec
# is the version selector.
const _ARXIV_VSPEC_RE = r"^(arxiv:)?(\d{4}\.\d{4,5}|[a-z\-]+(\.[A-Z]{2})?/\d{7})@(all|v?\d+(,v?\d+)*)$"i

"""
    is_doi(s) -> Bool

Whether `s` looks like a DOI (`10.xxxx/anything`). Strips surrounding whitespace
but does not otherwise transform the input.
"""
is_doi(s::AbstractString) = occursin(_DOI_RE, strip(s))

"""
    is_arxiv(s) -> Bool

Whether `s` looks like an arXiv id — both the new-style (`1706.03762`,
optionally with a version suffix `v2` and an `arxiv:` prefix) and the legacy
slash form (`cond-mat/0608208`).
"""
is_arxiv(s::AbstractString) = occursin(_ARXIV_RE, strip(s))

"""
    is_arxiv_versions(s) -> Bool

Whether `s` is the multi-version pseudo-ref form `arxiv:<id>@all` or
`arxiv:<id>@v1,v3` / `arxiv:<id>@1,3`. These refs can't be fetched as-is —
the run loop expands them into one `FetchEntry` per version before
dispatching to `fetch_paper!`.
"""
is_arxiv_versions(s::AbstractString) = occursin(_ARXIV_VSPEC_RE, strip(s))

"""
    parse_arxiv_version_spec(s) -> (base_key, spec)

Parse an `arxiv:<id>@…` pseudo-ref into its components.

  * `base_key` — the canonical `arxiv:<id>` key (lower-cased, no version
    suffix, with `arxiv:` prefix).
  * `spec`     — either `:all` (every known version) or a sorted
    `Vector{Int}` of explicit version numbers.

Throws `ArgumentError` when `s` is not a well-formed pseudo-ref.
"""
function parse_arxiv_version_spec(s::AbstractString)
    t = strip(s)
    is_arxiv_versions(t) ||
        throw(ArgumentError("not an arxiv version-spec ref: $(s)"))
    # Split on the *last* '@' so a legacy slash-id doesn't confuse us.
    at = findlast('@', t)
    head = String(t[1:(at - 1)])
    tail = String(t[(at + 1):end])
    # Normalize the head through normalize_key so `arxiv:` prefix + lowercase
    # is applied identically to single-version refs.
    base_key = normalize_key(head)
    spec = if lowercase(tail) == "all"
        :all
    else
        parts = split(tail, ',')
        nums = Int[]
        for p in parts
            p = strip(p)
            p = startswith(lowercase(p), "v") ? p[2:end] : p
            n = tryparse(Int, p)
            (n === nothing || n < 1) &&
                throw(ArgumentError("invalid version '$(p)' in '$(s)'"))
            push!(nums, n)
        end
        sort!(unique!(nums))
    end
    return (base_key, spec)
end

"""
    normalize_key(s) -> String

Normalize a user-provided reference to a canonical key:
  * DOI  → lowercase DOI (`10.1103/physrevb.xx.yyyy`)
  * arXiv → `arxiv:<id>`
Throws `ArgumentError` if unrecognized.
"""
function normalize_key(s::AbstractString)
    t = strip(s)
    # strip common URL prefixes
    for pre in (
        "https://doi.org/",
        "http://doi.org/",
        "doi:",
        "DOI:",
        "https://arxiv.org/abs/",
        "http://arxiv.org/abs/",
        "https://arxiv.org/pdf/",
    )
        if startswith(t, pre)
            t = t[(length(pre) + 1):end]
            break
        end
    end
    t = rstrip(t, ['/'])
    if is_arxiv_versions(t)
        # arxiv:<id>@all / @v1,v3 — preserve the suffix so the run loop can
        # expand it into per-version entries. We only lowercase the id part;
        # the `@all` / `@vN` suffix is canonicalized via _reassemble below.
        at = findlast('@', t)
        head = String(t[1:(at - 1)])
        tail = lowercase(String(t[(at + 1):end]))
        id = startswith(lowercase(head), "arxiv:") ? head[7:end] : head
        return "arxiv:" * lowercase(id) * "@" * tail
    elseif is_arxiv(t)
        id = startswith(lowercase(t), "arxiv:") ? t[7:end] : t
        return "arxiv:" * lowercase(id)
    elseif is_doi(t)
        return lowercase(t)
    else
        throw(ArgumentError("Unrecognized reference: $(s)"))
    end
end

# Reference → URL helpers. Trivial but grouped here so callers don't have to
# know which provider owns the URL scheme.
arxiv_pdf_url(id::AbstractString) = "https://arxiv.org/pdf/" * id * ".pdf"
doi_landing_url(doi::AbstractString) = "https://doi.org/" * doi
