defmodule TangleGate.Store.Repo do
  @moduledoc """
  MongoDB connection pool managed by the `mongodb_driver` library.

  Starts a topology (connection pool) under the supervision tree.
  All store modules interact with MongoDB through this pool.

  ## Configuration

      config :tangle_gate, TangleGate.Store.Repo,
        url: "mongodb://localhost:27017/tangle_gate"

  In production the URL is read from the `MONGO_URL` environment variable
  via `config/runtime.exs`.
  """

  @pool_name :iota_mongo

  @doc """
  Child spec for the supervision tree.
  """
  def child_spec(_opts) do
    config = Application.get_env(:tangle_gate, __MODULE__, [])
    url = Keyword.get(config, :url, "mongodb://localhost:27017/tangle_gate")

    %{
      id: __MODULE__,
      start: {Mongo, :start_link, [[name: @pool_name, url: url, pool_size: pool_size()]]},
      type: :worker
    }
  end

  @doc """
  Returns the connection pool name for use in Mongo operations.
  """
  @spec pool :: atom()
  def pool, do: @pool_name

  defp pool_size do
    config = Application.get_env(:tangle_gate, __MODULE__, [])
    Keyword.get(config, :pool_size, 5)
  end
end
