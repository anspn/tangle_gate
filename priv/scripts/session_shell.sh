#!/bin/bash
# =============================================================================
# IOTA Service — TTY Session Recording Shell
# =============================================================================
#
# Entrypoint for the ttyd container. Spawns an interactive bash shell with
# tamper-proof command recording via a DEBUG trap audit log.
#
# Security model:
#   - Every command is captured by a DEBUG trap BEFORE it executes.
#   - Commands are written to an append-only audit log (chattr +a) that the
#     user cannot modify, truncate, or delete.
#   - Shell built-ins that could tamper with recording (history -c, unset
#     HISTFILE, HISTFILE=..., shopt, set +o, enable) are intercepted and
#     neutralised — the command is still logged but has no effect.
#   - The EXIT trap flushes any remaining data and writes an end marker.
#   - The audit log is the authoritative record; HISTFILE is kept as a
#     convenience copy but is NOT used for notarization.
#
# Flow:
#   1. Check /data/sessions/pending/ for a pending session created by the
#      Elixir app (contains session_id and DID).
#   2. Create a session directory under /data/sessions/<session_id>/.
#   3. Create a tamper-proof audit log file.
#   4. Configure bash with a DEBUG trap that logs every command.
#   5. On exit (trap), write a completion marker so the Elixir app can
#      detect that the session has ended and trigger notarization.
# =============================================================================

SESSIONS_DIR="${SESSIONS_DIR:-/data/sessions}"
PENDING_DIR="${SESSIONS_DIR}/pending"

# Ensure directories are writable by all containers on the shared Docker volume.
# The ttyd container runs as root; the Elixir app container runs as non-root "iota".
mkdir -p "$PENDING_DIR"
chmod 777 "$SESSIONS_DIR" "$PENDING_DIR" 2>/dev/null || true

# --- Consume pending session ------------------------------------------------
SESSION_ID=""
DID=""

