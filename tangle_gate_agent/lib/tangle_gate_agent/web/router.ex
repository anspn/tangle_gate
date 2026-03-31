defmodule TangleGateAgent.Web.Router do
  @moduledoc """
  Top-level HTTP router for the TangleGate Agent.

  All `/api/*` routes (except `/api/health`) require `X-API-Key` header auth.
  The `/ws/events` endpoint accepts WebSocket upgrades from the tangle_gate app.

  Routes:
  - `/ws/events`      — WebSocket for session lifecycle events (API key auth)
  - `/api/verify/*`   — Credential/presentation verification
  - `/api/resolve/*`  — DID resolution
  - `/api/health`     — Health check (unauthenticated)
  """

  use Plug.Router

  alias TangleGateAgent.Web.Helpers

  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:authenticate_api)
  plug(:dispatch)

  # WebSocket upgrade for tangle_gate connections
  get "/ws/events" do
    conn = fetch_query_params(conn)
    api_key = conn.query_params["api_key"] || ""
    expected = Application.get_env(:tangle_gate_agent, TangleGateAgent.Web.AuthPlug)[:api_key] || ""

    if api_key != "" and api_key == expected do
      conn
      |> WebSockAdapter.upgrade(TangleGateAgent.WS.Handler, [], timeout: 60_000)
      |> halt()
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{error: "unauthorized"}))
      |> halt()
    end
  end

  forward("/api", to: TangleGateAgent.Web.VerifyHandler)

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Route not found"})
  end

  # Authenticate all /api/* routes except /api/health
  defp authenticate_api(%Plug.Conn{path_info: ["api", "health"]} = conn, _opts), do: conn

  defp authenticate_api(%Plug.Conn{path_info: ["api" | _]} = conn, _opts) do
    TangleGateAgent.Web.AuthPlug.call(conn, [])
  end

  defp authenticate_api(conn, _opts), do: conn
end
