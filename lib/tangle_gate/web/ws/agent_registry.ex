defmodule TangleGate.Web.WS.AgentRegistry do
  @moduledoc """
  Tracks connected agent WebSocket PIDs and provides broadcast/notification
  functions for sending session events to agents.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register an agent WebSocket handler PID."
  @spec register(pid()) :: :ok
  def register(pid) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:register, pid})
  end

  @doc "Unregister an agent WebSocket handler PID."
  @spec unregister(pid()) :: :ok
  def unregister(pid) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:unregister, pid})
  end

  @doc "Send a message to all connected agents."
  @spec broadcast(map()) :: :ok
  def broadcast(message) when is_map(message) do
    GenServer.cast(__MODULE__, {:broadcast, message})
  end

  @doc "Notify agents that a session started."
  @spec notify_session_started(map()) :: :ok
  def notify_session_started(session_info) do
    broadcast(Map.put(session_info, :type, "session_started"))
  end

  @doc "Request agents to terminate a session."
  @spec request_termination(String.t()) :: :ok
  def request_termination(session_id) do
    broadcast(%{type: "terminate_session", session_id: session_id})
  end

  @doc "Notify agents that a session ended."
  @spec notify_session_ended(String.t()) :: :ok
  def notify_session_ended(session_id) do
    broadcast(%{type: "session_ended", session_id: session_id})
  end

  @doc "Check if any agents are connected."
  @spec any_connected?() :: boolean()
  def any_connected? do
    GenServer.call(__MODULE__, :any_connected?)
  catch
    :exit, _ -> false
  end

  @doc "Get the number of connected agents."
  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  catch
    :exit, _ -> 0
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    {:ok, %{agents: MapSet.new()}}
  end

  @impl true
  def handle_cast({:register, pid}, state) do
    Process.monitor(pid)
    Logger.info("Agent WebSocket connected (PID: #{inspect(pid)})")
    {:noreply, %{state | agents: MapSet.put(state.agents, pid)}}
  end

  @impl true
  def handle_cast({:unregister, pid}, state) do
    Logger.info("Agent WebSocket disconnected (PID: #{inspect(pid)})")
    {:noreply, %{state | agents: MapSet.delete(state.agents, pid)}}
  end

  @impl true
  def handle_cast({:broadcast, message}, state) do
    json = Jason.encode!(message)

    for pid <- state.agents do
      send(pid, {:broadcast, json})
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:any_connected?, _from, state) do
    {:reply, MapSet.size(state.agents) > 0, state}
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, MapSet.size(state.agents), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    Logger.info("Agent WebSocket process died (PID: #{inspect(pid)})")
    {:noreply, %{state | agents: MapSet.delete(state.agents, pid)}}
  end
end
