defmodule TangleGateAgent.Application do
  @moduledoc """
  TangleGate Agent OTP Application.

  ## Supervision Tree

      TangleGateAgent.Application (rest_for_one)
      ├── TangleGateAgent.NIF.Loader          # Ensures NIF is loaded first
      ├── TangleGateAgent.Session.Tracker      # ETS session tracking
      ├── TangleGateAgent.WS.Client           # WebSocket client to tangle_gate
      └── Bandit (port 8800)                   # HTTP verification API
          └── TangleGateAgent.Web.Router

  **Strategy**: `rest_for_one` — if NIF.Loader crashes, all downstream
  services restart since they depend on it.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting TangleGate Agent")

    children =
      [
        TangleGateAgent.NIF.Loader,
        TangleGateAgent.Session.Tracker,
        TangleGateAgent.WS.Client
      ] ++ web_children()

    opts = [strategy: :rest_for_one, name: TangleGateAgent.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("TangleGate Agent started successfully")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start TangleGate Agent: #{inspect(reason)}")
        error
    end
  end

  defp web_children do
    if Application.get_env(:tangle_gate_agent, :start_web, true) do
      port = Application.get_env(:tangle_gate_agent, :port, 8800)
      Logger.info("Starting agent web server on 0.0.0.0:#{port}")
      [{Bandit, plug: TangleGateAgent.Web.Router, port: port, ip: {0, 0, 0, 0}}]
    else
      []
    end
  end
end
