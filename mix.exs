# mix.exs — Project definition for the Skills-First AI Assistant.
#
# Elixir/Phoenix application. Webhooks-only (no HTML/browser).
# All schemas use binary_id (UUIDs). Backed by PostgreSQL.

defmodule Assistant.MixProject do
  use Mix.Project

  def project do
    [
      app: :assistant,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      mod: {Assistant.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix core (webhooks-only, no HTML)
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.1"},

      # Database
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},

      # HTTP client
      {:req, "~> 0.5"},

      # Google APIs
      {:goth, "~> 1.4"},
      {:google_api_drive, "~> 0.32"},
      {:google_api_gmail, "~> 0.17"},
      {:google_api_calendar, "~> 0.26"},

      # Job processing & scheduling
      {:oban, "~> 2.18"},
      {:quantum, "~> 3.5"},

      # Security
      {:cloak_ecto, "~> 1.3"},

      # Utilities
      {:earmark, "~> 1.4"},
      {:briefly, "~> 0.5"},
      {:muontrap, "~> 1.7"},
      {:fuse, "~> 2.5"},
      {:yaml_elixir, "~> 2.11"},
      {:file_system, "~> 1.0"},

      # Dev & test tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # Test only
      {:mox, "~> 1.1", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
