defmodule TangleGateAgent.Session.Terminator do
  @moduledoc """
  Terminates user sessions on the host system.

  Supports two strategies (tried in order):

  1. **loginctl-based** (`loginctl terminate-session`) — Preferred.
     First sends SIGHUP via `systemctl kill` to the session scope
     (kills all processes in the scope including the outer shell), then
     calls `loginctl terminate-session` for cleanup. Requires
     systemd-logind and polkit rules.

  2. **Signal-based** (`pkill -HUP -f <session_id>`) — Fallback when
     loginctl is unavailable. Only kills processes whose command line
     contains the session_id. Requires `CAP_KILL` capability.

  ## System Requirements

  | Requirement              | loginctl-based           | Signal-based             |
  |--------------------------|--------------------------|--------------------------|
  | **Privileges**           | Root or polkit rule      | `CAP_KILL` via systemd   |
  | **Process visibility**   | systemd-logind running   | `/proc` accessible       |
  | **PAM**                  | `UsePAM yes` in sshd    | Not required             |
  | **Terminal backend**     | Works with SSH           | Works with ttyd + SSH    |

  Capabilities are detected at startup and reported to tangle_gate via the
  WebSocket `connected` message.
  """

  require Logger

  @doc """
  Detect available termination capabilities on this host.

  Returns a list of capability strings, e.g. `["signal", "loginctl"]`.
  """
  @spec detect_capabilities() :: [String.t()]
  def detect_capabilities do
    caps = []

    caps =
      if signal_capable?() do
        ["signal" | caps]
      else
        caps
      end

    caps =
      if loginctl_capable?() do
        ["loginctl" | caps]
      else
        caps
      end

    Logger.info("Termination capabilities: #{inspect(caps)}")
    caps
  end

  @doc """
  Terminate a session by session_id.

  Looks up the session in the tracker and attempts termination using
  available strategies.

  Returns `{:ok, detail}` or `{:error, reason}`.
  """
  @spec terminate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def terminate(session_id) do
    case TangleGateAgent.Session.Tracker.get_session(session_id) do
      {:ok, session_info} ->
        do_terminate(session_id, session_info)

      :not_found ->
        # Even without tracker info, try pkill with session_id pattern
        Logger.warning("Session #{session_id} not in tracker, trying pkill fallback")
        try_signal_by_pattern(session_id)
    end
  end

  # ============================================================================
  # Termination strategies
  # ============================================================================

  defp do_terminate(session_id, session_info) do
    pid_hint = Map.get(session_info, :pid_hint)

    # Try loginctl first (targets ALL processes in the logind session scope,
    # including the outer session_shell.sh). Signal-based fallback only kills
    # processes whose command line contains the session_id, which misses the
    # outer shell script.
    with {:error, _} <- try_loginctl(session_id),
         {:error, _} <- try_signal(pid_hint, session_id) do
      {:error, "all termination strategies failed for session #{session_id}"}
    end
  end

  # Strategy 1: loginctl terminate-session (preferred)
  #
  # loginctl targets ALL processes in the logind session scope, including
  # the outer session_shell.sh. However, loginctl uses SIGTERM by default
  # and interactive bash ignores SIGTERM. To avoid a 90-second wait for
  # SIGKILL, we first send SIGHUP via `systemctl kill` to the session scope.
  # SIGHUP causes interactive bash to send HUP to all jobs and exit.
  defp try_loginctl(session_id) do
    if loginctl_capable?() do
      case find_loginctl_session(session_id) do
        {:ok, logind_session} ->
          Logger.info("Found logind session #{logind_session} for #{session_id}")

          # Step 1: Send SIGHUP to all processes in the session scope.
          # This makes interactive bash exit immediately (it doesn't ignore HUP)
          # and triggers the session_shell.sh trap to set _IOTA_SHUTDOWN_REQUESTED=1.
          scope = "session-#{logind_session}.scope"

          scope_hup_ok =
            case System.cmd("systemctl", ["kill", scope, "--signal=HUP"],
                   stderr_to_stdout: true
                 ) do
              {_, 0} ->
                Logger.info("Sent SIGHUP to scope #{scope}")
                true

              {output, code} ->
                Logger.warning(
                  "systemctl kill #{scope} --signal=HUP failed (#{code}): #{output}"
                )

                false
            end

          # Brief pause to let processes handle the signal and exit
          Process.sleep(500)

          # Step 2: Terminate the logind session (cleans up the scope).
          # If processes survived SIGHUP, this sends SIGTERM then SIGKILL.
          # If scope HUP already killed everything, the session may be gone—
          # that's a success, not a failure.
          case System.cmd("loginctl", ["terminate-session", logind_session],
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              TangleGateAgent.Session.Tracker.untrack_session(session_id)
              {:ok, "loginctl terminated session #{logind_session}"}

            {output, code} ->
              if scope_hup_ok do
                # Scope HUP succeeded and session is already gone — success
                Logger.info(
                  "Session #{logind_session} already gone after scope SIGHUP (expected)"
                )

                TangleGateAgent.Session.Tracker.untrack_session(session_id)
                {:ok, "session #{logind_session} terminated via scope SIGHUP"}
              else
                Logger.warning(
                  "loginctl terminate-session failed (code #{code}): #{output}"
                )

                {:error, "loginctl failed (code #{code}): #{output}"}
              end
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :loginctl_not_capable}
    end
  end

  # Strategy 2: Kill by PID hint (SIGHUP) — fallback when loginctl is unavailable
  defp try_signal(pid_hint, session_id) when is_integer(pid_hint) and pid_hint > 0 do
    Logger.info("Attempting signal termination: kill -HUP #{pid_hint}")

    case System.cmd("kill", ["-HUP", Integer.to_string(pid_hint)], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("Successfully sent SIGHUP to PID #{pid_hint} (session #{session_id})")
        TangleGateAgent.Session.Tracker.untrack_session(session_id)
        {:ok, "SIGHUP sent to PID #{pid_hint}"}

      {output, _} ->
        Logger.warning("kill -HUP #{pid_hint} failed: #{output}")
        # Fall through to pattern-based kill
        try_signal_by_pattern(session_id)
    end
  end

  defp try_signal(_, session_id) do
    try_signal_by_pattern(session_id)
  end

  # Fallback: pkill by session_id pattern in process arguments
  defp try_signal_by_pattern(session_id) do
    if signal_capable?() do
      Logger.info("Attempting pkill -HUP -f #{session_id}")

      case System.cmd("pkill", ["-HUP", "-f", session_id], stderr_to_stdout: true) do
        {_, 0} ->
          TangleGateAgent.Session.Tracker.untrack_session(session_id)
          {:ok, "pkill -HUP matched processes for #{session_id}"}

        {output, code} ->
          Logger.warning("pkill -HUP -f #{session_id} exited #{code}: #{output}")
          {:error, "pkill failed (code #{code})"}
      end
    else
      {:error, :signal_not_capable}
    end
  end

  # ============================================================================
  # Capability detection
  # ============================================================================

  defp signal_capable? do
    case System.cmd("which", ["kill"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  catch
    _, _ -> false
  end

  defp loginctl_capable? do
    case System.cmd("which", ["loginctl"], stderr_to_stdout: true) do
      {_, 0} ->
        case System.cmd("loginctl", ["--no-pager", "list-sessions"], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end

      _ ->
        false
    end
  catch
    _, _ -> false
  end

  # ============================================================================
  # loginctl helpers
  # ============================================================================

  defp find_loginctl_session(session_id) do
    # List all logind sessions and find the one whose processes have
    # IOTA_SESSION_ID=<session_id> in their environment. The session_shell.sh
    # exports this variable, and PAM/logind groups all session processes
    # under a systemd scope (session-N.scope).
    case System.cmd("loginctl", ["--no-pager", "--no-legend", "list-sessions"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        sessions =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.split(&1, ~r/\s+/, trim: true))
          |> Enum.filter(fn parts -> length(parts) >= 1 end)
          |> Enum.map(fn [id | _] -> id end)

        # For each logind session, get the leader PID and check its
        # environment for IOTA_SESSION_ID matching our target session_id.
        found =
          Enum.find(sessions, fn logind_id ->
            session_has_iota_id?(logind_id, session_id)
          end)

        case found do
          nil -> {:error, "no loginctl session found matching #{session_id}"}
          id -> {:ok, id}
        end

      {output, code} ->
        {:error, "loginctl list-sessions failed (code #{code}): #{output}"}
    end
  end

  # Check if a logind session contains a process whose command line or
  # environment references the target session_id. The inner bash has the
  # session_id in its rcfile path: `bash --rcfile /data/sessions/<id>/bashrc -i`.
  # /proc/<pid>/environ only shows the INITIAL env (not `export` in scripts),
  # so we also check /proc/<pid>/cmdline.
  defp session_has_iota_id?(logind_id, target_session_id) do
    case System.cmd("loginctl", ["--no-pager", "show-session", logind_id, "-p", "Leader"],
           stderr_to_stdout: true
         ) do
      {leader_output, 0} ->
        case Regex.run(~r/Leader=(\d+)/, leader_output) do
          [_, pid_str] ->
            process_tree_has_session_id?(pid_str, target_session_id)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # Recursively check a process and its children for the session_id
  # in either cmdline or environ.
  defp process_tree_has_session_id?(pid_str, session_id) do
    process_has_session_id?(pid_str, session_id) or
      children_have_session_id?(pid_str, session_id)
  end

  defp process_has_session_id?(pid_str, session_id) do
    process_cmdline_contains?(pid_str, session_id) or
      process_environ_contains?(pid_str, "IOTA_SESSION_ID=#{session_id}")
  end

  # Check /proc/<pid>/cmdline for the session_id string
  defp process_cmdline_contains?(pid_str, session_id) do
    case File.read("/proc/#{pid_str}/cmdline") do
      {:ok, content} -> String.contains?(content, session_id)
      {:error, _} -> false
    end
  end

  # Check /proc/<pid>/environ for a specific env var
  defp process_environ_contains?(pid_str, target_env) do
    case File.read("/proc/#{pid_str}/environ") do
      {:ok, content} ->
        content
        |> String.split(<<0>>)
        |> Enum.any?(&(&1 == target_env))

      {:error, _} ->
        false
    end
  end

  # Walk child processes recursively
  defp children_have_session_id?(parent_pid, session_id) do
    case System.cmd("pgrep", ["-P", parent_pid], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.any?(fn child_pid ->
          process_tree_has_session_id?(child_pid, session_id)
        end)

      _ ->
        false
    end
  end
end
