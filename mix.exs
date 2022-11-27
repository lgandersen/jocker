defmodule Jocker.MixProject do
  use Mix.Project

  def project do
    [
      app: :jocker,
      version: "0.0.1",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      releases: [
        jockerd: [include_executables_for: [:unix]]
      ],
      dialyzer: [
        # plt_ignore_apps: [:amnesia],
        ignore_warnings: "config/dialyzer.ignore",
        plt_add_deps: :apps_direct
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :eex, :cowboy, :plug],
      mod: {Jocker.Engine.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:esqlite, "0.4.1",
       override: true,
       system_env: [
         #   {"ESQLITE_USE_SYSTEM", "yes"},
         {"ESQLITE_CFLAGS",
          "$CFLAGS -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_JSON1 -DSQLITE_USE_URI -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS -I./c_src/sqlite3"}
       ]},
      {:sqlitex, "~> 1.7"},
      {:jason, "~> 1.2"},
      {:yaml_elixir, "~> 2.4"},
      {:cidr, "~> 1.1"},
      {:cowlib, "~> 2.11", override: true},
      {:plug, "~> 1.12"},
      {:plug_cowboy, "~> 2.5"},
      {:open_api_spex, "~> 3.10"},
      {:earmark, "~> 1.4.4", only: :dev},
      {:ex_doc, "~> 0.19", only: :dev},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:excoveralls, "~> 0.15.0", only: :test},
      {:gun, "~> 1.3", only: :test}
    ]
  end
end
