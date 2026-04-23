# ---------- reference-string classification and URL construction ----------
#
# Pure helpers: no network, no state. Used by both `core/` (fetch logic needs
# `is_doi` to decide which adapter to call) and `io/bibtex.jl` (citekey
# construction also looks at the reference shape).

const _DOI_RE = r"^10\.\d{4,9}/\S+$"i
const _ARXIV_RE = r"^(arxiv:)?(\d{4}\.\d{4,5}(v\d+)?|[a-z\-]+(\.[A-Z]{2})?/\d{7}(v\d+)?)$"i

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
    if is_arxiv(t)
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
