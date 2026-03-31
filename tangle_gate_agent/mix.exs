defmodule TangleGateAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :tangle_gate_agent,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TangleGateAgent.Application, []}
    ]
  end

  defp deps do
    [
      # IOTA NIF library (credential + DID verification)
      {:iota_nif, git: "https://github.com/anspn/iota_nif.git", tag: "v0.4.0-precompiled"},

      # Web server & HTTP
      {:bandit, "~> 1.10"},
      {:plug, "~> 1.19"},

      # JSON
      {:jason, "~> 1.4"},

      # WebSocket upgrade support (tangle_gate connects to agent)
      {:websock_adapter, "~> 0.5"},

      # Telemetry
      {:telemetry, "~> 1.2"}
    ]
  end

  defp releases do
    [
      tangle_gate_agent: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
