defmodule TangleGate.Store.CredentialStore do
  @moduledoc """
  MongoDB-backed storage for the server's DID identity and issued credentials.

  ## Collections

  - `server_identity` — Stores the server's own DID, DID document, and
    verification method fragment. Exactly one document lives here.
  - `issued_credentials` — Metadata for credentials issued by this server
    (the JWT itself is returned to the holder and not stored).
  """

  alias TangleGate.Store.Repo

  require Logger

  @identity_collection "server_identity"
  @credentials_collection "issued_credentials"

  # ============================================================================
  # Server Identity (singleton DID)
  # ============================================================================

  @doc """
  Store the server's DID identity.

  This overwrites any previous identity. Call only once during initial
  provisioning or DID rotation.
  """
  @spec store_server_identity(map()) :: :ok | {:error, term()}
  def store_server_identity(%{did: did, document: document} = identity) do
    doc = %{
      "_id" => "server",
      "did" => did,
      "document" => document,
      "verification_method_fragment" => Map.get(identity, :verification_method_fragment),
      "private_key_jwk" => Map.get(identity, :private_key_jwk),
      "network" => Map.get(identity, :network) |> to_string(),
      "published_at" => Map.get(identity, :published_at, DateTime.utc_now()),
      "updated_at" => DateTime.utc_now()
    }

    case Mongo.update_one(
           Repo.pool(),
           @identity_collection,
           %{"_id" => "server"},
           %{"$set" => doc},
           upsert: true
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to store server identity: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Retrieve the server's DID identity.

  Returns `{:ok, identity_map}` or `:not_found`.
  """
  @spec get_server_identity() :: {:ok, map()} | :not_found
  def get_server_identity do
    case Mongo.find_one(Repo.pool(), @identity_collection, %{"_id" => "server"}) do
      nil ->
        :not_found

      doc ->
        {:ok,
         %{
           did: doc["did"],
           document: doc["document"],
           verification_method_fragment: doc["verification_method_fragment"],
           private_key_jwk: doc["private_key_jwk"],
           network: doc["network"],
           published_at: doc["published_at"],
           updated_at: doc["updated_at"]
         }}
    end
  end

  # ============================================================================
  # Issued Credentials (metadata only)
  # ============================================================================

  @doc """
  Record metadata about an issued credential.

  The actual JWT is NOT stored — it's given to the holder.
  This record allows the server to track what was issued and to whom.
  """
  @spec record_issued_credential(map()) :: :ok | {:error, term()}
  def record_issued_credential(credential_meta) do
    doc = %{
      "credential_id" => credential_meta.credential_id,
      "issuer_did" => credential_meta.issuer_did,
      "holder_did" => credential_meta.holder_did,
      "credential_type" => credential_meta.credential_type,
      "claims_summary" => credential_meta[:claims_summary],
      "issued_at" => DateTime.utc_now(),
      "revoked" => false
    }

    case Mongo.insert_one(Repo.pool(), @credentials_collection, doc) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to record issued credential: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  List credentials issued to a specific holder DID.
  """
  @spec list_credentials_for_holder(String.t(), keyword()) :: [map()]
  def list_credentials_for_holder(holder_did, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Repo.pool()
    |> Mongo.find(@credentials_collection, %{"holder_did" => holder_did},
      sort: %{"issued_at" => -1},
      limit: limit
    )
    |> Enum.map(&deserialize_credential/1)
  end

  @doc """
  List all issued credentials.
  """
  @spec list_credentials(keyword()) :: [map()]
  def list_credentials(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Repo.pool()
    |> Mongo.find(@credentials_collection, %{}, sort: %{"issued_at" => -1}, limit: limit)
    |> Enum.map(&deserialize_credential/1)
  end

  @doc """
  Ensure indexes exist for credential collections.
  """
  @spec ensure_indexes() :: :ok
  def ensure_indexes do
    Mongo.create_indexes(Repo.pool(), @credentials_collection, [
      [key: %{"credential_id" => 1}, name: "credential_id_unique", unique: true],
      [key: %{"holder_did" => 1}, name: "holder_did"],
      [key: %{"issuer_did" => 1}, name: "issuer_did"]
    ])

    Logger.info("MongoDB indexes ensured for #{@credentials_collection}")
    :ok
  end

  # ============================================================================
  # Revocation
  # ============================================================================

  @doc """
  Revoke all active credentials for a given holder DID.

  This marks all non-revoked credentials for the holder as revoked in
  MongoDB. The NIF does not currently expose on-chain revocation bitmap
  operations, so revocation is tracked server-side.

  ## TODO: Implement on-chain revocation via revocation bitmaps when the
  ## iota_credential_nif adds support for revocation operations.
  """
  @spec revoke_credentials_for_holder(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_credentials_for_holder(holder_did) do
    case Mongo.update_many(
           Repo.pool(),
           @credentials_collection,
           %{"holder_did" => holder_did, "revoked" => false},
           %{"$set" => %{"revoked" => true, "revoked_at" => DateTime.utc_now()}}
         ) do
      {:ok, %Mongo.UpdateResult{modified_count: count}} ->
        if count > 0 do
          Logger.info("Revoked #{count} credential(s) for holder #{holder_did}")
        end

        {:ok, count}

      {:error, reason} ->
        Logger.error("Failed to revoke credentials for #{holder_did}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Check if a specific credential has been revoked.
  """
  @spec credential_revoked?(String.t()) :: boolean()
  def credential_revoked?(credential_id) do
    case Mongo.find_one(Repo.pool(), @credentials_collection, %{
           "credential_id" => credential_id,
           "revoked" => true
         }) do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Check if ALL credentials for a holder DID have been revoked.

  Returns `true` if the holder has credentials and all are revoked,
  or if the holder has no credentials at all.
  Returns `false` if any active (non-revoked) credential exists.
  """
  @spec all_credentials_revoked?(String.t()) :: boolean()
  def all_credentials_revoked?(holder_did) do
    case Mongo.find_one(Repo.pool(), @credentials_collection, %{
           "holder_did" => holder_did,
           "revoked" => false
         }) do
      nil -> true
      _ -> false
    end
  end

  # ============================================================================
  # Dashboard Aggregations
  # ============================================================================

  @doc """
  Count total issued credentials.
  """
  @spec count_credentials() :: non_neg_integer()
  def count_credentials do
    Mongo.count_documents!(Repo.pool(), @credentials_collection, %{})
  end

  @doc """
  Count active (non-revoked) credentials.
  """
  @spec count_active_credentials() :: non_neg_integer()
  def count_active_credentials do
    Mongo.count_documents!(Repo.pool(), @credentials_collection, %{"revoked" => false})
  end

  @doc """
  Count revoked credentials.
  """
  @spec count_revoked_credentials() :: non_neg_integer()
  def count_revoked_credentials do
    Mongo.count_documents!(Repo.pool(), @credentials_collection, %{"revoked" => true})
  end

  @doc """
  Count credentials issued per day over the last `days_back` days.

  Returns a list of `%{"date" => "2026-03-20", "count" => 5}` maps sorted ascending.
  """
  @spec credentials_by_date(non_neg_integer()) :: [map()]
  def credentials_by_date(days_back \\ 30) do
    cutoff = DateTime.add(DateTime.utc_now(), -days_back * 86_400, :second)

    Repo.pool()
    |> Mongo.aggregate(@credentials_collection, [
      %{"$match" => %{"issued_at" => %{"$gte" => cutoff}}},
      %{"$group" => %{
        "_id" => %{"$dateToString" => %{"format" => "%Y-%m-%d", "date" => "$issued_at"}},
        "count" => %{"$sum" => 1}
      }},
      %{"$sort" => %{"_id" => 1}}
    ])
    |> Enum.map(fn %{"_id" => date, "count" => count} ->
      %{"date" => date, "count" => count}
    end)
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp deserialize_credential(doc) do
    %{
      credential_id: doc["credential_id"],
      issuer_did: doc["issuer_did"],
      holder_did: doc["holder_did"],
      credential_type: doc["credential_type"],
      claims_summary: doc["claims_summary"],
      issued_at: doc["issued_at"],
      revoked: doc["revoked"] || false
    }
  end
end
