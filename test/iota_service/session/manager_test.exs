defmodule IotaService.Session.ManagerTest do
  use ExUnit.Case, async: false

  alias IotaService.Session.Manager

  @test_did "did:iota:0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
  @test_user_id "usr_test"

  setup do
    # Use a temporary directory for test sessions
    test_dir = Path.join(System.tmp_dir!(), "iota_sessions_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:iota_service, :sessions_dir, test_dir)

    on_exit(fn ->
      # Clean up temp directory
      File.rm_rf!(test_dir)
    end)

    %{sessions_dir: test_dir}
  end

  describe "start_session/2" do
    test "creates a new active session" do
      assert {:ok, session} = Manager.start_session(@test_did, @test_user_id)
      assert is_binary(session.session_id)
      assert String.starts_with?(session.session_id, "ses_")
      assert session.did == @test_did
      assert session.user_id == @test_user_id
      assert session.status == :active
      assert %DateTime{} = session.started_at
      assert session.ended_at == nil
      assert session.command_count == 0
    end

    test "creates a pending file in the sessions directory", %{sessions_dir: dir} do
      {:ok, session} = Manager.start_session(@test_did, @test_user_id)
      pending_path = Path.join([dir, "pending", "#{session.session_id}.session"])
      assert File.exists?(pending_path)

      content = File.read!(pending_path)
      [session_id_line, did_line | _] = String.split(content, "\n", trim: true)
      assert session_id_line == session.session_id
      assert did_line == @test_did
    end

    test "persists session to ETS" do
      {:ok, session} = Manager.start_session(@test_did, @test_user_id)
      assert {:ok, found} = Manager.get_session(session.session_id)
      assert found.session_id == session.session_id
      assert found.did == @test_did
      assert found.status == :active
    end

    test "stores session in ETS for retrieval" do
      {:ok, session} = Manager.start_session(@test_did, @test_user_id)
      assert {:ok, retrieved} = Manager.get_session(session.session_id)
      assert retrieved.session_id == session.session_id
      assert retrieved.did == session.did
    end
  end

  describe "end_session/1" do
    test "ends an active session and computes hash" do
      {:ok, session} = Manager.start_session(@test_did, @test_user_id)
      assert {:ok, ended} = Manager.end_session(session.session_id)

      assert ended.status in [:ended, :notarized]
      assert %DateTime{} = ended.ended_at
      assert is_binary(ended.notarization_hash)
      assert String.length(ended.notarization_hash) == 64
    end

    test "reads command history from disk", %{sessions_dir: dir} do
      {:ok, session} = Manager.start_session(@test_did, @test_user_id)

      # Simulate bash writing a history file
      history_dir = Path.join(dir, session.session_id)
      File.mkdir_p!(history_dir)
      history_content = "    1  ls -la\n    2  echo hello world\n    3  cat /etc/os-release\n"
      File.write!(Path.join(history_dir, "history"), history_content)

      {:ok, ended} = Manager.end_session(session.session_id)
      assert ended.command_count == 3
      assert length(ended.commands) == 3

      commands = Enum.map(ended.commands, & &1.command)
      assert "ls -la" in commands
      assert "echo hello world" in commands
      assert "cat /etc/os-release" in commands
    end

    test "handles missing history file gracefully" do
      {:ok, session} = Manager.start_session(@test_did, @test_user_id)
      {:ok, ended} = Manager.end_session(session.session_id)

      assert ended.command_count == 0
      assert ended.commands == []
      # Should still produce a hash (of the session document)
      assert is_binary(ended.notarization_hash)
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = Manager.end_session("ses_nonexistent")
    end

    test "returns current state for already-ended session" do
      {:ok, session} = Manager.start_session(@test_did, @test_user_id)
      {:ok, _ended} = Manager.end_session(session.session_id)
      {:ok, again} = Manager.end_session(session.session_id)
      assert again.status in [:ended, :notarized]
    end

    test "persists final result to ETS" do
      {:ok, session} = Manager.start_session(@test_did, @test_user_id)
      {:ok, ended} = Manager.end_session(session.session_id)

      assert {:ok, found} = Manager.get_session(session.session_id)
      assert found.status in [:ended, :notarized]
      assert found.notarization_hash == ended.notarization_hash
    end
  end

  describe "get_session/1" do
    test "returns :not_found for unknown sessions" do
      assert :not_found = Manager.get_session("ses_doesnotexist")
    end

    test "returns session after creation" do
      {:ok, session} = Manager.start_session(@test_did, @test_user_id)
      assert {:ok, found} = Manager.get_session(session.session_id)
      assert found.session_id == session.session_id
    end
  end

  describe "list_sessions/1" do
    test "returns all sessions" do
      {:ok, _s1} = Manager.start_session(@test_did, @test_user_id)
      {:ok, _s2} = Manager.start_session(@test_did, "usr_other")

      sessions = Manager.list_sessions()
      assert length(sessions) >= 2
    end

    test "filters by user_id" do
      {:ok, _s1} = Manager.start_session(@test_did, "filter_user_a")
      {:ok, _s2} = Manager.start_session(@test_did, "filter_user_b")

      sessions = Manager.list_sessions(user_id: "filter_user_a")
      assert Enum.all?(sessions, &(&1.user_id == "filter_user_a"))
    end

    test "filters by status" do
      {:ok, s1} = Manager.start_session(@test_did, @test_user_id)
      {:ok, _s2} = Manager.start_session(@test_did, @test_user_id)
      Manager.end_session(s1.session_id)

      active_sessions = Manager.list_sessions(status: :active)
      assert Enum.all?(active_sessions, &(&1.status == :active))
    end

    test "respects limit" do
      for _ <- 1..5 do
        Manager.start_session(@test_did, @test_user_id)
      end

      sessions = Manager.list_sessions(limit: 3)
      assert length(sessions) <= 3
    end
  end

  describe "stats/0" do
    test "returns aggregate statistics" do
      {:ok, s1} = Manager.start_session(@test_did, @test_user_id)
      {:ok, _s2} = Manager.start_session(@test_did, @test_user_id)
      Manager.end_session(s1.session_id)

      stats = Manager.stats()
      assert is_integer(stats.total)
      assert is_integer(stats.active)
      assert is_integer(stats.sessions_started)
      assert stats.sessions_started >= 2
      assert stats.sessions_ended >= 1
    end
  end
end
