defmodule TangleGate.Web.Auth do
  @moduledoc """
  JWT token generation and verification for the IOTA Service API.

  Uses Joken with HS256 signing.  Tokens carry the user id, email,
  and a standard `exp` claim.

  ## User Resolution

  Authentication checks MongoDB-backed dynamic users first, then falls
  back to the static users defined in the application config. This allows
  the three bootstrap accounts (admin, user, verifier) to always work
  while supporting dynamic user creation by the admin.

  ## Configuration

      config :tangle_gate, TangleGate.Web.Auth,
        secret: "change-me-in-production",
        token_ttl_seconds: 3600,
        users: [
          %{id: "usr_dev", email: "dev@iota.local", password: "iota_dev_2026"}
        ]
  """

  use Joken.Config

  @impl true
  def token_config do
    default_claims(default_exp: ttl_seconds())
  end

  # --- Public API -----------------------------------------------------------

  @doc """
  Authenticate a user by email and password.

  Tries MongoDB-backed dynamic users first, then falls back to static
  config users. Returns `{:ok, user}` on success or `{:error, :invalid_credentials}`.
  """
  @spec authenticate(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_credentials}
  def authenticate(email, password) do
    # 1. Try dynamic users (MongoDB) if repo is enabled
    case authenticate_dynamic(email, password) do
      {:ok, user} ->
        {:ok, user}

      {:error, :invalid_credentials} ->
        # 2. Fall back to static config users
        authenticate_static(email, password)

      {:error, :repo_disabled} ->
        authenticate_static(email, password)
    end
  end

  @doc """
  Look up a user by email across both dynamic and static stores.

  Returns `{:ok, user}` or `:not_found`.
  """
  @spec get_user(String.t()) :: {:ok, map()} | :not_found
  def get_user(email) do
    if Application.get_env(:tangle_gate, :start_repo, true) do
      case TangleGate.Store.UserStore.get_user_by_email(email) do
        {:ok, user} -> {:ok, Map.drop(user, [:password_hash, :salt])}
        :not_found -> get_static_user(email)
      end
    else
      get_static_user(email)
    end
  end

  @doc """
  Generate a signed JWT for the given user.

  Returns `{:ok, token, claims}`.
  """
  @spec generate_token(map()) :: {:ok, String.t(), map()} | {:error, term()}
  def generate_token(%{id: user_id, email: email, role: role}) do
    extra_claims = %{"user_id" => user_id, "email" => email, "role" => to_string(role)}

    case generate_and_sign(extra_claims, signer()) do
      {:ok, token, claims} -> {:ok, token, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verify a JWT token and return its claims.

  Returns `{:ok, claims}` or `{:error, reason}`.
  """
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_token(token) when is_binary(token) do
    case verify_and_validate(token, signer()) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verify a JWT token ignoring the `exp` claim.

  Checks that the signature is valid but does **not** validate claim
  expiration. Used for endpoints that must succeed even after the token
  expires (e.g. ending a TTY session that outlived the token TTL).

  Returns `{:ok, claims}` or `{:error, reason}`.
  """

  ## TODO modify this behaviour to handle expiration of tokens
  @spec verify_token_ignoring_expiry(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_token_ignoring_expiry(token) when is_binary(token) do
    case verify(token, signer()) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Private --------------------------------------------------------------

  defp signer do
    Joken.Signer.create("HS256", secret())
  end

  defp secret do
    config()[:secret] || raise "JWT secret not configured"
  end

  defp ttl_seconds do
    config()[:token_ttl_seconds] || 3600
  end

  defp users do
    raw = config()[:users] || []

    Enum.map(raw, fn
      %{} = m -> m
      m when is_list(m) -> Map.new(m, fn {k, v} -> {k, v} end)
    end)
  end

  defp authenticate_dynamic(email, password) do
    if Application.get_env(:tangle_gate, :start_repo, true) do
      TangleGate.Store.UserStore.authenticate(email, password)
    else
      {:error, :repo_disabled}
    end
  rescue
    _ -> {:error, :repo_disabled}
  end

  defp authenticate_static(email, password) do
    users()
    |> Enum.find(fn u -> u.email == email and u.password == password end)
    |> case do
      nil -> {:error, :invalid_credentials}
      user -> {:ok, Map.take(user, [:id, :email, :role])}
    end
  end

  defp get_static_user(email) do
    users()
    |> Enum.find(fn u -> u.email == email end)
    |> case do
      nil -> :not_found
      user -> {:ok, Map.take(user, [:id, :email, :role])}
    end
  end

  defp config do
    Application.get_env(:tangle_gate, __MODULE__, [])
  end
end
