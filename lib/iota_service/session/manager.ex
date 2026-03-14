defmodule IotaService.Session.Manager do
  @moduledoc """
  GenServer for TTY session recording and notarization.

  Manages the lifecycle of user-role TTY sessions:

  1. **Start** — A session is created when a user validates their DID on the portal.
     A pending file is written to the shared volume so the ttyd shell can claim it.
  2. **Record** — The ttyd shell logs commands to a history file in the session directory.
  3. **End** — When the user disconnects, the session is finalized:
     - Command history is read from the session directory
     - A SHA-256 hash of the session document is computed
     - A notarization payload is created
     - If a notarization secret key is configured, the hash is published on-chain

  ## Session Storage

  Sessions are tracked in an ETS table (`:iota_sessions`) and backed by files
  in the sessions directory (shared Docker volume).

  ## Architecture

  ```
  Portal JS                    ttyd container          Session.Manager
  ──────────                   ──────────────          ───────────────
  DID validated ──POST────────────────────────────────► start_session()
                               reads pending file       │ writes pending file
                               creates session dir      │ creates ETS record
                               logs commands to disk     │
  Disconnect ────POST────────────────────────────────► end_session()
                                                        │ reads history file
                                                        │ hashes + notarizes
                                                        │ publishes on-chain
  ```
  """

  use GenServer

  require Logger

  alias IotaService.Store.NotarizationStore

  @table :iota_sessions

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a new TTY recording session.

  Creates a session record and writes a pending file to the sessions directory
  so the ttyd shell can link to it.

  ## Parameters
  - `did` — The validated DID of the user
  - `user_id` — The authenticated user's ID

  ## Returns
  `{:ok, session}` with the session map including `session_id`.
  """
  @spec start_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def start_session(did, user_id) when is_binary(did) and is_binary(user_id) do
    GenServer.call(__MODULE__, {:start_session, did, user_id})
  end

  @doc """
  End a TTY recording session.

  Reads the command history from the session directory, computes a hash,
  creates a notarization payload, and optionally publishes on-chain.

  ## Parameters
  - `session_id` — The session to end

  ## Returns
  `{:ok, session}` with notarization details.
  """
  @spec end_session(String.t()) :: {:ok, map()} | {:error, term()}
  def end_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:end_session, session_id}, 120_000)
  end

  @doc """
  Get a session by ID.
  """
  @spec get_session(String.t()) :: {:ok, map()} | :not_found
  def get_session(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] -> {:ok, session}
      [] -> :not_found
    end
  end

  @doc """
  List all sessions, optionally filtered.

  ## Options
  - `:user_id` — Filter by user ID
  - `:did` — Filter by DID
  - `:status` — Filter by status (`:active`, `:ended`, `:notarized`, `:failed`)
  - `:limit` — Maximum number of results (default: 100)
  """
  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, session} -> session end)
    |> filter_sessions(opts)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Get aggregate statistics about sessions.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Get the downloadable session document — the exact JSON whose SHA-256 hash
  was published on-chain.

  Returns `{:ok, document_json_binary}` where the binary is the canonical
  JSON string. Running `sha256sum` on it will match `notarization_hash`.
  """
  @spec get_session_history(String.t()) :: {:ok, binary()} | :not_found
  def get_session_history(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, %{document_json: doc}}] when is_binary(doc) ->
        {:ok, doc}

      [{^session_id, _session}] ->
        # document_json not in memory — try reading from MongoDB
        if repo_started?() do
          case NotarizationStore.get_document(session_id) do
            {:ok, content} -> {:ok, content}
            :not_found -> {:error, :no_document}
          end
        else
          {:error, :no_document}
        end

      [] ->
        :not_found
    end
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for session storage
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Ensure sessions directory exists
    sessions_dir = sessions_dir()
    File.mkdir_p!(sessions_dir)
    File.mkdir_p!(Path.join(sessions_dir, "pending"))

    # Load persisted sessions from MongoDB into ETS cache
    load_persisted_sessions()

    Logger.info("Session Manager started (sessions_dir: #{sessions_dir})")

    state = %{
      sessions_started: 0,
      sessions_ended: 0,
      sessions_notarized: 0,
      sessions_failed: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_session, did, user_id}, _from, state) do
    session_id = generate_session_id()
    now = DateTime.utc_now()

    session = %{
      session_id: session_id,
      did: did,
      user_id: user_id,
      started_at: now,
      ended_at: nil,
      status: :active,
      command_count: 0,
      commands: [],
      document_json: nil,
      notarization_hash: nil,
      notarization_payload: nil,
      on_chain_id: nil,
      error: nil
    }

    # Store in ETS (hot cache)
    :ets.insert(@table, {session_id, session})

    # Write pending file for ttyd shell to consume
    write_pending_file(session_id, did)

    # Persist session metadata to MongoDB asynchronously
    persist_async({:upsert_session, session})

    emit_telemetry(:start, %{did: did, user_id: user_id})

    Logger.info("Session #{session_id} started for DID #{did} (user: #{user_id})")

    new_state = %{state | sessions_started: state.sessions_started + 1}
    {:reply, {:ok, session}, new_state}
  end

  @impl true
  def handle_call({:end_session, session_id}, _from, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] when session.status == :active ->
        {result, new_state} = do_end_session(session, state)
        {:reply, result, new_state}

      [{^session_id, session}] ->
        # Session already ended — return current state
        {:reply, {:ok, session}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    all = :ets.tab2list(@table)
    sessions = Enum.map(all, fn {_id, s} -> s end)

    stats = %{
      total: length(sessions),
      active: Enum.count(sessions, &(&1.status == :active)),
      ended: Enum.count(sessions, &(&1.status == :ended)),
      notarized: Enum.count(sessions, &(&1.status == :notarized)),
      failed: Enum.count(sessions, &(&1.status == :failed)),
      sessions_started: state.sessions_started,
      sessions_ended: state.sessions_ended,
      sessions_notarized: state.sessions_notarized,
      sessions_failed: state.sessions_failed
    }

    {:reply, stats, state}
  end

  # Async MongoDB persistence callbacks
  @impl true
  def handle_info({:persist, {:upsert_session, session}}, state) do
    NotarizationStore.upsert_session(session)
    {:noreply, state}
  catch
    kind, reason ->
      Logger.warning("Async upsert_session failed: #{inspect(kind)} #{inspect(reason)}")
      {:noreply, state}
  end

  @impl true
  def handle_info({:persist, {:store_document, session_id, doc_json, hash}}, state) do
    NotarizationStore.store_document(session_id, doc_json, hash)
    {:noreply, state}
  catch
    kind, reason ->
      Logger.warning("Async store_document failed: #{inspect(kind)} #{inspect(reason)}")
      {:noreply, state}
  end

  # ============================================================================
  # Private — Session Finalization
  # ============================================================================

  defp do_end_session(session, state) do
    now = DateTime.utc_now()

    # Read command history from the session directory
    {commands, command_count} = read_session_history(session.session_id)

    # Build the session document for notarization
    session_document = build_session_document(session, commands, now)
    document_json = Jason.encode!(session_document)

    # Hash the session document
    hash = IotaService.Notarization.Server.hash_data(document_json)

    # Create notarization payload
    notarization_result =
      case IotaService.Notarization.Server.create_payload(document_json, "tty_session") do
        {:ok, payload} -> {:ok, payload}
        error -> error
      end

    # Attempt on-chain notarization if secret key is configured
    on_chain_result = maybe_publish_on_chain(hash, session)

    # Determine final status
    {final_status, on_chain_id, error} =
      case on_chain_result do
        {:ok, %{"object_id" => oid}} ->
          {:notarized, oid, nil}

        {:ok, result} when is_map(result) ->
          oid = Map.get(result, "object_id") || Map.get(result, "objectId")
          {:notarized, oid, nil}

        :skip ->
          # No secret key configured — still mark as ended with hash
          {:ended, nil, nil}

        {:error, reason} ->
          Logger.warning(
            "On-chain notarization failed for session #{session.session_id}: #{inspect(reason)}"
          )

          {:failed, nil, inspect(reason)}
      end

    notarization_payload =
      case notarization_result do
        {:ok, payload} -> payload
        _ -> nil
      end

    updated_session = %{
      session
      | ended_at: now,
        status: final_status,
        command_count: command_count,
        commands: commands,
        document_json: document_json,
        notarization_hash: hash,
        notarization_payload: notarization_payload,
        on_chain_id: on_chain_id,
        error: error
    }

    # Update ETS (hot cache)
    :ets.insert(@table, {session.session_id, updated_session})

    # Persist document and final session state to MongoDB asynchronously
    persist_async({:store_document, session.session_id, document_json, hash})
    persist_async({:upsert_session, updated_session})

    emit_telemetry(:end, %{
      session_id: session.session_id,
      status: final_status,
      command_count: command_count
    })

    Logger.info(
      "Session #{session.session_id} ended: #{final_status}, " <>
        "#{command_count} commands, hash=#{String.slice(hash || "", 0..15)}..."
    )

    new_state =
      state
      |> Map.update!(:sessions_ended, &(&1 + 1))
      |> then(fn s ->
        case final_status do
          :notarized -> %{s | sessions_notarized: s.sessions_notarized + 1}
          :failed -> %{s | sessions_failed: s.sessions_failed + 1}
          _ -> s
        end
      end)

    {{:ok, updated_session}, new_state}
  end

  # ============================================================================
  # Private — History & Document
  # ============================================================================

  @doc false
  defp read_session_history(session_id) do
    # The audit log is the authoritative, tamper-proof record.
    # It is written by the DEBUG trap in session_shell.sh and has
    # chattr +a (append-only) while the shell is running.
    audit_path = Path.join([sessions_dir(), session_id, "audit.log"])
    history_path = Path.join([sessions_dir(), session_id, "history"])

    # Wait briefly for the bash EXIT trap to flush after the WebSocket
    # disconnects. The JS side also waits ~1 s, but belt-and-suspenders.
    Process.sleep(500)

    case read_audit_log(audit_path) do
      {commands, count} when count > 0 ->
        {commands, count}

      _ ->
        # Retry once after a longer delay (race condition with shell exit)
        Process.sleep(1_000)

        case read_audit_log(audit_path) do
          {commands, count} when count > 0 ->
            {commands, count}

          _ ->
            # Fallback: try the bash HISTFILE (less reliable but better than nothing)
            Logger.debug("No audit log for session #{session_id}, trying HISTFILE fallback")

            case read_history_file(history_path) do
              {commands, count} when count > 0 ->
                {commands, count}

              _ ->
                # Final fallback: if the pending-file handoff failed, the shell
                # generated its own session_id. Check the "current" pointer.
                fallback_read_history(session_id)
            end
        end
    end
  end

  # Read and parse the tamper-proof audit log.
  # Format: ISO-timestamp\tsequence\tcommand
  defp read_audit_log(path) do
    case File.read(path) do
      {:ok, content} when byte_size(content) > 0 ->
        commands =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_audit_line/1)
          |> Enum.reject(&is_nil/1)

        {commands, length(commands)}

      {:ok, _empty} ->
        {[], 0}

      {:error, reason} ->
        Logger.debug("Could not read audit log at #{path}: #{inspect(reason)}")
        {[], 0}
    end
  end

  # Parse an audit log line: "2026-02-28T12:34:56Z\t1\tls -la"
  defp parse_audit_line(line) do
    case String.split(line, "\t", parts: 3) do
      [timestamp, _seq, command] when command != "" ->
        %{timestamp: String.trim(timestamp), command: String.trim(command)}

      _ ->
        nil
    end
  end

  # Attempt to read and parse a single bash history file.
  defp read_history_file(path) do
    case File.read(path) do
      {:ok, content} when byte_size(content) > 0 ->
        commands =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_history_line/1)
          |> Enum.reject(&is_nil/1)

        {commands, length(commands)}

      {:ok, _empty} ->
        {[], 0}

      {:error, reason} ->
        Logger.debug("Could not read history at #{path}: #{inspect(reason)}")
        {[], 0}
    end
  end

  # Check the "current" pointer file — the session shell writes its actual
  # session_id here on every launch. If the shell used a different session_id
  # (e.g. pending-file handoff failed), we can still find the history.
  defp fallback_read_history(session_id) do
    current_path = Path.join(sessions_dir(), "current")

    with {:ok, raw} <- File.read(current_path),
         shell_session_id = String.trim(raw),
         true <- shell_session_id != "" and shell_session_id != session_id do
      alt_path = Path.join([sessions_dir(), shell_session_id, "history"])

      case read_history_file(alt_path) do
        {commands, count} when count > 0 ->
          Logger.info(
            "Session #{session_id}: found #{count} commands via fallback " <>
              "(shell session: #{shell_session_id})"
          )

          {commands, count}

        _ ->
          Logger.debug("No history found for session #{session_id} (direct or fallback)")
          {[], 0}
      end
    else
      _ ->
        Logger.debug("No history found for session #{session_id}")
        {[], 0}
    end
  end

  # Parse bash history lines. With HISTTIMEFORMAT set, lines alternate between
  # timestamps (#epoch) and commands.
  defp parse_history_line("#" <> _), do: nil
  defp parse_history_line(""), do: nil

  defp parse_history_line(line) do
    line = String.trim(line)

    # HISTTIMEFORMAT produces lines like: " 1234  2025-01-01T12:00:00 command"
    case Regex.run(~r/^\s*\d+\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\s+(.+)$/, line) do
      [_, timestamp, command] ->
        %{timestamp: timestamp, command: command}

      _ ->
        # Plain history line (no timestamp format)
        case Regex.run(~r/^\s*\d+\s+(.+)$/, line) do
          [_, command] -> %{command: String.trim(command)}
          _ -> %{command: line}
        end
    end
  end

  defp build_session_document(session, commands, ended_at) do
    %{
      type: "tty_session_recording",
      version: "1.0",
      session_id: session.session_id,
      did: session.did,
      user_id: session.user_id,
      started_at: DateTime.to_iso8601(session.started_at),
      ended_at: DateTime.to_iso8601(ended_at),
      command_count: length(commands),
      commands:
        Enum.map(commands, fn cmd ->
          Map.put(cmd, :command, cmd.command)
        end)
    }
  end

  # ============================================================================
  # Private — On-chain Notarization
  # ============================================================================

  defp maybe_publish_on_chain(hash, session) do
    secret_key = Application.get_env(:iota_service, :secret_key)

    if secret_key && secret_key != "" do
      description = "TTY session #{session.session_id} for DID #{session.did}"

      opts = [
        secret_key: secret_key,
        state_data: hash,
        description: description
      ]

      Logger.info("Publishing session #{session.session_id} notarization on-chain...")

      IotaService.Notarization.Server.create_on_chain(opts)
    else
      Logger.debug("No secret_key configured — skipping on-chain publication")
      :skip
    end
  end

  # ============================================================================
  # Private — File Operations
  # ============================================================================

  defp write_pending_file(session_id, did) do
    pending_dir = Path.join(sessions_dir(), "pending")
    File.mkdir_p!(pending_dir)

    # Simple text file: line 1 = session_id, line 2 = DID
    content = "#{session_id}\n#{did}\n"
    path = Path.join(pending_dir, "#{session_id}.session")

    case File.write(path, content) do
      :ok ->
        Logger.debug("Wrote pending session file: #{path}")

      {:error, reason} ->
        Logger.warning("Failed to write pending session file: #{inspect(reason)}")
    end
  end

  defp load_persisted_sessions do
    if not Application.get_env(:iota_service, :start_repo, true) do
      Logger.debug("MongoDB disabled — skipping session load from database")
    else
      sessions = NotarizationStore.list_sessions(limit: 1000)

      Enum.each(sessions, fn session ->
        # Load document_json from the documents collection
        doc_json =
          case NotarizationStore.get_document(session.session_id) do
            {:ok, json} -> json
            _ -> nil
          end

        session = %{session | document_json: doc_json}
        :ets.insert(@table, {session.session_id, session})
      end)

      count = :ets.info(@table, :size)
      if count > 0, do: Logger.info("Loaded #{count} persisted session(s) from MongoDB")
    end
  catch
    kind, reason ->
      Logger.warning("Could not load sessions from MongoDB: #{inspect(kind)} #{inspect(reason)}")
  end

  defp parse_status("active"), do: :active
  defp parse_status("ended"), do: :ended
  defp parse_status("notarized"), do: :notarized
  defp parse_status("failed"), do: :failed
  defp parse_status(_), do: :ended

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  defp repo_started?, do: Application.get_env(:iota_service, :start_repo, true)

  defp persist_async(op) do
    if repo_started?(), do: send(self(), {:persist, op})
  end

  defp sessions_dir do
    Application.get_env(:iota_service, :sessions_dir) ||
      Path.join(:code.priv_dir(:iota_service) |> to_string(), "sessions")
  end

  defp generate_session_id do
    # Generate a URL-safe unique ID (similar to UUID v4)
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> String.slice(0, 22)
    |> then(&("ses_" <> &1))
  end

  defp filter_sessions(sessions, opts) do
    sessions
    |> maybe_filter(:user_id, Keyword.get(opts, :user_id))
    |> maybe_filter(:did, Keyword.get(opts, :did))
    |> maybe_filter(:status, Keyword.get(opts, :status))
  end

  defp maybe_filter(sessions, _field, nil), do: sessions

  defp maybe_filter(sessions, :status, status) when is_atom(status) do
    Enum.filter(sessions, &(&1.status == status))
  end

  defp maybe_filter(sessions, :status, status) when is_binary(status) do
    maybe_filter(sessions, :status, parse_status(status))
  end

  defp maybe_filter(sessions, field, value) do
    Enum.filter(sessions, &(Map.get(&1, field) == value))
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:iota_service, :session, event],
      %{system_time: System.system_time()},
      metadata
    )
  end
end
