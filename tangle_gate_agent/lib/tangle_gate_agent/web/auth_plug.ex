defmodule TangleGateAgent.Web.AuthPlug do
  @moduledoc """
  Plug that authenticates requests via `X-API-Key` header.

  The expected API key is configured under:

      config :tangle_gate_agent, TangleGateAgent.Web.AuthPlug,
        api_key: "shared-secret"
  """

  import Plug.Conn
  alias TangleGateAgent.Web.Helpers

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    expected = Application.get_env(:tangle_gate_agent, __MODULE__)[:api_key]

    case get_req_header(conn, "x-api-key") do
      [key] when is_binary(expected) and key == expected ->
        conn

      _ ->
        conn
        |> Helpers.json(401, %{error: "unauthorized", message: "Invalid or missing API key"})
        |> halt()
    end
  end
end
