#!/bin/bash
# =============================================================================
# Backend container entrypoint
# =============================================================================
# Captures Docker environment variables into a file before exec'ing systemd.
# systemd replaces the process environment, so services can't see Docker's
# env vars. This script saves them to /run/docker-env which configure.sh
# reads during the oneshot boot phase.
# =============================================================================

# Save Docker env vars to a file for the configure.sh service to read
env > /run/docker-env
chmod 600 /run/docker-env

# Exec systemd as PID 1
exec /sbin/init
