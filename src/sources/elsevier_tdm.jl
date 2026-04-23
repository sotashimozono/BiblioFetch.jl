# ---------- Elsevier TDM (ScienceDirect Article Retrieval) ----------
#
# Elsevier's article retrieval API at api.elsevier.com returns PDFs for DOIs
# under the 10.1016 prefix (ScienceDirect journals, Cell Press, The Lancet,
# etc.). Access is gated by an API key (free from https://dev.elsevier.com/)
# and either:
#   - the caller's IP being inside a subscribing institution's range, or
#   - an additional `X-ELS-Insttoken` header issued to the researcher
#
# Same shape as the APS TDM source (PR #18): a URL builder + an auth-header
# pair, wired into fetch.jl's per-source header plumbing. Opt-in via
# `[fetch].sources = [..., "elsevier"]` in a job TOML.

"""
    is_elsevier_doi(doi) -> Bool

Whether `doi` is published by Elsevier. `10.1016/*` covers ScienceDirect,
Cell Press, The Lancet, and the vast majority of Elsevier content.
"""
is_elsevier_doi(doi::AbstractString) = startswith(lowercase(strip(doi)), "10.1016/")

"""
    elsevier_tdm_url(doi; base_url = ELSEVIER_TDM_URL) -> String

Build the api.elsevier.com URL that returns the article PDF when combined
with `Accept: application/pdf` and the API-key headers from
[`elsevier_tdm_auth_headers`](@ref).
"""
function elsevier_tdm_url(
    doi::AbstractString; base_url::AbstractString=ELSEVIER_TDM_URL
)
    # DOI slashes are part of the path; escape only characters that don't
    # belong in a URL.
    safe_doi = replace(String(doi), r"[^A-Za-z0-9./%_\-]" => s -> URIs.escapeuri(s))
    return string(base_url, safe_doi)
end

# API key lookup: explicit kwarg wins, then $ELSEVIER_API_KEY.
function _elsevier_api_key(api_key)
    api_key === nothing || return String(api_key)
    v = get(ENV, "ELSEVIER_API_KEY", nothing)
    return v === nothing || isempty(v) ? nothing : String(v)
end

# Institutional token lookup: explicit kwarg wins, then $ELSEVIER_INSTTOKEN.
# Optional — only needed when the request's source IP isn't inside a
# subscribing institution's range.
function _elsevier_insttoken(insttoken)
    insttoken === nothing || return String(insttoken)
    v = get(ENV, "ELSEVIER_INSTTOKEN", nothing)
    return v === nothing || isempty(v) ? nothing : String(v)
end

"""
    elsevier_tdm_auth_headers(; api_key = ENV["ELSEVIER_API_KEY"],
                             insttoken = ENV["ELSEVIER_INSTTOKEN"])
        -> Vector{Pair{String,String}}

Build the header set for an Elsevier TDM request: `X-ELS-APIKey` always
(when a key is configured), plus `X-ELS-Insttoken` when a token is set
too. Returns an empty `Vector` when no key is configured — the fetch
pipeline uses that to skip `:elsevier` entirely, matching the APS TDM
pattern (don't spray requests that will 401 anyway).
"""
function elsevier_tdm_auth_headers(; api_key=nothing, insttoken=nothing)
    key = _elsevier_api_key(api_key)
    key === nothing && return Pair{String,String}[]
    out = Pair{String,String}["X-ELS-APIKey" => key]
    tok = _elsevier_insttoken(insttoken)
    tok === nothing || push!(out, "X-ELS-Insttoken" => tok)
    return out
end
