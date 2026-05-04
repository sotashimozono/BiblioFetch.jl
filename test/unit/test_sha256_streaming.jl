using BiblioFetch, Test, SHA
@testset "_sha256_file matches SHA.sha256 for arbitrary contents" begin
    mktempdir() do d
        for size in (0, 100, 65536, 200_000)
            data = rand(UInt8, size)
            p = joinpath(d, "blob_$size.bin")
            write(p, data)
            expected = bytes2hex(SHA.sha256(data))
            @test BiblioFetch._sha256_file(p) == expected
        end
    end
end
