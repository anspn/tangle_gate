defmodule TangleGate.Web.API.AuthHandler do
  @moduledoc """
  Authentication API handler.

  ## Login Flows

  1. **Email + Password** (`POST /login`) — Standard auth, returns JWT.
     If the user provides a `did`, the server verifies the DID is assigned
     to the user's account (ownership check) but does **not** issue a credential.
     Credentials are issued separately via the admin Authorize workflow.

  2. **VP-based** (`POST /present-with-credential`) — User submits their
     DID document (with keys) + credential JWT + challenge. Server creates a VP,
     verifies it, checks revocation status, and issues a JWT.

  3. **Raw VP** (`POST /present`) — User submits a pre-built VP JWT +
     challenge + holder DID. Server resolves the DID on-chain, verifies
     the VP, checks revocation, and issues a JWT.

  ## Endpoints

  - `POST /api/auth/login`                    — Email/password login (optional DID ownership check)
  - `GET  /api/auth/challenge`                — Get a challenge nonce for VP-based auth
  - `POST /api/auth/present`                  — Authenticate with a pre-built VP JWT
  - `POST /api/auth/present-with-credential`  — VP login from holder doc + credential
  """

  use Plug.Router

  alias TangleGate.Credential.ChallengeCache
  alias TangleGate.Credential.Server, as: CredServer
  alias TangleGate.Credential.Verifier
  alias TangleGate.Store.CredentialStore
  alias TangleGate.Web.API.Helpers
  alias TangleGate.Web.Auth

  plug(:match)
  plug(:dispatch)

  # POST /api/auth/login — Email/password login with optional DID-based 2FA
  post "/login" do
    with {:ok, %{"email" => email, "password" => password}} <-
           Helpers.require_fields(conn.body_params, ["email", "password"]),
         {:ok, user} <- Auth.authenticate(email, password),
         {:ok, token, claims} <- Auth.generate_token(user) do
      # Check if user is providing a DID for ownership verification
      did = (conn.body_params || %{})["did"]

      if did && did != "" do
        # Verify DID is assigned to this user, but don't issue a credential
        case verify_did_ownership(user, did) do
          :ok ->
            Helpers.json(conn, 200, %{
              token: token,
              expires_at: format_exp(claims["exp"]),
              user: %{id: user.id, email: user.email, role: user.role},
              holder_did: did,
              message: "Login successful. DID ownership verified."
            })

          {:error, message} ->
            Helpers.json(conn, 403, %{
              error: "did_mismatch",
              message: message
            })
        end
      else
        Helpers.json(conn, 200, %{
          token: token,
          expires_at: format_exp(claims["exp"]),
          user: %{id: user.id, email: user.email, role: user.role}
        })
      end
    else
      {:error, [:password]} ->
        Helpers.validation_error(conn, "Password is required")

      {:error, missing} when is_list(missing) ->
        Helpers.validation_error(conn, "Missing required fields: #{Enum.join(missing, ", ")}")

      {:error, :invalid_credentials} ->
        Helpers.json(conn, 401, %{
          error: "invalid_credentials",
          message: "Email or password is incorrect"
        })

      {:error, reason} ->
        Helpers.json(conn, 500, %{
          error: "internal_error",
          message: "Authentication failed: #{inspect(reason)}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/auth/challenge — Get a challenge nonce for VP-based auth
  # ---------------------------------------------------------------------------
  get "/challenge" do
    {:ok, challenge} = ChallengeCache.generate_challenge()

    Helpers.json(conn, 200, %{
      challenge: challenge,
      expires_in_seconds: 300,
      message: "Include this challenge when creating your Verifiable Presentation"
    })
  end

  # ---------------------------------------------------------------------------
  # POST /api/auth/present — Authenticate via Verifiable Presentation
  # ---------------------------------------------------------------------------
  post "/present" do
    params = conn.body_params || %{}
    presentation_jwt = params["presentation_jwt"]
    challenge = params["challenge"]
    holder_did = params["holder_did"]

    cond do
      is_nil(presentation_jwt) || presentation_jwt == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: presentation_jwt"
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
        do_vp_authentication(conn, presentation_jwt, challenge, holder_did)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/auth/present-with-credential — VP login from holder doc + credential
  #
  # Creates a VP server-side from the holder's DID document (with keys) and
  # a credential JWT, then verifies the VP for authentication.
  # This is for unauthenticated users who don't yet have a session JWT.
  # ---------------------------------------------------------------------------
  post "/present-with-credential" do
    params = conn.body_params || %{}
    holder_doc_json = params["holder_doc_json"]
    credential_jwt = params["credential_jwt"]
    challenge = params["challenge"]
    private_key_jwk = params["private_key_jwk"]
    fragment = params["fragment"]

    cond do
      is_nil(holder_doc_json) || holder_doc_json == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: holder_doc_json"
        })

      is_nil(credential_jwt) || credential_jwt == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: credential_jwt"
        })

      is_nil(challenge) || challenge == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: challenge"
        })

      is_nil(private_key_jwk) || private_key_jwk == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: private_key_jwk"
        })

      is_nil(fragment) || fragment == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: fragment"
        })

      true ->
        do_vp_login_with_credential(
          conn,
          holder_doc_json,
          credential_jwt,
          challenge,
          private_key_jwk,
          fragment
        )
    end
  end

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Auth route not found"})
  end

  # ===========================================================================
  # Private — DID ownership verification
  # ===========================================================================

  defp verify_did_ownership(user, did) do
    # For static config users, accept any DID (no DID assignment in config)
    # For dynamic users, the DID must match what's assigned to their account
    if Application.get_env(:tangle_gate, :start_repo, true) do
      case TangleGate.Store.UserStore.get_user_by_email(user.email) do
        {:ok, db_user} ->
          cond do
            db_user.did == did ->
              :ok

            is_nil(db_user.did) ->
              {:error, "No DID assigned to your account. Ask an admin to assign one."}

            true ->
              {:error, "DID does not match the one assigned to your account"}
          end

        :not_found ->
          # Static config user — no DID assignment, accept any
          :ok
      end
    else
      :ok
    end
  end

  # ===========================================================================
  # Private — VP-based authentication
  # ===========================================================================

  defp do_vp_authentication(conn, presentation_jwt, challenge, holder_did) do
    # 1. Consume the challenge (single-use)
    case ChallengeCache.consume_challenge(challenge) do
      :not_found ->
        Helpers.json(conn, 401, %{
          error: "invalid_challenge",
          message:
            "Challenge not found or already used. Request a new one via GET /api/auth/challenge."
        })

      :expired ->
        Helpers.json(conn, 401, %{
          error: "challenge_expired",
          message: "Challenge has expired. Request a new one via GET /api/auth/challenge."
        })

      :ok ->
        # 2. Resolve the holder's DID document on-chain
        node_url = Application.get_env(:tangle_gate, :node_url, "https://api.testnet.iota.cafe")
        identity_pkg_id = Application.get_env(:tangle_gate, :identity_pkg_id, "")

        case Verifier.resolve_did_document(holder_did, node_url, identity_pkg_id) do
          {:ok, holder_doc_json} ->
            verify_and_authenticate(
              conn,
              presentation_jwt,
              challenge,
              holder_did,
              holder_doc_json
            )

          {:error, reason} ->
            Helpers.json(conn, 422, %{
              error: "did_resolution_failed",
              message: "Could not resolve holder DID: #{inspect(reason)}"
            })
        end
    end
  end

  defp verify_and_authenticate(conn, presentation_jwt, challenge, holder_did, holder_doc_json) do
    # 3. Get server's DID doc (as issuer) for VC verification
    case CredServer.server_did_info() do
      {:error, :no_server_did} ->
        Helpers.json(conn, 503, %{
          error: "not_provisioned",
          message: "Server DID not provisioned — VP authentication is not available"
        })

      {:ok, server_identity} ->
        issuer_doc = server_identity.document

        # Build issuer docs array (only the server as issuer for now)
        issuer_docs_json =
          case Jason.decode(issuer_doc) do
            {:ok, doc_map} -> Jason.encode!([doc_map])
            # Already a raw string, wrap in array
            {:error, _} -> "[#{issuer_doc}]"
          end

        # 4. Verify the VP using the independent Verifier
        case Verifier.verify_presentation(
               presentation_jwt,
               holder_doc_json,
               issuer_docs_json,
               challenge
             ) do
          {:ok, %{"valid" => true} = result} ->
            # 5. Check revocation status in MongoDB
            if credential_revoked_for_holder?(holder_did) do
              Helpers.json(conn, 401, %{
                error: "credential_revoked",
                message:
                  "Your credential has been revoked. " <>
                    "Log in with email/password and provide your DID to get a new one."
              })
            else
              # 6. Extract claims from the VC to determine user role
              claims = extract_claims_from_vp(result, holder_doc_json, issuer_doc)

              user = %{
                id: holder_did,
                email: Map.get(claims, "email", holder_did),
                role: Map.get(claims, "role", "user") |> to_string()
              }

              case Auth.generate_token(user) do
                {:ok, token, token_claims} ->
                  Helpers.json(conn, 200, %{
                    token: token,
                    expires_at: format_exp(token_claims["exp"]),
                    user: %{id: user.id, email: user.email, role: user.role},
                    holder_did: holder_did,
                    credential_count: result["credential_count"],
                    auth_method: "verifiable_presentation"
                  })

                {:error, reason} ->
                  Helpers.json(conn, 500, %{
                    error: "token_generation_failed",
                    message: "VP verified but token generation failed: #{inspect(reason)}"
                  })
              end
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
    end
  end

  defp extract_claims_from_vp(vp_result, _holder_doc_json, issuer_doc) do
    # Verify the first credential JWT against the server's issuer DID document
    case Map.get(vp_result, "credentials", []) do
      [first_cred_jwt | _] ->
        case Verifier.verify_credential(first_cred_jwt, issuer_doc) do
          {:ok, %{"claims" => claims_json}} when is_binary(claims_json) ->
            case Jason.decode(claims_json) do
              {:ok, %{"credentialSubject" => claims}} when is_map(claims) -> claims
              {:ok, claims} when is_map(claims) -> claims
              _ -> %{}
            end

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp do_vp_login_with_credential(
         conn,
         holder_doc_json,
         credential_jwt,
         challenge,
         private_key_jwk,
         fragment
       ) do
    # 1. Consume the challenge (single-use)
    case ChallengeCache.consume_challenge(challenge) do
      :not_found ->
        Helpers.json(conn, 401, %{
          error: "invalid_challenge",
          message:
            "Challenge not found or already used. Request a new one via GET /api/auth/challenge."
        })

      :expired ->
        Helpers.json(conn, 401, %{
          error: "challenge_expired",
          message: "Challenge has expired. Request a new one via GET /api/auth/challenge."
        })

      :ok ->
        # 2. Create VP from holder doc + credential using the holder's key
        cred_jwts_json = Jason.encode!([credential_jwt])

        case CredServer.create_presentation(
               holder_doc_json,
               cred_jwts_json,
               challenge,
               300,
               private_key_jwk,
               fragment
             ) do
          {:ok, %{"presentation_jwt" => presentation_jwt, "holder_did" => holder_did}} ->
            # 3. Verify the VP cryptographically
            verify_and_authenticate(
              conn,
              presentation_jwt,
              challenge,
              holder_did,
              holder_doc_json
            )

          {:error, reason} ->
            Helpers.json(conn, 422, %{
              error: "presentation_failed",
              message: "Failed to create VP: #{inspect(reason)}"
            })
        end
    end
  end

  defp credential_revoked_for_holder?(holder_did) do
    if Application.get_env(:tangle_gate, :start_repo, true) do
      CredentialStore.all_credentials_revoked?(holder_did)
    else
      false
    end
  end

  defp format_exp(nil), do: nil

  defp format_exp(exp) when is_integer(exp) do
    exp |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end
end
