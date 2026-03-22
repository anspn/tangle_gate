defmodule TangleGate.Web.API.IdentityHandler do
  @moduledoc """
  DID / Identity API handler.

  All routes require JWT authentication (via `Authenticate` plug).

  ## Endpoints

  - `POST   /api/dids`             — Create (generate or publish) a DID
  - `GET    /api/dids/:did`        — Resolve / look up a DID
  - `POST   /api/dids/:did/revoke` — Deactivate (revoke) a DID on-chain
  """

  use Plug.Router

  alias TangleGate.Web.API.Helpers
  alias TangleGate.Web.Plugs.Authenticate

  # Require Bearer token on all identity routes
  plug(Authenticate)
  plug(:match)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # POST /api/dids/validate — Validate a DID on-chain
  # ---------------------------------------------------------------------------
  post "/validate" do
    params = conn.body_params || %{}
    did = params["did"]

    cond do
      is_nil(did) || did == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: did"
        })

      not TangleGate.valid_did?(did) ->
        Helpers.json(conn, 422, %{
          valid: false,
          did: did,
          message: "Invalid DID format. Expected: did:iota:0x..."
        })

      true ->
        # Resolve on-chain to validate
        opts =
          []
          |> maybe_put(:node_url, params["node_url"])
          |> maybe_put(:identity_pkg_id, params["identity_pkg_id"])
          |> maybe_put(:node_url, Application.get_env(:tangle_gate, :node_url))
          |> maybe_put(:identity_pkg_id, Application.get_env(:tangle_gate, :identity_pkg_id))

        case TangleGate.resolve_did(did, opts) do
          {:ok, resolved} ->
            doc_json = resolved["document"]

            if did_deactivated?(doc_json) do
              Helpers.json(conn, 200, %{
                valid: false,
                did: did,
                message: "DID has been deactivated on-chain",
                document: doc_json
              })
            else
              Helpers.json(conn, 200, %{
                valid: true,
                did: did,
                message: "DID resolved successfully on-chain",
                document: doc_json
              })
            end

          {:error, reason} when is_binary(reason) ->
            Helpers.json(conn, 422, %{
              valid: false,
              did: did,
              message: "DID could not be resolved on-chain: #{reason}"
            })

          {:error, reason} ->
            Helpers.json(conn, 422, %{
              valid: false,
              did: did,
              message: "DID could not be resolved on-chain: #{inspect(reason)}"
            })
        end
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/dids — Create a new DID
  # ---------------------------------------------------------------------------
  post "/" do
    params = conn.body_params || %{}
    publish = params["publish"] == true

    result =
      if publish do
        create_published_did(params)
      else
        network = parse_network(params["network"])
        create_local_did(network)
      end

    case result do
      {:ok, response} ->
        Helpers.json(conn, 201, response)

      {:error, {:invalid_network, _} = reason} ->
        Helpers.json(conn, 400, %{
          error: "invalid_request",
          message: "Invalid network: #{inspect(reason)}"
        })

      {:error, {:missing_option, key}} ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: #{key}"
        })

      {:error, reason} when is_binary(reason) ->
        Helpers.json(conn, 422, %{error: "publish_failed", message: reason})

      {:error, reason} ->
        Helpers.json(conn, 500, %{
          error: "internal_error",
          message: "DID creation failed: #{inspect(reason)}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/dids/:did — Resolve a DID (cache → ledger fallback)
  # ---------------------------------------------------------------------------
  get "/:did" do
    did = URI.decode(did)
    params = Plug.Conn.fetch_query_params(conn).query_params

    unless TangleGate.valid_did?(did) do
      Helpers.json(conn, 400, %{error: "invalid_request", message: "Invalid DID format"})
    else
      case resolve_from_ledger(did, params) do
        {:ok, response} ->
          Helpers.json(conn, 200, response)

        {:error, reason} when is_binary(reason) ->
          Helpers.json(conn, 404, %{error: "not_found", message: reason})

        {:error, reason} ->
          Helpers.json(conn, 404, %{
            error: "not_found",
            message: "Could not resolve DID: #{inspect(reason)}"
          })
      end
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/dids/:did/revoke — Deactivate (revoke) a DID on-chain
  # ---------------------------------------------------------------------------
  post "/:did/revoke" do
    did = URI.decode(did)
    params = conn.body_params || %{}

    unless TangleGate.valid_did?(did) do
      Helpers.json(conn, 400, %{error: "invalid_request", message: "Invalid DID format"})
    else
      case deactivate_did(did, params) do
        {:ok, response} ->
          Helpers.json(conn, 200, response)

        {:error, {:missing_option, key}} ->
          Helpers.json(conn, 400, %{
            error: "missing_parameter",
            message: "Required parameter missing: #{key}"
          })

        {:error, reason} when is_binary(reason) ->
          Helpers.json(conn, 422, %{
            error: "deactivation_failed",
            message: reason
          })

        {:error, reason} ->
          Helpers.json(conn, 500, %{
            error: "internal_error",
            message: "DID deactivation failed: #{inspect(reason)}"
          })
      end
    end
  end

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Identity route not found"})
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp parse_network(nil), do: :iota
  defp parse_network(n) when n in ["iota", "smr", "rms", "atoi"], do: String.to_atom(n)
  defp parse_network(n) when is_atom(n), do: n
  defp parse_network(n), do: {:invalid, n}

  defp create_local_did(network) do
    case TangleGate.generate_did(network: network) do
      {:ok, did_result} ->
        {:ok, format_did_response(did_result, nil, "active")}

      error ->
        error
    end
  end

  defp create_published_did(_params) do
    secret_key = Application.get_env(:tangle_gate, :secret_key)

    unless secret_key && secret_key != "" do
      {:error, {:missing_option, :secret_key}}
    else
      opts =
        [secret_key: secret_key]
        |> maybe_put(:node_url, Application.get_env(:tangle_gate, :node_url))
        |> maybe_put(:identity_pkg_id, Application.get_env(:tangle_gate, :identity_pkg_id))

      case TangleGate.publish_did(opts) do
        {:ok, did_result} ->
          {:ok, format_did_response(did_result, nil, "active")}

        error ->
          error
      end
    end
  end

  defp resolve_from_ledger(did, params) do
    opts =
      []
      |> maybe_put(:node_url, params["node_url"])
      |> maybe_put(:identity_pkg_id, params["identity_pkg_id"])
      # Fall back to Application env if client didn't supply
      |> maybe_put(:node_url, Application.get_env(:tangle_gate, :node_url))
      |> maybe_put(:identity_pkg_id, Application.get_env(:tangle_gate, :identity_pkg_id))

    case TangleGate.resolve_did(did, opts) do
      {:ok, resolved} ->
        {:ok,
         %{
           did: resolved["did"],
           network: resolved["network"],
           document: resolved["document"],
           status: "active"
         }}

      error ->
        error
    end
  end

  defp deactivate_did(did, _params) do
    secret_key = Application.get_env(:tangle_gate, :secret_key)

    unless secret_key && secret_key != "" do
      {:error, {:missing_option, :secret_key}}
    else
      opts =
        [secret_key: secret_key]
        |> maybe_put(:node_url, Application.get_env(:tangle_gate, :node_url))
        |> maybe_put(:identity_pkg_id, Application.get_env(:tangle_gate, :identity_pkg_id))

      case TangleGate.deactivate_did(did, opts) do
        {:ok, _} ->
          {:ok,
           %{
             did: did,
             status: "deactivated",
             message: "DID has been permanently deactivated on-chain"
           }}

        error ->
          error
      end
    end
  end

  defp format_did_response(did_result, label, status) do
    doc =
      case Map.get(did_result, :document) do
        nil -> nil
        doc when is_binary(doc) -> try_decode_json(doc)
        doc -> doc
      end

    %{
      did: did_result.did,
      network: to_string(Map.get(did_result, :network, "iota")),
      label: label,
      created_at:
        Map.get(did_result, :published_at, Map.get(did_result, :generated_at, DateTime.utc_now()))
        |> DateTime.to_iso8601(),
      status: status,
      document: doc
    }
  end

  defp try_decode_json(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> decoded
      _ -> str
    end
  end

  # Check whether a resolved DID document has been deactivated on-chain.
  # The document JSON has the shape: {"doc": {...}, "meta": {"deactivated": true, ...}}
  defp did_deactivated?(doc_json) when is_binary(doc_json) do
    case Jason.decode(doc_json) do
      {:ok, %{"meta" => %{"deactivated" => true}}} -> true
      _ -> false
    end
  end

  defp did_deactivated?(_), do: false

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts

  defp maybe_put(opts, key, value) do
    if Keyword.has_key?(opts, key), do: opts, else: Keyword.put(opts, key, value)
  end
end
