import Config

if config_env() == :prod do
  env = fn key, default ->
    case System.get_env(key) do
      nil -> default
      "" -> default
      val -> val
    end
  end

  config :tangle_gate_agent,
    port: String.to_integer(env.("PORT", "8800")),
    node_url: env.("IOTA_NODE_URL", "https://api.testnet.iota.cafe"),
    identity_pkg_id: env.("IOTA_IDENTITY_PKG_ID", "")

  config :tangle_gate_agent, TangleGateAgent.WS.Client,
    url: env.("TANGLE_GATE_WS_URL", "ws://localhost:4000/ws/agent"),
    api_key:
      System.get_env("AGENT_API_KEY") ||
        raise("Environment variable AGENT_API_KEY is required")

  config :tangle_gate_agent, TangleGateAgent.Web.AuthPlug,
    api_key:
      System.get_env("AGENT_API_KEY") ||
        raise("Environment variable AGENT_API_KEY is required")
end
