defmodule IotaService.Credential.Server do
  @moduledoc """
  GenServer for Verifiable Credential (VC) and Verifiable Presentation (VP) operations.

  Wraps the `:iota_credential_nif` Erlang NIF module to provide:

  ## Verifiable Credentials (Issuer operations)
  - `create_credential/4` — Issue a VC as a signed JWT
  - `verify_credential/2` — Verify a VC JWT against the issuer's DID document

  ## Verifiable Presentations (Holder / Verifier operations)
  - `create_presentation/4` — Wrap VCs into a signed VP with challenge and expiry
  - `verify_presentation/4` — Verify a VP and its contained VCs

  ## W3C Verifiable Credentials Workflow

  ```
  Issuer                      Holder                     Verifier
  ──────                      ──────                     ────────
  1. create_credential ──VC JWT──► stores VC
                                   2. create_presentation ──VP JWT──►
                                                           3. verify_presentation
                                                              ├─ check VP signature
                                                              ├─ check challenge
                                                              └─ verify each VC
  ```
  """

  use GenServer

  require Logger

  @nif_module :iota_credential_nif

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the server's DID identity (DID, document, fragment).

  Returns `{:ok, identity}` if the server DID has been provisioned,
  or `{:error, :no_server_did}` if it hasn't been set up yet.
  """
  @spec server_did_info() :: {:ok, map()} | {:error, :no_server_did}
  def server_did_info do
    GenServer.call(__MODULE__, :server_did_info)
  end

  @doc """
  Provision the server's DID by publishing it on-chain and persisting it.

  This must be called once (typically by an admin) to create the server's
  permanent DID identity. Subsequent calls will return an error.

  ## Options
  - `:secret_key` — Ed25519 private key (from app config if not provided)
  - `:node_url` — IOTA node URL (from app config if not provided)
  - `:identity_pkg_id` — Identity package ObjectID (from app config if not provided)
  """
  @spec provision_server_did(keyword()) :: {:ok, map()} | {:error, term()}
  def provision_server_did(opts \\ []) do
    GenServer.call(__MODULE__, {:provision_server_did, opts}, 120_000)
  end

  @doc """
  Issue a TangleGateAccessCredential to a holder.

  Uses the server's DID as the issuer. The credential JWT is returned
  to the caller (holder). Metadata is recorded in MongoDB.

  ## Parameters
  - `holder_did` — The holder's DID string
  - `claims` — Map of claims to include in the credential
  - `credential_type` — Credential type (default: "TangleGateAccessCredential")
  """
  @spec issue_credential(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def issue_credential(holder_did, claims, credential_type \\ "TangleGateAccessCredential") do
    GenServer.call(__MODULE__, {:issue_credential, holder_did, claims, credential_type}, 60_000)
  end

  @doc """
  Create a Verifiable Credential (VC) as a signed JWT.

  The issuer signs a credential containing claims about a subject (holder).

  ## Parameters
  - `issuer_doc_json` — The issuer's DID document as JSON string
  - `holder_did` — The subject/holder's DID string
  - `credential_type` — Credential type (e.g., "TangleGateAccessCredential")
  - `claims_json` — JSON string of credential claims

  ## Returns
  `{:ok, result}` with:
  - `credential_jwt` — The signed VC as a compact JWT
  - `issuer_did` — The issuer's DID
  - `subject_did` — The holder's DID
  - `credential_type` — The credential type
  """
  @spec create_credential(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def create_credential(issuer_doc_json, holder_did, credential_type, claims_json) do
    GenServer.call(
      __MODULE__,
      {:create_credential, issuer_doc_json, holder_did, credential_type, claims_json},
      60_000
    )
  end

  @doc """
  Verify a Verifiable Credential JWT.

  Validates the EdDSA signature, semantic structure, issuance date, and
  expiration against the issuer's DID document.

  ## Parameters
  - `credential_jwt` — The credential JWT string
  - `issuer_doc_json` — The issuer's DID document as JSON

  ## Returns
  `{:ok, result}` with:
  - `valid` — Boolean
  - `issuer_did` — Issuer's DID extracted from the credential
  - `subject_did` — Holder's DID
  - `claims` — Credential claims as a JSON string
  """
  @spec verify_credential(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_credential(credential_jwt, issuer_doc_json) do
    GenServer.call(__MODULE__, {:verify_credential, credential_jwt, issuer_doc_json}, 30_000)
  end

  @doc """
  Create a Verifiable Presentation (VP) as a signed JWT.

  The holder wraps one or more VC JWTs into a presentation, signs it with
  their DID document, and includes a challenge for replay protection.

  ## Parameters
  - `holder_doc_json` — The holder's DID document as JSON
  - `credential_jwts_json` — JSON array of credential JWT strings
  - `challenge` — Nonce for replay protection (pass "" to omit)
  - `expires_in_seconds` — Expiration in seconds from now (0 = no expiry)

  ## Returns
  `{:ok, result}` with:
  - `presentation_jwt` — The signed VP as a compact JWT
  - `holder_did` — The holder's DID
  """
  @spec create_presentation(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def create_presentation(holder_doc_json, credential_jwts_json, challenge, expires_in_seconds \\ 600) do
    GenServer.call(
      __MODULE__,
      {:create_presentation, holder_doc_json, credential_jwts_json, challenge, expires_in_seconds},
      60_000
    )
  end

  @doc """
  Verify a Verifiable Presentation JWT and all contained VCs.

  Validates the VP signature against the holder's DID document, checks the
  challenge nonce, and verifies each contained VC against the corresponding
  issuer's DID document.

  ## Parameters
  - `presentation_jwt` — The presentation JWT string
  - `holder_doc_json` — The holder's DID document as JSON
  - `issuer_docs_json` — JSON array of issuer DID documents (one per VC)
  - `challenge` — The expected challenge nonce (pass "" to skip check)

  ## Returns
  `{:ok, result}` with:
  - `valid` — Boolean
  - `holder_did` — The holder's DID
  - `credential_count` — Number of VCs in the presentation
  - `credentials` — Array of credential JWT strings
  """
  @spec verify_presentation(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def verify_presentation(presentation_jwt, holder_doc_json, issuer_docs_json, challenge) do
    GenServer.call(
      __MODULE__,
      {:verify_presentation, presentation_jwt, holder_doc_json, issuer_docs_json, challenge},
      30_000
    )
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("Credential Server started")

    server_identity = load_server_identity()

    state = %{
      server_identity: server_identity,
      credentials_issued: 0,
      credentials_verified: 0,
      presentations_created: 0,
      presentations_verified: 0,
      errors: []
    }

    if server_identity do
      Logger.info("Server DID loaded: #{server_identity.did}")
    else
      Logger.warning("No server DID provisioned — credential issuance disabled until provisioned")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:server_did_info, _from, state) do
    case state.server_identity do
      nil -> {:reply, {:error, :no_server_did}, state}
      identity -> {:reply, {:ok, identity}, state}
    end
  end

  @impl true
  def handle_call({:provision_server_did, opts}, _from, state) do
    if state.server_identity do
      {:reply, {:error, "Server DID already provisioned: #{state.server_identity.did}"}, state}
    else
      case do_provision_server_did(opts) do
        {:ok, identity} ->
          Logger.info("Server DID provisioned: #{identity.did}")
          {:reply, {:ok, identity}, %{state | server_identity: identity}}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call({:issue_credential, holder_did, claims, credential_type}, _from, state) do
    case state.server_identity do
      nil ->
        {:reply, {:error, :no_server_did}, state}

      %{document: issuer_doc_json} ->
        start_time = System.monotonic_time()
        claims_json = Jason.encode!(claims)

        result =
          with {:ok, json} <- call_nif(:create_credential, [issuer_doc_json, holder_did, credential_type, claims_json]),
               {:ok, parsed} <- Jason.decode(json) do
            # Record metadata in MongoDB (best-effort, don't block on failure)
            record_credential_metadata(parsed, holder_did, credential_type, claims)
            emit_telemetry(:issue_credential, start_time, %{success: true})
            {:ok, parsed}
          else
            {:error, reason} = error ->
              emit_telemetry(:issue_credential, start_time, %{success: false})
              Logger.warning("Credential issuance failed: #{inspect(reason)}")
              error
          end

        new_state =
          case result do
            {:ok, _} ->
              %{state | credentials_issued: state.credentials_issued + 1}

            {:error, reason} ->
              %{state | errors: [{DateTime.utc_now(), :issue_credential, reason} | Enum.take(state.errors, 99)]}
          end

        {:reply, result, new_state}
    end
  end

  @impl true
  def handle_call({:create_credential, issuer_doc_json, holder_did, credential_type, claims_json}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, json} <- call_nif(:create_credential, [issuer_doc_json, holder_did, credential_type, claims_json]),
           {:ok, parsed} <- Jason.decode(json) do
        emit_telemetry(:create_credential, start_time, %{success: true})
        {:ok, parsed}
      else
        {:error, reason} = error ->
          emit_telemetry(:create_credential, start_time, %{success: false})
          Logger.warning("Credential creation failed: #{inspect(reason)}")
          error
      end

    new_state =
      case result do
        {:ok, _} ->
          %{state | credentials_issued: state.credentials_issued + 1}

        {:error, reason} ->
          %{state | errors: [{DateTime.utc_now(), :create_credential, reason} | Enum.take(state.errors, 99)]}
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:verify_credential, credential_jwt, issuer_doc_json}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, json} <- call_nif(:verify_credential, [credential_jwt, issuer_doc_json]),
           {:ok, parsed} <- Jason.decode(json) do
        emit_telemetry(:verify_credential, start_time, %{success: true})
        {:ok, parsed}
      else
        {:error, reason} = error ->
          emit_telemetry(:verify_credential, start_time, %{success: false})
          Logger.warning("Credential verification failed: #{inspect(reason)}")
          error
      end

    new_state =
      case result do
        {:ok, _} ->
          %{state | credentials_verified: state.credentials_verified + 1}

        {:error, reason} ->
          %{state | errors: [{DateTime.utc_now(), :verify_credential, reason} | Enum.take(state.errors, 99)]}
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:create_presentation, holder_doc_json, credential_jwts_json, challenge, expires_in_seconds}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, json} <- call_nif(:create_presentation, [holder_doc_json, credential_jwts_json, challenge, expires_in_seconds]),
           {:ok, parsed} <- Jason.decode(json) do
        emit_telemetry(:create_presentation, start_time, %{success: true})
        {:ok, parsed}
      else
        {:error, reason} = error ->
          emit_telemetry(:create_presentation, start_time, %{success: false})
          Logger.warning("Presentation creation failed: #{inspect(reason)}")
          error
      end

    new_state =
      case result do
        {:ok, _} ->
          %{state | presentations_created: state.presentations_created + 1}

        {:error, reason} ->
          %{state | errors: [{DateTime.utc_now(), :create_presentation, reason} | Enum.take(state.errors, 99)]}
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:verify_presentation, presentation_jwt, holder_doc_json, issuer_docs_json, challenge}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, json} <- call_nif(:verify_presentation, [presentation_jwt, holder_doc_json, issuer_docs_json, challenge]),
           {:ok, parsed} <- Jason.decode(json) do
        emit_telemetry(:verify_presentation, start_time, %{success: true})
        {:ok, parsed}
      else
        {:error, reason} = error ->
          emit_telemetry(:verify_presentation, start_time, %{success: false})
          Logger.warning("Presentation verification failed: #{inspect(reason)}")
          error
      end

    new_state =
      case result do
        {:ok, _} ->
          %{state | presentations_verified: state.presentations_verified + 1}

        {:error, reason} ->
          %{state | errors: [{DateTime.utc_now(), :verify_presentation, reason} | Enum.take(state.errors, 99)]}
      end

    {:reply, result, new_state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp call_nif(function, args) do
    case apply(@nif_module, function, args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:ok, other}
    end
  catch
    :error, :badarg -> {:error, :badarg}
    kind, reason ->
      Logger.error("NIF call #{function} failed: #{kind} - #{inspect(reason)}")
      {:error, {kind, reason}}
  end

  defp emit_telemetry(operation, start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:iota_service, :credential, operation],
      %{duration: duration},
      metadata
    )
  end

  # --- Server DID management ------------------------------------------------

  defp load_server_identity do
    if Application.get_env(:iota_service, :start_repo, true) do
      case IotaService.Store.CredentialStore.get_server_identity() do
        {:ok, identity} -> identity
        :not_found -> nil
      end
    else
      nil
    end
  rescue
    e ->
      Logger.warning("Could not load server identity from MongoDB: #{Exception.message(e)}")
      nil
  end

  defp do_provision_server_did(opts) do
    secret_key =
      Keyword.get_lazy(opts, :secret_key, fn ->
        Application.get_env(:iota_service, :secret_key)
      end)

    unless secret_key && secret_key != "" do
      {:error, "secret_key is required to provision server DID"}
    else
      publish_opts =
        [secret_key: secret_key]
        |> maybe_put(:node_url, Keyword.get(opts, :node_url) || Application.get_env(:iota_service, :node_url))
        |> maybe_put(:identity_pkg_id, Keyword.get(opts, :identity_pkg_id) || Application.get_env(:iota_service, :identity_pkg_id))

      case IotaService.Identity.Server.publish_did(publish_opts) do
        {:ok, did_result} ->
          identity = %{
            did: did_result.did,
            document: did_result.document,
            verification_method_fragment: did_result.verification_method_fragment,
            network: did_result.network,
            published_at: DateTime.utc_now()
          }

          if Application.get_env(:iota_service, :start_repo, true) do
            IotaService.Store.CredentialStore.store_server_identity(identity)
          end

          {:ok, identity}

        {:error, _} = error ->
          error
      end
    end
  end

  defp record_credential_metadata(parsed, holder_did, credential_type, claims) do
    if Application.get_env(:iota_service, :start_repo, true) do
      meta = %{
        credential_id: generate_credential_id(),
        issuer_did: parsed["issuer_did"],
        holder_did: holder_did,
        credential_type: credential_type,
        claims_summary: summarize_claims(claims)
      }

      IotaService.Store.CredentialStore.record_issued_credential(meta)
    end
  rescue
    e ->
      Logger.warning("Failed to record credential metadata: #{Exception.message(e)}")
  end

  defp generate_credential_id do
    "cred_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end

  defp summarize_claims(claims) when is_map(claims) do
    claims
    |> Map.take(["role", "email", "type", :role, :email, :type])
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Jason.encode!()
  end

  defp summarize_claims(_), do: "{}"

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put_new(opts, key, value)
end
