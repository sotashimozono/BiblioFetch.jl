# ---------- DataCite ----------
#
# DataCite registers DOIs for research data (Zenodo, Figshare, institutional
# repositories, simulation output). Crossref and DataCite don't overlap —
# each DOI has exactly one registration agency — so we use DataCite as a
# fallback only when Crossref returned nothing.

# Translate a DataCite `attributes` object into a Crossref-shaped metadata
# dict, so fetch_paper!'s existing extraction code works unchanged.
#
# DataCite's JSON:API shape:
#   { "data": { "attributes": {
#       "titles":          [{"title": "..."}],
#       "creators":        [{"givenName": "...", "familyName": "..."}, ...],
#       "publisher":       "Zenodo",
#       "publicationYear": 2024,
#       "types":           {"resourceTypeGeneral": "Dataset"},
#       "url":             "https://zenodo.org/record/..."
#   }}}
function _datacite_to_crossref_shape(attr::AbstractDict)
    titles = String[]
    for t in get(attr, "titles", [])
        s = strip(String(get(t, "title", "")))
        isempty(s) || push!(titles, s)
    end

    authors = Dict{String,Any}[]
    for c in get(attr, "creators", [])
        given = String(get(c, "givenName", ""))
        family = String(get(c, "familyName", ""))
        # Some DataCite records only have `name` ("Last, First" or unstructured).
        if isempty(given) && isempty(family)
            name = String(get(c, "name", ""))
            if occursin(",", name)
                parts = split(name, ','; limit=2)
                family = strip(parts[1])
                given = length(parts) > 1 ? strip(parts[2]) : ""
            else
                family = strip(name)
            end
        end
        isempty(family) && isempty(given) && continue
        push!(authors, Dict{String,Any}("given" => given, "family" => family))
    end

    publisher = String(get(attr, "publisher", ""))
    container_title = isempty(publisher) ? String[] : [publisher]

    year_val = get(attr, "publicationYear", nothing)
    year_int = if year_val isa Integer
        Int(year_val)
    elseif year_val isa AbstractString
        tryparse(Int, String(year_val))
    else
        nothing
    end
    issued = Dict{String,Any}("date-parts" => [Any[year_int]])

    out = Dict{String,Any}(
        "title" => titles,
        "author" => authors,
        "container-title" => container_title,
        "issued" => issued,
    )
    # Carry the resource type forward — useful to display `@misc{…, type=dataset}`
    # in future BibTeX work. Not used by fetch_paper! today.
    rtype = get(get(attr, "types", Dict{String,Any}()), "resourceTypeGeneral", nothing)
    rtype === nothing || (out["datacite-resource-type"] = String(rtype))
    url = String(get(attr, "url", ""))
    isempty(url) || (out["datacite-url"] = url)
    return out
end

"""
    datacite_lookup(doi; proxy = nothing, timeout = 15, base_url = DATACITE_URL,
                    max_retries, base_delay) -> Dict

Fetch DataCite metadata for a DOI and return it in Crossref's metadata shape
(so it slots straight into the existing `fetch_paper!` extraction). Returns
an empty `Dict` on any failure.

Used as a fallback after Crossref returns nothing — covers dataset DOIs
registered through Zenodo, Figshare, institutional DataCite clients, etc.
"""
function datacite_lookup(
    doi::AbstractString;
    proxy=nothing,
    timeout=15,
    base_url=DATACITE_URL,
    max_retries::Int=DEFAULT_MAX_RETRIES,
    base_delay::Real=DEFAULT_BASE_DELAY,
    sleep_fn=Base.sleep,
)
    url = base_url * URIs.escapeuri(doi)
    resp, _ = _http_get_with_retry(
        url;
        proxy=proxy,
        request_kwargs=(;
            headers=["User-Agent" => USER_AGENT, "Accept" => "application/vnd.api+json"],
            connect_timeout=timeout,
            readtimeout=timeout,
        ),
        max_retries=max_retries,
        base_delay=base_delay,
        sleep_fn=sleep_fn,
    )
    (resp === nothing || resp.status != 200) && return Dict{String,Any}()
    try
        obj = _to_plain(JSON3.read(resp.body))
        data = get(obj, "data", Dict{String,Any}())
        attr = get(data, "attributes", Dict{String,Any}())
        isempty(attr) && return Dict{String,Any}()
        return _datacite_to_crossref_shape(attr)
    catch e
        @debug "datacite_lookup: JSON parse failed" doi exception=e
        return Dict{String,Any}()
    end
end
