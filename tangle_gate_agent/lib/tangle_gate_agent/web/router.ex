defmodule TangleGateAgent.Web.Router do
  @moduledoc """
  Top-level HTTP router for the TangleGate Agent.

  All `/api/*` routes (except `/api/health`) require `X-API-Key` header auth.

  Routes:
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
