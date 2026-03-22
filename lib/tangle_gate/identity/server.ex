defmodule TangleGate.Identity.Server do
  @moduledoc """
  GenServer for DID (Decentralized Identifier) operations.

  Supports both local DID generation and on-chain publishing/resolution
  via the IOTA Rebased ledger (MoveVM).

  ## Local operations (no network required)
  - `generate_did/1` — Generate a DID locally (placeholder tag)
  - `valid_did?/1` — Validate DID format
  - `extract_did/1` — Extract DID from a document JSON
  - `create_did_url/2` — Create a DID URL with fragment

  ## Ledger operations (require IOTA node)
  - `publish_did/1` — Create and publish a DID on-chain
  - `resolve_did/2` — Resolve a published DID from the ledger
  - `deactivate_did/2` — Permanently deactivate (revoke) a DID on-chain
  """

  use GenServer

  require Logger

  @default_network :iota
  @nif_module :iota_did_nif

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec generate_did(keyword()) :: {:ok, map()} | {:error, term()}
  def generate_did(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(__MODULE__, {:generate_did, opts}, timeout)
  end

  @doc """
  Create and publish a DID on the IOTA Rebased ledger.

  ## Options
  - `:secret_key` - Ed25519 private key (Bech32, Base64 33-byte, or Base64 32-byte)
  - `:node_url` - URL of the IOTA node (default: from app config)
  - `:identity_pkg_id` - ObjectID of the identity Move package (default: from app config, or "" for auto-discovery)
  - `:gas_coin_id` - Specific gas coin ObjectID (default: "" for auto-selection)
  - `:timeout` - GenServer call timeout in ms (default: 60_000)
  """
  @spec publish_did(keyword()) :: {:ok, map()} | {:error, term()}
  def publish_did(opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(__MODULE__, {:publish_did, opts}, timeout)
  end

  @doc """
  Resolve a published DID from the IOTA ledger.

  ## Options
  - `:node_url` - URL of the IOTA node (default: from app config)
  - `:identity_pkg_id` - ObjectID of the identity Move package (default: from app config, or "" for auto-discovery)
  - `:timeout` - GenServer call timeout in ms (default: 30_000)
  """
  @spec resolve_did(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_did(did, opts \\ []) when is_binary(did) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(__MODULE__, {:resolve_did, did, opts}, timeout)
  end

  @spec valid_did?(String.t()) :: boolean()
  def valid_did?(did) when is_binary(did) do
    GenServer.call(__MODULE__, {:valid_did?, did})
  end

  @spec extract_did(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract_did(document_json) when is_binary(document_json) do
    GenServer.call(__MODULE__, {:extract_did, document_json})
  end

  @spec create_did_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_did_url(did, fragment) when is_binary(did) and is_binary(fragment) do
    GenServer.call(__MODULE__, {:create_did_url, did, fragment})
  end

  @doc """
  Permanently deactivate (revoke) a DID on the IOTA Rebased ledger.

  **Warning**: This operation is irreversible. Once deactivated, the DID
  cannot be reactivated.

  ## Options
  - `:secret_key` - (required) Ed25519 private key of a DID controller
  - `:node_url` - URL of the IOTA node (default: from app config)
  - `:identity_pkg_id` - ObjectID of the identity Move package (default: from app config, or "" for auto-discovery)
  - `:timeout` - GenServer call timeout in ms (default: 60_000)
  """
  @spec deactivate_did(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def deactivate_did(did, opts) when is_binary(did) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(__MODULE__, {:deactivate_did, did, opts}, timeout)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Identity Server started")

    state = %{
      generated_count: 0,
      published_count: 0,
      last_generation: nil,
      errors: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:generate_did, opts}, _from, state) do
    network = Keyword.get(opts, :network, @default_network)

    start_time = System.monotonic_time()

    result =
      with {:ok, network_str} <- validate_network(network),
           {:ok, json} <- call_nif(:generate_did, [network_str]),
           {:ok, parsed} <- Jason.decode(json) do
        did_result = %{
          did: parsed["did"],
          document: parsed["document"],
          verification_method_fragment: parsed["verification_method_fragment"],
          private_key_jwk: parsed["private_key_jwk"],
          network: network,
          generated_at: DateTime.utc_now()
        }

        emit_telemetry(:generate_did, start_time, %{network: network, success: true})
        {:ok, did_result}
      else
        {:error, reason} = error ->
          emit_telemetry(:generate_did, start_time, %{network: network, success: false})
          Logger.warning("DID generation failed: #{inspect(reason)}")
          error
      end

    new_state =
      case result do
        {:ok, _} ->
          %{
            state
            | generated_count: state.generated_count + 1,
              last_generation: DateTime.utc_now()
          }

        {:error, reason} ->
          %{state | errors: [{DateTime.utc_now(), reason} | Enum.take(state.errors, 99)]}
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:publish_did, opts}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, secret_key} <- require_opt(opts, :secret_key),
           node_url <- ledger_opt(opts, :node_url),
           identity_pkg_id <- ledger_opt(opts, :identity_pkg_id, ""),
           gas_coin_id <- Keyword.get(opts, :gas_coin_id, ""),
           {:ok, json} <-
             call_nif(:create_and_publish_did, [
               secret_key,
               node_url,
               identity_pkg_id,
               gas_coin_id
             ]),
           {:ok, parsed} <- Jason.decode(json) do
        did_result = %{
          did: parsed["did"],
          document: parsed["document"],
          verification_method_fragment: parsed["verification_method_fragment"],
          private_key_jwk: parsed["private_key_jwk"],
          network: parsed["network"],
          sender_address: parsed["sender_address"],
          published_at: DateTime.utc_now()
        }

        emit_telemetry(:publish_did, start_time, %{success: true})
        {:ok, did_result}
      else
        {:error, reason} = error ->
          emit_telemetry(:publish_did, start_time, %{success: false})
          Logger.warning("DID publishing failed: #{inspect(reason)}")
          error
      end

    new_state =
      case result do
        {:ok, _} ->
          %{
            state
            | published_count: state.published_count + 1,
              last_generation: DateTime.utc_now()
          }

        {:error, reason} ->
          %{state | errors: [{DateTime.utc_now(), reason} | Enum.take(state.errors, 99)]}
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:resolve_did, did, opts}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with node_url <- ledger_opt(opts, :node_url),
           identity_pkg_id <- ledger_opt(opts, :identity_pkg_id, ""),
           {:ok, json} <- call_nif(:resolve_did, [did, node_url, identity_pkg_id]),
           {:ok, parsed} <- Jason.decode(json) do
        emit_telemetry(:resolve_did, start_time, %{success: true})
        {:ok, parsed}
      else
        {:error, reason} = error ->
          emit_telemetry(:resolve_did, start_time, %{success: false})
          Logger.warning("DID resolution failed: #{inspect(reason)}")
          error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:deactivate_did, did, opts}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, secret_key} <- require_opt(opts, :secret_key),
           node_url <- ledger_opt(opts, :node_url),
           identity_pkg_id <- ledger_opt(opts, :identity_pkg_id, "") do
        case call_nif(:deactivate_did, [secret_key, did, node_url, identity_pkg_id]) do
          {:ok, _} ->
            emit_telemetry(:deactivate_did, start_time, %{success: true})
            {:ok, "deactivated"}

          {:error, reason} = error ->
            emit_telemetry(:deactivate_did, start_time, %{success: false})
            Logger.warning("DID deactivation failed: #{inspect(reason)}")
            error
        end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:valid_did?, did}, _from, state) do
    result = call_nif(:is_valid_iota_did, [did])
    {:reply, result == {:ok, true}, state}
  end

  @impl true
  def handle_call({:extract_did, document_json}, _from, state) do
    result = call_nif(:extract_did_from_document, [document_json])
    {:reply, result, state}
  end

  @impl true
  def handle_call({:create_did_url, did, fragment}, _from, state) do
    result = call_nif(:create_did_url, [did, fragment])
    {:reply, result, state}
  end

  # Private Functions

  defp validate_network(network) when network in [:iota, :smr, :rms, :atoi] do
    {:ok, Atom.to_string(network)}
  end

  defp validate_network(network)
       when is_binary(network) and network in ["iota", "smr", "rms", "atoi"] do
    {:ok, network}
  end

  defp validate_network(network) do
    {:error, {:invalid_network, network}}
  end

  defp require_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_option, key}}
    end
  end

  defp ledger_opt(opts, key, default \\ nil) do
    Keyword.get_lazy(opts, key, fn ->
      case key do
        :node_url ->
          Application.get_env(
            :tangle_gate,
            :node_url,
            default || "https://api.testnet.iota.cafe"
          )

        :identity_pkg_id ->
          Application.get_env(:tangle_gate, :identity_pkg_id, default || "")
      end
    end)
  end

  defp call_nif(function, args) do
    case apply(@nif_module, function, args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      true -> {:ok, true}
      false -> {:ok, false}
      other -> {:ok, other}
    end
  catch
    :error, :badarg ->
      {:error, :badarg}

    kind, reason ->
      Logger.error("NIF call #{function} failed: #{kind} - #{inspect(reason)}")
      {:error, {kind, reason}}
  end

  defp emit_telemetry(operation, start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:tangle_gate, :identity, operation],
      %{duration: duration},
      metadata
    )
  end
end
