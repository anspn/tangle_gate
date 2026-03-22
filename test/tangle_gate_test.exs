defmodule TangleGateTest do
  use ExUnit.Case
  doctest TangleGate

  describe "generate_did/1" do
    test "generates a valid DID for default network" do
      assert {:ok, result} = TangleGate.generate_did()
      assert String.starts_with?(result.did, "did:iota:0x")
      assert TangleGate.valid_did?(result.did)
    end

    test "generates a valid DID for SMR network" do
      assert {:ok, result} = TangleGate.generate_did(network: :smr)
      assert String.starts_with?(result.did, "did:iota:smr:0x")
      assert TangleGate.valid_did?(result.did)
    end
  end

  describe "notarize/2" do
    test "creates a notarization payload with hash" do
      assert {:ok, payload} = TangleGate.notarize("test data")
      assert is_binary(payload["data_hash"])
      assert String.length(payload["data_hash"]) == 64
    end
  end

  describe "valid_did?/1" do
    test "returns true for valid DIDs" do
      assert TangleGate.valid_did?("did:iota:0x123abc")
    end

    test "returns false for invalid DIDs" do
      refute TangleGate.valid_did?("not-a-did")
      refute TangleGate.valid_did?("did:other:0x123")
    end
  end
end
