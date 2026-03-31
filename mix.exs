defmodule TangleGate.MixProject do
  use Mix.Project

  def project do
    [
      app: :tangle_gate,
      version: "3.5.0",
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
      mod: {TangleGate.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # IOTA NIF library
      {:iota_nif, git: "https://github.com/anspn/iota_nif.git", tag: "v0.4.0-precompiled"},

      # Web server & HTTP
      {:bandit, "~> 1.10"},
      {:plug, "~> 1.19"},

      # JWT authentication
      {:joken, "~> 2.6"},

      # JSON parsing
      {:jason, "~> 1.4"},

      # HTTP client
      {:req, "~> 0.5"},

      # WebSocket client (connects to agent microservice)
      {:websockex, "~> 0.4"},

      # SMTP email client
      {:gen_smtp, "~> 1.2"},

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
      tangle_gate: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  def cli do
    [default_env: :dev]
  end
end
