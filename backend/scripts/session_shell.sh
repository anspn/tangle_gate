#!/bin/bash
# =============================================================================
# IOTA Service — TTY Session Recording Shell (systemd-logind version)
# =============================================================================
#
# This is the login shell for the sessionuser account. It is invoked after
# PAM authentication (via login(1) or sshd), so the session is already
# registered with systemd-logind by pam_systemd.
#
# The agent can terminate the session via `loginctl terminate-session`
# which sends SIGHUP to all processes in the logind session scope.
#
# Security model:
#   - Every command is captured by a DEBUG trap BEFORE it executes.
#   - Commands are written to an append-only audit log (chattr +a).
#   - Shell built-ins that could tamper with recording are intercepted.
#   - The EXIT trap flushes any remaining data and writes an end marker.
#
# Flow:
#   1. Check /data/sessions/pending/ for a pending session from the Elixir app.
#   2. Export IOTA_SESSION_ID to the environment (visible to loginctl).
#   3. Create session directory and tamper-proof audit log.
#   4. Configure bash with a DEBUG trap for command recording.
#   5. On exit, write completion marker for the Elixir app.
# =============================================================================

SESSIONS_DIR="${SESSIONS_DIR:-/data/sessions}"
PENDING_DIR="${SESSIONS_DIR}/pending"

mkdir -p "$PENDING_DIR"
chmod 777 "$SESSIONS_DIR" "$PENDING_DIR" 2>/dev/null || true

# --- Consume pending session ------------------------------------------------
SESSION_ID=""
DID=""

