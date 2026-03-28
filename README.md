# TangleGate

Elixir application (v2.0.0) for IOTA Tangle operations, including DID (Decentralized Identifier)
management, Verifiable Credentials/Presentations, and data notarization. Credential verification
is handled by a standalone microservice (**tangle_gate_agent**) that communicates via HTTP REST
and WebSocket.

## Features

- **DID Generation**: Create IOTA DIDs with Ed25519 verification methods
- **Verifiable Credentials**: Issue and verify W3C Verifiable Credentials as signed JWTs
- **Verifiable Presentations**: Create and verify W3C Verifiable Presentations with challenge/expiry
- **DID-based 2FA**: Login with email/password + DID triggers credential issuance and revocation
- **User Management**: Admin can create dynamic users, assign DIDs, authorize/unauthorize, revoke DIDs on-chain, and delete users
- **Credential Revocation**: Server-side revocation tracking in MongoDB (TODO: on-chain via revocation bitmaps)
- **Notarization**: Timestamp and hash-anchor data for Tangle submission
- **Supervised Architecture**: Fault-tolerant supervision tree
- **NIF Integration**: Uses Rust NIFs for cryptographic operations
- **Web Portal**: User portal with VP-gated terminal access via ttyd
- **Session Recording**: Tamper-proof TTY session recording with downloadable audit logs
- **On-Chain Notarization**: Automatic publishing of session hashes to the IOTA Rebased ledger
- **Session Management**: Admin can terminate active sessions and retry failed notarizations
- **Verification**: Verifier role with on-chain notarization verification page
- **Credential Verification Agent**: Standalone microservice (`tangle_gate_agent`) for VC/VP verification, deployable as systemd service
- **Graceful Degradation**: Main app continues operating when the agent is unavailable (verification fails gracefully)
- **Agent Session Termination**: Agent terminates user sessions via `systemctl kill` (SIGHUP to session scope) + `loginctl terminate-session` for cleanup
- **Docker Ready**: Multi-stage Dockerfile + Docker Compose with backend (systemd + logind + sshd + ttyd + agent), MongoDB, and Vault


## Quick Start

```elixir
# Start the application
Application.ensure_all_started(:tangle_gate)

# Generate a DID
{:ok, did_result} = TangleGate.generate_did()
IO.puts("Generated DID: #{did_result.did}")

# Notarize data
{:ok, payload} = TangleGate.notarize("Important document content")
IO.inspect(payload, label: "Notarization payload")

# Verify the DID format
true = TangleGate.valid_did?(did_result.did)
```

## Supervision Tree

### Main Application

```
TangleGate.Application (rest_for_one)
├── TangleGate.NIF.Loader              # Ensures NIF is loaded
├── TangleGate.Store.Repo              # MongoDB connection pool
├── TangleGate.Identity.Supervisor     # (one_for_one)
│   ├── TangleGate.Identity.Cache      # ETS-backed DID cache
│   └── TangleGate.Identity.Server     # DID operations
├── TangleGate.Credential.Supervisor   # (one_for_one)
│   ├── TangleGate.Credential.ChallengeCache  # ETS challenge nonce store
│   └── TangleGate.Credential.Server   # VC/VP operations
├── TangleGate.Notarization.Supervisor # (one_for_one)
│   ├── TangleGate.Notarization.Queue  # Job queue
│   └── TangleGate.Notarization.Server # Notarization operations
├── TangleGate.Session.Supervisor      # (one_for_one)
│   └── TangleGate.Session.Manager     # Session recording & notarization
├── TangleGate.Web.WS.AgentRegistry   # Tracks connected agent WebSocket PIDs
└── Bandit                              # HTTP server
    └── TangleGate.Web.Router          # Includes /ws/agent WebSocket upgrade
```

### Agent Microservice (runs inside backend container)

```
TangleGateAgent.Application (rest_for_one)
├── TangleGateAgent.NIF.Loader         # Ensures credential/DID NIFs are loaded
├── TangleGateAgent.Session.Tracker    # ETS-backed session tracking
├── TangleGateAgent.WS.Client          # WebSocket client → tangle_gate /ws/agent
└── Bandit (port 8800)
    └── TangleGateAgent.Web.Router     # HTTP verification API
```

The backend container runs systemd as PID 1 with logind, sshd (PAM), ttyd, and the agent.
Session termination sends SIGHUP to the logind session scope via `systemctl kill`, which kills all processes in the session. `loginctl terminate-session` follows as cleanup.

## API Reference

### REST API — Admin Dashboard

```
GET /api/dashboard/stats          — Aggregated dashboard statistics (admin-only)
```

Returns user counts (total, by status, authorized, with DID), credential counts (total, active, revoked, issued per day over last 30 days), and session time-series data (total, notarized, failed, active per day over last 30 days).

### Identity

```elixir
# Generate DID for different networks
TangleGate.generate_did()                    # IOTA mainnet
TangleGate.generate_did(network: :smr)       # Shimmer
TangleGate.generate_did(network: :rms)       # Shimmer testnet
TangleGate.generate_did(network: :atoi)      # IOTA testnet

# Validate DID format
TangleGate.valid_did?("did:iota:0x123...")   # => true/false

# Create DID URL
TangleGate.create_did_url("did:iota:0x123", "key-1")
# => {:ok, "did:iota:0x123#key-1"}
```

### Notarization

