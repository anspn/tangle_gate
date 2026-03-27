defmodule TangleGate.Web.API.SessionHandler do
  @moduledoc """
  TTY Session Recording API handler.

  All routes require JWT authentication (via `Authenticate` plug).

  Session creation requires a Verifiable Presentation (VP) containing a
  TangleGateAccessCredential. The VP is verified against the holder's
  on-chain DID and the server's issuer DID before the session is started.

  ## Endpoints

  - `POST   /api/sessions`                        — Start a new recording session (VP required)
  - `POST   /api/sessions/create-vp`              — Create a VP for portal session start (credential + private key)
  - `POST   /api/sessions/:id/end`                — End a session (triggers notarization)
  - `POST   /api/sessions/:id/terminate`           — Admin: terminate active session (kick user + notarize)
  - `POST   /api/sessions/:id/retry-notarization`  — Admin: retry failed on-chain notarization
  - `GET    /api/sessions`                         — List sessions (admin: all, user: own)
  - `GET    /api/sessions/:id`                     — Get session details
  - `GET    /api/sessions/:id/download`            — Download session history as JSON file
  """

  use Plug.Router

  import Plug.Conn

  alias TangleGate.Credential.ChallengeCache
  alias TangleGate.Credential.Server, as: CredServer
  alias TangleGate.Credential.Verifier
  alias TangleGate.Session.Manager
  alias TangleGate.Web.API.Helpers
  alias TangleGate.Web.Auth

  # Auth is handled per-route: most routes use strict JWT validation,
  # but POST /:id/end uses lenient auth (signature only, ignoring exp)
  # so that sessions can be ended even after the token expires.
  plug(:match)
  plug(:authenticate)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # Auth — route-aware plug
  # ---------------------------------------------------------------------------

  defp authenticate(%{path_info: path_info} = conn, _opts) do
    if lenient_auth_path?(path_info) do
      do_authenticate(conn, :lenient)
    else
      do_authenticate(conn, :strict)
    end
  end

  # POST /:session_id/end → ["ses_xxx", "end"]
  defp lenient_auth_path?([_, "end"]), do: true
  defp lenient_auth_path?(_), do: false

  defp do_authenticate(conn, mode) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, claims} <- verify_token(token, mode) do
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

  defp verify_token(token, :strict), do: Auth.verify_token(token)
  defp verify_token(token, :lenient), do: Auth.verify_token_ignoring_expiry(token)

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :no_token}
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions — Start a new recording session (VP required)
  # ---------------------------------------------------------------------------
  post "/" do
    params = conn.body_params || %{}
    presentation_jwt = params["presentation_jwt"]
    challenge = params["challenge"]
    holder_did = params["holder_did"]
    user = conn.assigns[:current_user]

    cond do
      is_nil(presentation_jwt) || presentation_jwt == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message:
            "Required parameter missing: presentation_jwt. " <>
              "Submit a Verifiable Presentation to start a session."
        })

      is_nil(challenge) || challenge == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: challenge"
        })

      is_nil(holder_did) || holder_did == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: holder_did"
        })

      true ->
        start_session_with_vp(conn, presentation_jwt, challenge, holder_did, user)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions/create-vp — Create a VP for portal session start
  #
  # Takes credential_jwt + private_key_jwk from the user.
  # Server looks up the user's DID/fragment from MongoDB, resolves the DID
  # document on-chain, generates a challenge, and creates a VP.
  # Returns the VP JWT, challenge, and holder DID for use with POST /.
  # ---------------------------------------------------------------------------
  post "/create-vp" do
    params = conn.body_params || %{}
    credential_jwt = params["credential_jwt"]
    private_key_jwk = params["private_key_jwk"]
    user = conn.assigns[:current_user]

    cond do
      is_nil(credential_jwt) || credential_jwt == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: credential_jwt"
        })

      is_nil(private_key_jwk) || private_key_jwk == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: private_key_jwk"
        })

      true ->
        do_create_vp_for_session(conn, credential_jwt, private_key_jwk, user)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions/:id/end — End a session (triggers notarization)
  # ---------------------------------------------------------------------------
  post "/:session_id/end" do
    user = conn.assigns[:current_user]

    case Manager.get_session(session_id) do
      {:ok, session} ->
        # Verify the user owns this session (or is admin)
        if user.role == "admin" || session.user_id == user.id do
          case Manager.end_session(session_id) do
            {:ok, ended_session} ->
              Helpers.json(conn, 200, serialize_session(ended_session))

            {:error, reason} ->
              Helpers.json(conn, 500, %{
                error: "session_error",
                message: "Failed to end session: #{inspect(reason)}"
              })
          end
        else
          Helpers.json(conn, 403, %{
            error: "forbidden",
            message: "You can only end your own sessions"
          })
        end

      :not_found ->
        Helpers.json(conn, 404, %{
          error: "not_found",
          message: "Session not found: #{session_id}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions/:id/terminate — Admin terminates an active session
  # ---------------------------------------------------------------------------
  post "/:session_id/terminate" do
    user = conn.assigns[:current_user]

    unless user.role == "admin" do
      Helpers.json(conn, 403, %{
        error: "forbidden",
        message: "Only admins can terminate sessions"
      })
    else
      case Manager.terminate_session(session_id) do
        {:ok, session} ->
          Helpers.json(conn, 200, %{
            session: serialize_session(session),
            message:
              "Session terminated and notarization #{if session.status == :notarized, do: "succeeded", else: "attempted"}"
          })

        {:error, :not_found} ->
          Helpers.json(conn, 404, %{
            error: "not_found",
            message: "Session not found: #{session_id}"
          })

        {:error, :not_active} ->
          Helpers.json(conn, 409, %{
            error: "not_active",
            message: "Session is not active — cannot terminate"
          })

        {:error, reason} ->
          Helpers.json(conn, 500, %{
            error: "terminate_failed",
            message: "Failed to terminate session: #{inspect(reason)}"
          })
      end
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions/:id/retry-notarization — Retry failed notarization
  # ---------------------------------------------------------------------------
  post "/:session_id/retry-notarization" do
    user = conn.assigns[:current_user]

    unless user.role == "admin" do
      Helpers.json(conn, 403, %{
        error: "forbidden",
        message: "Only admins can retry notarization"
      })
    else
      case Manager.retry_notarization(session_id) do
        {:ok, session} ->
          Helpers.json(conn, 200, %{
            session: serialize_session(session),
            message: "Notarization succeeded — session is now on-chain"
          })

        {:error, :not_found} ->
          Helpers.json(conn, 404, %{
            error: "not_found",
            message: "Session not found: #{session_id}"
          })

        {:error, {:invalid_status, status}} ->
          Helpers.json(conn, 409, %{
            error: "invalid_status",
            message:
              "Cannot retry notarization for session in '#{status}' status — only 'failed' sessions can be retried"
          })

        {:error, :no_hash} ->
          Helpers.json(conn, 422, %{
            error: "no_hash",
            message: "Session has no notarization hash — cannot retry"
          })

        {:error, :no_secret_key} ->
          Helpers.json(conn, 422, %{
            error: "no_secret_key",
            message: "No IOTA secret key configured — cannot publish on-chain"
          })

        {:error, reason} ->
          Helpers.json(conn, 500, %{
            error: "notarization_failed",
            message: "Notarization retry failed: #{inspect(reason)}"
          })
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/sessions — List sessions
  # ---------------------------------------------------------------------------
  get "/" do
    user = conn.assigns[:current_user]
    params = Plug.Conn.fetch_query_params(conn).query_params

    opts =
      []
      |> then(fn o ->
        # Non-admins can only see their own sessions
        if user.role == "admin" do
          if params["user_id"], do: [{:user_id, params["user_id"]} | o], else: o
        else
          [{:user_id, user.id} | o]
        end
      end)
      |> then(fn o ->
        if params["did"], do: [{:did, params["did"]} | o], else: o
      end)
      |> then(fn o ->
        if params["status"], do: [{:status, params["status"]} | o], else: o
      end)
      |> then(fn o ->
        if params["limit"], do: [{:limit, String.to_integer(params["limit"])} | o], else: o
      end)

    sessions = Manager.list_sessions(opts)

    Helpers.json(conn, 200, %{
      sessions: Enum.map(sessions, &serialize_session/1),
      count: length(sessions)
    })
  end

  # ---------------------------------------------------------------------------
  # GET /api/sessions/stats — Session statistics
  # ---------------------------------------------------------------------------
  get "/stats" do
    user = conn.assigns[:current_user]

    unless user.role == "admin" do
      Helpers.json(conn, 403, %{
        error: "forbidden",
        message: "Only admins can view session statistics"
      })
    else
      stats = Manager.stats()
      Helpers.json(conn, 200, stats)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/sessions/:id/download — Download session history as JSON file
  # ---------------------------------------------------------------------------
  get "/:session_id/download" do
    user = conn.assigns[:current_user]

    case Manager.get_session(session_id) do
      {:ok, session} ->
        if user.role == "admin" || session.user_id == user.id do
          case Manager.get_session_history(session_id) do
            {:ok, json_binary} ->
              filename = "session_#{session_id}.json"

              conn
              |> put_resp_content_type("application/json")
              |> put_resp_header(
                "content-disposition",
                "attachment; filename=\"#{filename}\""
              )
              |> send_resp(200, json_binary)

            {:error, :no_document} ->
              Helpers.json(conn, 404, %{
                error: "no_document",
                message: "Session document not available (session may still be active)"
              })

            :not_found ->
              Helpers.json(conn, 404, %{
                error: "not_found",
                message: "Session not found: #{session_id}"
              })
          end
        else
          Helpers.json(conn, 403, %{
            error: "forbidden",
            message: "You can only download your own sessions"
          })
        end

      :not_found ->
        Helpers.json(conn, 404, %{
          error: "not_found",
          message: "Session not found: #{session_id}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/sessions/:id — Get session details
  # ---------------------------------------------------------------------------
  get "/:session_id" do
    user = conn.assigns[:current_user]

    case Manager.get_session(session_id) do
      {:ok, session} ->
        if user.role == "admin" || session.user_id == user.id do
          Helpers.json(conn, 200, serialize_session(session, include_commands: true))
        else
          Helpers.json(conn, 403, %{
            error: "forbidden",
            message: "You can only view your own sessions"
          })
        end

      :not_found ->
        Helpers.json(conn, 404, %{
          error: "not_found",
          message: "Session not found: #{session_id}"
        })
    end
  end

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Session route not found"})
  end

  # ===========================================================================
  # Private — VP creation for portal (user provides credential + private key)
  # ===========================================================================

  defp do_create_vp_for_session(conn, credential_jwt, private_key_jwk, user) do
    alias TangleGate.Store.UserStore

    # 1. Look up the user's DID and fragment from MongoDB
    case UserStore.get_user_by_email(user.email) do
      {:ok, db_user} ->
        cond do
          is_nil(db_user.did) ->
            Helpers.json(conn, 422, %{
              error: "no_did",
              message: "No DID assigned to your account. Ask an admin to assign one."
            })

          is_nil(db_user.verification_method_fragment) ->
            Helpers.json(conn, 422, %{
              error: "missing_fragment",
              message:
                "Verification method fragment not stored. Ask an admin to re-assign your DID."
            })

          db_user.authorized != true ->
            Helpers.json(conn, 403, %{
              error: "not_authorized",
              message: "Your account is not authorized for terminal access. Contact an admin."
            })

          true ->
            do_build_vp(conn, credential_jwt, private_key_jwk, db_user)
        end

      :not_found ->
        Helpers.json(conn, 404, %{
          error: "user_not_found",
          message: "User account not found in database"
        })
    end
  end

  defp do_build_vp(conn, credential_jwt, private_key_jwk, db_user) do
    node_url = Application.get_env(:tangle_gate, :node_url, "https://api.testnet.iota.cafe")
    identity_pkg_id = Application.get_env(:tangle_gate, :identity_pkg_id, "")

    # 2. Resolve the user's DID document on-chain
    case Verifier.resolve_did_document(db_user.did, node_url, identity_pkg_id) do
      {:ok, holder_doc_json} ->
        # 3. Generate challenge and create VP
        {:ok, challenge} = ChallengeCache.generate_challenge()
        cred_jwts_json = Jason.encode!([credential_jwt])

        case CredServer.create_presentation(
               holder_doc_json,
               cred_jwts_json,
               challenge,
               300,
               private_key_jwk,
               db_user.verification_method_fragment
             ) do
          {:ok, %{"presentation_jwt" => presentation_jwt, "holder_did" => holder_did}} ->
            Helpers.json(conn, 201, %{
              presentation_jwt: presentation_jwt,
              challenge: challenge,
              holder_did: holder_did,
              message: "VP created. Submit it to start a session."
            })

          {:error, reason} ->
            Helpers.json(conn, 422, %{
              error: "presentation_failed",
              message: "Failed to create VP: #{inspect(reason)}"
            })
        end

      {:error, reason} ->
        Helpers.json(conn, 422, %{
          error: "did_resolution_failed",
          message: "Could not resolve your DID on-chain: #{inspect(reason)}"
        })
    end
  end

  # ===========================================================================
  # Private — VP-based session creation (manual VP submission)
  # ===========================================================================

  defp start_session_with_vp(conn, presentation_jwt, challenge, holder_did, user) do
    # 1. Consume the challenge (single-use)
    case ChallengeCache.consume_challenge(challenge) do
      :not_found ->
        Helpers.json(conn, 401, %{
          error: "invalid_challenge",
          message: "Challenge not found or already used"
        })

      :expired ->
        Helpers.json(conn, 401, %{
          error: "challenge_expired",
          message: "Challenge has expired"
        })

      :ok ->
        # 2. Get server's issuer DID
        case CredServer.server_did_info() do
          {:error, :no_server_did} ->
            Helpers.json(conn, 503, %{
              error: "not_provisioned",
              message: "Server DID not provisioned — cannot verify credentials"
            })

          {:ok, server_identity} ->
            verify_vp_and_start_session(
              conn,
              presentation_jwt,
              challenge,
              holder_did,
              user,
              server_identity
            )
        end
    end
  end

  defp verify_vp_and_start_session(
         conn,
         presentation_jwt,
         challenge,
         holder_did,
         user,
         server_identity
       ) do
    node_url = Application.get_env(:tangle_gate, :node_url, "https://api.testnet.iota.cafe")
    identity_pkg_id = Application.get_env(:tangle_gate, :identity_pkg_id, "")

    # 3. Resolve the holder's DID document on-chain
    case Verifier.resolve_did_document(holder_did, node_url, identity_pkg_id) do
      {:ok, holder_doc_json} ->
        issuer_doc = server_identity.document

        issuer_docs_json =
          case Jason.decode(issuer_doc) do
            {:ok, doc_map} -> Jason.encode!([doc_map])
            {:error, _} -> "[#{issuer_doc}]"
          end

        # 4. Verify the VP using the independent Verifier
        case Verifier.verify_presentation(
               presentation_jwt,
               holder_doc_json,
               issuer_docs_json,
               challenge
             ) do
          {:ok, %{"valid" => true}} ->
            # 5. VP valid — start the session with the verified holder DID
            case Manager.start_session(holder_did, user.id) do
              {:ok, session} ->
                Helpers.json(conn, 201, %{
                  session_id: session.session_id,
                  did: session.did,
                  started_at: DateTime.to_iso8601(session.started_at),
                  status: to_string(session.status),
                  auth_method: "verifiable_presentation"
                })

              {:error, reason} ->
                Helpers.json(conn, 500, %{
                  error: "session_error",
                  message: "VP verified but session creation failed: #{inspect(reason)}"
                })
            end

          {:ok, %{"valid" => false}} ->
            Helpers.json(conn, 401, %{
              error: "invalid_presentation",
              message: "Verifiable Presentation is not valid"
            })

          {:error, reason} ->
            Helpers.json(conn, 401, %{
              error: "verification_failed",
              message: "VP verification failed: #{inspect(reason)}"
            })
        end

      {:error, reason} ->
        Helpers.json(conn, 422, %{
          error: "did_resolution_failed",
          message: "Could not resolve holder DID on-chain: #{inspect(reason)}"
        })
    end
  end

  # ===========================================================================
  # Private — serialization
  # ===========================================================================

  defp serialize_session(session, opts \\ []) do
    base = %{
      session_id: session.session_id,
      did: session.did,
      user_id: session.user_id,
      started_at: if(session.started_at, do: DateTime.to_iso8601(session.started_at)),
      ended_at: if(session.ended_at, do: DateTime.to_iso8601(session.ended_at)),
      status: to_string(session.status),
      command_count: session.command_count,
      notarization_hash: session.notarization_hash,
      on_chain_id: session.on_chain_id,
      error: session.error
    }

    if Keyword.get(opts, :include_commands, false) do
      Map.put(base, :commands, session.commands || [])
    else
      base
    end
  end
end
