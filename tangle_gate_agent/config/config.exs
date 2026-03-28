import Config

config :tangle_gate_agent,
  # HTTP server port for verification API
  port: 8800,
  # IOTA node URL for on-chain DID resolution
  node_url: "https://api.testnet.iota.cafe",
  # Identity package ObjectID ("" for auto-discovery)
  identity_pkg_id: ""

# WebSocket connection to tangle_gate
config :tangle_gate_agent, TangleGateAgent.WS.Client,
  url: "ws://localhost:4000/ws/agent",
  api_key: "dev-agent-key",
  # Reconnect interval range (exponential backoff)
  reconnect_min_ms: 1_000,
  reconnect_max_ms: 30_000

# API key for incoming HTTP requests
config :tangle_gate_agent, TangleGateAgent.Web.AuthPlug,
  api_key: "dev-agent-key"

# Import environment-specific config
import_config "#{config_env()}.exs"
