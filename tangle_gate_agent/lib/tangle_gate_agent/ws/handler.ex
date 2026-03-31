defmodule TangleGateAgent.WS.Handler do
  @moduledoc """
  WebSocket handler for connections from the tangle_gate application.

  Implements the `WebSock` behaviour (used by Bandit natively).
  The main app connects to `/ws/events?api_key=<key>` to receive
  session lifecycle events and send termination results.

  ## Inbound messages (from tangle_gate)
  - `{"type": "session_started", "session_id": "...", "user_id": "...", "did": "...", "pid_hint": <int|null>}`
  - `{"type": "terminate_session", "session_id": "..."}`
  - `{"type": "session_ended", "session_id": "..."}`
  - `{"type": "ping"}`

  ## Outbound messages (to tangle_gate)
  - `{"type": "connected", "agent_version": "...", "capabilities": [...]}`
  - `{"type": "session_terminated", "session_id": "...", "success": true, "detail": "..."}`
  - `{"type": "pong"}`
  """

  require Logger

  @behaviour WebSock

  @ping_interval 30_000

  # ============================================================================
  # WebSock Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("tangle_gate WebSocket client connected")

    # Send capabilities on connect
    send(self(), :send_connected)
    schedule_ping()

    {:ok, %{authenticated: true}}
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
  def handle_info(:send_connected, state) do
    capabilities = TangleGateAgent.Session.Terminator.detect_capabilities()

    connected_msg =
      Jason.encode!(%{
        type: "connected",
        agent_version: Application.spec(:tangle_gate_agent, :vsn) |> to_string(),
        capabilities: capabilities
      })

    {:push, {:text, connected_msg}, state}
  end

  @impl true
  def handle_info({:send_termination_result, response}, state) do
    {:push, {:text, Jason.encode!(response)}, state}
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
    Logger.info("tangle_gate WebSocket disconnected: #{inspect(reason)}")
    :ok
  end

  # ============================================================================
  # Message Handlers
  # ============================================================================

  defp handle_message(%{"type" => "session_started"} = msg, state) do
    session_id = msg["session_id"]
    user_id = msg["user_id"]
    did = msg["did"]
    pid_hint = msg["pid_hint"]

    Logger.info("Session started: #{session_id} (user: #{user_id})")

    TangleGateAgent.Session.Tracker.track_session(session_id, %{
      user_id: user_id,
      did: did,
      pid_hint: pid_hint,
      started_at: DateTime.utc_now()
    })

    {:ok, state}
  end

  defp handle_message(%{"type" => "terminate_session"} = msg, state) do
    session_id = msg["session_id"]
    Logger.info("Received terminate command for session: #{session_id}")

    # Capture the handler PID so the async task can send the result back
    handler_pid = self()

    # Run termination asynchronously to not block the WS
    Task.start(fn ->
      result = TangleGateAgent.Session.Terminator.terminate(session_id)

      response = %{
        type: "session_terminated",
        session_id: session_id,
        success: match?({:ok, _}, result),
        detail: format_result(result)
      }

      send(handler_pid, {:send_termination_result, response})
    end)

    {:ok, state}
  end

  defp handle_message(%{"type" => "session_ended"} = msg, state) do
    session_id = msg["session_id"]
    Logger.debug("Session ended: #{session_id}")
    TangleGateAgent.Session.Tracker.untrack_session(session_id)
    {:ok, state}
  end

  defp handle_message(%{"type" => "ping"}, state) do
    {:reply, {:text, Jason.encode!(%{type: "pong"})}, state}
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

  defp format_result({:ok, detail}), do: detail
  defp format_result({:error, reason}), do: inspect(reason)
end
