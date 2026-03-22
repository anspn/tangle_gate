defmodule TangleGate.Vault.Client do
  @moduledoc """
  HTTP client for HashiCorp Vault KV v2 secrets engine.

  Reads secrets at application startup and caches them in application config.
  Uses the `Req` HTTP library (already a project dependency).

  ## Configuration

      config :tangle_gate, TangleGate.Vault.Client,
        addr: "http://localhost:8200",
        token: "dev-root-token",
        secret_path: "secret/data/tangle_gate"

  In production, `VAULT_ADDR` and `VAULT_TOKEN` environment variables
  are passed via Docker Compose.
  """

  require Logger

  @doc """
  Fetch a secret from Vault KV v2 and return its data map.

  ## Parameters
  - `key` — The key path under the KV mount (e.g., `"tangle_gate"`)

  ## Returns
  `{:ok, data_map}` or `{:error, reason}`
  """
  @spec read_secret(String.t()) :: {:ok, map()} | {:error, term()}
  def read_secret(key) do
    config = vault_config()
    addr = Keyword.fetch!(config, :addr)
    token = Keyword.fetch!(config, :token)
    mount = Keyword.get(config, :mount, "secret")

    url = "#{addr}/v1/#{mount}/data/#{key}"

    case Req.get(url, headers: [{"x-vault-token", token}], receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        data = get_in(body, ["data", "data"]) || %{}
        {:ok, data}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Vault read_secret (#{key}) returned #{status}: #{inspect(body)}")
        {:error, {:vault_error, status}}

      {:error, reason} ->
        Logger.error("Vault request failed: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Write a secret to Vault KV v2.

  ## Parameters
  - `key` — The key path under the KV mount
  - `data` — Map of key-value pairs to store
  """
  @spec write_secret(String.t(), map()) :: :ok | {:error, term()}
  def write_secret(key, data) when is_map(data) do
    config = vault_config()
    addr = Keyword.fetch!(config, :addr)
    token = Keyword.fetch!(config, :token)
    mount = Keyword.get(config, :mount, "secret")

    url = "#{addr}/v1/#{mount}/data/#{key}"
    body = Jason.encode!(%{data: data})

    case Req.post(url,
           headers: [
             {"x-vault-token", token},
             {"content-type", "application/json"}
           ],
           body: body,
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.warning("Vault write_secret (#{key}) returned #{status}: #{inspect(resp_body)}")
        {:error, {:vault_error, status}}

      {:error, reason} ->
        Logger.error("Vault write request failed: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Load secrets from Vault and merge them into application config.

  Called during application startup. Fetches the `tangle_gate` secret
  and applies known keys (e.g., `secret_key`) to the `:tangle_gate` config.

  Falls back gracefully — if Vault is unavailable, logs a warning and
  continues with existing config (env vars / .env).
  """
  @spec load_secrets() :: :ok
  def load_secrets do
    config = vault_config()

    unless Keyword.get(config, :enabled, false) do
      Logger.info("Vault integration disabled — using config from environment")
      :ok
    else
      secret_key_path = Keyword.get(config, :secret_path, "tangle_gate")

      case read_secret(secret_key_path) do
        {:ok, data} ->
          apply_secrets(data)
          Logger.info("Loaded secrets from Vault (path: #{secret_key_path})")
          :ok

        {:error, :not_found} ->
          Logger.warning(
            "Vault secret '#{secret_key_path}' not found — " <>
              "populate it with: vault kv put secret/#{secret_key_path} iota_secret_key=<key>"
          )

          :ok

        {:error, reason} ->
          Logger.warning(
            "Could not load Vault secrets: #{inspect(reason)} — continuing with env config"
          )

          :ok
      end
    end
  end

  @doc """
  Read the server DID identity from Vault.

  Stored under `<mount>/data/<secret_path>/server_did`.

  Returns `{:ok, identity_map}` or `{:error, reason}`.
  """
  @spec read_server_did() :: {:ok, map()} | {:error, term()}
  def read_server_did do
    config = vault_config()

    unless Keyword.get(config, :enabled, false) do
      {:error, :vault_disabled}
    else
      secret_path = Keyword.get(config, :secret_path, "tangle_gate")
      key = "#{secret_path}/server_did"

      case read_secret(key) do
        {:ok, data} when map_size(data) > 0 ->
          {:ok, %{
            did: data["did"],
            document: data["document"],
            verification_method_fragment: data["verification_method_fragment"],
            private_key_jwk: data["private_key_jwk"],
            network: data["network"],
            published_at: data["published_at"]
          }}

        {:ok, _empty} ->
          {:error, :not_found}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Write the server DID identity to Vault for persistence across restarts.

  Stored under `<mount>/data/<secret_path>/server_did`.
  """
  @spec write_server_did(map()) :: :ok | {:error, term()}
  def write_server_did(%{did: did, document: document} = identity) do
    config = vault_config()

    unless Keyword.get(config, :enabled, false) do
      Logger.debug("Vault disabled — skipping server DID write")
      :ok
    else
      secret_path = Keyword.get(config, :secret_path, "tangle_gate")
      key = "#{secret_path}/server_did"

      data = %{
        "did" => did,
        "document" => document,
        "verification_method_fragment" => Map.get(identity, :verification_method_fragment),
        "private_key_jwk" => Map.get(identity, :private_key_jwk),
        "network" => Map.get(identity, :network) |> to_string(),
        "published_at" => Map.get(identity, :published_at) |> to_string()
      }

      case write_secret(key, data) do
        :ok ->
          Logger.info("Server DID written to Vault (#{key})")
          :ok

        {:error, reason} = error ->
          Logger.warning("Failed to write server DID to Vault: #{inspect(reason)}")
          error
      end
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp vault_config do
    Application.get_env(:tangle_gate, __MODULE__, [])
  end

  defp apply_secrets(data) do
    # Map Vault keys to application config keys
    secret_mappings = %{
      "iota_secret_key" => :secret_key
    }

    Enum.each(secret_mappings, fn {vault_key, config_key} ->
      case Map.get(data, vault_key) do
        nil ->
          :ok

        "" ->
          :ok

        value ->
          Application.put_env(:tangle_gate, config_key, value)
          Logger.debug("Applied Vault secret: #{vault_key} → :#{config_key}")
      end
    end)
  end
end
