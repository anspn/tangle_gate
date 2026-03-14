defmodule IotaService.Store.CredentialStore do
  @moduledoc """
  MongoDB-backed storage for the server's DID identity and issued credentials.

  ## Collections

  - `server_identity` — Stores the server's own DID, DID document, and
    verification method fragment. Exactly one document lives here.
  - `issued_credentials` — Metadata for credentials issued by this server
    (the JWT itself is returned to the holder and not stored).
  """

  alias IotaService.Store.Repo

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
