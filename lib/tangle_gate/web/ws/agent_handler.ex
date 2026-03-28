defmodule TangleGate.Web.WS.AgentHandler do
  @moduledoc """
  WebSocket handler for agent connections.

  Implements the `WebSock` behaviour (used by Bandit natively).
  Agents connect to `/ws/agent?api_key=<key>` and receive session
  lifecycle events.

  ## Inbound messages (from agent)
  - `{"type": "connected", "agent_version": "...", "capabilities": [...]}`
  - `{"type": "session_terminated", "session_id": "...", "success": true, "detail": "..."}`
  - `{"type": "pong"}`

  ## Outbound messages (to agent)
  - `{"type": "session_started", "session_id": "...", "user_id": "...", "did": "...", "pid_hint": <int|null>}`
  - `{"type": "terminate_session", "session_id": "..."}`
  - `{"type": "session_ended", "session_id": "..."}`
  - `{"type": "ping"}`
  """

  require Logger

  @behaviour WebSock

  @ping_interval 30_000

  # ============================================================================
  # WebSock Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    TangleGate.Web.WS.AgentRegistry.register(self())
    schedule_ping()
    Logger.info("Agent WebSocket handler initialized")
    {:ok, %{authenticated: true, opts: opts, agent_info: nil}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, payload} ->
        handle_message(payload, state)

      {:error, _} ->
        Logger.warning("Agent WS: received non-JSON text")
        {:ok, state}
    end
  end

  @impl true
  def handle_in(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_info({:broadcast, json}, state) do
    {:push, {:text, json}, state}
  end

  @impl true
  def handle_info(:send_ping, state) do
    schedule_ping()
    {:push, {:text, Jason.encode!(%{type: "ping"})}, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(reason, _state) do
    TangleGate.Web.WS.AgentRegistry.unregister(self())
    Logger.info("Agent WebSocket handler terminated: #{inspect(reason)}")
    :ok
  end

  # ============================================================================
  # Message Handlers
  # ============================================================================

  defp handle_message(%{"type" => "connected"} = msg, state) do
    agent_info = %{
      version: msg["agent_version"],
      capabilities: msg["capabilities"] || []
    }

    Logger.info(
      "Agent connected: v#{agent_info.version}, capabilities: #{inspect(agent_info.capabilities)}"
    )

    {:ok, %{state | agent_info: agent_info}}
  end

  defp handle_message(%{"type" => "session_terminated"} = msg, state) do
    session_id = msg["session_id"]
    success = msg["success"]
    detail = msg["detail"]

    if success do
      Logger.info("Agent terminated session #{session_id}: #{detail}")
    else
      Logger.warning("Agent failed to terminate session #{session_id}: #{detail}")
    end

    {:ok, state}
  end

  defp handle_message(%{"type" => "pong"}, state) do
    {:ok, state}
  end

  defp handle_message(msg, state) do
    Logger.debug("Agent WS: unknown message type: #{inspect(msg["type"])}")
    {:ok, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp schedule_ping do
    Process.send_after(self(), :send_ping, @ping_interval)
  end
end
