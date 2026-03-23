defmodule TangleGate.Web.Frontend.SPARouter do
  @moduledoc """
  SPA frontend router.

  Serves the React/Vite single-page application from `priv/static/spa/`.
  All non-asset routes return `index.html` so React Router handles
  client-side navigation.

  Activated when `config :tangle_gate, frontend: :spa`.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  # Serve the SPA index.html for all routes — React Router handles routing
  match _ do
    index_path = Application.app_dir(:tangle_gate, "priv/static/spa/index.html")

    case File.read(index_path) do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      {:error, _} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "SPA not built. Run: cd web_tangle_gate && npm run build")
    end
  end
end
