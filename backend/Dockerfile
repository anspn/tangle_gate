# =============================================================================
# Dockerfile for tangle_gate backend
# =============================================================================
# Combined container: systemd + logind + sshd + ttyd + tangle_gate_agent
#
# Provides:
#   - systemd-logind for session management (loginctl terminate-session)
#   - sshd with PAM integration (pam_systemd registers sessions with logind)
#   - ttyd web terminal pointing at the session shell via PAM login
#   - tangle_gate_agent as a systemd service
#
# The tangle_gate app communicates with the agent over WebSocket.
# When an admin terminates a session, the agent uses loginctl to kill it.
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build tangle_gate_agent release
# ---------------------------------------------------------------------------
FROM hexpm/elixir:1.18.3-erlang-27.3.4.8-debian-bookworm-20260202 AS agent-build

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates cmake pkg-config libssl-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY tangle_gate_agent/mix.exs tangle_gate_agent/mix.lock ./
RUN mix deps.get --only $MIX_ENV

COPY tangle_gate_agent/config/config.exs tangle_gate_agent/config/prod.exs \
     tangle_gate_agent/config/runtime.exs config/
RUN mix deps.compile

COPY tangle_gate_agent/lib lib
RUN mix compile && mix release

# ---------------------------------------------------------------------------
# Stage 2: Runtime — systemd + logind + sshd + ttyd + agent
# ---------------------------------------------------------------------------
FROM debian:bookworm AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      # systemd core (PID 1 + logind for session management)
      systemd \
      systemd-sysv \
      dbus \
      # SSH server (PAM integration → logind session registration)
      openssh-server \
      # Erlang/Elixir runtime dependencies
      libstdc++6 openssl libncurses5 locales ca-certificates curl \
      # Utilities for session management
      procps e2fsprogs \
      # loginctl needs polkit for unprivileged session termination
      policykit-1 \
      # websocket library needed by ttyd
      libwebsockets-dev libjson-c-dev && \
    rm -rf /var/lib/apt/lists/*

# Install ttyd from GitHub releases (not in Debian repos)
RUN ARCH=$(uname -m) && \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${ARCH}" \
      -o /usr/local/bin/ttyd && \
    chmod 755 /usr/local/bin/ttyd

# Locale setup
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# ---------------------------------------------------------------------------
# systemd configuration — strip unnecessary units for container use
# ---------------------------------------------------------------------------
RUN (cd /lib/systemd/system/sysinit.target.wants/ && \
      ls | grep -v systemd-tmpfiles-setup | xargs rm -f) && \
    rm -f /lib/systemd/system/multi-user.target.wants/* && \
    rm -f /etc/systemd/system/*.wants/* && \
    rm -f /lib/systemd/system/local-fs.target.wants/* && \
    rm -f /lib/systemd/system/sockets.target.wants/*udev* && \
    rm -f /lib/systemd/system/sockets.target.wants/*initctl* && \
    rm -f /lib/systemd/system/basic.target.wants/* && \
    rm -f /lib/systemd/system/anaconda.target.wants/* && \
    # Keep logind, dbus, and journal
    systemctl set-default multi-user.target

# Enable logind, dbus, and SSH (required for loginctl + PAM session registration)
RUN systemctl enable systemd-logind && \
    systemctl enable dbus && \
    systemctl enable ssh

# ---------------------------------------------------------------------------
# Session directory structure & scripts (must be before useradd for shell path)
# ---------------------------------------------------------------------------
RUN mkdir -p /data/sessions/pending /data/scripts && \
    chmod 777 /data/sessions /data/sessions/pending

COPY backend/scripts/session_shell.sh /data/scripts/session_shell.sh
COPY backend/scripts/session_login.sh /data/scripts/session_login.sh
RUN chmod 755 /data/scripts/session_shell.sh /data/scripts/session_login.sh

# Create the session user account — ttyd users log in as this user
# Shell is set to the session recording script so PAM login → logind + audit
RUN useradd -m -s /data/scripts/session_shell.sh -G systemd-journal sessionuser && \
    echo "sessionuser:sessionpass" | chpasswd

# ---------------------------------------------------------------------------
# SSH server configuration
# ---------------------------------------------------------------------------
RUN mkdir -p /run/sshd && \
    # PAM is enabled by default on Debian; ensure pam_systemd is in the stack
    # so SSH sessions get registered with logind
    grep -q 'pam_systemd' /etc/pam.d/sshd || \
      echo 'session optional pam_systemd.so' >> /etc/pam.d/sshd && \
    # SSH config: allow password auth, set the session shell
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    # Ensure SSH uses PAM
    sed -i 's/UsePAM no/UsePAM yes/' /etc/ssh/sshd_config && \
    grep -q 'UsePAM yes' /etc/ssh/sshd_config || echo 'UsePAM yes' >> /etc/ssh/sshd_config && \
    # Generate host keys
    ssh-keygen -A

# ---------------------------------------------------------------------------
# tangle_gate_agent installation
# ---------------------------------------------------------------------------
RUN groupadd --system agent && useradd --system --gid agent agent && \
    mkdir -p /opt/tangle_gate_agent

COPY --from=agent-build /app/_build/prod/rel/tangle_gate_agent /opt/tangle_gate_agent/
RUN chown -R agent:agent /opt/tangle_gate_agent

# Install agent systemd service
COPY backend/systemd/tangle_gate_agent.service /etc/systemd/system/tangle_gate_agent.service
RUN systemctl enable tangle_gate_agent

# ---------------------------------------------------------------------------
# ttyd systemd service — wraps SSH login for web terminal access
# ---------------------------------------------------------------------------
COPY backend/systemd/ttyd.service /etc/systemd/system/ttyd.service
RUN systemctl enable ttyd

# ---------------------------------------------------------------------------
# Polkit rule: allow agent user to terminate sessions and manage scopes
# ---------------------------------------------------------------------------
COPY backend/polkit/50-agent-terminate.rules /etc/polkit-1/rules.d/50-agent-terminate.rules
RUN chown polkitd:root /etc/polkit-1/rules.d/50-agent-terminate.rules && \
    chmod 644 /etc/polkit-1/rules.d/50-agent-terminate.rules

# ---------------------------------------------------------------------------
# Environment file template for the agent service
# ---------------------------------------------------------------------------
COPY backend/systemd/tangle_gate_agent.env /etc/tangle_gate_agent/env

# ---------------------------------------------------------------------------
# Entrypoint configuration script
# ---------------------------------------------------------------------------
COPY backend/scripts/configure.sh /usr/local/bin/configure.sh
COPY backend/scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/configure.sh /usr/local/bin/entrypoint.sh

# Install the configure script as a oneshot service that runs before agent/ttyd
COPY backend/systemd/backend-configure.service /etc/systemd/system/backend-configure.service
RUN systemctl enable backend-configure

EXPOSE 7681 8800

# Use entrypoint that captures Docker env vars, then execs systemd as PID 1
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/local/bin/entrypoint.sh"]
