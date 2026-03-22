defmodule TangleGate.Integration.NotarizationTest do
  @moduledoc """
  Integration tests for the Notarization lifecycle.
  These tests require the NIF to be loaded (either via local node or testnet).

  Run with:

      IOTA_TESTNET=1 mix test test/tangle_gate/integration/notarization_test.exs
  """

  use ExUnit.Case

  @moduletag :testnet

  describe "hashing" do
    test "produces consistent SHA-256 hashes" do
      hash_a = TangleGate.hash("hello")
      hash_b = TangleGate.hash("hello")

      assert hash_a == hash_b
      assert String.length(hash_a) == 64
      assert String.match?(hash_a, ~r/^[0-9a-f]{64}$/)
    end

    test "produces known SHA-256 hash for 'hello'" do
      assert TangleGate.hash("hello") ==
               "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    end

    test "different inputs produce different hashes" do
      hash_a = TangleGate.hash("document A")
      hash_b = TangleGate.hash("document B")

      assert hash_a != hash_b
    end

    test "handles binary data" do
      hash = TangleGate.hash(<<0, 1, 2, 3, 255>>)
      assert String.length(hash) == 64
    end
  end

  describe "payload creation" do
    test "creates a valid notarization payload" do
      assert {:ok, payload} = TangleGate.notarize("important document")

      assert is_map(payload)
      assert is_binary(payload["data_hash"])
      assert String.length(payload["data_hash"]) == 64
    end

    test "payload hash matches direct hash of data" do
      data = "test document content"
      expected_hash = TangleGate.hash(data)

      assert {:ok, payload} = TangleGate.notarize(data)
      assert payload["data_hash"] == expected_hash
    end

    test "creates payload with custom tag" do
      assert {:ok, payload} = TangleGate.notarize("data", "custom_tag")
      assert is_map(payload)
    end

    test "different data produces different payloads" do
      {:ok, payload_a} = TangleGate.notarize("document A")
      {:ok, payload_b} = TangleGate.notarize("document B")

      assert payload_a["data_hash"] != payload_b["data_hash"]
    end
  end

  describe "payload verification" do
    test "verifies a valid hex string" do
      assert TangleGate.Notarization.Server.valid_hex?("deadbeef")
      assert TangleGate.Notarization.Server.valid_hex?("0123456789abcdef")
    end

    test "rejects invalid hex strings" do
      refute TangleGate.Notarization.Server.valid_hex?("not_hex!")
      refute TangleGate.Notarization.Server.valid_hex?("ZZZZ")
    end
  end

  describe "notarization queue" do
    test "enqueues a job and retrieves status" do
      assert {:ok, ref} = TangleGate.enqueue_notarization("queued data", "test_tag")
      assert is_reference(ref)

      assert {:ok, job} = TangleGate.Notarization.Queue.status(ref)
      assert job.status == :pending
      assert job.data == "queued data"
      assert job.tag == "test_tag"
    end

    test "returns :not_found for unknown job ref" do
      unknown_ref = make_ref()
      assert :not_found = TangleGate.Notarization.Queue.status(unknown_ref)
    end

    test "reports queue stats" do
      stats = TangleGate.queue_stats()

      assert is_map(stats)
      assert is_integer(stats.pending)
    end
  end

  describe "full notarization lifecycle" do
    test "hash → notarize → verify payload integrity" do
      data = "This is an important legal document signed on #{DateTime.utc_now()}"

      # Step 1: Hash the data
      hash = TangleGate.hash(data)
      assert String.length(hash) == 64

      # Step 2: Create notarization payload
      assert {:ok, payload} = TangleGate.notarize(data, "legal_doc")
      assert payload["data_hash"] == hash

      # Step 3: Enqueue for batch processing
      assert {:ok, ref} = TangleGate.enqueue_notarization(data, "legal_doc")
      assert {:ok, job} = TangleGate.Notarization.Queue.status(ref)
      assert job.status == :pending
    end
  end
end
