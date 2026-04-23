# ---------- APS TDM (Harvest) ----------
#
# APS runs a text-and-data-mining API at harvest.aps.org that returns PDFs
# directly for DOIs published by APS (PRL / PRB / PRX / PRResearch / RMP /
# PRA / PRD / PRE / …), authenticated with a Bearer token. The token is
# free to academic users by request from the APS ombudsman. See:
#
#   https://harvest.aps.org/docs
#
# Unlike Unpaywall / arXiv / direct, this is an *entitled* route — if you
# have a token, you get the publisher PDF for every APS paper you're
# subscribed to, even when no OA alternative exists. That's what makes it
# worth wiring up as a dedicated source: it's the canonical route for the
# physics use case, and it's complementary to Unpaywall (Unpaywall gives
# the publisher URL when gold-OA, but not most paywalled APS papers).

# APS DOIs live under the 10.1103 prefix. Checking before dispatching to
# APS avoids spraying harvest.aps.org with DOIs that definitely won't
# resolve (and avoids burning quota).
is_aps_doi(doi::AbstractString) = startswith(lowercase(strip(doi)), "10.1103/")

"""
    aps_tdm_url(doi; base_url = APS_TDM_URL) -> String

Build the harvest.aps.org URL that returns a PDF for the given APS DOI.
Does no validation beyond the 10.1103 prefix check in [`is_aps_doi`](@ref).
"""
function aps_tdm_url(doi::AbstractString; base_url::AbstractString=APS_TDM_URL)
    # The DOI slashes are part of the URL path for harvest.aps.org; don't
    # percent-encode them. Spaces and other non-URL chars shouldn't appear in
    # DOIs, but escape them just in case.
    safe_doi = replace(String(doi), r"[^A-Za-z0-9./%_\-]" => s -> URIs.escapeuri(s))
    return string(base_url, safe_doi, "?set=simple&fmt=pdf")
end

# Pick the API token — explicit kwarg wins; otherwise $APS_API_KEY.
function _aps_api_key(api_key)
    api_key === nothing || return String(api_key)
    v = get(ENV, "APS_API_KEY", nothing)
    return v === nothing || isempty(v) ? nothing : String(v)
end

"""
    aps_tdm_auth_header(; api_key = ENV["APS_API_KEY"]) -> Union{Pair,Nothing}

Return an `Authorization => "Bearer <token>"` header pair to attach to an
APS TDM request, or `nothing` when no key is configured (in which case the
fetch pipeline should skip `:aps` for that DOI — hitting APS without a
token produces 401s).
"""
function aps_tdm_auth_header(; api_key=nothing)
    key = _aps_api_key(api_key)
    key === nothing && return nothing
    return "Authorization" => "Bearer $(key)"
end
