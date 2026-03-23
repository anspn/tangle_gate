defmodule TangleGate.Web.Router do
  @moduledoc """
  Top-level HTTP router for the IOTA Service.

  Routes:
  - `/api/*`    → REST API (JSON)
  - `/static/*` → Static assets (CSS, JS, SPA bundle)
  - `/*`        → Frontend (SSR or SPA, controlled by `config :tangle_gate, frontend:`)

  ## Frontend modes

  - `:static` (default) — server-side rendered EEx templates via `Frontend.Router`
  - `:spa` — React SPA served from `priv/static/spa/` via `Frontend.SPARouter`

  Set in config:

      config :tangle_gate, frontend: :spa
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

  forward("/api", to: TangleGate.Web.API.Router)

  match _ do
    case Application.get_env(:tangle_gate, :frontend, :static) do
      :spa ->
        TangleGate.Web.Frontend.SPARouter.call(conn, TangleGate.Web.Frontend.SPARouter.init([]))

      _ ->
        TangleGate.Web.Frontend.Router.call(conn, TangleGate.Web.Frontend.Router.init([]))
    end
  end
end
