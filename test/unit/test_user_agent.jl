using BiblioFetch, Test
@testset "user_agent" begin
    # default: no email leak
    prev = get(ENV, "BIBLIOFETCH_CONTACT_EMAIL", nothing)
    delete!(ENV, "BIBLIOFETCH_CONTACT_EMAIL")
    try
        ua = BiblioFetch.user_agent()
        @test occursin("BiblioFetch/", ua)
        @test !occursin("souta.shimozono", ua)
        @test !occursin("@gmail", ua)
        # with env var
        ENV["BIBLIOFETCH_CONTACT_EMAIL"] = "test@example.com"
        ua2 = BiblioFetch.user_agent()
        @test occursin("mailto:test@example.com", ua2)
    finally
        if prev === nothing
            delete!(ENV, "BIBLIOFETCH_CONTACT_EMAIL")
        else
            (ENV["BIBLIOFETCH_CONTACT_EMAIL"] = prev)
        end
    end
end
