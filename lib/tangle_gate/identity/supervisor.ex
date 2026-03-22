defmodule TangleGate.Identity.Supervisor do
  @moduledoc """
  Supervisor for Identity domain services.

  Children:
  - Identity.Server: Handles DID generation and validation
  - Identity.Cache: ETS-backed cache for DID documents
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Cache starts first - Server may need it
      TangleGate.Identity.Cache,

      # Main DID operations server
      TangleGate.Identity.Server
    ]

    # one_for_one: Cache and Server are independent
    # If one crashes, don't restart the other
    Supervisor.init(children, strategy: :one_for_one)
  end
end
