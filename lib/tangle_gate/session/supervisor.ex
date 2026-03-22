defmodule TangleGate.Session.Supervisor do
  @moduledoc """
  Supervisor for TTY session recording services.

  Children:
  - Session.Manager: Manages session lifecycle, recording, and notarization
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      TangleGate.Session.Manager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
