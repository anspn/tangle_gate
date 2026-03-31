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
    ws_url: env.("AGENT_WS_URL", "ws://localhost:8800/ws/events"),
    node_url: env.("IOTA_NODE_URL", "https://api.testnet.iota.cafe"),
    identity_pkg_id: env.("IOTA_IDENTITY_PKG_ID", "")

  config :tangle_gate_agent, TangleGateAgent.Web.AuthPlug,
    api_key:
      System.get_env("AGENT_API_KEY") ||
        raise("Environment variable AGENT_API_KEY is required")
end
