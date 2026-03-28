defmodule TangleGateAgent.WS.Client do
  @moduledoc """
  WebSocket client that maintains a persistent connection to the tangle_gate
  application server.

  Receives session lifecycle events (session_started, terminate_session) and
  sends back termination results.

  Uses exponential backoff for reconnection.
  """

  use WebSockex

  require Logger

  @default_reconnect_min 1_000
  @default_reconnect_max 30_000

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    config = Application.get_env(:tangle_gate_agent, __MODULE__, [])

    if Keyword.get(config, :autostart, true) do
      url = Keyword.get(config, :url, "ws://localhost:4000/ws/agent")
      api_key = Keyword.get(config, :api_key, "dev-agent-key")
      ws_url = append_api_key(url, api_key)

      state = %{
        url: url,
        api_key: api_key,
        reconnect_attempts: 0,
        reconnect_min: Keyword.get(config, :reconnect_min_ms, @default_reconnect_min),
        reconnect_max: Keyword.get(config, :reconnect_max_ms, @default_reconnect_max),
        connected: false
      }

      WebSockex.start_link(ws_url, __MODULE__, state,
        name: __MODULE__,
        handle_initial_conn_failure: true,
        extra_headers: opts[:extra_headers] || []
      )
    else
      :ignore
    end
  end

  @spec connected?() :: boolean()
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid) and get_state_connected(pid)
    end
  end

  @spec send_message(map()) :: :ok | {:error, term()}
  def send_message(message) when is_map(message) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_connected}

      _pid ->
        json = Jason.encode!(message)
        WebSockex.send_frame(__MODULE__, {:text, json})
    end
  end

  # ============================================================================
  # WebSockex Callbacks
  # ============================================================================

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Agent WebSocket connected to tangle_gate")

    # Send "connected" message after init completes (handle_connect must return {:ok, state})
    send(self(), :send_connected)

    {:ok, %{state | connected: true, reconnect_attempts: 0}}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, payload} ->
        handle_message(payload, state)

      {:error, _} ->
        Logger.warning("Agent WS received non-JSON message: #{inspect(msg)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("Agent WebSocket disconnected: #{inspect(reason)}")
    new_state = %{state | connected: false, reconnect_attempts: state.reconnect_attempts + 1}
    delay = backoff_delay(new_state)
    Logger.info("Reconnecting in #{delay}ms (attempt #{new_state.reconnect_attempts})")
    Process.send_after(self(), :reconnect, delay)
    {:ok, new_state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:reconnect, state}
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

    {:reply, {:text, connected_msg}, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("Agent WebSocket terminating: #{inspect(reason)}")
    :ok
  end

  # ============================================================================
  # Message Handlers
  # ============================================================================

  defp handle_message(%{"type" => "ping"}, state) do
    {:reply, {:text, Jason.encode!(%{type: "pong"})}, state}
  end

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

    # Run termination asynchronously to not block the WS
    Task.start(fn ->
      result = TangleGateAgent.Session.Terminator.terminate(session_id)

      response = %{
        type: "session_terminated",
        session_id: session_id,
        success: match?({:ok, _}, result),
        detail: format_result(result)
      }

      send_message(response)
    end)

    {:ok, state}
  end

  defp handle_message(%{"type" => "session_ended"} = msg, state) do
    session_id = msg["session_id"]
    Logger.debug("Session ended: #{session_id}")
    TangleGateAgent.Session.Tracker.untrack_session(session_id)
    {:ok, state}
  end

  defp handle_message(msg, state) do
    Logger.debug("Agent WS received unknown message type: #{inspect(msg["type"])}")
    {:ok, state}
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp append_api_key(url, api_key) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    "#{url}#{separator}api_key=#{URI.encode_www_form(api_key)}"
  end

  defp backoff_delay(%{
         reconnect_attempts: attempts,
         reconnect_min: min_ms,
         reconnect_max: max_ms
       }) do
    # Exponential backoff with jitter
    base = min(min_ms * :math.pow(2, attempts), max_ms)
    jitter = :rand.uniform(round(max(base * 0.1, 1)))
    round(base) + jitter
  end

  defp get_state_connected(pid) do
    try do
      # WebSockex doesn't expose state directly, we track it via the process
      Process.alive?(pid)
    catch
      _, _ -> false
    end
  end

  defp format_result({:ok, detail}), do: detail
  defp format_result({:error, reason}), do: inspect(reason)
end
