defmodule TangleGate.Web.API.VerifyHandler do
  @moduledoc """
  Notarization verification API handler.

  Accessible to admin and verifier roles.

  ## Endpoints

  - `GET  /api/verify/:object_id` — Read an on-chain notarization by object ID
  - `POST /api/verify/hash`       — Compute SHA-256 hash of submitted data
  """

  use Plug.Router

  import Plug.Conn

  alias TangleGate.Web.API.Helpers
  alias TangleGate.Web.Auth

  plug(:match)
  plug(:authenticate)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # Auth — only admin and verifier roles
  # ---------------------------------------------------------------------------

  defp authenticate(conn, _opts) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, claims} <- Auth.verify_token(token) do
      role = claims["role"] || "user"

      if role in ["admin", "verifier"] do
        assign(conn, :current_user, %{
          id: claims["user_id"],
          email: claims["email"],
          role: role
        })
      else
        conn
        |> Helpers.json(403, %{error: "forbidden", message: "Requires admin or verifier role"})
        |> halt()
      end
    else
      {:error, :no_token} ->
        conn |> Helpers.unauthorized("Missing Authorization header") |> halt()

      {:error, _reason} ->
        conn |> Helpers.unauthorized("Invalid or expired token") |> halt()
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :no_token}
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/verify/hash — Compute SHA-256 hash of submitted data
  # ---------------------------------------------------------------------------
  post "/hash" do
    params = conn.body_params || %{}
    data = params["data"]

    if is_nil(data) || data == "" do
      Helpers.json(conn, 400, %{
        error: "missing_parameter",
        message: "Required parameter missing: data"
      })
    else
      hash = TangleGate.Notarization.Server.hash_data(data)

      Helpers.json(conn, 200, %{
        hash: hash,
        algorithm: "sha256",
        data_size: byte_size(data)
      })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/verify/:object_id — Read on-chain notarization
  # ---------------------------------------------------------------------------
  get "/:object_id" do
    case TangleGate.Notarization.Server.read_on_chain(object_id) do
      {:ok, result} ->
        result = Map.put(result, "immutable", result["method"] == "Locked")
        Helpers.json(conn, 200, result)

      {:error, reason} ->
        message =
          if is_binary(reason) and String.contains?(reason, "not found"),
            do: "No document on chain matches the object ID you searched, please check if the input is correct",
            else: "Failed to read on-chain notarization: #{inspect(reason)}"

        Helpers.json(conn, 422, %{
          error: "verification_failed",
          message: message
        })
    end
  end

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Verify route not found"})
  end
end
