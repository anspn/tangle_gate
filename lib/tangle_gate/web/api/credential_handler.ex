defmodule TangleGate.Web.API.CredentialHandler do
  @moduledoc """
  Credential API handler — VC issuance, VP creation, server DID management,
  and dynamic user management.

  Admin routes require JWT authentication with admin role.
  The `create-presentation` route is available to any authenticated user.

  ## Endpoints

  - `POST /api/credentials/provision`            — Provision the server's DID (admin)
  - `GET  /api/credentials/server-did`            — Get the server's DID info (admin)
  - `POST /api/credentials/issue`                 — Issue a VC to a holder DID (admin)
  - `POST /api/credentials/create-presentation`   — Create a VP from holder doc + credentials (any auth)
  - `GET  /api/credentials`                       — List issued credentials (admin)
  - `POST /api/credentials/users`                 — Create a dynamic user (admin)
  - `GET  /api/credentials/users`                 — List users with DIDs (admin)
  - `POST /api/credentials/users/:email/assign-did` — Create a DID and assign to user (admin)
  - `POST /api/credentials/users/:email/authorize` — Authorize user (issue VC) (admin)
  - `POST /api/credentials/users/:email/unauthorize` — Unauthorize user (revoke VC) (admin)
  - `POST /api/credentials/users/:email/revoke-did` — Revoke DID on-chain (admin, irreversible)
  - `POST /api/credentials/users/:email/reactivate-did` — Assign new DID after revocation (admin)
  - `POST /api/credentials/users/:email/delete`   — Delete user (revoke DID + disable access) (admin)
  """

  use Plug.Router

  import Plug.Conn

  require Logger

  alias TangleGate.Credential.Server, as: CredServer
  alias TangleGate.Identity.Server, as: IdentityServer
  alias TangleGate.Store.UserStore
  alias TangleGate.Web.API.Helpers
  alias TangleGate.Web.Auth

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
    if conn.halted, do: conn, else: do_provision(conn)
  end

  # ---------------------------------------------------------------------------
  # GET /api/credentials/server-did — Get server DID info (admin)
  # ---------------------------------------------------------------------------
  get "/server-did" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_server_did(conn)
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/issue — Issue a VC to a holder (admin)
  # ---------------------------------------------------------------------------
  post "/issue" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_issue(conn)
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/create-presentation — Create a VP (any authenticated user)
  # ---------------------------------------------------------------------------
  post "/create-presentation" do
    params = conn.body_params || %{}

    with {:ok, holder_doc_json} <- require_param(params, "holder_doc_json"),
         {:ok, credential_jwts} <- require_param(params, "credential_jwts"),
         {:ok, challenge} <- require_param(params, "challenge"),
         {:ok, private_key_jwk} <- require_param(params, "private_key_jwk"),
         {:ok, fragment} <- require_param(params, "fragment") do
      expires_in = params["expires_in"] || 600

      # credential_jwts can be a list or a JSON string
      cred_jwts_json =
        cond do
          is_list(credential_jwts) -> Jason.encode!(credential_jwts)
          is_binary(credential_jwts) -> credential_jwts
        end

      case CredServer.create_presentation(
             holder_doc_json,
             cred_jwts_json,
             challenge,
             expires_in,
             private_key_jwk,
             fragment
           ) do
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
    if conn.halted, do: conn, else: do_list_credentials(conn)
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/users — Create a dynamic user (admin)
  # ---------------------------------------------------------------------------
  post "/users" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_create_user(conn)
  end

  # ---------------------------------------------------------------------------
  # GET /api/credentials/users — List all users with DIDs (admin)
  # ---------------------------------------------------------------------------
  get "/users" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_list_users(conn)
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/users/:email/assign-did — Create DID and assign (admin)
  # ---------------------------------------------------------------------------
  post "/users/:email/assign-did" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_assign_did(conn, conn.params["email"])
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/users/:email/authorize — Issue VC and mark authorized (admin)
  # ---------------------------------------------------------------------------
  post "/users/:email/authorize" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_authorize_user(conn, conn.params["email"])
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/users/:email/unauthorize — Revoke VC and mark unauthorized (admin)
  # ---------------------------------------------------------------------------
  post "/users/:email/unauthorize" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_unauthorize_user(conn, conn.params["email"])
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/users/:email/revoke-did — Revoke DID on-chain (admin)
  # ---------------------------------------------------------------------------
  post "/users/:email/revoke-did" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_revoke_user_did(conn, conn.params["email"])
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/users/:email/delete — Delete user (admin)
  # ---------------------------------------------------------------------------
  post "/users/:email/delete" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_delete_user(conn, conn.params["email"])
  end

  # ---------------------------------------------------------------------------
  # POST /api/credentials/users/:email/reactivate-did — Assign new DID after revocation (admin)
  # ---------------------------------------------------------------------------
  post "/users/:email/reactivate-did" do
    conn = require_admin(conn)
    if conn.halted, do: conn, else: do_reactivate_did(conn, conn.params["email"])
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
    if Application.get_env(:tangle_gate, :start_repo, true) do
      params = Plug.Conn.fetch_query_params(conn).query_params

      credentials =
        if params["holder_did"] do
          TangleGate.Store.CredentialStore.list_credentials_for_holder(params["holder_did"])
        else
          TangleGate.Store.CredentialStore.list_credentials()
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

  # ===========================================================================
  # Private — user management
  # ===========================================================================

  defp do_create_user(conn) do
    params = conn.body_params || %{}

    with {:ok, email} <- require_param(params, "email"),
         {:ok, password} <- require_param(params, "password"),
         role = params["role"] || "user",
         {:ok, user} <- UserStore.create_user(email, password, role) do
      Helpers.json(conn, 201, %{
        email: user.email,
        role: user.role,
        did: user.did,
        message: "User created successfully"
      })
    else
      {:error, {:missing_parameter, key}} ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: #{key}"
        })

      {:error, reason} when is_binary(reason) ->
        Helpers.json(conn, 409, %{error: "create_failed", message: reason})

      {:error, reason} ->
        Helpers.json(conn, 500, %{
          error: "create_failed",
          message: "Failed to create user: #{inspect(reason)}"
        })
    end
  end

  defp do_list_users(conn) do
    if Application.get_env(:tangle_gate, :start_repo, true) do
      dynamic_users = UserStore.list_users()

      # Also include static config users for a full picture
      static_users =
        (Application.get_env(:tangle_gate, TangleGate.Web.Auth, [])[:users] || [])
        |> Enum.map(fn u ->
          %{email: u.email, role: to_string(u.role), did: nil, source: "config"}
        end)

      all_users =
        Enum.map(dynamic_users, fn u ->
          Map.put(u, :source, "dynamic")
        end) ++ static_users

      # Include status field in all users
      all_users =
        Enum.map(all_users, fn u ->
          Map.put_new(u, :status, "active")
        end)

      Helpers.json(conn, 200, %{users: all_users, count: length(all_users)})
    else
      Helpers.json(conn, 503, %{
        error: "unavailable",
        message: "MongoDB is not enabled — user listing unavailable"
      })
    end
  end

  defp do_assign_did(conn, email) do
    params = conn.body_params || %{}
    network = params["network"] || "iota"
    secret_key = Application.get_env(:tangle_gate, :secret_key)

    unless secret_key && secret_key != "" do
      Helpers.json(conn, 503, %{
        error: "not_configured",
        message: "Server secret_key is not configured — cannot create DIDs"
      })
    else
      publish_opts =
        [secret_key: secret_key, network: String.to_existing_atom(network)]
        |> maybe_put(:node_url, Application.get_env(:tangle_gate, :node_url))
        |> maybe_put(:identity_pkg_id, Application.get_env(:tangle_gate, :identity_pkg_id))

      # 1. Generate and publish a DID on-chain
      case IdentityServer.publish_did(publish_opts) do
        {:ok, did_result} ->
          did = did_result.did
          private_key_jwk = did_result.private_key_jwk
          fragment = did_result.verification_method_fragment

          # 2. Assign the DID (with private key and fragment) to the user in MongoDB
          case UserStore.assign_did(email, did, private_key_jwk, fragment) do
            {:ok, _user} ->
              # Parse private_key_jwk so it's returned as a JSON object, not an escaped string
              parsed_jwk =
                case Jason.decode(private_key_jwk) do
                  {:ok, obj} -> obj
                  {:error, _} -> private_key_jwk
                end

              Helpers.json(conn, 200, %{
                email: email,
                did: did,
                did_document: did_result.document,
                verification_method_fragment: fragment,
                private_key_jwk: parsed_jwk,
                message:
                  "DID created and published on-chain. " <>
                    "Use the Authorize button to issue a credential when ready."
              })

            {:error, reason} when is_binary(reason) ->
              Helpers.json(conn, 404, %{error: "assign_failed", message: reason})

            {:error, reason} ->
              Helpers.json(conn, 500, %{
                error: "assign_failed",
                message: "DID created (#{did}) but assignment failed: #{inspect(reason)}"
              })
          end

        {:error, reason} ->
          Helpers.json(conn, 500, %{
            error: "did_creation_failed",
            message: "Failed to create DID: #{inspect(reason)}"
          })
      end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # ===========================================================================
  # Private — authorize / unauthorize
  # ===========================================================================

  defp do_authorize_user(conn, email) do
    case UserStore.get_user_by_email(email) do
      :not_found ->
        Helpers.json(conn, 404, %{error: "not_found", message: "User not found: #{email}"})

      {:ok, user} ->
        cond do
          is_nil(user.did) ->
            Helpers.json(conn, 422, %{
              error: "no_did",
              message: "User has no DID assigned. Assign a DID first."
            })

          user.authorized == true ->
            Helpers.json(conn, 409, %{
              error: "already_authorized",
              message: "User is already authorized."
            })

          true ->
            case CredServer.issue_credential(
                   user.did,
                   %{"email" => email, "role" => user.role || "user"},
                   "TangleGateAccessCredential"
                 ) do
              {:ok, cred_result} ->
                # Mark the user as authorized in MongoDB
                :ok = UserStore.set_authorized(email, true)

                Helpers.json(conn, 200, %{
                  email: email,
                  did: user.did,
                  authorized: true,
                  credential_jwt: cred_result["credential_jwt"],
                  message:
                    "User authorized. Provide the credential_jwt to the user — " <>
                      "they need it (together with their private key) to access the portal."
                })

              {:error, :no_server_did} ->
                Helpers.json(conn, 503, %{
                  error: "not_provisioned",
                  message: "Server DID not provisioned. POST /api/credentials/provision first."
                })

              {:error, reason} ->
                Helpers.json(conn, 500, %{
                  error: "authorize_failed",
                  message: "Failed to issue credential: #{inspect(reason)}"
                })
            end
        end
    end
  end

  defp do_unauthorize_user(conn, email) do
    case UserStore.get_user_by_email(email) do
      :not_found ->
        Helpers.json(conn, 404, %{error: "not_found", message: "User not found: #{email}"})

      {:ok, user} ->
        if is_nil(user.did) do
          Helpers.json(conn, 422, %{
            error: "no_did",
            message: "User has no DID assigned."
          })
        else
          # Revoke all credentials for this DID
          if Application.get_env(:tangle_gate, :start_repo, true) do
            TangleGate.Store.CredentialStore.revoke_credentials_for_holder(user.did)
          end

          # Mark user as unauthorized
          :ok = UserStore.set_authorized(email, false)

          Helpers.json(conn, 200, %{
            email: email,
            did: user.did,
            authorized: false,
            message: "User unauthorized. All credentials for this DID have been revoked."
          })
        end
    end
  end

  defp do_revoke_user_did(conn, email) do
    case UserStore.get_user_by_email(email) do
      :not_found ->
        Helpers.json(conn, 404, %{error: "not_found", message: "User not found: #{email}"})

      {:ok, user} ->
        cond do
          is_nil(user.did) ->
            Helpers.json(conn, 422, %{
              error: "no_did",
              message: "User has no DID assigned."
            })

          user.status == "did_revoked" ->
            Helpers.json(conn, 409, %{
              error: "already_revoked",
              message: "DID is already revoked for this user."
            })

          true ->
            # 1. Deactivate the DID on-chain
            secret_key = Application.get_env(:tangle_gate, :secret_key)

            unless secret_key && secret_key != "" do
              Helpers.json(conn, 503, %{
                error: "not_configured",
                message: "Server secret_key is not configured — cannot revoke DIDs"
              })
            else
              opts =
                [secret_key: secret_key]
                |> maybe_put(:node_url, Application.get_env(:tangle_gate, :node_url))
                |> maybe_put(:identity_pkg_id, Application.get_env(:tangle_gate, :identity_pkg_id))

              case TangleGate.deactivate_did(user.did, opts) do
                {:ok, _} ->
                  # 2. Revoke all credentials for this DID
                  if Application.get_env(:tangle_gate, :start_repo, true) do
                    TangleGate.Store.CredentialStore.revoke_credentials_for_holder(user.did)
                  end

                  # 3. Mark user status as did_revoked
                  :ok = UserStore.set_authorized(email, false)
                  :ok = UserStore.set_status(email, "did_revoked")

                  Helpers.json(conn, 200, %{
                    email: email,
                    did: user.did,
                    status: "did_revoked",
                    message: "DID has been permanently deactivated on-chain and all credentials revoked."
                  })

                {:error, reason} ->
                  Helpers.json(conn, 500, %{
                    error: "revoke_failed",
                    message: "Failed to deactivate DID on-chain: #{inspect(reason)}"
                  })
              end
            end
        end
    end
  end

  defp do_delete_user(conn, email) do
    case UserStore.get_user_by_email(email) do
      :not_found ->
        Helpers.json(conn, 404, %{error: "not_found", message: "User not found: #{email}"})

      {:ok, user} ->
        # 1. If user has a DID that hasn't been revoked yet, deactivate it on-chain
        did_revoke_result =
          if user.did && user.status != "did_revoked" do
            secret_key = Application.get_env(:tangle_gate, :secret_key)

            if secret_key && secret_key != "" do
              opts =
                [secret_key: secret_key]
                |> maybe_put(:node_url, Application.get_env(:tangle_gate, :node_url))
                |> maybe_put(:identity_pkg_id, Application.get_env(:tangle_gate, :identity_pkg_id))

              TangleGate.deactivate_did(user.did, opts)
            else
              {:error, "secret_key not configured"}
            end
          else
            :ok
          end

        case did_revoke_result do
          {:error, reason} ->
            Helpers.json(conn, 500, %{
              error: "delete_failed",
              message: "Failed to deactivate DID on-chain: #{inspect(reason)}"
            })

          _ ->
            # 2. Revoke all credentials
            if user.did && Application.get_env(:tangle_gate, :start_repo, true) do
              TangleGate.Store.CredentialStore.revoke_credentials_for_holder(user.did)
            end

            # 3. Disable the user (clear credentials)
            :ok = UserStore.disable_user(email)

            Helpers.json(conn, 200, %{
              email: email,
              did: user.did,
              status: "deleted",
              message: "User deleted. DID revoked on-chain and access credentials disabled."
            })
        end
    end
  end

  defp do_reactivate_did(conn, email) do
    case UserStore.get_user_by_email(email) do
      :not_found ->
        Helpers.json(conn, 404, %{error: "not_found", message: "User not found: #{email}"})

      {:ok, user} ->
        unless user.status == "did_revoked" do
          Helpers.json(conn, 422, %{
            error: "invalid_state",
            message: "User DID is not revoked. Only users with a revoked DID can be reactivated."
          })
        else
          secret_key = Application.get_env(:tangle_gate, :secret_key)

          unless secret_key && secret_key != "" do
            Helpers.json(conn, 503, %{
              error: "not_configured",
              message: "Server secret_key is not configured — cannot create DIDs"
            })
          else
            publish_opts =
              [secret_key: secret_key, network: :iota]
              |> maybe_put(:node_url, Application.get_env(:tangle_gate, :node_url))
              |> maybe_put(:identity_pkg_id, Application.get_env(:tangle_gate, :identity_pkg_id))

            # 1. Generate and publish a new DID on-chain
            case IdentityServer.publish_did(publish_opts) do
              {:ok, did_result} ->
                did = did_result.did
                private_key_jwk = did_result.private_key_jwk
                fragment = did_result.verification_method_fragment

                # 2. Assign the new DID to the user in MongoDB
                case UserStore.assign_did(email, did, private_key_jwk, fragment) do
                  {:ok, _user} ->
                    # 3. Reset status to active (unauthorized)
                    :ok = UserStore.set_status(email, "active")
                    :ok = UserStore.set_authorized(email, false)

                    parsed_jwk =
                      case Jason.decode(private_key_jwk) do
                        {:ok, obj} -> obj
                        {:error, _} -> private_key_jwk
                      end

                    Helpers.json(conn, 200, %{
                      email: email,
                      did: did,
                      did_document: did_result.document,
                      verification_method_fragment: fragment,
                      private_key_jwk: parsed_jwk,
                      message:
                        "New DID created and published on-chain (previous DID was permanently deactivated). " <>
                          "Use the Authorize button to issue a credential when ready."
                    })

                  {:error, reason} when is_binary(reason) ->
                    Helpers.json(conn, 404, %{error: "assign_failed", message: reason})

                  {:error, reason} ->
                    Helpers.json(conn, 500, %{
                      error: "assign_failed",
                      message: "DID created (#{did}) but assignment failed: #{inspect(reason)}"
                    })
                end

              {:error, reason} ->
                Helpers.json(conn, 500, %{
                  error: "did_creation_failed",
                  message: "Failed to create new DID: #{inspect(reason)}"
                })
            end
          end
        end
    end
  end
end
