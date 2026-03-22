defmodule TangleGate.Identity.Cache do
  @moduledoc """
  ETS-backed cache for DID documents.

  Provides fast local lookup of recently generated or resolved DIDs.
  Uses TTL-based expiration to prevent stale data.

  ## Features
  - ETS table for O(1) lookups
  - Configurable TTL (default: 1 hour)
  - Automatic cleanup of expired entries
  """

  use GenServer

  require Logger

  @table_name :iota_did_cache
  @default_ttl_ms :timer.hours(1)
  @cleanup_interval_ms :timer.minutes(5)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a cached DID document by DID string"
  @spec get(String.t()) :: {:ok, map()} | :miss
  def get(did) when is_binary(did) do
    case :ets.lookup(@table_name, did) do
      [{^did, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          # Expired, delete and return miss
          :ets.delete(@table_name, did)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc "Cache a DID document"
  @spec put(String.t(), map(), keyword()) :: :ok
  def put(did, value, opts \\ []) when is_binary(did) do
    ttl = Keyword.get(opts, :ttl, @default_ttl_ms)
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ets.insert(@table_name, {did, value, expires_at})
    :ok
  end

  @doc "Delete a cached entry"
  @spec delete(String.t()) :: :ok
  def delete(did) when is_binary(did) do
    :ets.delete(@table_name, did)
    :ok
  end

  @doc "Clear all cached entries"
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc "Get cache statistics"
  @spec stats() :: map()
  def stats do
    info = :ets.info(@table_name)

    %{
      size: Keyword.get(info, :size, 0),
      memory_bytes: Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
    }
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    table_opts = [:named_table, :public, :set, read_concurrency: true]
    :ets.new(@table_name, table_opts)

    Logger.info("Identity Cache started (table: #{@table_name})")

    # Schedule periodic cleanup
    schedule_cleanup()

    state = %{
      ttl: Keyword.get(opts, :ttl, @default_ttl_ms),
      cleanup_interval: Keyword.get(opts, :cleanup_interval, @cleanup_interval_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleaned = cleanup_expired()

    if cleaned > 0 do
      Logger.debug("Identity Cache: cleaned up #{cleaned} expired entries")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  # Private Functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    # Find and delete expired entries
    expired =
      :ets.select(@table_name, [
        {{:"$1", :_, :"$2"}, [{:<, :"$2", now}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table_name, &1))
    length(expired)
  end
end
