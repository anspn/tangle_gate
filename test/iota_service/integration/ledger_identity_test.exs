defmodule IotaService.Integration.LedgerIdentityTest do
  @moduledoc """
  End-to-end integration tests for DID publishing and resolution
  against the IOTA Rebased testnet (or a local node via IOTA_NODE_URL override).

  Requires:
  - Environment variables:
    - `IOTA_TEST_SECRET_KEY` — Bech32 or Base64 Ed25519 private key with gas
    - `IOTA_IDENTITY_PKG_ID` — ObjectID of the `iota_identity` Move package
      (optional on testnet — auto-discovery is used when set to "")
  - Optionally: `IOTA_TEST_NODE_URL` to override the default testnet URL

  Run with:

      IOTA_TEST_SECRET_KEY=iotaprivkey1... \\
      IOTA_TESTNET=1 mix test test/iota_service/integration/ledger_identity_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :testnet

  setup_all do
    secret_key = System.get_env("IOTA_TEST_SECRET_KEY")
    identity_pkg_id = System.get_env("IOTA_IDENTITY_PKG_ID", "")

    if is_nil(secret_key) do
      IO.puts("""
      \n  Skipping ledger identity tests:
        IOTA_TEST_SECRET_KEY must be set.
        IOTA_IDENTITY_PKG_ID is optional ("" enables auto-discovery on testnet).
      """)
    end

    node_url = System.get_env("IOTA_TEST_NODE_URL", "https://api.testnet.iota.cafe")

    {:ok, secret_key: secret_key, identity_pkg_id: identity_pkg_id, node_url: node_url}
  end

  setup %{secret_key: sk} do
    if is_nil(sk) do
      {:ok, skip: true}
    else
      :ok
    end
  end

  describe "publish DID on ledger" do
    @tag timeout: 120_000
    test "publishes a new DID on the IOTA testnet", ctx do
      if ctx[:skip], do: flunk("IOTA_TEST_SECRET_KEY not set")

      assert {:ok, result} =
               IotaService.publish_did(
                 secret_key: ctx.secret_key,
                 node_url: ctx.node_url,
                 identity_pkg_id: ctx.identity_pkg_id
               )

      # Result is a map with on-chain DID fields
      assert is_binary(result.did)
      assert String.starts_with?(result.did, "did:iota:")
      assert is_binary(result.document)
      assert is_binary(result.verification_method_fragment)
      assert is_binary(result.sender_address)
      assert %DateTime{} = result.published_at

      # The DID must be valid
      assert IotaService.valid_did?(result.did)
    end
  end

  describe "publish and resolve DID lifecycle" do
    @tag timeout: 120_000
    test "publishes then resolves the same DID from ledger", ctx do
      if ctx[:skip], do: flunk("IOTA_TEST_SECRET_KEY not set")

      # Step 1: Publish
      assert {:ok, published} =
               IotaService.publish_did(
                 secret_key: ctx.secret_key,
                 node_url: ctx.node_url,
                 identity_pkg_id: ctx.identity_pkg_id
               )

      did = published.did
      assert is_binary(did)

      # Step 2: Resolve from ledger
      assert {:ok, resolved} =
               IotaService.resolve_did(did,
                 node_url: ctx.node_url,
                 identity_pkg_id: ctx.identity_pkg_id
               )

      # Resolved DID must match the published one
      assert resolved["did"] == did
      assert is_binary(resolved["document"])
    end

    @tag timeout: 120_000
    test "publishes DID and creates a DID URL with the verification fragment", ctx do
      if ctx[:skip], do: flunk("IOTA_TEST_SECRET_KEY not set")

      assert {:ok, published} =
               IotaService.publish_did(
                 secret_key: ctx.secret_key,
                 node_url: ctx.node_url,
                 identity_pkg_id: ctx.identity_pkg_id
               )

      fragment = published.verification_method_fragment
      assert is_binary(fragment)

      assert {:ok, did_url} = IotaService.create_did_url(published.did, fragment)
      assert did_url == "#{published.did}##{fragment}"
    end
  end

  describe "error handling" do
    test "returns error with missing secret_key" do
      assert {:error, {:missing_option, :secret_key}} =
               IotaService.publish_did(
                 node_url: "https://api.testnet.iota.cafe",
                 identity_pkg_id: "0xdummy"
               )
    end

    test "returns error for resolve of non-existent DID", ctx do
      if ctx[:skip], do: flunk("IOTA_TEST_SECRET_KEY not set")

      fake_did =
        "did:iota:88ccb5ca:0x0000000000000000000000000000000000000000000000000000000000000000"

      result =
        IotaService.resolve_did(fake_did,
          node_url: ctx.node_url,
          identity_pkg_id: ctx.identity_pkg_id
        )

      assert {:error, _reason} = result
    end
  end
end
