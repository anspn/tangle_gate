defmodule TangleGateAgent do
  @moduledoc """
  TangleGate Agent — standalone credential verification microservice.

  Exposes Verifiable Credential and Verifiable Presentation verification
  via HTTP REST API, and manages session termination on the host system.
  The main tangle_gate application connects to this agent via WebSocket
  (`/ws/events`) for real-time session lifecycle events.

  ## API

      POST /api/verify/credential           — Verify VC JWT
      POST /api/verify/presentation         — Verify VP JWT
      POST /api/verify/presentation/resolve — Verify VP with on-chain DID resolution
      POST /api/resolve/did                 — Resolve DID document from IOTA ledger
      GET  /api/health                      — Health check
      WS   /ws/events                       — WebSocket for session events

  ## Architecture

      TangleGateAgent.Application (rest_for_one)
      ├── TangleGateAgent.NIF.Loader          # Ensures Rust NIF is loaded
      ├── TangleGateAgent.Session.Tracker      # ETS-based session tracking
      └── Bandit (port 8800)                   # HTTP + WebSocket server
          └── TangleGateAgent.Web.Router       # /api/* + /ws/events
  """

  defdelegate verify_credential(credential_jwt, issuer_doc_json),
    to: TangleGateAgent.Verifier

  defdelegate verify_presentation(presentation_jwt, holder_doc_json, issuer_docs_json, challenge),
    to: TangleGateAgent.Verifier

  defdelegate verify_presentation_with_resolution(presentation_jwt, challenge, opts),
    to: TangleGateAgent.Verifier

  defdelegate resolve_did_document(did, node_url, identity_pkg_id),
    to: TangleGateAgent.Verifier

  @spec nif_ready?() :: boolean()
  def nif_ready?, do: TangleGateAgent.NIF.Loader.ready?()
end
