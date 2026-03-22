defmodule TangleGate.Credential.Supervisor do
  @moduledoc """
  Supervisor for Credential domain services.

  Children:
  - Credential.ChallengeCache: ETS-backed challenge nonce store for VP replay protection
  - Credential.Server: Handles VC/VP operations (create, verify)
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Challenge cache starts first — Server may need it
      TangleGate.Credential.ChallengeCache,

      # Main VC/VP operations server
      TangleGate.Credential.Server
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
