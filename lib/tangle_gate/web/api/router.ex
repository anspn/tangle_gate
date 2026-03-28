defmodule TangleGate.Web.API.Router do
  @moduledoc """
  REST API router — `/api/*`.

  All routes produce `application/json` responses.
  Mounts sub-routers per domain:

  - `/api/auth/*`         → Authentication (login, challenge, VP-based auth, VP-login-with-credential)
  - `/api/dids/*`         → DID / Identity management
  - `/api/credentials/*`  → VC issuance, VP creation, and server DID management
  - `/api/sessions/*`     → TTY session recording & notarization (VP-gated)
  - `/api/verify/*`       → Notarization verification
  - `/api/health`         → Health check
  """

  use Plug.Router

  alias TangleGate.Web.API.Helpers

  # Parse JSON bodies for all API routes
  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  # --- Health ---------------------------------------------------------------

  get "/health" do
    nif_ready = TangleGate.nif_ready?()
    agent_reachable = TangleGate.Agent.Client.healthy?()

    ledger_reachable =
      case check_ledger() do
        :ok -> true
        _ -> false
      end

    status =
      cond do
        not nif_ready -> "nif_not_loaded"
        not agent_reachable and not ledger_reachable -> "agent_and_ledger_unreachable"
        not agent_reachable -> "agent_unreachable"
        not ledger_reachable -> "ledger_unreachable"
        true -> "ok"
      end

    body = %{
      status: status,
      nif_loaded: nif_ready,
      agent_reachable: agent_reachable,
      ledger_reachable: ledger_reachable,
      timestamp: DateTime.utc_now()
    }

    http_status = if nif_ready, do: 200, else: 503
    Helpers.json(conn, http_status, body)
  end

  # --- Domain routers -------------------------------------------------------

  forward("/auth", to: TangleGate.Web.API.AuthHandler)
  forward("/dashboard", to: TangleGate.Web.API.DashboardHandler)
  forward("/dids", to: TangleGate.Web.API.IdentityHandler)
  forward("/credentials", to: TangleGate.Web.API.CredentialHandler)
  forward("/sessions", to: TangleGate.Web.API.SessionHandler)
  forward("/verify", to: TangleGate.Web.API.VerifyHandler)
  forward("/agent", to: TangleGate.Web.API.AgentHandler)

  # --- Catch-all ------------------------------------------------------------

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "API route not found"})
  end

  # --- Private helpers -------------------------------------------------------

  defp check_ledger do
    node_url = Application.get_env(:tangle_gate, :node_url, "https://api.testnet.iota.cafe")

    case Req.post("#{node_url}",
           json: %{jsonrpc: "2.0", id: 1, method: "iota_getLatestCheckpointSequenceNumber"},
           receive_timeout: 5_000,
           connect_options: [timeout: 3_000]
         ) do
      {:ok, %{status: 200}} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
