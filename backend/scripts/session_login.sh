#!/bin/bash
# =============================================================================
# ttyd login wrapper — ensures sessions go through PAM → logind
# =============================================================================
# ttyd calls this script for every new web terminal connection.
# It uses `login` to authenticate through PAM, which registers the
# session with systemd-logind. This makes the session visible to
# `loginctl list-sessions` and terminable via `loginctl terminate-session`.
#
# After PAM authentication, the user's shell is set to session_shell.sh
# which handles audit logging and session recording.
# =============================================================================

# Use login(1) to authenticate through PAM — this is what registers
# the session with systemd-logind via pam_systemd.so
exec login -f sessionuser
