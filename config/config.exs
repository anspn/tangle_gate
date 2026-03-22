import Config

# IOTA Service base configuration
# Defaults target the IOTA Rebased testnet — no local node required.
config :iota_service,
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
  ttyd_url: "http://localhost:7681"

# JWT Authentication
config :iota_service, IotaService.Web.Auth,
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
config :iota_service, IotaService.Store.Repo,
  url: "mongodb://localhost:27017/iota_service",
  pool_size: 5

# Vault — disabled by default in dev (secrets come from config/env)
config :iota_service, IotaService.Vault.Client,
  enabled: false,
  addr: "http://localhost:8200",
  token: "dev-root-token",
  mount: "secret",
  secret_path: "iota_service"

# Joken default signer (not used — we configure our own in Web.Auth)
config :joken, default_signer: nil

import_config "#{Mix.env()}.exs"
