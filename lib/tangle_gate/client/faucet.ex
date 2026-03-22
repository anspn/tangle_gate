defmodule TangleGate.Client.Faucet do
  @moduledoc """
  HTTP client for the IOTA faucet.

  Requests test tokens from the IOTA faucet for a given address.

  ## Configuration

  The faucet URL can be configured in your application config:

      config :tangle_gate, :faucet_url, "https://faucet.testnet.iota.cafe/gas"

  ## Examples

      iex> TangleGate.Client.Faucet.request_funds("0xYOUR_IOTA_ADDRESS")
      {:ok, %{status: 202, body: ...}}

      iex> TangleGate.Client.Faucet.request_funds("0xADDRESS", url: "https://custom-faucet.example.com/gas")
      {:ok, %{status: 202, body: ...}}
  """

  require Logger

  @default_faucet_url "https://faucet.testnet.iota.cafe/gas"
  @doc """
  Request test tokens from the IOTA faucet.

  ## Parameters

    - `recipient` - The IOTA address to receive funds
    - `opts` - Keyword options:
      - `:url` - Override the faucet URL (default: configured or `#{@default_faucet_url}`)
      - `:receive_timeout` - Request timeout in ms (default: 60_000)

  ## Returns

    - `{:ok, %{status: integer(), body: term()}}` on success
    - `{:error, reason}` on failure
  """
  @spec request_funds(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_funds(recipient, opts \\ []) when is_binary(recipient) do
    url = faucet_url(opts)
    timeout = Keyword.get(opts, :receive_timeout, 60_000)

    payload = %{
      "FixedAmountRequest" => %{
        "recipient" => recipient
      }
    }

    Logger.info("Requesting faucet funds for #{recipient} from #{url}")

    case Req.post(url, json: payload, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        Logger.info("Faucet request successful (HTTP #{status})")
        {:ok, %{status: status, body: body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Faucet request failed (HTTP #{status}): #{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        Logger.error("Faucet request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp faucet_url(opts) do
    Keyword.get_lazy(opts, :url, fn ->
      Application.get_env(:tangle_gate, :faucet_url, @default_faucet_url)
    end)
  end
end
