defmodule IotaService.Web.API.CredentialHandler do
  @moduledoc """
  Credential API handler — VC issuance, VP creation, and server DID management.

  Admin routes require JWT authentication with admin role.
  The `create-presentation` route is available to any authenticated user.

  ## Endpoints

  - `POST /api/credentials/provision`            — Provision the server's DID (admin)
  - `GET  /api/credentials/server-did`            — Get the server's DID info (admin)
  - `POST /api/credentials/issue`                 — Issue a VC to a holder DID (admin)
  - `POST /api/credentials/create-presentation`   — Create a VP from holder doc + credentials (any auth)
  - `GET  /api/credentials`                       — List issued credentials (admin)
  """

  use Plug.Router

  import Plug.Conn

  alias IotaService.Credential.Server, as: CredServer
  alias IotaService.Web.API.Helpers
  alias IotaService.Web.Auth

  plug(:match)
  plug(:authenticate)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # Auth — any authenticated user; admin checked per-route
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
  # POST /api/credentials/provision — Provision server DID (one-time, admin)
  # ---------------------------------------------------------------------------
  post "/provision" do
    conn = require_admin(conn)
    if conn.halted?, do: conn, else: do_provision(conn)
  end

  # ---------------------------------------------------------------------------
  # GET /api/credentials/server-did — Get server DID info (admin)
  # ---------------------------------------------------------------------------
  get "/server-did" do
    conn = require_admin(conn)
    if conn.halted?, do: conn, else: do_server_did(conn)
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/issue — Issue a VC to a holder (admin)
  # ---------------------------------------------------------------------------
  post "/issue" do
    conn = require_admin(conn)
    if conn.halted?, do: conn, else: do_issue(conn)
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/create-presentation — Create a VP (any authenticated user)
  # ---------------------------------------------------------------------------
  post "/create-presentation" do
    params = conn.body_params || %{}

    with {:ok, holder_doc_json} <- require_param(params, "holder_doc_json"),
         {:ok, credential_jwts} <- require_param(params, "credential_jwts"),
         {:ok, challenge} <- require_param(params, "challenge") do
      expires_in = params["expires_in"] || 600

      # credential_jwts can be a list or a JSON string
      cred_jwts_json =
        cond do
          is_list(credential_jwts) -> Jason.encode!(credential_jwts)
          is_binary(credential_jwts) -> credential_jwts
        end

      case CredServer.create_presentation(holder_doc_json, cred_jwts_json, challenge, expires_in) do
        {:ok, result} ->
          Helpers.json(conn, 201, %{
            presentation_jwt: result["presentation_jwt"],
            holder_did: result["holder_did"],
            message: "Verifiable Presentation created"
          })

        {:error, reason} ->
          Helpers.json(conn, 422, %{
            error: "presentation_failed",
            message: "Failed to create presentation: #{inspect(reason)}"
          })
      end
    else
      {:error, {:missing_parameter, key}} ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: #{key}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/credentials — List issued credentials (admin)
  # ---------------------------------------------------------------------------
  get "/" do
    conn = require_admin(conn)
    if conn.halted?, do: conn, else: do_list_credentials(conn)
  end

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Credential route not found"})
  end

  # ===========================================================================
  # Private — route implementations
  # ===========================================================================

  defp do_provision(conn) do
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

  defp do_server_did(conn) do
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

  defp do_issue(conn) do
    params = conn.body_params || %{}

    with {:ok, holder_did} <- require_param(params, "holder_did"),
         claims <- params["claims"] || %{},
         credential_type <- params["credential_type"] || "TangleGateAccessCredential" do
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

  defp do_list_credentials(conn) do
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

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, {:missing_parameter, key}}
      "" -> {:error, {:missing_parameter, key}}
      value -> {:ok, value}
    end
  end
end
