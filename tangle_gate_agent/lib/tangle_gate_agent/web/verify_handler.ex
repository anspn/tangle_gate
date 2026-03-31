defmodule TangleGateAgent.Web.VerifyHandler do
  @moduledoc """
  HTTP handler for credential and presentation verification.

  ## Endpoints

  - `POST /api/verify/credential`              — Verify a VC JWT
  - `POST /api/verify/presentation`            — Verify a VP JWT
  - `POST /api/verify/presentation/resolve`    — Verify VP with on-chain DID resolution
  - `POST /api/resolve/did`                    — Resolve a DID document from the IOTA ledger
  - `GET  /api/health`                         — Health check
  """

  use Plug.Router

  alias TangleGateAgent.Verifier
  alias TangleGateAgent.Web.Helpers

  plug(:match)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # POST /api/verify/credential
  # ---------------------------------------------------------------------------
  post "/verify/credential" do
    params = conn.body_params || %{}

    case Helpers.require_fields(params, ["credential_jwt", "issuer_doc_json"]) do
      {:ok, %{"credential_jwt" => jwt, "issuer_doc_json" => issuer_doc}} ->
        case Verifier.verify_credential(jwt, issuer_doc) do
          {:ok, result} ->
            Helpers.json(conn, 200, result)

          {:error, reason} ->
            Helpers.json(conn, 422, %{
              error: "verification_failed",
              message: inspect(reason)
            })
        end

      {:error, missing} ->
        Helpers.json(conn, 400, %{
          error: "missing_parameters",
          message: "Required parameters missing: #{Enum.join(missing, ", ")}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/verify/presentation
  # ---------------------------------------------------------------------------
  post "/verify/presentation" do
    params = conn.body_params || %{}

    case Helpers.require_fields(params, [
           "presentation_jwt",
           "holder_doc_json",
           "issuer_docs_json",
           "challenge"
         ]) do
      {:ok,
       %{
         "presentation_jwt" => vp_jwt,
         "holder_doc_json" => holder_doc,
         "issuer_docs_json" => issuer_docs,
         "challenge" => challenge
       }} ->
        case Verifier.verify_presentation(vp_jwt, holder_doc, issuer_docs, challenge) do
          {:ok, result} ->
            Helpers.json(conn, 200, result)

          {:error, reason} ->
            Helpers.json(conn, 422, %{
              error: "verification_failed",
              message: inspect(reason)
            })
        end

      {:error, missing} ->
        Helpers.json(conn, 400, %{
          error: "missing_parameters",
          message: "Required parameters missing: #{Enum.join(missing, ", ")}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/verify/presentation/resolve
  # ---------------------------------------------------------------------------
  post "/verify/presentation/resolve" do
    params = conn.body_params || %{}

    case Helpers.require_fields(params, [
           "presentation_jwt",
           "challenge",
           "holder_did",
           "issuer_dids"
         ]) do
      {:ok,
       %{
         "presentation_jwt" => vp_jwt,
         "challenge" => challenge,
         "holder_did" => holder_did,
         "issuer_dids" => issuer_dids
       }}
      when is_list(issuer_dids) ->
        node_url =
          Map.get(params, "node_url") ||
            Application.get_env(:tangle_gate_agent, :node_url)

        identity_pkg_id =
          Map.get(params, "identity_pkg_id") ||
            Application.get_env(:tangle_gate_agent, :identity_pkg_id, "")

        opts = [
          node_url: node_url,
          identity_pkg_id: identity_pkg_id,
          holder_did: holder_did,
          issuer_dids: issuer_dids
        ]

        case Verifier.verify_presentation_with_resolution(vp_jwt, challenge, opts) do
          {:ok, result} ->
            Helpers.json(conn, 200, result)

          {:error, reason} ->
            Helpers.json(conn, 422, %{
              error: "verification_failed",
              message: inspect(reason)
            })
        end

      {:ok, _} ->
        Helpers.json(conn, 400, %{
          error: "invalid_parameter",
          message: "issuer_dids must be a JSON array of DID strings"
        })

      {:error, missing} ->
        Helpers.json(conn, 400, %{
          error: "missing_parameters",
          message: "Required parameters missing: #{Enum.join(missing, ", ")}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/resolve/did
  # ---------------------------------------------------------------------------
  post "/resolve/did" do
    params = conn.body_params || %{}

    case Helpers.require_fields(params, ["did"]) do
      {:ok, %{"did" => did}} ->
        node_url =
          Map.get(params, "node_url") ||
            Application.get_env(:tangle_gate_agent, :node_url)

        identity_pkg_id =
          Map.get(params, "identity_pkg_id") ||
            Application.get_env(:tangle_gate_agent, :identity_pkg_id, "")

        case Verifier.resolve_did_document(did, node_url, identity_pkg_id) do
          {:ok, doc_json} ->
            Helpers.json(conn, 200, %{document: Jason.decode!(doc_json)})

          {:error, reason} ->
            Helpers.json(conn, 422, %{
              error: "resolution_failed",
              message: inspect(reason)
            })
        end

      {:error, missing} ->
        Helpers.json(conn, 400, %{
          error: "missing_parameters",
          message: "Required parameters missing: #{Enum.join(missing, ", ")}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/health
  # ---------------------------------------------------------------------------
  get "/health" do
    nif_ready = TangleGateAgent.NIF.Loader.ready?()

    status = if nif_ready, do: "ok", else: "unavailable"
    code = if nif_ready, do: 200, else: 503

    ws_url = Application.get_env(:tangle_gate_agent, :ws_url, "ws://localhost:8800/ws/events")

    Helpers.json(conn, code, %{
      status: status,
      nif_loaded: nif_ready,
      ws_url: ws_url,
      timestamp: DateTime.utc_now()
    })
  end

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Route not found"})
  end
end
