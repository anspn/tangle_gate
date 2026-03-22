defmodule TangleGate.Notarization.Supervisor do
  @moduledoc """
  Supervisor for Notarization domain services.

  Children:
  - Notarization.Server: Handles notarization operations
  - Notarization.Queue: Queue for pending/retry notarizations
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Queue starts first - Server may need it
      TangleGate.Notarization.Queue,

      # Main notarization server
      TangleGate.Notarization.Server
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