if [ -d "$PENDING_DIR" ]; then
  PENDING_FILE=$(ls -t "$PENDING_DIR"/*.session 2>/dev/null | head -1)

  if [ -n "$PENDING_FILE" ] && [ -f "$PENDING_FILE" ]; then
    SESSION_ID=$(sed -n '1p' "$PENDING_FILE")
    DID=$(sed -n '2p' "$PENDING_FILE")
    rm -f "$PENDING_FILE"
  fi
fi

# Fallback: generate a UUID if no pending session was claimed
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "s_$(date +%s%N)")
fi

# Export session ID so it's visible in the logind session environment.
# The agent's Terminator uses this to correlate logind sessions with
# tangle_gate session IDs.
export IOTA_SESSION_ID="$SESSION_ID"

SESSION_DIR="${SESSIONS_DIR}/${SESSION_ID}"
mkdir -p "$SESSION_DIR"
chmod 755 "$SESSION_DIR"

# --- Create the tamper-proof audit log --------------------------------------
AUDIT_LOG="$SESSION_DIR/audit.log"
touch "$AUDIT_LOG"
chmod 666 "$AUDIT_LOG"
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

echo "$SESSION_ID" > "${SESSIONS_DIR}/current"
chmod 644 "${SESSIONS_DIR}/current" 2>/dev/null

# --- Diagnostic logging -----------------------------------------------------
LOG="$SESSION_DIR/shell.log"
{
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] session_shell.sh started"
  echo "  Session ID  : $SESSION_ID"
  echo "  DID         : ${DID:-<none>}"
  echo "  Pending file: ${PENDING_FILE:-<not found>}"
  echo "  Session dir : $SESSION_DIR"
  echo "  Audit log   : $AUDIT_LOG"
  echo "  Shell PID   : $$"
  echo "  UID/GID     : $(id)"
  # Log the logind session ID so we can verify PAM registration
  echo "  loginctl    : $(loginctl --no-pager show-session self -p Id 2>/dev/null || echo 'N/A')"
} >> "$LOG" 2>&1
chmod 644 "$LOG" 2>/dev/null

# --- Build the bashrc for the interactive shell ------------------------------
cat > "$SESSION_DIR/bashrc" << 'RCEOF'
# ---- HISTFILE setup (convenience copy, NOT the audit source) ----
export HISTCONTROL=ignoredups:ignorespace
export HISTTIMEFORMAT="%Y-%m-%dT%H:%M:%S "
shopt -s histappend
PROMPT_COMMAND='history -a; chmod 644 "$HISTFILE" 2>/dev/null'
RCEOF

cat >> "$SESSION_DIR/bashrc" << DYNEOF
export HISTFILE="${SESSION_DIR}/history"
export _IOTA_AUDIT_LOG="${AUDIT_LOG}"
export _IOTA_SESSION_DIR="${SESSION_DIR}"
export _IOTA_SESSION_ID="${SESSION_ID}"
export IOTA_SESSION_ID="${SESSION_ID}"
DYNEOF

# ---- Tamper-proof DEBUG trap ------------------------------------------------
cat >> "$SESSION_DIR/bashrc" << 'TRAPEOF'

_IOTA_CMD_SEQ=0

_iota_audit_command() {
  local cmd="$BASH_COMMAND"

  [[ "$cmd" == "history -a"* ]] && return 0
  [[ "$cmd" == "chmod 644"* ]] && return 0
  [[ "$cmd" == "_iota_"* ]] && return 0

  _IOTA_CMD_SEQ=$(( _IOTA_CMD_SEQ + 1 ))
  printf '%s\t%d\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_IOTA_CMD_SEQ" "$cmd" \
    >> "$_IOTA_AUDIT_LOG" 2>/dev/null
}

# ---- Protect critical variables from user tampering -------------------------
readonly HISTFILE
readonly HISTTIMEFORMAT
readonly HISTCONTROL
readonly _IOTA_AUDIT_LOG
readonly _IOTA_SESSION_DIR
readonly _IOTA_SESSION_ID
readonly IOTA_SESSION_ID

# ---- Neutralise history-tampering built-ins ---------------------------------
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
cat >> "$SESSION_DIR/bashrc" << EXITEOF
_iota_session_cleanup() {
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
TAILEOF

# --- Launch the interactive shell in a restart loop -------------------------
# When the user types 'exit' (or Ctrl+D), bash terminates but the session
# continues — the loop restarts bash with the same session context.
# The session truly ends when:
#   1. loginctl terminate-session sends SIGHUP (admin termination), or
#   2. The ttyd WebSocket disconnects (user closes browser)

_IOTA_SHUTDOWN_REQUESTED=0
_IOTA_PARENT_PID=$PPID

_iota_final_cleanup() {
  rm -f "$SESSION_DIR/.shutdown" 2>/dev/null
  chattr -a "$AUDIT_LOG" 2>/dev/null || true
  chmod 644 "$AUDIT_LOG" 2>/dev/null
  echo "{\"ended_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$SESSION_DIR/ended.json"
}

# EXIT trap ensures cleanup runs regardless of how the script exits
trap '_iota_final_cleanup' EXIT

_iota_request_shutdown() {
  _IOTA_SHUTDOWN_REQUESTED=1
  touch "$SESSION_DIR/.shutdown" 2>/dev/null
}

# On TERM/HUP/INT: mark shutdown and exit immediately.
# Bash defers trap handlers while a foreground child is running, so
# the handler fires only after the inner bash exits. At that point,
# `exit 0` terminates session_shell.sh and the EXIT trap runs cleanup.
trap '_iota_request_shutdown; exit 0' TERM HUP INT

while true; do
  bash --rcfile "$SESSION_DIR/bashrc" -i

  # Three independent checks to detect termination:
  #   1. Trap handler set the variable (trap may have fired between iterations)
  #   2. Trap handler wrote the marker file
  #   3. Parent process (su/login/sshd) died (e.g., killed by scope HUP)
  if [[ $_IOTA_SHUTDOWN_REQUESTED -eq 1 ]] \
     || [[ -f "$SESSION_DIR/.shutdown" ]] \
     || [[ ! -d "/proc/$_IOTA_PARENT_PID" ]]; then
    break
  fi

  # User typed 'exit' or Ctrl+D — log the restart and re-launch bash
  printf '%s\t0\t[shell restarted after exit command]\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AUDIT_LOG" 2>/dev/null
done

# Cleanup is handled by the EXIT trap above
