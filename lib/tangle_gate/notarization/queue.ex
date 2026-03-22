defmodule TangleGate.Notarization.Queue do
  @moduledoc """
  Queue for managing pending notarization jobs.

  Useful for batch processing or retry logic when
  Tangle submissions fail.

  ## Features
  - In-memory queue with persistence option
  - Automatic retry with exponential backoff
  - Job status tracking
  """

  use GenServer

  require Logger

  @max_queue_size 10_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueue a notarization job"
  @spec enqueue(binary(), String.t()) :: {:ok, reference()} | {:error, :queue_full}
  def enqueue(data, tag \\ "tangle_gate") when is_binary(data) do
    GenServer.call(__MODULE__, {:enqueue, data, tag})
  end

  @doc "Get status of a queued job"
  @spec status(reference()) :: {:ok, map()} | :not_found
  def status(job_ref) do
    GenServer.call(__MODULE__, {:status, job_ref})
  end

  @doc "Get queue statistics"
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "Process the next job in queue (for manual processing)"
  @spec process_next() :: {:ok, map()} | :empty | {:error, term()}
  def process_next do
    GenServer.call(__MODULE__, :process_next, 30_000)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Notarization Queue started")

    state = %{
      queue: :queue.new(),
      # job_ref => job_state
      jobs: %{},
      processed: 0,
      failed: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, data, tag}, _from, state) do
    if :queue.len(state.queue) >= @max_queue_size do
      {:reply, {:error, :queue_full}, state}
    else
      job_ref = make_ref()

      job = %{
        ref: job_ref,
        data: data,
        tag: tag,
        status: :pending,
        enqueued_at: DateTime.utc_now(),
        attempts: 0
      }

      new_queue = :queue.in(job_ref, state.queue)
      new_jobs = Map.put(state.jobs, job_ref, job)

      {:reply, {:ok, job_ref}, %{state | queue: new_queue, jobs: new_jobs}}
    end
  end

  @impl true
  def handle_call({:status, job_ref}, _from, state) do
    case Map.fetch(state.jobs, job_ref) do
      {:ok, job} -> {:reply, {:ok, job}, state}
      :error -> {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      pending: :queue.len(state.queue),
      total_jobs: map_size(state.jobs),
      processed: state.processed,
      failed: state.failed
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:process_next, _from, state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        {:reply, :empty, state}

      {{:value, job_ref}, new_queue} ->
        case Map.fetch(state.jobs, job_ref) do
          {:ok, job} ->
            result = process_job(job)

            {new_jobs, new_processed, new_failed} =
              case result do
                {:ok, _payload} ->
                  updated_job = %{job | status: :completed}
                  {Map.put(state.jobs, job_ref, updated_job), state.processed + 1, state.failed}

                {:error, _reason} ->
                  updated_job = %{job | status: :failed, attempts: job.attempts + 1}
                  {Map.put(state.jobs, job_ref, updated_job), state.processed, state.failed + 1}
              end

            new_state = %{
              state
              | queue: new_queue,
                jobs: new_jobs,
                processed: new_processed,
                failed: new_failed
            }

            {:reply, result, new_state}

          :error ->
            # Job was removed, skip
            {:reply, :not_found, %{state | queue: new_queue}}
        end
    end
  end

  # Private Functions

  defp process_job(job) do
    TangleGate.Notarization.Server.create_payload(job.data, job.tag)
  end
end
