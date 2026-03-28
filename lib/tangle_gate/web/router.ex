defmodule TangleGate.Web.Router do
  @moduledoc """
  Top-level HTTP router for the IOTA Service.

  Routes:
  - `/api/*`    → REST API (JSON)
  - `/static/*` → Static assets (logo, SPA bundle)
  - `/assets/*` → Vite-hashed SPA assets (immutable cache)
  - `/*`        → React SPA via `Frontend.SPARouter`
  """

  use Plug.Router

  plug(Plug.RequestId)
  plug(Plug.Logger)

  plug(Plug.Static,
    at: "/static",
    from: {:tangle_gate, "priv/static"},
    gzip: false
  )

  # SPA assets live at /assets/* (Vite's default output prefix)
  plug(Plug.Static,
    at: "/assets",
    from: {:tangle_gate, "priv/static/spa/assets"},
    gzip: true,
    cache_control_for_etags: "public, max-age=31536000, immutable"
  )

  # Serve favicon and other root-level SPA files
  plug(Plug.Static,
    at: "/",
    from: {:tangle_gate, "priv/static/spa"},
    only: ~w(logo.svg),
    gzip: false
  )

  plug(:match)
  plug(:dispatch)

  # WebSocket upgrade for agent connections
  get "/ws/agent" do
    conn = fetch_query_params(conn)
    api_key = conn.query_params["api_key"] || ""
    expected = Application.get_env(:tangle_gate, TangleGate.Agent.Client, [])[:api_key] || ""

    if api_key != "" and api_key == expected do
      conn
      |> WebSockAdapter.upgrade(TangleGate.Web.WS.AgentHandler, [], timeout: 60_000)
      |> halt()
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{error: "unauthorized"}))
      |> halt()
    end
  end

  forward("/api", to: TangleGate.Web.API.Router)

  match _ do
    TangleGate.Web.Frontend.SPARouter.call(conn, TangleGate.Web.Frontend.SPARouter.init([]))
  end
end
