defmodule TangleGate.Client.FaucetTest do
  use ExUnit.Case

  @moduletag :testnet

  test "requests gas tokens successfully" do
    address_file = Application.fetch_env!(:tangle_gate, :faucet_address_file)

    recipient =
      address_file
      |> File.read!()
      |> String.trim()

    if recipient == "" or String.starts_with?(recipient, "REPLACE_WITH_IOTA_ADDRESS") do
      flunk("Set a real IOTA address in #{address_file} before running local faucet tests")
    end

    assert {:ok, %{status: status}} = TangleGate.Client.Faucet.request_funds(recipient)
    assert status in 200..299
  end
end
