using BiblioFetch
using Test

@testset "config loading" begin
    mktempdir() do dir
        cfg_path = joinpath(dir, "config.toml")
        open(cfg_path, "w") do io
            write(
                io,
                """
          [defaults]
          email = "test@example.com"
          store_root = "$(dir)/store"

          [profiles.panza]
          proxy = "http://proxy.univ.example:8080"

          [profiles.remote]
          proxy = "http://localhost:18080"
      """,
            )
        end

        cfg, path = BiblioFetch.load_config(; path=cfg_path)
        @test path == cfg_path
        @test haskey(cfg, "profiles")
        @test cfg["defaults"]["email"] == "test@example.com"
    end
end

@testset "mode classification" begin
    # no proxy → :oa_only
    @test BiblioFetch._classify_mode(nothing, :none, true) === :oa_only

    # proxy unreachable → :oa_only
    @test BiblioFetch._classify_mode("http://proxy.example:8080", :profile, false) ===
        :oa_only

    # localhost proxy reachable → :tunneled
    @test BiblioFetch._classify_mode("http://localhost:18080", :profile, true) === :tunneled
    @test BiblioFetch._classify_mode("http://127.0.0.1:18080", :env, true) === :tunneled

    # remote proxy reachable → :direct
    @test BiblioFetch._classify_mode("http://proxy.univ.example:8080", :profile, true) ===
        :direct
end

@testset "profile selection" begin
    cfg = Dict{String,Any}(
        "profiles" => Dict{String,Any}(
            "panza" => Dict("proxy" => "http://a:1"),
            "compute-a" => Dict("proxy" => "http://b:2"),
        ),
        "defaults" => Dict("email" => "x@y"),
    )
    name, body = BiblioFetch._pick_profile(cfg, "panza")
    @test name == "panza"
    @test body["proxy"] == "http://a:1"

    # prefix match: "panza.lan" → profile "panza"
    name2, body2 = BiblioFetch._pick_profile(cfg, "panza.lan")
    @test name2 == "panza"

    # no match → "default" profile returned from defaults
    name3, body3 = BiblioFetch._pick_profile(cfg, "other-host")
    @test name3 == "default"
    @test body3["email"] == "x@y"
end

@testset "env detection (no probe)" begin
    mktempdir() do dir
        cfg_path = joinpath(dir, "config.toml")
        open(cfg_path, "w") do io
            write(
                io,
                """
          [defaults]
          email      = "test@example.com"
          store_root = "$(dir)/store"
      """,
            )
        end
        withenv(
            "BIBLIOFETCH_CONFIG" => cfg_path,
            "HTTP_PROXY" => nothing,
            "HTTPS_PROXY" => nothing,
            "http_proxy" => nothing,
            "https_proxy" => nothing,
        ) do
            rt = detect_environment(; probe=false)
            @test rt.proxy === nothing
            @test rt.proxy_source === :none
            @test rt.email == "test@example.com"
            @test rt.store_root == joinpath(dir, "store")
            @test rt.reachable === missing
        end
    end
end
