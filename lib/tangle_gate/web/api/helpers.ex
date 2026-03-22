defmodule TangleGate.Web.API.Helpers do
  @moduledoc """
  Shared helper functions for API handlers.

  Provides consistent JSON response formatting and common patterns
  used across all API endpoints.
  """

  import Plug.Conn

  @doc "Send a JSON response with the given status code."
  @spec json(Plug.Conn.t(), integer(), term()) :: Plug.Conn.t()
  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc "Extract and validate required fields from a map."
  @spec require_fields(map(), [String.t()]) :: {:ok, map()} | {:error, [String.t()]}
  def require_fields(params, fields) do
    missing =
      Enum.filter(fields, fn field ->
        value = Map.get(params, field)
        is_nil(value) or value == ""
      end)

    case missing do
      [] -> {:ok, Map.take(params, fields)}
      _ -> {:error, missing}
    end
  end

  @doc "Send a 422 Unprocessable Entity response for validation errors."
  @spec validation_error(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def validation_error(conn, message) do
    json(conn, 422, %{error: "validation_error", message: message})
  end

  @doc "Send a 401 Unauthorized response."
  @spec unauthorized(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def unauthorized(conn, message \\ "Invalid or expired token") do
    json(conn, 401, %{error: "unauthorized", message: message})
  end
end
