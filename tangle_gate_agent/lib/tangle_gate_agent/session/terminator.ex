defmodule TangleGateAgent.Session.Terminator do
  @moduledoc """
  Terminates user sessions on the host system.

  Supports two strategies (tried in order):

  1. **Signal-based** (`kill -HUP <pid>`) — Requires `CAP_KILL` capability
     or root. Sends SIGHUP to the session's shell process.

  2. **loginctl-based** (`loginctl terminate-session`) — Requires
     systemd-logind and appropriate polkit rules or root.

  ## System Requirements

  | Requirement              | Signal-based             | loginctl-based           |
  |--------------------------|--------------------------|--------------------------|
  | **Privileges**           | `CAP_KILL` via systemd   | Root or polkit rule      |
  | **Process visibility**   | `/proc` accessible       | systemd-logind running   |
  | **PAM**                  | Not required             | `UsePAM yes` in sshd    |
  | **Terminal backend**     | Works with ttyd + SSH    | Works with SSH           |

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

    # Try strategies in order
    with {:error, _} <- try_signal(pid_hint, session_id),
         {:error, _} <- try_loginctl(session_id) do
      {:error, "all termination strategies failed for session #{session_id}"}
    end
  end

  # Strategy 1: Kill by PID hint (SIGHUP)
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

  # Strategy 2: loginctl terminate-session
  defp try_loginctl(session_id) do
    if loginctl_capable?() do
      # Find the logind session for this session_id
      case find_loginctl_session(session_id) do
        {:ok, logind_session} ->
          Logger.info("Attempting loginctl terminate-session #{logind_session}")

          case System.cmd("loginctl", ["terminate-session", logind_session],
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              TangleGateAgent.Session.Tracker.untrack_session(session_id)
              {:ok, "loginctl terminated session #{logind_session}"}

            {output, code} ->
              Logger.warning("loginctl terminate-session failed (code #{code}): #{output}")
              {:error, "loginctl failed (code #{code}): #{output}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :loginctl_not_capable}
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
    # List all logind sessions and try to match by session metadata.
    # The session_id from tangle_gate is stored as an environment variable
    # or process argument in the user's shell.
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

        # Check each logind session's environment for our session_id
        found =
          Enum.find(sessions, fn logind_id ->
            case System.cmd("loginctl", ["--no-pager", "show-session", logind_id, "-p", "TTY"],
                   stderr_to_stdout: true
                 ) do
              {env_output, 0} -> String.contains?(env_output, session_id)
              _ -> false
            end
          end)

        case found do
          nil -> {:error, "no loginctl session found matching #{session_id}"}
          id -> {:ok, id}
        end

      {output, code} ->
        {:error, "loginctl list-sessions failed (code #{code}): #{output}"}
    end
  end
end
