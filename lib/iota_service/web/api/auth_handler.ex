defmodule IotaService.Web.API.AuthHandler do
  @moduledoc """
  Authentication API handler.

  ## Endpoints

  - `POST /api/auth/login`     — Authenticate with email/password, receive JWT
  - `GET  /api/auth/challenge` — Get a fresh challenge nonce for VP-based auth
  - `POST /api/auth/present`   — Authenticate with a Verifiable Presentation
  """

  use Plug.Router

  alias IotaService.Credential.ChallengeCache
  alias IotaService.Credential.Server, as: CredServer
  alias IotaService.Credential.Verifier
  alias IotaService.Web.API.Helpers
  alias IotaService.Web.Auth

  plug(:match)
  plug(:dispatch)

  # POST /api/auth/login
  post "/login" do
    with {:ok, %{"email" => email, "password" => password}} <-
           Helpers.require_fields(conn.body_params, ["email", "password"]),
         {:ok, user} <- Auth.authenticate(email, password),
         {:ok, token, claims} <- Auth.generate_token(user) do
      Helpers.json(conn, 200, %{
        token: token,
        expires_at: format_exp(claims["exp"]),
        user: %{id: user.id, email: user.email, role: user.role}
      })
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

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Auth route not found"})
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
        node_url = Application.get_env(:iota_service, :node_url, "https://api.testnet.iota.cafe")
        identity_pkg_id = Application.get_env(:iota_service, :identity_pkg_id, "")

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
            # 5. Extract claims from the VC to determine user role
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
    # The VP contains credential JWTs; verify the first one to extract claims
    case Map.get(vp_result, "credentials", []) do
      [first_cred_jwt | _] ->
        case Verifier.verify_credential(first_cred_jwt, issuer_doc) do
          {:ok, %{"claims" => claims_json}} when is_binary(claims_json) ->
            case Jason.decode(claims_json) do
              {:ok, claims} -> claims
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

  defp format_exp(nil), do: nil

  defp format_exp(exp) when is_integer(exp) do
    exp |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end
end
