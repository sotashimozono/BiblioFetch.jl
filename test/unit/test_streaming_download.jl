using BiblioFetch
using HTTP
using Sockets
using Test

# Local copy of the mock harness from test_http_mocks.jl. Kept here so this
# file is runnable standalone without depending on test_http_mocks.jl already
# having been loaded.
function _free_port_streaming()
    for _ in 1:50
        port = rand(40000:60000)
        try
            sock = Sockets.listen(ip"127.0.0.1", port)
            close(sock)
            return port
        catch
            continue
        end
    end
    return error("could not find a free loopback port")
end

function _with_mock_streaming(fn, handler)
    port = _free_port_streaming()
    server = HTTP.serve!(handler, "127.0.0.1", port)
    try
        fn("http://127.0.0.1:$(port)")
    finally
        close(server)
        try
            wait(server)
        catch
        end
    end
end

# A synthetic PDF: %PDF magic + filler + %%EOF marker. The size is 100KB so
# we can sanity-check that the streamed-to-disk file matches what the server
# pushed (i.e. nothing got buffered+truncated).
function _synthetic_pdf(payload_size::Int=100 * 1024)
    head = b"%PDF-1.4\n"
    tail = b"\n%%EOF\n"
    pad = rand(UInt8, max(0, payload_size - length(head) - length(tail)))
    return vcat(head, pad, tail)
end

@testset "streaming download: ok=true and full file size on disk" begin
    body = _synthetic_pdf(100 * 1024)
    handler = function (_req::HTTP.Request)
        return HTTP.Response(200, ["Content-Type" => "application/pdf"], body)
    end
    _with_mock_streaming(handler) do base
        mktempdir() do dir
            dest = joinpath(dir, "out.pdf")
            r = BiblioFetch._http_download_pdf(
                base * "/p.pdf", dest; base_delay=0.01, sleep_fn=(_)->nothing, timeout=5
            )
            @test r.ok
            @test r.http_status == 200
            @test r.retry_count == 0
            @test isempty(r.retried_statuses)
            @test isfile(dest)
            @test filesize(dest) == length(body)
            # Content matches byte-for-byte: streaming must not corrupt the
            # body (no premature flush, no double-write).
            @test read(dest) == body
        end
    end
end

@testset "streaming download: 503 then 200 retries and succeeds" begin
    body = _synthetic_pdf(8 * 1024)
    calls = Ref(0)
    handler = function (_req::HTTP.Request)
        calls[] += 1
        if calls[] == 1
            return HTTP.Response(503, [], "warming up")
        end
        return HTTP.Response(200, ["Content-Type" => "application/pdf"], body)
    end
    _with_mock_streaming(handler) do base
        mktempdir() do dir
            dest = joinpath(dir, "out.pdf")
            r = BiblioFetch._http_download_pdf(
                base * "/p.pdf", dest; base_delay=0.01, sleep_fn=(_)->nothing, timeout=5
            )
            @test r.ok
            @test r.http_status == 200
            @test r.retry_count == 1
            @test r.retried_statuses == [503]
            @test filesize(dest) == length(body)
        end
    end
end

@testset "streaming download: HTML body returns ok=false with 'not a PDF'" begin
    # Realistic landing-page case: server returns 200 + text/html, no %PDF
    # magic. _looks_like_pdf must reject after the streamed write completes.
    html = "<!doctype html><html><body>landing page</body></html>"
    # Pad to exceed the 1024-byte _looks_like_pdf size floor.
    html = html * repeat(" ", 2048)
    handler = function (_req::HTTP.Request)
        return HTTP.Response(200, ["Content-Type" => "text/html"], html)
    end
    _with_mock_streaming(handler) do base
        mktempdir() do dir
            dest = joinpath(dir, "out.pdf")
            r = BiblioFetch._http_download_pdf(
                base * "/p.pdf", dest; base_delay=0.01, sleep_fn=(_)->nothing, timeout=5
            )
            @test !r.ok
            @test r.http_status == 200
            @test r.error == "not a PDF (got HTML/landing)"
            # Temp file (and dest) should both be cleaned up on rejection.
            @test !isfile(dest)
            @test !isfile(dest * ".part")
        end
    end
end
