defmodule IotaService.MixProject do
  use Mix.Project

  def project do
    [
      app: :iota_service,
      version: "0.10.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {IotaService.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # IOTA NIF library (fetched via git)
      {:iota_nif, git: "https://github.com/anspn/iota_nif.git", tag: "v0.3.1"},

      # Web server & HTTP
      {:bandit, "~> 1.10"},
      {:plug, "~> 1.19"},

      # JWT authentication
      {:joken, "~> 2.6"},

      # JSON parsing
      {:jason, "~> 1.4"},

      # HTTP client
      {:req, "~> 0.5"},

      # MongoDB driver
      {:mongodb_driver, "~> 1.4"},

      # Telemetry for metrics
      {:telemetry, "~> 1.2"},

      # Development/Test dependencies
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      iota_service: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  def cli do
    [default_env: :dev]
  end
end
