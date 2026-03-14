# IotaService

Elixir application for IOTA Tangle operations, including DID (Decentralized Identifier)
management and data notarization.

## Features

- **DID Generation**: Create IOTA DIDs with Ed25519 verification methods
- **Verifiable Credentials**: Issue and verify W3C Verifiable Credentials as signed JWTs
- **Verifiable Presentations**: Create and verify W3C Verifiable Presentations with challenge/expiry
- **Notarization**: Timestamp and hash-anchor data for Tangle submission
- **Supervised Architecture**: Fault-tolerant supervision tree
- **NIF Integration**: Uses Rust NIFs for cryptographic operations
- **Web Portal**: User portal with VP-gated terminal access via ttyd
- **Session Recording**: Tamper-proof TTY session recording with downloadable audit logs
- **On-Chain Notarization**: Automatic publishing of session hashes to the IOTA Rebased ledger
- **Verification**: Verifier role with on-chain notarization verification page
- **Docker Ready**: Multi-stage Dockerfile + Docker Compose with ttyd terminal, MongoDB, and Vault services


## Quick Start

```elixir
# Start the application
Application.ensure_all_started(:iota_service)

# Generate a DID
{:ok, did_result} = IotaService.generate_did()
IO.puts("Generated DID: #{did_result.did}")

# Notarize data
{:ok, payload} = IotaService.notarize("Important document content")
IO.inspect(payload, label: "Notarization payload")

# Verify the DID format
true = IotaService.valid_did?(did_result.did)
```

## Supervision Tree

```
IotaService.Application (rest_for_one)
├── IotaService.NIF.Loader            # Ensures NIF is loaded
├── IotaService.Store.Repo            # MongoDB connection pool
├── IotaService.Identity.Supervisor   # (one_for_one)
│   ├── IotaService.Identity.Cache    # ETS-backed DID cache
│   └── IotaService.Identity.Server   # DID operations
├── IotaService.Credential.Supervisor # (one_for_one)
│   ├── IotaService.Credential.ChallengeCache  # ETS challenge nonce store
│   └── IotaService.Credential.Server # VC/VP operations
├── IotaService.Notarization.Supervisor  # (one_for_one)
│   ├── IotaService.Notarization.Queue   # Job queue
│   └── IotaService.Notarization.Server  # Notarization operations
└── IotaService.Session.Supervisor    # (one_for_one)
    └── IotaService.Session.Manager   # Session recording & notarization
```

## API Reference

### Identity

```elixir
# Generate DID for different networks
IotaService.generate_did()                    # IOTA mainnet
IotaService.generate_did(network: :smr)       # Shimmer
IotaService.generate_did(network: :rms)       # Shimmer testnet
IotaService.generate_did(network: :atoi)      # IOTA testnet

# Validate DID format
IotaService.valid_did?("did:iota:0x123...")   # => true/false

# Create DID URL
IotaService.create_did_url("did:iota:0x123", "key-1")
# => {:ok, "did:iota:0x123#key-1"}
```

### Notarization

```elixir
# Hash data
hash = IotaService.hash("data to hash")

# Create notarization payload
{:ok, payload} = IotaService.notarize("document", "my-tag")

# Verify payload
{:ok, result} = IotaService.verify_notarization(payload["payload_hex"])
```

### Verifiable Credentials

```elixir
# Issue a credential (server as issuer)
{:ok, vc} = IotaService.create_credential(
  issuer_doc_json,
  holder_did,
  "TangleGateAccessCredential",
  Jason.encode!(%{"role" => "user", "email" => "alice@example.com"})
)
credential_jwt = vc["credential_jwt"]

# Verify a credential
{:ok, result} = IotaService.verify_credential(credential_jwt, issuer_doc_json)
# result["valid"] => true
```

### Verifiable Presentations

```elixir
# Create a presentation (holder side)
{:ok, vp} = IotaService.create_presentation(
  holder_doc_json,
  Jason.encode!([credential_jwt]),
  "challenge-nonce",
  600  # expires in 10 minutes
)
presentation_jwt = vp["presentation_jwt"]

# Verify a presentation (verifier side)
{:ok, result} = IotaService.verify_presentation(
  presentation_jwt,
  holder_doc_json,
  Jason.encode!([Jason.decode!(issuer_doc_json)]),
  "challenge-nonce"
)
```

### Queue (Batch Processing)

```elixir
# Enqueue for later processing
{:ok, job_ref} = IotaService.enqueue_notarization("data", "batch-tag")

# Check stats
IotaService.queue_stats()
# => %{pending: 1, total_jobs: 1, processed: 0, failed: 0}
```

## Configuration

Configure via `config/config.exs`

## Docker

```bash
# 1. Copy the env example and fill in secrets
cp .env.example .env

# 2. Build and start (app + ttyd terminal)
docker compose up -d --build

# 3. Open http://localhost:4000 (app) or http://localhost:7681 (ttyd directly)
```

### Services

| Service | Port | Purpose |
|---------|------|---------|
| `app` | 4000 | IOTA Service (Elixir) |
| `mongo` | 27017 | MongoDB — document store for sessions & notarization records |
| `vault` | 8200 | HashiCorp Vault — secrets management (IOTA private keys) |
| `ttyd` | 7681 | Web-based terminal — embedded in portal after VP verification |

### Required Environment Variables

- `SECRET_KEY_BASE` — JWT signing secret (`openssl rand -base64 64`)
- `ADMIN_PASSWORD` — Admin user password
- `MONGO_PASSWORD` — MongoDB root password
- `VAULT_ROOT_TOKEN` — Vault dev server root token

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
IOTA_TESTNET=1 mix test test/iota_service/integration/ledger_identity_test.exs

# Against a local node
MIX_ENV=local mix test
```

## TODO

- **lib/iota_service/web/auth.ex** (L80) — Modify token verification behaviour to handle expiration of tokens
- **lib/iota_service/credential/challenge_cache.ex** (L17) — Evaluate converting challenge storage from ETS to MongoDB for persistence across restarts and multi-node deployments
- **lib/iota_service/credential/verifier.ex** (L21) — Verify that the module is truly self-contained and has no hidden dependencies on application state or GenServers; test connectivity with IOTA testnet


## License

MIT
