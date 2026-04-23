using BiblioFetch
using Dates
using Test

@testset "_humanize_bytes" begin
    @test BiblioFetch._humanize_bytes(0) == "0 B"
    @test BiblioFetch._humanize_bytes(512) == "512 B"
    @test BiblioFetch._humanize_bytes(1024) == "1.0 KB"
    @test BiblioFetch._humanize_bytes(1536) == "1.5 KB"
    @test BiblioFetch._humanize_bytes(2 * 1024^2) == "2.0 MB"
    @test BiblioFetch._humanize_bytes(3 * 1024^3) == "3.0 GB"
end

@testset "_humanize_age" begin
    # Use a fixed "now" so the test is deterministic.
    now = DateTime(2026, 4, 23, 12, 0, 0)

    @test BiblioFetch._humanize_age(string(now - Second(3)); now_dt=now) == "just now"
    @test BiblioFetch._humanize_age(string(now - Second(30)); now_dt=now) == "30s ago"
    @test BiblioFetch._humanize_age(string(now - Minute(5)); now_dt=now) == "5m ago"
    @test BiblioFetch._humanize_age(string(now - Hour(3)); now_dt=now) == "3.0h ago"
    @test BiblioFetch._humanize_age(string(now - Day(2)); now_dt=now) == "2.0d ago"

    # Invalid / empty string → "" (no exception)
    @test BiblioFetch._humanize_age(""; now_dt=now) == ""
    @test BiblioFetch._humanize_age("not a date"; now_dt=now) == ""

    # Future timestamp (clock skew?) → explicit label, not panic
    @test BiblioFetch._humanize_age(string(now + Hour(1)); now_dt=now) == "in the future"
end

@testset "_truncate" begin
    @test BiblioFetch._truncate("short", 10) == "short"
    @test BiblioFetch._truncate("exactly10!", 10) == "exactly10!"
    @test BiblioFetch._truncate("this is longer than ten", 10) == "this is l…"
end

@testset "_format_info_entry: successful OA article" begin
    now = DateTime(2026, 4, 23, 12, 0, 0)
    md = Dict{String,Any}(
        "key" => "10.1103/physrevresearch.1.033027",
        "title" => "Excitation of a uniformly moving atom",
        "authors" => ["Anatoly A. Svidzinsky"],
        "journal" => "Physical Review Research",
        "year" => 2019,
        "is_oa" => true,
        "status" => "ok",
        "source" => "unpaywall",
        "group" => "condensed-matter",
        "pdf_path" => "/nonexistent/path.pdf",
        "fetched_at" => string(now - Hour(2)),
        "attempts" => [
            Dict(
                "source" => "unpaywall",
                "url" => "http://link.aps.org/pdf/10.1103/PhysRevResearch.1.033027",
                "ok" => true,
                "http_status" => 200,
                "duration_s" => 1.83,
            ),
        ],
    )
    s = BiblioFetch._format_info_entry(md; now_dt=now)

    @test startswith(s, "── 10.1103/physrevresearch.1.033027 ──\n")
    @test occursin(r"title\s+: Excitation of a uniformly moving atom", s)
    @test occursin(r"authors\s+: Anatoly A. Svidzinsky", s)
    @test occursin(r"journal\s+: Physical Review Research", s)
    @test occursin(r"year\s+: 2019", s)
    @test occursin(r"status\s+: ok", s)
    @test occursin(r"source\s+: unpaywall", s)
    @test occursin(r"group\s+: condensed-matter", s)
    @test occursin(r"is_oa\s+: true", s)
    @test occursin(r"citekey\s+: Svidzinsky2019", s)
    @test occursin("(missing!)", s)               # the seeded path doesn't exist
    @test occursin("2.0h ago", s)

    # attempts block present, with the unpaywall line and the trailing (200) and duration
    @test occursin("attempts:", s)
    @test occursin("✓ unpaywall", s)
    @test occursin("(200)", s)
    @test occursin("1.83s", s)
end

@testset "_format_info_entry: failed entry shows error + all attempts" begin
    now = DateTime(2026, 4, 23, 12, 0, 0)
    md = Dict{String,Any}(
        "key" => "10.1234/fake.doi",
        "status" => "failed",
        "error" => "no candidate PDF URL",
        "last_attempt_at" => string(now - Minute(5)),
        "attempts" => [
            Dict(
                "source" => "unpaywall",
                "url" => "https://api.unpaywall.org/v2/xxx",
                "ok" => false,
                "http_status" => 404,
                "duration_s" => 0.31,
                "error" => "not found in OA DB",
            ),
            Dict(
                "source" => "arxiv",
                "url" => "https://arxiv.org/pdf/yyy.pdf",
                "ok" => false,
                "http_status" => 404,
                "duration_s" => 0.52,
                "error" => "http status 404",
            ),
        ],
    )
    s = BiblioFetch._format_info_entry(md; now_dt=now)

    @test occursin(r"status\s+: failed", s)
    @test occursin(r"error\s+: no candidate PDF URL", s)
    @test occursin(r"last try\s+: ", s)
    @test occursin("5m ago", s)
    @test occursin("✗ unpaywall", s)
    @test occursin("✗ arxiv", s)
    @test occursin("not found in OA DB", s)      # per-attempt error preserved
    # Successful rows for fields we didn't supply should NOT appear.
    @test !occursin("title ", s)
    @test !occursin("journal ", s)
end

@testset "_format_info_entry: real PDF size reported" begin
    mktempdir() do dir
        p = joinpath(dir, "fake.pdf")
        open(p, "w") do io
            write(io, "%PDF-1.5\n")
            write(io, rand(UInt8, 1536))
        end
        md = Dict{String,Any}(
            "key" => "arxiv:9999.0001",
            "status" => "ok",
            "pdf_path" => p,
            "authors" => ["Demo"],
            "year" => 2025,
        )
        s = BiblioFetch._format_info_entry(md)
        # file is ~1.5 KB
        @test occursin("KB)", s)
        @test !occursin("missing!", s)
    end
end
