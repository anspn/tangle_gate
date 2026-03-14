defmodule IotaService do
  @moduledoc """
  IOTA Service - Elixir interface for IOTA Rebased operations.

  This module provides a high-level API for:
  - **Identity**: DID (Decentralized Identifier) generation, publishing, and resolution
  - **Credentials**: W3C Verifiable Credentials issuance and verification
  - **Presentations**: W3C Verifiable Presentations creation and verification
  - **Notarization**: Local payload creation and on-chain CRUD via the official IOTA notarization library

  ## Local Operations (no network required)

      # Generate a DID locally (placeholder tag)
      {:ok, did_result} = IotaService.generate_did()

      # Create a notarization payload
      {:ok, payload} = IotaService.notarize("Hello, IOTA!")

  ## Ledger Operations (require IOTA Rebased node)

      # Publish a DID on-chain
      {:ok, published} = IotaService.publish_did(secret_key: "iotaprivkey1...")

      # Create a locked notarization on-chain
      {:ok, notarization} = IotaService.create_notarization(
        secret_key: "iotaprivkey1...",
        state_data: "document-hash-here"
      )

  ## Architecture

  ```
  IotaService.Application (rest_for_one)
  ├── NIF.Loader           - Ensures Rust NIF is loaded (:iota_did_nif, :iota_notarization_nif, :iota_credential_nif)
  ├── Identity.Supervisor  - DID services
  │   ├── Identity.Cache   - ETS cache for DIDs
  │   └── Identity.Server  - DID operations (local + ledger)
  ├── Credential.Supervisor - VC/VP services
  │   └── Credential.Server - Verifiable Credential & Presentation operations
  ├── Notarization.Supervisor
  │   ├── Notarization.Queue  - Job queue
  │   └── Notarization.Server - Notarization operations (local + ledger CRUD)
  └── Session.Supervisor
      └── Session.Manager  - TTY session recording & notarization
  ```
  """

  alias IotaService.Credential
  alias IotaService.Identity
  alias IotaService.Notarization
  alias IotaService.Session

  # ============================================================================
  # Identity API — Local Operations
  # ============================================================================

  @doc """
  Generate a new IOTA DID locally (not published on-chain).

  The generated DID has a placeholder tag (all zeros). Use `publish_did/1`
  to get a real on-chain DID.

  ## Options
  - `:network` - Target network: `:iota`, `:smr`, `:rms`, `:atoi` (default: `:iota`)

  ## Examples

      iex> {:ok, result} = IotaService.generate_did()
      iex> String.starts_with?(result.did, "did:iota:0x")
      true

      iex> {:ok, result} = IotaService.generate_did(network: :smr)
      iex> String.starts_with?(result.did, "did:iota:smr:0x")
      true
  """
  @spec generate_did(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate generate_did(opts \\ []), to: Identity.Server

  @doc """
  Check if a string is a valid IOTA DID format.

  ## Examples

      iex> IotaService.valid_did?("did:iota:0x123")
      true

      iex> IotaService.valid_did?("not-a-did")
      false
  """
  @spec valid_did?(String.t()) :: boolean()
  defdelegate valid_did?(did), to: Identity.Server

  @doc """
  Create a DID URL with a fragment.

  ## Examples

      iex> IotaService.create_did_url("did:iota:0x123", "key-1")
      {:ok, "did:iota:0x123#key-1"}
  """
  @spec create_did_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate create_did_url(did, fragment), to: Identity.Server

  # ============================================================================
  # Identity API — Ledger Operations
  # ============================================================================

  @doc """
  Create and publish a DID on the IOTA Rebased ledger.

  The resulting DID has a real, unique tag derived from the on-chain object.

  ## Options
  - `:secret_key` - (required) Ed25519 private key (Bech32, Base64)
  - `:node_url` - URL of the IOTA node (default: from app config)
  - `:identity_pkg_id` - ObjectID of the identity Move package (default: from app config, or "" for auto)
  - `:gas_coin_id` - Specific gas coin ObjectID (default: "" for auto)
  - `:cache` - Whether to cache the result (default: true)
  """
  @spec publish_did(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate publish_did(opts), to: Identity.Server

  @doc """
  Resolve a published DID from the IOTA ledger.

  ## Options
  - `:node_url` - URL of the IOTA node (default: from app config)
  - `:identity_pkg_id` - ObjectID of the identity Move package (default: from app config, or "" for auto)
  """
  @spec resolve_did(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate resolve_did(did, opts \\ []), to: Identity.Server

  @doc """
  Permanently deactivate (revoke) a DID on the IOTA Rebased ledger.

  **Warning**: This operation is irreversible. Once deactivated, the DID
  cannot be reactivated.

  ## Options
  - `:secret_key` - (required) Ed25519 private key of a DID controller
  - `:node_url` - URL of the IOTA node (default: from app config)
  - `:identity_pkg_id` - ObjectID of the identity Move package (default: from app config, or "" for auto)
  """
  @spec deactivate_did(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate deactivate_did(did, opts), to: Identity.Server

  # ============================================================================
  # Credential API — Verifiable Credentials
  # ============================================================================

  @doc """
  Create a Verifiable Credential (VC) as a signed JWT.

  The issuer signs a credential containing claims about a subject (holder).

  ## Parameters
  - `issuer_doc_json` — The issuer's DID document as JSON string
  - `holder_did` — The subject/holder's DID string
  - `credential_type` — Credential type (e.g., "TangleGateAccessCredential")
  - `claims_json` — JSON string of credential claims

  ## Examples

      claims = Jason.encode!(%{"role" => "user", "email" => "alice@example.com"})
      {:ok, result} = IotaService.create_credential(issuer_doc, holder_did, "AccessCredential", claims)
      credential_jwt = result["credential_jwt"]
  """
  @spec create_credential(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate create_credential(issuer_doc_json, holder_did, credential_type, claims_json),
    to: Credential.Server

  @doc """
  Verify a Verifiable Credential JWT.

  Validates the EdDSA signature, semantic structure, issuance date, and
  expiration against the issuer's DID document.

  ## Parameters
  - `credential_jwt` — The credential JWT string
  - `issuer_doc_json` — The issuer's DID document as JSON
  """
  @spec verify_credential(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate verify_credential(credential_jwt, issuer_doc_json), to: Credential.Server

  # ============================================================================
  # Credential API — Verifiable Presentations
  # ============================================================================

  @doc """
  Create a Verifiable Presentation (VP) as a signed JWT.

  The holder wraps one or more VC JWTs into a presentation, signs it with
  their DID document, and includes a challenge for replay protection.

  ## Parameters
  - `holder_doc_json` — The holder's DID document as JSON
  - `credential_jwts_json` — JSON array of credential JWT strings
  - `challenge` — Nonce for replay protection (pass "" to omit)
  - `expires_in_seconds` — Expiration in seconds from now (default: 600, 0 = no expiry)
  """
  @spec create_presentation(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  defdelegate create_presentation(
                holder_doc_json,
                credential_jwts_json,
                challenge,
                expires_in_seconds \\ 600
              ),
              to: Credential.Server

  @doc """
  Verify a Verifiable Presentation JWT and all contained VCs.

  Validates the VP signature, challenge nonce, and each contained VC
  against the corresponding issuer's DID document.

  ## Parameters
  - `presentation_jwt` — The presentation JWT string
  - `holder_doc_json` — The holder's DID document as JSON
  - `issuer_docs_json` — JSON array of issuer DID documents (one per VC)
  - `challenge` — The expected challenge nonce (pass "" to skip)
  """
  @spec verify_presentation(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate verify_presentation(presentation_jwt, holder_doc_json, issuer_docs_json, challenge),
    to: Credential.Server

  # ============================================================================
  # Notarization API — Local Operations
  # ============================================================================

  @doc """
  Create a local notarization payload (not published on-chain).

  Creates a timestamped, hash-anchored payload ready for Tangle submission.

  ## Examples

      iex> {:ok, payload} = IotaService.notarize("test")
      iex> is_binary(payload["data_hash"]) and String.length(payload["data_hash"]) == 64
      true
  """
  @spec notarize(binary(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate notarize(data, tag \\ "iota_service"), to: Notarization.Server, as: :create_payload

  @doc """
  Hash data using SHA-256.

  ## Examples

      iex> IotaService.hash("hello")
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  """
  @spec hash(binary()) :: String.t()
  defdelegate hash(data), to: Notarization.Server, as: :hash_data

  @doc """
  Verify a notarization payload.
  """
  @spec verify_notarization(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate verify_notarization(payload_hex), to: Notarization.Server, as: :verify_payload

  # ============================================================================
  # Notarization API — Ledger Operations (IOTA Rebased)
  # ============================================================================

  @doc """
  Create a locked (immutable) notarization on the IOTA Rebased ledger.

  ## Options
  - `:secret_key` - (required) Ed25519 private key
  - `:state_data` - (required) Data to notarize (e.g., a document hash)
  - `:description` - Immutable description label (default: "")
  - `:node_url` - IOTA node URL (default: from app config)
  - `:notarize_pkg_id` - Notarization Move package ObjectID (default: from app config)
  """
  @spec create_notarization(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate create_notarization(opts), to: Notarization.Server, as: :create_on_chain

  @doc """
  Create a dynamic (updatable) notarization on the IOTA Rebased ledger.

  Same options as `create_notarization/1`. The state can be updated via
  `update_notarization/3`.
  """
  @spec create_dynamic_notarization(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate create_dynamic_notarization(opts),
    to: Notarization.Server,
    as: :create_dynamic_on_chain

  @doc """
  Read a notarization from the IOTA Rebased ledger by object ID.

  ## Options
  - `:node_url` - IOTA node URL (default: from app config)
  - `:notarize_pkg_id` - Notarization Move package ObjectID (default: from app config)
  """
  @spec read_notarization(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate read_notarization(object_id, opts \\ []),
    to: Notarization.Server,
    as: :read_on_chain

  @doc """
  Update the state of a dynamic notarization.

  ## Options
  - `:secret_key` - (required) Ed25519 private key
  - `:node_url` - IOTA node URL (default: from app config)
  - `:notarize_pkg_id` - Notarization Move package ObjectID (default: from app config)
  """
  @spec update_notarization(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate update_notarization(object_id, new_state_data, opts \\ []),
    to: Notarization.Server,
    as: :update_on_chain

  @doc """
  Destroy a notarization on the ledger.

  ## Options
  - `:secret_key` - (required) Ed25519 private key
  - `:node_url` - IOTA node URL (default: from app config)
  - `:notarize_pkg_id` - Notarization Move package ObjectID (default: from app config)
  """
  @spec destroy_notarization(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate destroy_notarization(object_id, opts \\ []),
    to: Notarization.Server,
    as: :destroy_on_chain

  # ============================================================================
  # Queue API
  # ============================================================================

  @doc """
  Enqueue data for batch notarization.
  """
  @spec enqueue_notarization(binary(), String.t()) :: {:ok, reference()} | {:error, :queue_full}
  defdelegate enqueue_notarization(data, tag \\ "iota_service"),
    to: Notarization.Queue,
    as: :enqueue

  @doc """
  Get notarization queue statistics.
  """
  @spec queue_stats() :: map()
  defdelegate queue_stats(), to: Notarization.Queue, as: :stats

  # ============================================================================
  # Session API — TTY Session Recording & Notarization
  # ============================================================================

  @doc """
  Start a new TTY recording session.

  Creates a session linked to the given DID. The session records all
  commands executed in the ttyd terminal and notarizes them on the
  IOTA Tangle when ended.

  Returns `{:ok, session}` with `:session_id`, `:did`, `:status` (`:active`).
  """
  @spec start_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate start_session(did, user_id), to: Session.Manager

  @doc """
  End a TTY recording session and trigger notarization.

  Reads the command history, hashes it, creates a notarization payload,
  and (if configured) publishes the hash on-chain.
  """
  @spec end_session(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate end_session(session_id), to: Session.Manager

  @doc """
  Get a session by ID.
  """
  @spec get_session(String.t()) :: {:ok, map()} | :not_found
  defdelegate get_session(session_id), to: Session.Manager

  @doc """
  List all sessions, optionally filtered.

  ## Options
  - `:user_id` — Filter by user ID
  - `:did` — Filter by DID
  - `:status` — Filter by status
  - `:limit` — Maximum results (default: 100)
  """
  @spec list_sessions(keyword()) :: [map()]
  defdelegate list_sessions(opts \\ []), to: Session.Manager

  @doc """
  Get session recording statistics.
  """
  @spec session_stats() :: map()
  defdelegate session_stats(), to: Session.Manager, as: :stats

  # ============================================================================
  # Health & Status
  # ============================================================================

  @doc """
  Check if the IOTA NIF is loaded and ready.
  """
  @spec nif_ready?() :: boolean()
  defdelegate nif_ready?(), to: IotaService.NIF.Loader, as: :ready?

  @doc """
  Get NIF information.
  """
  @spec nif_info() :: map()
  defdelegate nif_info(), to: IotaService.NIF.Loader, as: :info
end
