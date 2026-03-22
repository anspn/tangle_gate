defmodule TangleGate.Web.Router do
  @moduledoc """
  Top-level HTTP router for the IOTA Service.

  Routes:
  - `/api/*`    → REST API (JSON)
  - `/static/*` → Static assets (CSS, JS)
  - `/*`        → Server-side rendered frontend
  """

  use Plug.Router

  plug(Plug.RequestId)
  plug(Plug.Logger)

  plug(Plug.Static,
    at: "/static",
    from: {:tangle_gate, "priv/static"},
    gzip: false
  )

  plug(:match)
  plug(:dispatch)

  forward("/api", to: TangleGate.Web.API.Router)
  forward("/", to: TangleGate.Web.Frontend.Router)
end