# Look for the newest pending session file
if [ -d "$PENDING_DIR" ]; then
  PENDING_FILE=$(ls -t "$PENDING_DIR"/*.session 2>/dev/null | head -1)

  if [ -n "$PENDING_FILE" ] && [ -f "$PENDING_FILE" ]; then
    # File format: line 1 = session_id, line 2 = DID
    SESSION_ID=$(sed -n '1p' "$PENDING_FILE")
    DID=$(sed -n '2p' "$PENDING_FILE")
    rm -f "$PENDING_FILE"
  fi
fi

# Fallback: generate a UUID if no pending session was claimed
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "s_$(date +%s%N)")
fi

SESSION_DIR="${SESSIONS_DIR}/${SESSION_ID}"
mkdir -p "$SESSION_DIR"
chmod 755 "$SESSION_DIR"

# --- Create the tamper-proof audit log --------------------------------------
# This is the authoritative command record used for notarization.
AUDIT_LOG="$SESSION_DIR/audit.log"
touch "$AUDIT_LOG"
chmod 666 "$AUDIT_LOG"

# Make the audit log append-only so the user cannot modify or truncate it.
# chattr may not be available in all containers — fall back gracefully.
chattr +a "$AUDIT_LOG" 2>/dev/null || true

# Pre-create the history file (convenience copy, NOT used for notarization)
touch "$SESSION_DIR/history"
chmod 666 "$SESSION_DIR/history"

# --- Write session metadata -------------------------------------------------
cat > "$SESSION_DIR/meta.json" << METAEOF
{
  "session_id": "${SESSION_ID}",
  "did": "${DID}",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pid": $$
}
METAEOF

# Write a pointer so the app can quickly find the current session
echo "$SESSION_ID" > "${SESSIONS_DIR}/current"
chmod 644 "${SESSIONS_DIR}/current" 2>/dev/null

# --- Diagnostic logging (helps debug pending-file handoff) -------------------
LOG="$SESSION_DIR/shell.log"
{
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] session_shell.sh started"
  echo "  Session ID  : $SESSION_ID"
  echo "  DID         : ${DID:-<none>}"
  echo "  Pending file: ${PENDING_FILE:-<not found>}"
  echo "  Session dir : $SESSION_DIR"
  echo "  Audit log   : $AUDIT_LOG"
  echo "  History file: $SESSION_DIR/history"
  echo "  Shell PID   : $$"
  echo "  UID/GID     : $(id)"
  echo "--- directory listing ---"
  ls -la "$SESSION_DIR/" 2>/dev/null
  echo "--- pending dir ---"
  ls -la "$PENDING_DIR/" 2>/dev/null || echo "  (not accessible)"
} >> "$LOG" 2>&1
chmod 644 "$LOG" 2>/dev/null

# --- Build a bashrc for the interactive shell --------------------------------
cat > "$SESSION_DIR/bashrc" << 'RCEOF'
# ---- HISTFILE setup (convenience copy, NOT the audit source) ----
export HISTCONTROL=ignoredups:ignorespace
export HISTTIMEFORMAT="%Y-%m-%dT%H:%M:%S "
shopt -s histappend
PROMPT_COMMAND='history -a; chmod 644 "$HISTFILE" 2>/dev/null'
RCEOF

# Inject the dynamic paths
cat >> "$SESSION_DIR/bashrc" << DYNEOF
export HISTFILE="${SESSION_DIR}/history"
export _IOTA_AUDIT_LOG="${AUDIT_LOG}"
export _IOTA_SESSION_DIR="${SESSION_DIR}"
export _IOTA_SESSION_ID="${SESSION_ID}"
DYNEOF

# ---- Tamper-proof DEBUG trap ------------------------------------------------
# The DEBUG trap fires BEFORE every simple command. It writes each command
# with a timestamp to the audit log. Because the audit log has chattr +a
# (append-only), the user cannot modify or truncate it.
cat >> "$SESSION_DIR/bashrc" << 'TRAPEOF'

# Command counter for the audit log
_IOTA_CMD_SEQ=0

_iota_audit_command() {
  # Skip logging the trap function itself and PROMPT_COMMAND internals
  local cmd="$BASH_COMMAND"

  # Ignore PROMPT_COMMAND invocations and internal traps
  [[ "$cmd" == "history -a"* ]] && return 0
  [[ "$cmd" == "chmod 644"* ]] && return 0
  [[ "$cmd" == "_iota_"* ]] && return 0
  # Ignore watchdog setup commands
  [[ "$cmd" == "_IOTA_WATCHDOG"* ]] && return 0
  [[ "$cmd" == *"_watchdog_ppid"* ]] && return 0

  _IOTA_CMD_SEQ=$(( _IOTA_CMD_SEQ + 1 ))
  printf '%s\t%d\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_IOTA_CMD_SEQ" "$cmd" \
    >> "$_IOTA_AUDIT_LOG" 2>/dev/null
}
# NOTE: The DEBUG trap is activated at the END of this bashrc (after the
# welcome banner) so that init commands are not recorded in the audit log.

# ---- Protect critical variables from user tampering -------------------------
# Make key variables readonly so `unset HISTFILE`, `HISTFILE=/dev/null`, etc.
# produce an error instead of silently disabling recording.
readonly HISTFILE
readonly HISTTIMEFORMAT
readonly HISTCONTROL
readonly _IOTA_AUDIT_LOG
readonly _IOTA_SESSION_DIR
readonly _IOTA_SESSION_ID

# ---- Neutralise history-tampering built-ins ---------------------------------
# Override dangerous commands with no-ops that still get logged by the DEBUG
# trap (so the tampering attempt itself is recorded).
history() {
  case "$1" in
    -c|-d|-r|-w)
      echo "iota: history modification is disabled in recorded sessions."
      return 1
      ;;
    *)
      builtin history "$@"
      ;;
  esac
}
TRAPEOF

# ---- Cleanup on exit -------------------------------------------------------
# The bash EXIT trap only flushes history. Final cleanup (chattr -a, ended.json)
# is handled by the outer restart loop in session_shell.sh so that typing
# 'exit' restarts the shell instead of finalizing the session.
cat >> "$SESSION_DIR/bashrc" << EXITEOF
_iota_session_cleanup() {
  # Kill the terminate watchdog if running
  if [ -n "\$_IOTA_WATCHDOG_PID" ]; then
    kill "\$_IOTA_WATCHDOG_PID" 2>/dev/null
    wait "\$_IOTA_WATCHDOG_PID" 2>/dev/null
  fi
  history -a 2>/dev/null
  chmod 644 "\$HISTFILE" 2>/dev/null
}
trap '_iota_session_cleanup' EXIT
EXITEOF

# ---- Welcome banner --------------------------------------------------------
cat >> "$SESSION_DIR/bashrc" << BANNEREOF

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║  🔷   TangleGate Terminal            ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
echo "  Session : ${SESSION_ID}"
BANNEREOF

if [ -n "$DID" ]; then
  echo "echo \"  DID     : ${DID}\"" >> "$SESSION_DIR/bashrc"
fi

cat >> "$SESSION_DIR/bashrc" << 'TAILEOF'
echo ""
echo "  Commands are recorded and will be notarized on the TangleGate."
echo "  History tampering is disabled — all commands are audit-logged."
echo ""
# ---- Activate the DEBUG trap LAST so init commands are not recorded ----
trap '_iota_audit_command' DEBUG

# ---- Background watchdog: monitors for admin termination ----
# Polls every second for the terminate marker file. When found, sends
# SIGHUP to the parent bash PID to forcefully end the session.
# Uses HUP because interactive bash ignores SIGTERM by default.
# This is more reliable than PROMPT_COMMAND because it works even if
# the user is in the middle of a long-running command.
(
  _watchdog_ppid=$$
  while true; do
    sleep 1
    if [ -f "$_IOTA_SESSION_DIR/terminate" ]; then
      echo "" >&2
      echo "  Session terminated by administrator." >&2
      # Use SIGHUP, not SIGTERM — interactive bash ignores SIGTERM by default.
      # SIGHUP causes bash to send HUP to all jobs and exit cleanly.
      kill -HUP "$_watchdog_ppid" 2>/dev/null
      break
    fi
  done
) &
_IOTA_WATCHDOG_PID=$!
TAILEOF

# --- Launch the interactive shell in a restart loop -------------------------
# When the user types 'exit' (or Ctrl+D), bash terminates but the session
# continues — the loop restarts bash with the same session context (same
# session_id, same audit log). The session only truly ends when ttyd sends
# SIGHUP/SIGTERM (user clicks Disconnect) or the container is stopped.
#
# This prevents the bug where typing 'exit' finalizes the audit log and any
# subsequent commands (after reconnecting) are lost.

_IOTA_SHUTDOWN_REQUESTED=0

_iota_request_shutdown() {
  _IOTA_SHUTDOWN_REQUESTED=1
}

# TERM/HUP are sent by ttyd when the WebSocket disconnects
trap '_iota_request_shutdown' TERM HUP INT

while true; do
  bash --rcfile "$SESSION_DIR/bashrc" -i

  # If a shutdown signal was received, break out of the loop
  if [[ $_IOTA_SHUTDOWN_REQUESTED -eq 1 ]]; then
    break
  fi

  # If admin terminated the session, break out of the loop
  if [[ -f "$SESSION_DIR/terminate" ]]; then
    break
  fi

  # User typed 'exit' or Ctrl+D — log the restart and re-launch bash
  printf '%s\t0\t[shell restarted after exit command]\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AUDIT_LOG" 2>/dev/null
done

# --- Final cleanup (session truly ended) ------------------------------------
# Remove append-only attribute so the Elixir app can manage the file
chattr -a "$AUDIT_LOG" 2>/dev/null || true
chmod 644 "$AUDIT_LOG" 2>/dev/null
echo "{\"ended_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$SESSION_DIR/ended.json"
