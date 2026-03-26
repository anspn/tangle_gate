defmodule TangleGate.Store.NotarizationStore do
  @moduledoc """
  MongoDB-backed storage for notarization documents and session records.

  Replaces the previous filesystem-based storage (session.json / document.json)
  with durable MongoDB collections.

  ## Collections

  - `sessions` — Session metadata and lifecycle state
  - `notarization_documents` — Canonical session documents (the exact JSON whose
    SHA-256 hash is published on-chain)
  """

  alias TangleGate.Store.Repo

  require Logger

  @sessions_collection "sessions"
  @documents_collection "notarization_documents"

  # ============================================================================
  # Sessions
  # ============================================================================

  @doc """
  Insert or upsert a session record.
  """
  @spec upsert_session(map()) :: :ok | {:error, term()}
  def upsert_session(%{session_id: session_id} = session) do
    doc = serialize_session(session)

    case Mongo.update_one(
           Repo.pool(),
           @sessions_collection,
           %{"session_id" => session_id},
           %{"$set" => doc},
           upsert: true
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("MongoDB upsert_session failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Find a session by session_id.
  """
  @spec find_session(String.t()) :: {:ok, map()} | :not_found
  def find_session(session_id) when is_binary(session_id) do
    case Mongo.find_one(Repo.pool(), @sessions_collection, %{"session_id" => session_id}) do
      nil -> :not_found
      doc -> {:ok, deserialize_session(doc)}
    end
  end

  @doc """
  List sessions with optional filters.

  ## Options
  - `:user_id` — Filter by user ID
  - `:did` — Filter by DID
  - `:status` — Filter by status string
  - `:limit` — Maximum results (default: 100)
  """
  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    filter =
      %{}
      |> maybe_put("user_id", Keyword.get(opts, :user_id))
      |> maybe_put("did", Keyword.get(opts, :did))
      |> maybe_put("status", option_to_string(Keyword.get(opts, :status)))

    Repo.pool()
    |> Mongo.find(@sessions_collection, filter,
      sort: %{"started_at" => -1},
      limit: limit
    )
    |> Enum.map(&deserialize_session/1)
  end

  # ============================================================================
  # Notarization Documents
  # ============================================================================

  @doc """
  Store the canonical notarization document JSON for a session.

  This is the exact JSON string whose SHA-256 hash is published on-chain.
  """
  @spec store_document(String.t(), binary(), String.t() | nil) :: :ok | {:error, term()}
  def store_document(session_id, document_json, hash \\ nil)
      when is_binary(session_id) and is_binary(document_json) do
    doc = %{
      "session_id" => session_id,
      "document_json" => document_json,
      "hash" => hash,
      "stored_at" => DateTime.utc_now()
    }

    case Mongo.update_one(
           Repo.pool(),
           @documents_collection,
           %{"session_id" => session_id},
           %{"$set" => doc},
           upsert: true
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("MongoDB store_document failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Retrieve the canonical document JSON for a session.
  """
  @spec get_document(String.t()) :: {:ok, binary()} | :not_found
  def get_document(session_id) when is_binary(session_id) do
    case Mongo.find_one(Repo.pool(), @documents_collection, %{"session_id" => session_id}) do
      nil -> :not_found
      %{"document_json" => json} -> {:ok, json}
    end
  end

  @doc """
  Ensure indexes exist on the collections.

  Called once during application startup.
  """
  @spec ensure_indexes() :: :ok
  def ensure_indexes do
    Mongo.create_indexes(Repo.pool(), @sessions_collection, [
      [key: %{"session_id" => 1}, name: "session_id_unique", unique: true],
      [key: %{"user_id" => 1}, name: "user_id"],
      [key: %{"did" => 1}, name: "did"],
      [key: %{"status" => 1}, name: "status"]
    ])

    Mongo.create_indexes(Repo.pool(), @documents_collection, [
      [key: %{"session_id" => 1}, name: "session_id_unique", unique: true]
    ])

    Logger.info("MongoDB indexes ensured for sessions and notarization_documents")
    :ok
  end

  # ============================================================================
  # Dashboard Aggregations
  # ============================================================================

  @doc """
  Count sessions per day over the last `days_back` days, with status breakdown.

  Returns a list of maps sorted by date ascending:

      [%{"date" => "2026-03-20", "total" => 10, "notarized" => 8, "failed" => 1, "active" => 1}]
  """
  @spec sessions_by_date(non_neg_integer()) :: [map()]
  def sessions_by_date(days_back \\ 30) do
    cutoff = DateTime.add(DateTime.utc_now(), -days_back * 86_400, :second)

    Repo.pool()
    |> Mongo.aggregate(@sessions_collection, [
      %{"$match" => %{"started_at" => %{"$gte" => cutoff}}},
      %{"$group" => %{
        "_id" => %{"$dateToString" => %{"format" => "%Y-%m-%d", "date" => "$started_at"}},
        "total" => %{"$sum" => 1},
        "notarized" => %{"$sum" => %{"$cond" => [%{"$eq" => ["$status", "notarized"]}, 1, 0]}},
        "failed" => %{"$sum" => %{"$cond" => [%{"$eq" => ["$status", "failed"]}, 1, 0]}},
        "active" => %{"$sum" => %{"$cond" => [%{"$eq" => ["$status", "active"]}, 1, 0]}}
      }},
      %{"$sort" => %{"_id" => 1}}
    ])
    |> Enum.map(fn %{"_id" => date} = entry ->
      %{
        "date" => date,
        "total" => entry["total"] || 0,
        "notarized" => entry["notarized"] || 0,
        "failed" => entry["failed"] || 0,
        "active" => entry["active"] || 0
      }
    end)
  end

  # ============================================================================
  # Serialization Helpers
  # ============================================================================

  defp serialize_session(session) do
    %{
      "session_id" => session.session_id,
      "did" => session.did,
      "user_id" => session.user_id,
      "started_at" => session.started_at,
      "ended_at" => session.ended_at,
      "status" => to_string(session.status),
      "command_count" => session.command_count || 0,
      "commands" => serialize_commands(session[:commands] || []),
      "notarization_hash" => session[:notarization_hash],
      "on_chain_id" => session[:on_chain_id],
      "error" => session[:error]
    }
  end

  defp serialize_commands(commands) do
    Enum.map(commands, fn
      %{timestamp: ts, command: cmd} -> %{"timestamp" => ts, "command" => cmd}
      %{command: cmd} -> %{"command" => cmd}
      other when is_map(other) -> Map.new(other, fn {k, v} -> {to_string(k), v} end)
    end)
  end

  defp deserialize_session(doc) do
    commands =
      (doc["commands"] || [])
      |> Enum.map(fn
        %{"timestamp" => ts, "command" => cmd} -> %{timestamp: ts, command: cmd}
        %{"command" => cmd} -> %{command: cmd}
        other when is_map(other) -> %{command: Map.get(other, "command", "")}
      end)

    %{
      session_id: doc["session_id"],
      did: doc["did"],
      user_id: doc["user_id"],
      started_at: parse_datetime(doc["started_at"]),
      ended_at: parse_datetime(doc["ended_at"]),
      status: parse_status(doc["status"]),
      command_count: doc["command_count"] || 0,
      commands: commands,
      document_json: nil,
      notarization_hash: doc["notarization_hash"],
      notarization_payload: nil,
      on_chain_id: doc["on_chain_id"],
      error: doc["error"]
    }
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # BSON DateTime values come back as DateTime already from mongodb_driver
  defp parse_datetime(_), do: nil

  defp parse_status("active"), do: :active
  defp parse_status("ended"), do: :ended
  defp parse_status("notarized"), do: :notarized
  defp parse_status("failed"), do: :failed
  defp parse_status(_), do: :ended

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp option_to_string(nil), do: nil
  defp option_to_string(atom) when is_atom(atom), do: to_string(atom)
  defp option_to_string(str) when is_binary(str), do: str
end
