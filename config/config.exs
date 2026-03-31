import Config

# IOTA Service base configuration
# Defaults target the IOTA Rebased testnet — no local node required.
config :tangle_gate,
  # IOTA Rebased testnet node URL
  node_url: "https://api.testnet.iota.cafe",
  faucet_url: "https://faucet.testnet.iota.cafe/gas",
  # Identity Move package ObjectID ("" for auto-discovery on official networks)
  identity_pkg_id: "",
  # Notarization Move package ObjectID ("" for auto-discovery on official networks)
  notarize_pkg_id: "",
  # Web server
  port: 4000,
  start_web: true,
  # Set to true to require login before accessing the app
  login_required: true,
  # ttyd URL for portal terminal (user-facing URL the browser connects to)
  ttyd_url: "/terminal"

# JWT Authentication
config :tangle_gate, TangleGate.Web.Auth,
  secret: "dev-secret-please-change-in-production",
  token_ttl_seconds: 3600,
  users: [
    %{id: "usr_admin", email: "admin@iota.local", password: "iota_admin_2026", role: "admin"},
    %{id: "usr_user", email: "user@iota.local", password: "iota_user_2026", role: "user"},
    %{
      id: "usr_verifier",
      email: "verifier@iota.local",
      password: "iota_verifier_2026",
      role: "verifier"
    }
  ]

# MongoDB
config :tangle_gate, TangleGate.Store.Repo,
  url: "mongodb://localhost:27017/tangle_gate",
  pool_size: 5

# Vault — disabled by default in dev (secrets come from config/env)
config :tangle_gate, TangleGate.Vault.Client,
  enabled: false,
  addr: "http://localhost:8200",
  token: "dev-root-token",
  mount: "secret",
  secret_path: "tangle_gate"

# Agent microservice — credential verification & session termination
config :tangle_gate, TangleGate.Agent.Client,
  url: "http://localhost:8800",
  api_key: "dev-agent-key",
  timeout: 30_000

# Joken default signer (not used — we configure our own in Web.Auth)
config :joken, default_signer: nil

import_config "#{Mix.env()}.exs"
