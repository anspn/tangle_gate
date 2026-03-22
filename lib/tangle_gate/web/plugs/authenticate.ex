defmodule TangleGate.Web.Plugs.Authenticate do
  @moduledoc """
  Plug that verifies JWT Bearer tokens on protected API routes.

  Extracts the token from the `Authorization: Bearer <token>` header,
  validates it, and assigns `:current_user` to the connection.

  Returns 401 if the token is missing, malformed, or invalid.
  """

  @behaviour Plug

  import Plug.Conn
  alias TangleGate.Web.API.Helpers
  alias TangleGate.Web.Auth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, claims} <- Auth.verify_token(token) do
      conn
      |> assign(:current_user, %{
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

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :no_token}
    end
  end
end
