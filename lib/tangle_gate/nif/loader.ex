defmodule TangleGate.NIF.Loader do
  @moduledoc """
  NIF Loader GenServer

  Ensures the IOTA NIF library is loaded before any other services start.
  Acts as a gate in the supervision tree - if NIF loading fails,
  downstream services won't start.

  The NIF exposes three public Erlang modules:
  - `:iota_did_nif` — DID operations (local + ledger)
  - `:iota_notarization_nif` — Notarization operations (local + ledger)
  - `:iota_credential_nif` — Verifiable Credential & Presentation operations
  """

  use GenServer

  require Logger

  @nif_modules [:iota_did_nif, :iota_notarization_nif, :iota_credential_nif]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ready?() :: boolean()
  def ready? do
    GenServer.call(__MODULE__, :ready?)
  catch
    :exit, _ -> false
  end

  @spec info() :: map()
  def info do
    GenServer.call(__MODULE__, :info)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Loading IOTA NIF library...")

    case load_and_verify_nif() do
      :ok ->
        Logger.info("IOTA NIF library loaded successfully")
        {:ok, %{loaded_at: DateTime.utc_now(), status: :ready}}

      {:error, reason} ->
        Logger.error("Failed to load IOTA NIF: #{inspect(reason)}")
        {:stop, {:nif_load_failed, reason}}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.status == :ready, state}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      status: state.status,
      loaded_at: state.loaded_at,
      nif_modules: @nif_modules,
      available_functions: list_all_nif_functions()
    }

    {:reply, info, state}
  end

  # Private Functions

  defp load_and_verify_nif do
    with :ok <- ensure_application_started(),
         :ok <- verify_nif_functions() do
      :ok
    end
  end

  defp ensure_application_started do
    case Application.ensure_all_started(:iota_nif) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, {:app_start_failed, reason}}
    end
  end

  defp verify_nif_functions do
    try do
      # Verify identity NIF is loaded
      false = :iota_did_nif.is_valid_iota_did("not_a_did")
      # Verify notarization NIF is loaded
      true = is_binary(:iota_notarization_nif.hash_data("test"))
      # Verify credential NIF is loaded
      true = is_atom(:iota_credential_nif.module_info(:module))
      :ok
    catch
      :error, :undef -> {:error, :nif_not_loaded}
      :error, reason -> {:error, {:verification_failed, reason}}
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp list_all_nif_functions do
    Enum.flat_map(@nif_modules, fn mod ->
      list_nif_functions(mod)
    end)
  end

  defp list_nif_functions(module) do
    try do
      module.module_info(:exports)
      |> Enum.reject(fn {name, _arity} -> name in [:module_info] end)
      |> Enum.map(fn {name, arity} -> "#{module}.#{name}/#{arity}" end)
    catch
      _, _ -> []
    end
  end
end
