defmodule TangleGate.Web.API.DashboardHandler do
  @moduledoc """
  Admin-only dashboard statistics endpoint.

  Aggregates user, credential, and session time-series data for the
  admin dashboard overview.

  ## Routes

  - `GET /api/dashboard/stats` — Aggregated dashboard statistics (admin)
  """

  use Plug.Router

  alias TangleGate.Store.{UserStore, CredentialStore, NotarizationStore}
  alias TangleGate.Web.API.Helpers
  alias TangleGate.Web.Auth

  plug(:match)
  plug(:authenticate)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # Auth
  # ---------------------------------------------------------------------------

  defp authenticate(conn, _opts) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, claims} <- Auth.verify_token(token) do
      assign(conn, :current_user, %{
        id: claims["user_id"],
        email: claims["email"],
        role: claims["role"] || "user"
      })
    else
      {:error, :no_token} ->
        conn |> Helpers.unauthorized("Missing Authorization header") |> halt()

      {:error, _reason} ->
        conn |> Helpers.unauthorized("Invalid or expired token") |> halt()
    end
  end

  defp require_admin(conn) do
    if conn.assigns[:current_user].role == "admin" do
      conn
    else
      conn
      |> Helpers.json(403, %{error: "forbidden", message: "Requires admin role"})
      |> halt()
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :no_token}
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/dashboard/stats
  # ---------------------------------------------------------------------------

  get "/stats" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_stats(conn)
  end

  defp do_stats(conn) do
    users = %{
      total: UserStore.count_users(),
      by_status: UserStore.count_users_by_status(),
      authorized: UserStore.count_authorized_users(),
      unauthorized: UserStore.count_unauthorized_users()
    }

    credentials = %{
      total: CredentialStore.count_credentials(),
      active: CredentialStore.count_active_credentials(),
      revoked: CredentialStore.count_revoked_credentials(),
      by_date: CredentialStore.credentials_by_date(30)
    }

    sessions_by_date = NotarizationStore.sessions_by_date(30)

    Helpers.json(conn, 200, %{
      users: users,
      credentials: credentials,
      sessions_by_date: sessions_by_date
    })
  end

  # ---------------------------------------------------------------------------
  # Catch-all
  # ---------------------------------------------------------------------------

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Dashboard route not found"})
  end
end
