defmodule TangleGate.Agent.WS do
  @moduledoc """
  WebSocket client that maintains a persistent connection to the tangle_gate_agent
  microservice.

  Sends session lifecycle events (session_started, terminate_session, session_ended)
  and receives termination results and capability announcements.

  Uses exponential backoff for reconnection.

  ## Configuration

      config :tangle_gate, TangleGate.Agent.Client,
        url: "http://localhost:8800",   # HTTP base URL — WS path is derived
        api_key: "shared-secret",
        timeout: 30_000,
        ws_reconnect_min_ms: 1_000,
        ws_reconnect_max_ms: 30_000
  """

  use WebSockex

  require Logger

  @default_reconnect_min 1_000
  @default_reconnect_max 30_000
  @ping_timeout 3_000

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    config = Application.get_env(:tangle_gate, TangleGate.Agent.Client, [])

    if Keyword.get(config, :ws_autostart, true) do
      http_url = Keyword.get(config, :url, "http://localhost:8800")
      api_key = Keyword.get(config, :api_key, "")
      connect_url = derive_ws_url(http_url, api_key)

      # Try to discover the agent-advertised WS URL from health check
      advertised_ws_url =
        case TangleGate.Agent.Client.discover_ws_url() do
          {:ok, url} -> url
          _ -> nil
        end

      state = %{
        http_url: http_url,
        api_key: api_key,
        reconnect_attempts: 0,
        reconnect_min: Keyword.get(config, :ws_reconnect_min_ms, @default_reconnect_min),
        reconnect_max: Keyword.get(config, :ws_reconnect_max_ms, @default_reconnect_max),
        connected: false,
        agent_info: nil,
        advertised_ws_url: advertised_ws_url,
        ping_caller: nil
      }

      WebSockex.start_link(connect_url, __MODULE__, state,
        name: __MODULE__,
        handle_initial_conn_failure: true,
        extra_headers: opts[:extra_headers] || []
      )
    else
      :ignore
    end
  end

  @doc """
  Actively check if the WebSocket connection is alive by sending a ping
  and waiting for a pong response. Returns true only if the round-trip
  completes within #{@ping_timeout}ms.
  """
  @spec connected?() :: boolean()
  def connected? do
    case Process.whereis(__MODULE__) do
      nil ->
        false

      pid ->
        ref = make_ref()
        send(pid, {:ws_ping, self(), ref})

        receive do
          {:ws_pong, ^ref} -> true
        after
          @ping_timeout -> false
        end
    end
  end

  @doc "Get the agent-advertised WebSocket URL, falling back to derived URL."
  @spec ws_url() :: String.t() | nil
  def ws_url do
    case Process.whereis(__MODULE__) do
      nil -> derive_ws_url_from_config()
      _pid -> GenServer.call(__MODULE__, :get_ws_url)
    end
  catch
    :exit, _ -> derive_ws_url_from_config()
  end

  @doc "Send a JSON message to the agent over WebSocket."
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

  @doc "Notify agent that a session started."
  @spec notify_session_started(map()) :: :ok | {:error, term()}
  def notify_session_started(session_info) do
    send_message(Map.put(session_info, :type, "session_started"))
  end

  @doc "Request agent to terminate a session."
  @spec request_termination(String.t()) :: :ok | {:error, term()}
  def request_termination(session_id) do
    send_message(%{type: "terminate_session", session_id: session_id})
  end

  @doc "Notify agent that a session ended."
  @spec notify_session_ended(String.t()) :: :ok | {:error, term()}
  def notify_session_ended(session_id) do
    send_message(%{type: "session_ended", session_id: session_id})
  end

  @doc "Get agent info (version, capabilities) from the last connected message."
  @spec agent_info() :: map() | nil
  def agent_info do
    case Process.whereis(__MODULE__) do
      nil -> nil
      _pid -> GenServer.call(__MODULE__, :get_agent_info)
    end
  catch
    :exit, _ -> nil
  end

  # ============================================================================
  # WebSockex Callbacks
  # ============================================================================

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("WebSocket connected to agent at #{state.http_url}")

    # Discover agent-advertised WS URL on (re)connect
    advertised =
      case TangleGate.Agent.Client.discover_ws_url() do
        {:ok, url} -> url
        _ -> state.advertised_ws_url
      end

    {:ok, %{state | connected: true, reconnect_attempts: 0, advertised_ws_url: advertised}}
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

    # Notify any pending ping caller immediately
    case state.ping_caller do
      {pid, ref} when is_pid(pid) -> send(pid, {:ws_pong_error, ref})
      _ -> :ok
    end

    new_state = %{state | connected: false, reconnect_attempts: state.reconnect_attempts + 1, ping_caller: nil}
    delay = backoff_delay(new_state)
    Logger.info("Reconnecting to agent in #{delay}ms (attempt #{new_state.reconnect_attempts})")
    # Sleep for backoff before returning :reconnect — WebSockex exits the
    # process if we return {:ok, _} (especially on initial conn failure).
    Process.sleep(delay)
    {:reconnect, new_state}
  end

  @impl true
  def handle_pong(_pong_frame, %{ping_caller: {pid, ref}} = state) when is_pid(pid) do
    send(pid, {:ws_pong, ref})
    {:ok, %{state | ping_caller: nil}}
  end

  def handle_pong(_pong_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_info({:ws_ping, caller_pid, ref}, state) do
    # Send a WebSocket-level ping frame; pong is handled by handle_pong/2
    new_state = %{state | ping_caller: {caller_pid, ref}}
    {:reply, :ping, new_state}
  end

  def handle_info({:"$gen_call", from, :get_agent_info}, state) do
    GenServer.reply(from, state.agent_info)
    {:ok, state}
  end

  def handle_info({:"$gen_call", from, :get_ws_url}, state) do
    url = state.advertised_ws_url || derive_ws_url(state.http_url, state.api_key)
    GenServer.reply(from, url)
    {:ok, state}
  end

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
  # Private helpers
  # ============================================================================

  defp derive_ws_url_from_config do
    config = Application.get_env(:tangle_gate, TangleGate.Agent.Client, [])
    http_url = Keyword.get(config, :url, "http://localhost:8800")
    api_key = Keyword.get(config, :api_key, "")
    derive_ws_url(http_url, api_key)
  end

  defp derive_ws_url(http_url, api_key) do
    # Convert http(s)://host:port to ws(s)://host:port/ws/events?api_key=...
    ws_url =
      http_url
      |> String.replace_leading("https://", "wss://")
      |> String.replace_leading("http://", "ws://")
      |> String.trim_trailing("/")

    ws_url = "#{ws_url}/ws/events"

    if api_key != "" do
      "#{ws_url}?api_key=#{URI.encode_www_form(api_key)}"
    else
      ws_url
    end
  end

  defp backoff_delay(%{
         reconnect_attempts: attempts,
         reconnect_min: min_ms,
         reconnect_max: max_ms
       }) do
    base = min(min_ms * :math.pow(2, attempts), max_ms)
    jitter = :rand.uniform(round(max(base * 0.1, 1)))
    round(base) + jitter
  end
end
