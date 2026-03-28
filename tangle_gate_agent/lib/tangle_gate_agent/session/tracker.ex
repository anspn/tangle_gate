defmodule TangleGateAgent.Session.Tracker do
  @moduledoc """
  ETS-backed session tracker.

  Maintains a mapping of active sessions received from tangle_gate over WebSocket.
  Used by the Terminator to find and kill sessions on the host.
  """

  use GenServer

  require Logger

  @table :agent_sessions

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec track_session(String.t(), map()) :: :ok
  def track_session(session_id, info) when is_binary(session_id) and is_map(info) do
    GenServer.cast(__MODULE__, {:track, session_id, info})
  end

  @spec untrack_session(String.t()) :: :ok
  def untrack_session(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:untrack, session_id})
  end

  @spec get_session(String.t()) :: {:ok, map()} | :not_found
  def get_session(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, info}] -> {:ok, info}
      [] -> :not_found
    end
  end

  @spec list_sessions() :: [{String.t(), map()}]
  def list_sessions do
    :ets.tab2list(@table)
  end

  @spec session_count() :: non_neg_integer()
  def session_count do
    :ets.info(@table, :size)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Logger.info("Session tracker started")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:track, session_id, info}, state) do
    :ets.insert(@table, {session_id, info})
    Logger.debug("Tracking session: #{session_id}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:untrack, session_id}, state) do
    :ets.delete(@table, session_id)
    Logger.debug("Untracking session: #{session_id}")
    {:noreply, state}
  end
end
