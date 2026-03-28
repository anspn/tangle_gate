defmodule TangleGateAgent.NIF.Loader do
  @moduledoc """
  NIF Loader GenServer for the TangleGate Agent.

  Ensures the IOTA NIF library is loaded before any verification services start.
  Only loads the credential and DID NIFs (notarization NIF is not needed).
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ready?() :: boolean()
  def ready? do
    GenServer.call(__MODULE__, :ready?)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(_opts) do
    Logger.info("Loading IOTA NIF library (agent)...")

    case load_and_verify_nif() do
      :ok ->
        Logger.info("IOTA NIF library loaded successfully (agent)")
        {:ok, %{loaded_at: DateTime.utc_now(), status: :ready}}

      {:error, reason} ->
        Logger.error("Failed to load IOTA NIF (agent): #{inspect(reason)}")
        {:stop, {:nif_load_failed, reason}}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.status == :ready, state}
  end

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
      false = :iota_did_nif.is_valid_iota_did("not_a_did")
      true = is_atom(:iota_credential_nif.module_info(:module))
      :ok
    catch
      :error, :undef -> {:error, :nif_not_loaded}
      :error, reason -> {:error, {:verification_failed, reason}}
    end
  end
end
