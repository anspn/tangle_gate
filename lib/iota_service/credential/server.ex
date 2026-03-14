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

    state = %{
      credentials_issued: 0,
      credentials_verified: 0,
      presentations_created: 0,
      presentations_verified: 0,
      errors: []
    }

    {:ok, state}
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
end
