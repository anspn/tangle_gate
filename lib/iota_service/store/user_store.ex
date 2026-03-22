defmodule IotaService.Store.UserStore do
  @moduledoc """
  MongoDB-backed user storage for dynamically created users.

  Works alongside the static users defined in the application config.
  Config users serve as the bootstrap fallback — they're always available
  even without MongoDB.

  ## Collections

  - `users` — Dynamic users created by the admin at runtime.
    Fields: email, password_hash, salt, role, did, authorized, created_at, updated_at

  ## Password Hashing

  Uses PBKDF2-HMAC-SHA256 via Erlang's `:crypto` module (no extra deps).
  """

  alias IotaService.Store.Repo

  require Logger

  @collection "users"
  @hash_iterations 100_000
  @hash_length 32

  # ============================================================================
  # User CRUD
  # ============================================================================

  @doc """
  Create a new user. Email must be unique.

  Returns `{:ok, user}` or `{:error, reason}`.
  """
  @spec create_user(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_user(email, password, role) when role in ["user", "verifier"] do
    case get_user_by_email(email) do
      {:ok, _} ->
        {:error, "User with email #{email} already exists"}

      :not_found ->
        {hash, salt} = hash_password(password)
        now = DateTime.utc_now()

        doc = %{
          "email" => email,
          "password_hash" => hash,
          "salt" => salt,
          "role" => role,
          "did" => nil,
          "authorized" => false,
          "created_at" => now,
          "updated_at" => now
        }

        case Mongo.insert_one(Repo.pool(), @collection, doc) do
          {:ok, _} ->
            {:ok, deserialize_user(doc)}

          {:error, reason} ->
            Logger.error("Failed to create user: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  def create_user(_email, _password, role) do
    {:error, "Invalid role: #{role}. Must be 'user' or 'verifier'"}
  end

  @doc """
  Get a user by email.

  Returns `{:ok, user}` or `:not_found`.
  """
  @spec get_user_by_email(String.t()) :: {:ok, map()} | :not_found
  def get_user_by_email(email) do
    case Mongo.find_one(Repo.pool(), @collection, %{"email" => email}) do
      nil -> :not_found
      doc -> {:ok, deserialize_user(doc)}
    end
  end

  @doc """
  Authenticate a dynamic user by email and password.

  Returns `{:ok, user}` or `{:error, :invalid_credentials}`.
  """
  @spec authenticate(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_credentials}
  def authenticate(email, password) do
    case get_user_by_email(email) do
      {:ok, user} ->
        if verify_password(password, user.password_hash, user.salt) do
          {:ok, Map.drop(user, [:password_hash, :salt])}
        else
          {:error, :invalid_credentials}
        end

      :not_found ->
        # Constant-time comparison to prevent timing attacks
        _dummy = hash_password(password)
        {:error, :invalid_credentials}
    end
  end

  @doc """
  Assign a DID to a user (by email), along with the private key and fragment.

  The `private_key_jwk` and `fragment` are stored so the server can create
  Verifiable Presentations on behalf of the user.

  Returns `{:ok, user}` or `{:error, reason}`.
  """
  @spec assign_did(String.t(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def assign_did(email, did, private_key_jwk \\ nil, fragment \\ nil) do
    update = %{
      "did" => did,
      "updated_at" => DateTime.utc_now()
    }

    update = if private_key_jwk, do: Map.put(update, "private_key_jwk", private_key_jwk), else: update
    update = if fragment, do: Map.put(update, "verification_method_fragment", fragment), else: update

    case Mongo.update_one(
           Repo.pool(),
           @collection,
           %{"email" => email},
           %{"$set" => update}
         ) do
      {:ok, %Mongo.UpdateResult{matched_count: 1}} ->
        get_user_by_email(email)

      {:ok, %Mongo.UpdateResult{matched_count: 0}} ->
        {:error, "User not found: #{email}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Set the authorized status for a user.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec set_authorized(String.t(), boolean()) :: :ok | {:error, term()}
  def set_authorized(email, authorized?) when is_boolean(authorized?) do
    case Mongo.update_one(
           Repo.pool(),
           @collection,
           %{"email" => email},
           %{"$set" => %{"authorized" => authorized?, "updated_at" => DateTime.utc_now()}}
         ) do
      {:ok, %Mongo.UpdateResult{matched_count: 1}} -> :ok
      {:ok, %Mongo.UpdateResult{matched_count: 0}} -> {:error, "User not found: #{email}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List all dynamic users.
  """
  @spec list_users(keyword()) :: [map()]
  def list_users(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    Repo.pool()
    |> Mongo.find(@collection, %{}, sort: %{"created_at" => -1}, limit: limit)
    |> Enum.map(&deserialize_user/1)
    |> Enum.map(&Map.drop(&1, [:password_hash, :salt]))
  end

  @doc """
  Find the user (dynamic) who owns a given DID.
  """
  @spec get_user_by_did(String.t()) :: {:ok, map()} | :not_found
  def get_user_by_did(did) do
    case Mongo.find_one(Repo.pool(), @collection, %{"did" => did}) do
      nil -> :not_found
      doc -> {:ok, deserialize_user(doc) |> Map.drop([:password_hash, :salt])}
    end
  end

  @doc """
  Ensure indexes exist for the users collection.
  """
  @spec ensure_indexes() :: :ok
  def ensure_indexes do
    Mongo.create_indexes(Repo.pool(), @collection, [
      [key: %{"email" => 1}, name: "email_unique", unique: true],
      [key: %{"did" => 1}, name: "did_index", sparse: true]
    ])

    Logger.info("MongoDB indexes ensured for #{@collection}")
    :ok
  end

  # ============================================================================
  # Password Hashing (PBKDF2-HMAC-SHA256 via :crypto)
  # ============================================================================

  defp hash_password(password) do
    salt = :crypto.strong_rand_bytes(16)
    hash = pbkdf2(password, salt)
    {Base.encode64(hash), Base.encode64(salt)}
  end

  defp verify_password(password, stored_hash, stored_salt) do
    salt = Base.decode64!(stored_salt)
    computed = pbkdf2(password, salt)
    # Constant-time comparison
    :crypto.hash_equals(Base.encode64(computed), stored_hash)
  end

  defp pbkdf2(password, salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @hash_iterations, @hash_length)
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp deserialize_user(doc) do
    %{
      id: doc["_id"] && BSON.ObjectId.encode!(doc["_id"]) || doc["email"],
      email: doc["email"],
      password_hash: doc["password_hash"],
      salt: doc["salt"],
      role: doc["role"],
      did: doc["did"],
      authorized: doc["authorized"] || false,
      private_key_jwk: doc["private_key_jwk"],
      verification_method_fragment: doc["verification_method_fragment"],
      created_at: doc["created_at"],
      updated_at: doc["updated_at"]
    }
  end
end
