import Config

# Runtime configuration — loaded at application startup (not compile time).
# This is the right place to read environment variables for Docker/production.
#
# All optional env vars fall back to sensible defaults below.
# Docker Compose passes vars via env_file (.env); SECRET_KEY_BASE and
# ADMIN_PASSWORD are explicitly required in docker-compose.yml.

if config_env() == :prod do
  # Helper: treat "" the same as nil so empty Docker env vars don't
  # override defaults (env_file passes commented-out vars as "").
  env = fn key, default ->
    case System.get_env(key) do
      nil -> default
      "" -> default
      val -> val
    end
  end

  # --- IOTA Node (defaults to testnet) ---
  config :tangle_gate,
    node_url: env.("IOTA_NODE_URL", "https://api.testnet.iota.cafe"),
    faucet_url: env.("IOTA_FAUCET_URL", "https://faucet.testnet.iota.cafe/gas"),
    identity_pkg_id: env.("IOTA_IDENTITY_PKG_ID", ""),
    notarize_pkg_id: env.("IOTA_NOTARIZE_PKG_ID", ""),
    ttyd_url: env.("TTYD_URL", "http://localhost:7681"),
    # Frontend mode: "static" (SSR) or "spa" (React)
    frontend: (if env.("FRONTEND_MODE", "static") == "spa", do: :spa, else: :static),
    # TTY session recording — shared Docker volume with ttyd container
    sessions_dir: env.("SESSIONS_DIR", "/data/sessions"),
    # IOTA Ed25519 secret key — used for on-chain notarization of sessions
    # and as the default key for DID publishing when not provided per-call.
    # IOTA_NOTARIZE_SECRET_KEY is a legacy alias; prefer IOTA_SECRET_KEY.
    secret_key: env.("IOTA_SECRET_KEY", nil) || env.("IOTA_NOTARIZE_SECRET_KEY", nil)

  # --- Web server ---
  port =
    case System.get_env("PORT") do
      nil -> 4000
      "" -> 4000
      val -> String.to_integer(val)
    end

  config :tangle_gate, port: port

  # --- MongoDB ---
  mongo_url = env.("MONGO_URL", "mongodb://localhost:27017/tangle_gate")

  config :tangle_gate, TangleGate.Store.Repo,
    url: mongo_url,
    pool_size: String.to_integer(env.("MONGO_POOL_SIZE", "10"))

  # --- Vault ---
  vault_enabled = env.("VAULT_ENABLED", "true") == "true"

  config :tangle_gate, TangleGate.Vault.Client,
    enabled: vault_enabled,
    addr: env.("VAULT_ADDR", "http://localhost:8200"),
    token: env.("VAULT_TOKEN", ""),
    mount: env.("VAULT_MOUNT", "secret"),
    secret_path: env.("VAULT_SECRET_PATH", "tangle_gate")

  # --- JWT Auth ---
  secret =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      Environment variable SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret (or openssl rand -base64 64)
      """

  admin_password =
    case System.get_env("ADMIN_PASSWORD") do
      nil -> raise("Environment variable ADMIN_PASSWORD is missing.")
      "" -> raise("Environment variable ADMIN_PASSWORD is missing.")
      pw -> pw
    end

  user_password = env.("USER_PASSWORD", nil)
  verifier_password = env.("VERIFIER_PASSWORD", nil)

  config :tangle_gate, TangleGate.Web.Auth,
    secret: secret,
    token_ttl_seconds: String.to_integer(env.("TOKEN_TTL_SECONDS", "3600")),
    users:
      [
        %{
          id: env.("ADMIN_USER_ID", "usr_admin"),
          email: env.("ADMIN_EMAIL", "admin@iota.local"),
          password: admin_password,
          role: "admin"
        }
      ] ++
        if(user_password,
          do: [
            %{
              id: env.("USER_USER_ID", "usr_user"),
              email: env.("USER_EMAIL", "user@iota.local"),
              password: user_password,
              role: "user"
            }
          ],
          else: []
        ) ++
        if(verifier_password,
          do: [
            %{
              id: env.("VERIFIER_USER_ID", "usr_verifier"),
              email: env.("VERIFIER_EMAIL", "verifier@iota.local"),
              password: verifier_password,
              role: "verifier"
            }
          ],
          else: []
        )
end
