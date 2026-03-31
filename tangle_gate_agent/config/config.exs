import Config

config :tangle_gate_agent,
  # HTTP server port for verification API
  port: 8800,
  # Full WebSocket URL advertised in the health endpoint
  # In Docker this would be e.g. "ws://backend:8800/ws/events"
  ws_url: "ws://localhost:8800/ws/events",
  # IOTA node URL for on-chain DID resolution
  node_url: "https://api.testnet.iota.cafe",
  # Identity package ObjectID ("" for auto-discovery)
  identity_pkg_id: ""

# API key for incoming HTTP/WebSocket requests
config :tangle_gate_agent, TangleGateAgent.Web.AuthPlug,
  api_key: "dev-agent-key"

# Import environment-specific config
import_config "#{config_env()}.exs"