```elixir
# Hash data
hash = TangleGate.hash("data to hash")

# Create notarization payload
{:ok, payload} = TangleGate.notarize("document", "my-tag")

# Verify payload
{:ok, result} = TangleGate.verify_notarization(payload["payload_hex"])
```

### Verifiable Credentials

```elixir
# Issue a credential (server as issuer)
{:ok, vc} = TangleGate.create_credential(
  issuer_doc_json,
  holder_did,
  "TangleGateAccessCredential",
  Jason.encode!(%{"role" => "user", "email" => "alice@example.com"})
)
credential_jwt = vc["credential_jwt"]

# Verify a credential
{:ok, result} = TangleGate.verify_credential(credential_jwt, issuer_doc_json)
# result["valid"] => true
```

### Verifiable Presentations

```elixir
# Create a presentation (holder side)
{:ok, vp} = TangleGate.create_presentation(
  holder_doc_json,
  Jason.encode!([credential_jwt]),
  "challenge-nonce",
  600  # expires in 10 minutes
)
presentation_jwt = vp["presentation_jwt"]

# Verify a presentation (verifier side)
{:ok, result} = TangleGate.verify_presentation(
  presentation_jwt,
  holder_doc_json,
  Jason.encode!([Jason.decode!(issuer_doc_json)]),
  "challenge-nonce"
)
```

### Queue (Batch Processing)

```elixir
# Enqueue for later processing
{:ok, job_ref} = TangleGate.enqueue_notarization("data", "batch-tag")

# Check stats
TangleGate.queue_stats()
# => %{pending: 1, total_jobs: 1, processed: 0, failed: 0}
```

## Configuration

Configure via `config/config.exs`

## Docker

```bash
# 1. Copy the env example and fill in secrets
cp .env.example .env

# 2. Build and start all services
docker compose up -d --build

# 3. Open http://localhost:4000 (app) or http://localhost:7681 (ttyd directly)
```

### Services

| Service | Port | Purpose |
|---------|------|---------|
| `app` | 4000 | IOTA Service (Elixir) |
| `backend` | 7681, 8800 | systemd container: logind + sshd + ttyd + tangle_gate_agent |
| `mongo` | 27017 | MongoDB — document store for sessions & notarization records |
| `vault` | 8200 | HashiCorp Vault — secrets management (IOTA private keys) |

The `backend` container runs systemd as PID 1 and bundles the web terminal (ttyd), SSH server (with PAM/logind session management), and the credential verification agent. When an admin terminates a session, the agent sends SIGHUP to the logind session scope via `systemctl kill`, which immediately kills all processes (interactive bash doesn't ignore SIGHUP). `loginctl terminate-session` follows for scope cleanup.

### Required Environment Variables

- `SECRET_KEY_BASE` — JWT signing secret (`openssl rand -base64 64`)
- `ADMIN_PASSWORD` — Admin user password
- `MONGO_PASSWORD` — MongoDB root password
- `VAULT_ROOT_TOKEN` — Vault dev server root token
- `AGENT_API_KEY` — Shared API key for main app ↔ agent authentication

See [.env.example](.env.example) for the full list.

## Testing

Test against the IOTA testnet with:

```bash
# Unit tests only (no node/NIF needed)
mix test

# Integration tests (requires NIF, uses testnet by default)
IOTA_TESTNET=1 mix test

# Ledger tests (requires funded secret key)
IOTA_TEST_SECRET_KEY=iotaprivkey1... \
IOTA_TESTNET=1 mix test test/tangle_gate/integration/ledger_identity_test.exs

# Against a local node
MIX_ENV=local mix test
```

## Agent Deployment

### Docker (recommended)

The agent runs inside the `backend` container as a systemd service. See Docker section above.

### systemd (bare-metal)

```bash
# Build the release
cd tangle_gate_agent && MIX_ENV=prod mix release

# Create system user
sudo useradd --system --shell /usr/sbin/nologin tangle_agent

# Install the release
sudo cp -r _build/prod/rel/tangle_gate_agent /opt/tangle_gate_agent
sudo chown -R tangle_agent:tangle_agent /opt/tangle_gate_agent

# Configure environment
sudo mkdir -p /etc/tangle_gate_agent
sudo cp systemd/env.example /etc/tangle_gate_agent/env
sudo nano /etc/tangle_gate_agent/env  # fill in values

# Install and start service
sudo cp systemd/tangle_gate_agent.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now tangle_gate_agent
```

The agent requires `CAP_KILL` and `CAP_SYS_PTRACE` capabilities for sending signals and reading process info. The systemd unit file sets `AmbientCapabilities=CAP_KILL CAP_SYS_PTRACE` automatically. A polkit JavaScript rule (`/etc/polkit-1/rules.d/50-agent-terminate.rules`) authorizes the agent user to call `loginctl terminate-session` and `systemctl kill` on session scopes.

## TODO

- **lib/tangle_gate/web/auth.ex** (L80) — Modify token verification behaviour to handle expiration of tokens
- **lib/tangle_gate/credential/challenge_cache.ex** (L17) — Evaluate converting challenge storage from ETS to MongoDB for persistence across restarts and multi-node deployments
- **lib/tangle_gate/store/credential_store.ex** — Implement on-chain credential revocation via revocation bitmaps when `iota_credential_nif` adds support for revocation operations
- Swap websocket client/server roles between app and agent. Right now the agent is the client but if app was the client it would be more semantically correct when configuring agent connection parameters
## License

MIT
