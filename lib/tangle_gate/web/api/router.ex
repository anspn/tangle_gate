defmodule TangleGate.Web.API.Router do
  @moduledoc """
  REST API router — `/api/*`.

  All routes produce `application/json` responses.
  Mounts sub-routers per domain:

  - `/api/auth/*`         → Authentication (login, challenge, VP-based auth, VP-login-with-credential)
  - `/api/dids/*`         → DID / Identity management
  - `/api/credentials/*`  → VC issuance, VP creation, and server DID management
  - `/api/sessions/*`     → TTY session recording & notarization (VP-gated)
  - `/api/verify/*`       → Notarization verification
  - `/api/health`         → Health check
  """

  use Plug.Router

  alias TangleGate.Web.API.Helpers

  # Parse JSON bodies for all API routes
  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  # --- Health ---------------------------------------------------------------

  get "/health" do
    ready = TangleGate.nif_ready?()

    body = %{
      status: if(ready, do: "ok", else: "degraded"),
      nif_loaded: ready,
      timestamp: DateTime.utc_now()
    }

    status = if ready, do: 200, else: 503
    Helpers.json(conn, status, body)
  end

  # --- Domain routers -------------------------------------------------------

  forward("/auth", to: TangleGate.Web.API.AuthHandler)
  forward("/dids", to: TangleGate.Web.API.IdentityHandler)
  forward("/credentials", to: TangleGate.Web.API.CredentialHandler)
  forward("/sessions", to: TangleGate.Web.API.SessionHandler)
  forward("/verify", to: TangleGate.Web.API.VerifyHandler)

  # --- Catch-all ------------------------------------------------------------

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "API route not found"})
  end
end
