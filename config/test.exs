import Config

# Disable web server and MongoDB in test environment
config :tangle_gate, start_web: false, start_repo: false

# Disable agent WebSocket client in tests
config :tangle_gate, TangleGate.Agent.Client, ws_autostart: false

# Use a separate test database to avoid polluting dev data
config :tangle_gate, TangleGate.Store.Repo, url: "mongodb://localhost:27017/tangle_gate_test"

# Vault disabled in tests
config :tangle_gate, TangleGate.Vault.Client, enabled: false
