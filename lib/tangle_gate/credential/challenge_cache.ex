defmodule TangleGate.Credential.ChallengeCache do
  @moduledoc """
  ETS-backed cache for VP challenge nonces.

  Generates cryptographically random challenge strings and stores them
  with a short TTL. When a VP is submitted, the challenge is consumed
  (single-use) — preventing replay attacks.

  ## Design

  - Each challenge is 32 bytes of random data, hex-encoded (64 chars).
  - Challenges expire after a configurable TTL (default: 5 minutes).
  - A periodic cleanup sweeps expired entries every minute.
  - Consuming a challenge deletes it from the table (single-use).
  """

  # TODO: Evaluate converting challenge storage from ETS to MongoDB
  # for persistence across node restarts and multi-node deployments.

  use GenServer

  require Logger

  @table_name :iota_challenge_cache
  @default_ttl_ms :timer.minutes(5)
  @cleanup_interval_ms :timer.minutes(1)

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generate a new challenge nonce and store it in the cache.

  Returns `{:ok, challenge}` with the hex-encoded challenge string.
  """
  @spec generate_challenge() :: {:ok, String.t()}
  def generate_challenge do
    challenge = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    expires_at = System.monotonic_time(:millisecond) + @default_ttl_ms
    :ets.insert(@table_name, {challenge, expires_at})
    {:ok, challenge}
  end

  @doc """
  Consume (validate and delete) a challenge nonce.

  Returns `:ok` if the challenge existed and had not expired,
  `:expired` if it existed but is past its TTL,
  or `:not_found` if it was never issued or already consumed.
  """
  @spec consume_challenge(String.t()) :: :ok | :expired | :not_found
  def consume_challenge(challenge) when is_binary(challenge) do
    case :ets.lookup(@table_name, challenge) do
      [{^challenge, expires_at}] ->
        :ets.delete(@table_name, challenge)

        if System.monotonic_time(:millisecond) < expires_at do
          :ok
        else
          :expired
        end

      [] ->
        :not_found
    end
  end

  @doc """
  Check if a challenge exists and is valid (without consuming it).
  """
  @spec valid_challenge?(String.t()) :: boolean()
  def valid_challenge?(challenge) when is_binary(challenge) do
    case :ets.lookup(@table_name, challenge) do
      [{^challenge, expires_at}] ->
        System.monotonic_time(:millisecond) < expires_at

      [] ->
        false
    end
  end

  @doc "Get cache statistics."
  @spec stats() :: map()
  def stats do
    now = System.monotonic_time(:millisecond)
    all = :ets.tab2list(@table_name)
    active = Enum.count(all, fn {_challenge, expires_at} -> now < expires_at end)

    %{
      total: length(all),
      active: active,
      expired: length(all) - active
    }
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    Logger.info("Challenge cache started (table: #{inspect(table)})")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    expired =
      :ets.select(@table_name, [
        {{:"$1", :"$2"}, [{:<, :"$2", now}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table_name, &1))

    if length(expired) > 0 do
      Logger.debug("Challenge cache cleanup: removed #{length(expired)} expired entries")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
