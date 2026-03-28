defmodule TangleGateAgent.Web.Helpers do
  @moduledoc """
  Shared helper functions for API handlers.
  """

  import Plug.Conn

  @spec json(Plug.Conn.t(), integer(), term()) :: Plug.Conn.t()
  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

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
end
