defmodule TangleGate.Agent.Client do
  @moduledoc """
  HTTP client for communicating with the TangleGate Agent microservice.

  Proxies credential/presentation verification requests to the standalone agent
  running on the same host or network. All functions mirror the former
  `TangleGate.Credential.Verifier` API and return identical result tuples.

  If the agent is unreachable, returns `{:error, :agent_unavailable}`.
  Callers already handle `{:error, reason}`, so degradation is automatic.

  ## Configuration

      config :tangle_gate, TangleGate.Agent.Client,
        url: "http://localhost:8800",
        api_key: "shared-secret",
        timeout: 30_000
  """

  require Logger

  @doc """
  Verify a Verifiable Credential JWT against the issuer's DID document.
  """
  @spec verify_credential(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_credential(credential_jwt, issuer_doc_json) do
    post("/api/verify/credential", %{
      credential_jwt: credential_jwt,
      issuer_doc_json: issuer_doc_json
    })
  end

  @doc """
  Verify a Verifiable Presentation JWT.
  """
  @spec verify_presentation(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def verify_presentation(presentation_jwt, holder_doc_json, issuer_docs_json, challenge) do
    post("/api/verify/presentation", %{
      presentation_jwt: presentation_jwt,
      holder_doc_json: holder_doc_json,
      issuer_docs_json: issuer_docs_json,
      challenge: challenge
    })
  end

  @doc """
  Verify a Verifiable Presentation with automatic on-chain DID resolution.
  """
  @spec verify_presentation_with_resolution(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_presentation_with_resolution(presentation_jwt, challenge, opts) do
    post("/api/verify/presentation/resolve", %{
      presentation_jwt: presentation_jwt,
      challenge: challenge,
      holder_did: Keyword.fetch!(opts, :holder_did),
      issuer_dids: Keyword.fetch!(opts, :issuer_dids),
      node_url: Keyword.get(opts, :node_url),
      identity_pkg_id: Keyword.get(opts, :identity_pkg_id)
    })
  end

  @doc """
  Resolve a DID document from the IOTA ledger via the agent.
  """
  @spec resolve_did_document(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_did_document(did, node_url, identity_pkg_id \\ "") do
    case post("/api/resolve/did", %{
           did: did,
           node_url: node_url,
           identity_pkg_id: identity_pkg_id
         }) do
      {:ok, %{"document" => doc}} when is_map(doc) ->
        {:ok, Jason.encode!(doc)}

      {:ok, %{"document" => doc}} when is_binary(doc) ->
        {:ok, doc}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Check if the agent is healthy and reachable.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    case health_check() do
      {:ok, _body} -> true
      _ -> false
    end
  end

  @doc """
  Perform a health check against the agent and return the full response body.

  Returns `{:ok, body}` on success (HTTP 200) or `{:error, reason}` otherwise.
  The body includes a `ws_url` field with the agent's advertised WebSocket endpoint.
  """
  @spec health_check() :: {:ok, map()} | {:error, term()}
  def health_check do
    config = config()
    url = "#{config[:url]}/api/health"

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "Agent returned status #{status}"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Discover the agent's advertised WebSocket URL from its health endpoint.

  Returns `{:ok, ws_url}` or `{:error, reason}`.
  """
  @spec discover_ws_url() :: {:ok, String.t()} | {:error, term()}
  def discover_ws_url do
    case health_check() do
      {:ok, %{"ws_url" => ws_url}} when is_binary(ws_url) -> {:ok, ws_url}
      {:ok, _body} -> {:error, :ws_url_not_in_response}
      {:error, _} = err -> err
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp post(path, body) do
    config = config()
    url = "#{config[:url]}#{path}"
    timeout = config[:timeout] || 30_000
    api_key = config[:api_key] || ""

    case Req.post(url,
           json: body,
           headers: [{"x-api-key", api_key}],
           receive_timeout: timeout,
           connect_options: [timeout: 5_000]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} when is_map(body) ->
        message = body["message"] || "Agent returned status #{status}"
        {:error, message}

      {:ok, %{status: status}} ->
        {:error, "Agent returned status #{status}"}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.warning("Agent unreachable (#{config[:url]}): #{inspect(reason)}")
        {:error, :agent_unavailable}

      {:error, reason} ->
        Logger.warning("Agent request failed: #{inspect(reason)}")
        {:error, :agent_unavailable}
    end
  rescue
    e ->
      Logger.warning("Agent client error: #{Exception.message(e)}")
      {:error, :agent_unavailable}
  end

  defp config do
    Application.get_env(:tangle_gate, __MODULE__, [])
  end
end
