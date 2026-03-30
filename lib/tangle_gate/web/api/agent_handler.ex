defmodule TangleGate.Web.API.AgentHandler do
  @moduledoc """
  Agent management API handler (admin-only).

  Provides endpoints for monitoring and configuring the agent client.

  ## Endpoints

  - `GET  /api/agent/status`  — Get agent connection status and health
  - `GET  /api/agent/config`  — Get current agent client configuration
  - `POST /api/agent/config`  — Update agent client configuration at runtime
  """

  use Plug.Router

  alias TangleGate.Web.API.Helpers
  alias TangleGate.Web.Plugs.Authenticate

  plug(:match)
  plug(Authenticate)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # GET /api/agent/status — Agent connection status
  # ---------------------------------------------------------------------------
  get "/status" do
    user = conn.assigns[:current_user]

    unless user.role == "admin" do
      Helpers.json(conn, 403, %{error: "forbidden", message: "Admin only"})
    else
      agent_reachable = TangleGate.Agent.Client.healthy?()

      ws_connected = TangleGate.Web.WS.AgentRegistry.any_connected?()
      ws_count = TangleGate.Web.WS.AgentRegistry.count()

      Helpers.json(conn, 200, %{
        agent_reachable: agent_reachable,
        ws_connected: ws_connected,
        ws_agent_count: ws_count,
        timestamp: DateTime.utc_now()
      })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/agent/config — Current agent client config
  # ---------------------------------------------------------------------------
  get "/config" do
    user = conn.assigns[:current_user]

    unless user.role == "admin" do
      Helpers.json(conn, 403, %{error: "forbidden", message: "Admin only"})
    else
      config = Application.get_env(:tangle_gate, TangleGate.Agent.Client, [])

      Helpers.json(conn, 200, %{
        url: Keyword.get(config, :url, "http://localhost:8800"),
        ws_url: Keyword.get(config, :ws_url, "ws://localhost:4000/ws/agent"),
        api_key: mask_key(Keyword.get(config, :api_key, "")),
        timeout: Keyword.get(config, :timeout, 30_000)
      })
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/agent/config — Update agent client config at runtime
  # ---------------------------------------------------------------------------
  post "/config" do
    user = conn.assigns[:current_user]

    unless user.role == "admin" do
      Helpers.json(conn, 403, %{error: "forbidden", message: "Admin only"})
    else
      params = conn.body_params || %{}
      current = Application.get_env(:tangle_gate, TangleGate.Agent.Client, [])

      updated =
        current
        |> maybe_update(:url, params["url"])
        |> maybe_update(:ws_url, params["ws_url"])
        |> maybe_update(:api_key, params["api_key"])
        |> maybe_update_int(:timeout, params["timeout"])

      Application.put_env(:tangle_gate, TangleGate.Agent.Client, updated)

      Helpers.json(conn, 200, %{
        message: "Agent client configuration updated",
        url: Keyword.get(updated, :url, "http://localhost:8800"),
        ws_url: Keyword.get(updated, :ws_url, "ws://localhost:4000/ws/agent"),
        api_key: mask_key(Keyword.get(updated, :api_key, "")),
        timeout: Keyword.get(updated, :timeout, 30_000)
      })
    end
  end

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Agent route not found"})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp mask_key(key) when is_binary(key) and byte_size(key) > 8 do
    String.slice(key, 0, 4) <> String.duplicate("*", byte_size(key) - 8) <> String.slice(key, -4, 4)
  end

  defp mask_key(key) when is_binary(key), do: String.duplicate("*", byte_size(key))
  defp mask_key(_), do: ""

  defp maybe_update(kw, key, value) when is_binary(value) and value != "" do
    Keyword.put(kw, key, value)
  end

  defp maybe_update(kw, _key, _value), do: kw

  defp maybe_update_int(kw, key, value) when is_integer(value) and value > 0 do
    Keyword.put(kw, key, value)
  end

  defp maybe_update_int(kw, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> Keyword.put(kw, key, int)
      _ -> kw
    end
  end

  defp maybe_update_int(kw, _key, _value), do: kw
end
