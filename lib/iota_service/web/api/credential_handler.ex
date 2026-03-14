defmodule IotaService.Web.API.CredentialHandler do
  @moduledoc """
  Credential API handler — VC issuance and server DID management.

  All routes require JWT authentication with admin role.

  ## Endpoints

  - `POST /api/credentials/provision`   — Provision the server's DID (one-time)
  - `GET  /api/credentials/server-did`  — Get the server's DID info
  - `POST /api/credentials/issue`       — Issue a VC to a holder DID
  - `GET  /api/credentials`             — List issued credentials
  """

  use Plug.Router

  import Plug.Conn

  alias IotaService.Credential.Server, as: CredServer
  alias IotaService.Web.API.Helpers
  alias IotaService.Web.Auth

  plug(:match)
  plug(:authenticate_admin)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # Auth — admin only
  # ---------------------------------------------------------------------------

  defp authenticate_admin(conn, _opts) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, claims} <- Auth.verify_token(token) do
      role = claims["role"] || "user"

      if role == "admin" do
        assign(conn, :current_user, %{
          id: claims["user_id"],
          email: claims["email"],
          role: role
        })
      else
        conn
        |> Helpers.json(403, %{error: "forbidden", message: "Requires admin role"})
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
  # POST /api/credentials/provision — Provision server DID (one-time)
  # ---------------------------------------------------------------------------
  post "/provision" do
    case CredServer.provision_server_did() do
      {:ok, identity} ->
        Helpers.json(conn, 201, %{
          did: identity.did,
          network: to_string(identity.network),
          verification_method_fragment: identity.verification_method_fragment,
          message: "Server DID provisioned successfully"
        })

      {:error, reason} when is_binary(reason) ->
        Helpers.json(conn, 409, %{error: "provision_failed", message: reason})

      {:error, reason} ->
        Helpers.json(conn, 500, %{
          error: "provision_failed",
          message: "Failed to provision server DID: #{inspect(reason)}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/credentials/server-did — Get server DID info
  # ---------------------------------------------------------------------------
  get "/server-did" do
    case CredServer.server_did_info() do
      {:ok, identity} ->
        Helpers.json(conn, 200, %{
          did: identity.did,
          network: identity.network,
          verification_method_fragment: identity.verification_method_fragment,
          published_at: identity.published_at
        })

      {:error, :no_server_did} ->
        Helpers.json(conn, 404, %{
          error: "not_provisioned",
          message: "Server DID has not been provisioned. POST /api/credentials/provision first."
        })
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/issue — Issue a VC to a holder
  # ---------------------------------------------------------------------------
  post "/issue" do
    params = conn.body_params || %{}

    with {:ok, holder_did} <- require_param(params, "holder_did"),
         claims <- params["claims"] || %{},
         credential_type <- params["credential_type"] || "TangleGateAccessCredential" do
      # Merge role into claims if provided separately
      claims =
        if params["role"] do
          Map.put(claims, "role", params["role"])
        else
          claims
        end

      case CredServer.issue_credential(holder_did, claims, credential_type) do
        {:ok, result} ->
          Helpers.json(conn, 201, %{
            credential_jwt: result["credential_jwt"],
            issuer_did: result["issuer_did"],
            subject_did: result["subject_did"],
            credential_type: result["credential_type"],
            message: "Credential issued. Provide the credential_jwt to the holder."
          })

        {:error, :no_server_did} ->
          Helpers.json(conn, 503, %{
            error: "not_provisioned",
            message: "Server DID not provisioned. POST /api/credentials/provision first."
          })

        {:error, reason} when is_binary(reason) ->
          Helpers.json(conn, 422, %{error: "issuance_failed", message: reason})

        {:error, reason} ->
          Helpers.json(conn, 500, %{
            error: "issuance_failed",
            message: "Credential issuance failed: #{inspect(reason)}"
          })
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/credentials — List issued credentials
  # ---------------------------------------------------------------------------
  get "/" do
    if Application.get_env(:iota_service, :start_repo, true) do
      params = Plug.Conn.fetch_query_params(conn).query_params

      credentials =
        if params["holder_did"] do
          IotaService.Store.CredentialStore.list_credentials_for_holder(params["holder_did"])
        else
          IotaService.Store.CredentialStore.list_credentials()
        end

      Helpers.json(conn, 200, %{
        credentials: credentials,
        count: length(credentials)
      })
    else
      Helpers.json(conn, 503, %{
        error: "unavailable",
        message: "MongoDB is not enabled — credential listing unavailable"
      })
    end
  end

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Credential route not found"})
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, {:missing_parameter, key}}
      "" -> {:error, {:missing_parameter, key}}
      value -> {:ok, value}
    end
  end
end
