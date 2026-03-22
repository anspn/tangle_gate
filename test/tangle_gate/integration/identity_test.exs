defmodule TangleGate.Integration.IdentityTest do
  @moduledoc """
  Integration tests for the Identity (DID) lifecycle.
  These tests require the NIF to be loaded (either via local node or testnet).

  Run with:

      IOTA_TESTNET=1 mix test test/tangle_gate/integration/identity_test.exs
  """

  use ExUnit.Case

  @moduletag :testnet

  describe "DID generation" do
    test "generates a DID with default network (iota)" do
      assert {:ok, result} = TangleGate.generate_did()

      assert is_binary(result.did)
      assert String.starts_with?(result.did, "did:iota:0x")
      # document comes as a JSON string from the NIF; verify it's valid JSON
      assert is_binary(result.document)
      assert {:ok, _doc} = Jason.decode(result.document)
      assert is_binary(result.verification_method_fragment)
      assert result.network == :iota
      assert %DateTime{} = result.generated_at
    end

    test "generates a DID for each supported network" do
      networks = [:iota, :smr, :rms, :atoi]

      for network <- networks do
        assert {:ok, result} = TangleGate.generate_did(network: network),
               "Failed to generate DID for network #{network}"

        assert result.network == network

        expected_prefix =
          case network do
            :iota -> "did:iota:0x"
            other -> "did:iota:#{other}:0x"
          end

        assert String.starts_with?(result.did, expected_prefix),
               "DID #{result.did} does not start with #{expected_prefix}"
      end
    end

    test "rejects invalid network" do
      assert {:error, {:invalid_network, :invalid}} =
               TangleGate.generate_did(network: :invalid)
    end
  end

  describe "DID validation" do
    test "validates a correctly generated DID" do
      {:ok, result} = TangleGate.generate_did()
      assert TangleGate.valid_did?(result.did)
    end

    test "rejects invalid DID formats" do
      refute TangleGate.valid_did?("")
      refute TangleGate.valid_did?("not-a-did")
      refute TangleGate.valid_did?("did:other:0x123")
    end
  end

  describe "DID URL creation" do
    test "creates a DID URL with a fragment" do
      {:ok, result} = TangleGate.generate_did()
      assert {:ok, url} = TangleGate.create_did_url(result.did, "key-1")
      assert url == "#{result.did}#key-1"
    end

    test "creates DID URLs with various fragments" do
      {:ok, result} = TangleGate.generate_did()

      fragments = ["key-1", "auth-0", "verification", "my-service"]

      for fragment <- fragments do
        assert {:ok, url} = TangleGate.create_did_url(result.did, fragment)
        assert String.ends_with?(url, "##{fragment}")
      end
    end
  end

  describe "full DID lifecycle" do
    test "generate → validate → create URL" do
      # Step 1: Generate
      assert {:ok, did_result} = TangleGate.generate_did()
      did = did_result.did

      # Step 2: Validate
      assert TangleGate.valid_did?(did)

      # Step 3: Create DID URL
      assert {:ok, url} = TangleGate.create_did_url(did, "key-1")
      assert url == "#{did}#key-1"
    end
  end
end
