defmodule IotaService.Notarization.Server do
  @moduledoc """
  GenServer for data notarization operations.

  Supports both local payload creation/verification and on-chain notarization
  CRUD via the IOTA Rebased ledger (MoveVM) using the official IOTA
  notarization library.

  ## Local operations (no network required)
  - `hash_data/1` — SHA-256 hash
  - `create_payload/2` — Create timestamped notarization payload
  - `verify_payload/1` — Verify a notarization payload
  - `valid_hex?/1` — Validate hex format

  ## Ledger operations (require IOTA node + notarization package)
  - `create_on_chain/2` — Create a locked (immutable) notarization
  - `create_dynamic_on_chain/2` — Create a dynamic (updatable) notarization
  - `read_on_chain/2` — Read a notarization from the ledger
  - `update_on_chain/3` — Update a dynamic notarization's state
  - `destroy_on_chain/2` — Destroy a notarization
  """

  use GenServer

  require Logger

  @nif_module :iota_notarization_nif

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec hash_data(binary()) :: String.t()
  def hash_data(data) when is_binary(data) do
    GenServer.call(__MODULE__, {:hash_data, data})
  end

  @spec create_payload(binary(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_payload(data, tag \\ "iota_service") when is_binary(data) and is_binary(tag) do
    GenServer.call(__MODULE__, {:create_payload, data, tag})
  end

  @spec verify_payload(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_payload(payload_hex) when is_binary(payload_hex) do
    GenServer.call(__MODULE__, {:verify_payload, payload_hex})
  end

  @spec valid_hex?(String.t()) :: boolean()
  def valid_hex?(input) when is_binary(input) do
    GenServer.call(__MODULE__, {:valid_hex?, input})
  end

  @doc """
  Create a locked (immutable) notarization on the IOTA Rebased ledger.

  ## Options
  - `:secret_key` - (required) Ed25519 private key
  - `:state_data` - (required) Data to notarize (e.g., a document hash)
  - `:description` - Immutable description label (default: "")
  - `:node_url` - URL of the IOTA node (default: from app config)
  - `:notarize_pkg_id` - ObjectID of the notarization Move package (default: from app config)
  - `:timeout` - GenServer call timeout in ms (default: 60_000)
  """
  @spec create_on_chain(keyword()) :: {:ok, map()} | {:error, term()}
  def create_on_chain(opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(__MODULE__, {:create_on_chain, opts}, timeout)
  end

  @doc """
  Create a dynamic (updatable) notarization on the IOTA Rebased ledger.

  Same options as `create_on_chain/1`.
  """
  @spec create_dynamic_on_chain(keyword()) :: {:ok, map()} | {:error, term()}
  def create_dynamic_on_chain(opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(__MODULE__, {:create_dynamic_on_chain, opts}, timeout)
  end

  @doc """
  Read a notarization from the IOTA Rebased ledger by object ID.

  ## Options
  - `:node_url` - URL of the IOTA node (default: from app config)
  - `:notarize_pkg_id` - ObjectID of the notarization Move package (default: from app config)
  - `:timeout` - GenServer call timeout in ms (default: 30_000)
  """
  @spec read_on_chain(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_on_chain(object_id, opts \\ []) when is_binary(object_id) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(__MODULE__, {:read_on_chain, object_id, opts}, timeout)
  end

  @doc """
  Update the state of a dynamic notarization.

  ## Options
  - `:secret_key` - (required) Ed25519 private key
  - `:node_url` - URL of the IOTA node (default: from app config)
  - `:notarize_pkg_id` - ObjectID of the notarization Move package (default: from app config)
  - `:timeout` - GenServer call timeout in ms (default: 60_000)
  """
  @spec update_on_chain(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_on_chain(object_id, new_state_data, opts \\ [])
      when is_binary(object_id) and is_binary(new_state_data) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(__MODULE__, {:update_on_chain, object_id, new_state_data, opts}, timeout)
  end

  @doc """
  Destroy a notarization on the ledger.

  ## Options
  - `:secret_key` - (required) Ed25519 private key
  - `:node_url` - URL of the IOTA node (default: from app config)
  - `:notarize_pkg_id` - ObjectID of the notarization Move package (default: from app config)
  - `:timeout` - GenServer call timeout in ms (default: 60_000)
  """
  @spec destroy_on_chain(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def destroy_on_chain(object_id, opts \\ []) when is_binary(object_id) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(__MODULE__, {:destroy_on_chain, object_id, opts}, timeout)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Notarization Server started")

    state = %{
      notarizations_created: 0,
      verifications_performed: 0,
      on_chain_created: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:hash_data, data}, _from, state) do
    result = call_nif(:hash_data, [data])
    {:reply, result, state}
  end

  @impl true
  def handle_call({:create_payload, data, tag}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with hash when is_binary(hash) <- call_nif(:hash_data, [data]),
           {:ok, payload_json} <- call_nif(:create_notarization_payload, [hash, tag]),
           {:ok, payload} <- Jason.decode(payload_json) do
        emit_telemetry(:create_payload, start_time, %{success: true})
        {:ok, payload}
      else
        {:error, _} = error ->
          emit_telemetry(:create_payload, start_time, %{success: false})
          error
      end

    new_state =
      case result do
        {:ok, _} -> %{state | notarizations_created: state.notarizations_created + 1}
        _ -> state
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:verify_payload, payload_hex}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, json} <- call_nif(:verify_notarization_payload, [payload_hex]),
           {:ok, verification} <- Jason.decode(json) do
        emit_telemetry(:verify_payload, start_time, %{success: true})
        {:ok, verification}
      else
        {:error, _} = error ->
          emit_telemetry(:verify_payload, start_time, %{success: false})
          error
      end

    new_state = %{state | verifications_performed: state.verifications_performed + 1}
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:valid_hex?, input}, _from, state) do
    result = call_nif(:is_valid_hex_string, [input])
    {:reply, result == true, state}
  end

  # -- On-chain handlers --

  @impl true
  def handle_call({:create_on_chain, opts}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, secret_key} <- require_opt(opts, :secret_key),
           {:ok, state_data} <- require_opt(opts, :state_data),
           node_url <- ledger_opt(opts, :node_url),
           notarize_pkg_id <- ledger_opt(opts, :notarize_pkg_id),
           description <- Keyword.get(opts, :description, ""),
           {:ok, json} <-
             call_nif(:create_notarization, [
               secret_key,
               node_url,
               notarize_pkg_id,
               state_data,
               description
             ]),
           {:ok, parsed} <- Jason.decode(json) do
        emit_telemetry(:create_on_chain, start_time, %{success: true, method: "locked"})
        {:ok, parsed}
      else
        {:error, reason} = error ->
          emit_telemetry(:create_on_chain, start_time, %{success: false})
          Logger.warning("On-chain notarization creation failed: #{inspect(reason)}")
          error
      end

    new_state =
      case result do
        {:ok, _} -> %{state | on_chain_created: state.on_chain_created + 1}
        _ -> state
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:create_dynamic_on_chain, opts}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, secret_key} <- require_opt(opts, :secret_key),
           {:ok, state_data} <- require_opt(opts, :state_data),
           node_url <- ledger_opt(opts, :node_url),
           notarize_pkg_id <- ledger_opt(opts, :notarize_pkg_id),
           description <- Keyword.get(opts, :description, ""),
           {:ok, json} <-
             call_nif(:create_dynamic_notarization, [
               secret_key,
               node_url,
               notarize_pkg_id,
               state_data,
               description
             ]),
           {:ok, parsed} <- Jason.decode(json) do
        emit_telemetry(:create_on_chain, start_time, %{success: true, method: "dynamic"})
        {:ok, parsed}
      else
        {:error, reason} = error ->
          emit_telemetry(:create_on_chain, start_time, %{success: false})
          Logger.warning("On-chain dynamic notarization creation failed: #{inspect(reason)}")
          error
      end

    new_state =
      case result do
        {:ok, _} -> %{state | on_chain_created: state.on_chain_created + 1}
        _ -> state
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:read_on_chain, object_id, opts}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with node_url <- ledger_opt(opts, :node_url),
           notarize_pkg_id <- ledger_opt(opts, :notarize_pkg_id),
           {:ok, json} <- call_nif(:read_notarization, [node_url, object_id, notarize_pkg_id]),
           {:ok, parsed} <- Jason.decode(json) do
        emit_telemetry(:read_on_chain, start_time, %{success: true})
        {:ok, parsed}
      else
        {:error, reason} = error ->
          emit_telemetry(:read_on_chain, start_time, %{success: false})
          Logger.warning("On-chain notarization read failed: #{inspect(reason)}")
          error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:update_on_chain, object_id, new_state_data, opts}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, secret_key} <- require_opt(opts, :secret_key),
           node_url <- ledger_opt(opts, :node_url),
           notarize_pkg_id <- ledger_opt(opts, :notarize_pkg_id),
           {:ok, json} <-
             call_nif(:update_notarization_state, [
               secret_key,
               node_url,
               notarize_pkg_id,
               object_id,
               new_state_data
             ]),
           {:ok, parsed} <- Jason.decode(json) do
        emit_telemetry(:update_on_chain, start_time, %{success: true})
        {:ok, parsed}
      else
        {:error, reason} = error ->
          emit_telemetry(:update_on_chain, start_time, %{success: false})
          Logger.warning("On-chain notarization update failed: #{inspect(reason)}")
          error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:destroy_on_chain, object_id, opts}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, secret_key} <- require_opt(opts, :secret_key),
           node_url <- ledger_opt(opts, :node_url),
           notarize_pkg_id <- ledger_opt(opts, :notarize_pkg_id),
           {:ok, json} <-
             call_nif(:destroy_notarization, [secret_key, node_url, notarize_pkg_id, object_id]),
           {:ok, parsed} <- Jason.decode(json) do
        emit_telemetry(:destroy_on_chain, start_time, %{success: true})
        {:ok, parsed}
      else
        {:error, reason} = error ->
          emit_telemetry(:destroy_on_chain, start_time, %{success: false})
          Logger.warning("On-chain notarization destroy failed: #{inspect(reason)}")
          error
      end

    {:reply, result, state}
  end

  # Private Functions

  defp require_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_option, key}}
    end
  end

  defp ledger_opt(opts, key) do
    Keyword.get_lazy(opts, key, fn ->
      case key do
        :node_url ->
          Application.get_env(:iota_service, :node_url, "https://api.testnet.iota.cafe")

        :notarize_pkg_id ->
          Application.get_env(:iota_service, :notarize_pkg_id, "")
      end
    end)
  end

  defp call_nif(function, args) do
    try do
      case apply(@nif_module, function, args) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
        result when is_binary(result) -> result
        result when is_boolean(result) -> result
        other -> {:ok, other}
      end
    rescue
      e ->
        Logger.error("NIF call #{function} raised: #{inspect(e)}")
        {:error, {:nif_exception, e}}
    catch
      kind, reason ->
        Logger.error("NIF call #{function} failed: #{kind} - #{inspect(reason)}")
        {:error, {kind, reason}}
    end
  end

  defp emit_telemetry(operation, start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:iota_service, :notarization, operation],
      %{duration: duration},
      metadata
    )
  end
end
