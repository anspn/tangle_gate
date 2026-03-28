defmodule TangleGateAgent.Verifier do
  @moduledoc """
  Self-contained Verifiable Credential (VC) and Verifiable Presentation (VP) verifier.

  This module is the core of the TangleGate Agent microservice. It performs
  cryptographic verification of VCs and VPs using IOTA Identity NIFs with
  no dependencies on GenServers, OTP supervision, Application config,
  ETS caches, or databases. Every input is passed explicitly as a function
  argument.

  ## Dependencies

  Only depends on:
  - `:iota_credential_nif` — Erlang NIF for cryptographic verification
  - `:iota_did_nif` — Erlang NIF for DID resolution (optional, for on-chain lookups)
  - `Jason` — JSON encoding/decoding

  ## Usage

      # Verify a VC
      {:ok, result} = Verifier.verify_credential(vc_jwt, issuer_doc_json)

      # Verify a VP with challenge
      {:ok, result} = Verifier.verify_presentation(vp_jwt, holder_doc_json, issuer_docs_json, challenge)

      # Full VP verification with on-chain DID resolution
      {:ok, result} = Verifier.verify_presentation_with_resolution(
        vp_jwt, challenge, node_url: "https://api.testnet.iota.cafe"
      )
  """

  require Logger

  @credential_nif :iota_credential_nif
  @did_nif :iota_did_nif

  # ============================================================================
  # Verifiable Credential Verification
  # ============================================================================

  @doc """
  Verify a Verifiable Credential JWT against the issuer's DID document.

  ## Parameters
  - `credential_jwt` — The VC JWT string to verify
  - `issuer_doc_json` — The issuer's DID document as a JSON string

  ## Returns
  - `{:ok, result}` with `valid`, `issuer_did`, `subject_did`, `claims`
  - `{:error, reason}` if verification fails
  """
  @spec verify_credential(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_credential(credential_jwt, issuer_doc_json)
      when is_binary(credential_jwt) and is_binary(issuer_doc_json) do
    with {:ok, json} <-
           call_nif(@credential_nif, :verify_credential, [credential_jwt, issuer_doc_json]),
         {:ok, parsed} <- Jason.decode(json) do
      {:ok, parsed}
    end
  end

  # ============================================================================
  # Verifiable Presentation Verification
  # ============================================================================

  @doc """
  Verify a Verifiable Presentation JWT.

  Validates the VP signature against the holder's DID document, checks the
  challenge nonce, and validates each contained VC against the provided issuer docs.

  ## Parameters
  - `presentation_jwt` — The VP JWT string
  - `holder_doc_json` — The holder's DID document as a JSON string
  - `issuer_docs_json` — JSON array of issuer DID documents (one per VC, in order)
  - `challenge` — The expected challenge nonce ("" to skip check)

  ## Returns
  - `{:ok, result}` with `valid`, `holder_did`, `credential_count`, `credentials`
  - `{:error, reason}` if verification fails
  """
  @spec verify_presentation(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def verify_presentation(presentation_jwt, holder_doc_json, issuer_docs_json, challenge)
      when is_binary(presentation_jwt) and is_binary(holder_doc_json) and
             is_binary(issuer_docs_json) and is_binary(challenge) do
    with {:ok, json} <-
           call_nif(@credential_nif, :verify_presentation, [
             presentation_jwt,
             holder_doc_json,
             issuer_docs_json,
             challenge
           ]),
         {:ok, parsed} <- Jason.decode(json) do
      {:ok, parsed}
    end
  end

  @doc """
  Verify a Verifiable Presentation with automatic on-chain DID resolution.

  Resolves the holder's DID and each issuer's DID from the IOTA ledger,
  then verifies the VP and all contained VCs.

  ## Parameters
  - `presentation_jwt` — The VP JWT string
  - `challenge` — The expected challenge nonce ("" to skip)
  - `opts` — Options:
    - `:node_url` — (required) IOTA node URL
    - `:identity_pkg_id` — Identity package ObjectID ("" for auto-discovery)
    - `:holder_did` — Holder's DID (required)
    - `:issuer_dids` — List of issuer DIDs (required)

  ## Returns
  - `{:ok, result}` with verification result plus resolved documents
  - `{:error, reason}` if resolution or verification fails
  """
  @spec verify_presentation_with_resolution(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_presentation_with_resolution(presentation_jwt, challenge, opts)
      when is_binary(presentation_jwt) and is_binary(challenge) do
    node_url = Keyword.fetch!(opts, :node_url)
    identity_pkg_id = Keyword.get(opts, :identity_pkg_id, "")

    with {:ok, holder_did} <- extract_holder_did(opts),
         {:ok, holder_doc_json} <- resolve_did_document(holder_did, node_url, identity_pkg_id),
         {:ok, issuer_dids} <- extract_issuer_dids(opts),
         {:ok, issuer_docs} <- resolve_issuer_documents(issuer_dids, node_url, identity_pkg_id),
         issuer_docs_json <- Jason.encode!(issuer_docs),
         {:ok, result} <-
           verify_presentation(presentation_jwt, holder_doc_json, issuer_docs_json, challenge) do
      {:ok, Map.merge(result, %{"holder_did_resolved" => true, "issuer_dids_resolved" => true})}
    end
  end

  # ============================================================================
  # DID Resolution (self-contained, uses NIF directly)
  # ============================================================================

  @doc """
  Resolve a DID document from the IOTA ledger.

  Calls the DID NIF directly — no GenServer or cache involved.

  ## Parameters
  - `did` — The DID string to resolve
  - `node_url` — IOTA node URL
  - `identity_pkg_id` — Identity package ObjectID ("" for auto-discovery)
  """
  @spec resolve_did_document(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_did_document(did, node_url, identity_pkg_id \\ "")
      when is_binary(did) and is_binary(node_url) do
    with {:ok, json} <- call_nif(@did_nif, :resolve_did, [did, node_url, identity_pkg_id]),
         {:ok, parsed} <- Jason.decode(json) do
      case parsed["document"] do
        doc when is_binary(doc) -> {:ok, doc}
        doc when is_map(doc) -> {:ok, Jason.encode!(doc)}
        _ -> {:error, "resolved DID has no document field"}
      end
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp extract_holder_did(opts) do
    case Keyword.get(opts, :holder_did) do
      did when is_binary(did) and did != "" ->
        {:ok, did}

      _ ->
        {:error, "holder_did must be provided in opts for on-chain resolution"}
    end
  end

  defp extract_issuer_dids(opts) do
    case Keyword.get(opts, :issuer_dids) do
      dids when is_list(dids) and length(dids) > 0 ->
        {:ok, dids}

      _ ->
        {:error, "issuer_dids must be provided in opts for on-chain resolution"}
    end
  end

  defp resolve_issuer_documents(issuer_dids, node_url, identity_pkg_id) do
    results =
      Enum.reduce_while(issuer_dids, {:ok, []}, fn did, {:ok, acc} ->
        case resolve_did_document(did, node_url, identity_pkg_id) do
          {:ok, doc_json} ->
            case Jason.decode(doc_json) do
              {:ok, doc} -> {:cont, {:ok, [doc | acc]}}
              {:error, _} -> {:halt, {:error, "failed to parse issuer document for #{did}"}}
            end

          {:error, reason} ->
            {:halt, {:error, "failed to resolve issuer DID #{did}: #{inspect(reason)}"}}
        end
      end)

    case results do
      {:ok, docs} -> {:ok, Enum.reverse(docs)}
      error -> error
    end
  end

  defp call_nif(module, function, args) do
    case apply(module, function, args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  catch
    :error, :undef ->
      {:error, "NIF module #{module} not loaded"}

    :error, :badarg ->
      {:error, :badarg}

    kind, reason ->
      {:error, "NIF call #{module}.#{function} failed: #{kind} - #{inspect(reason)}"}
  end
end
