# =============================================================================
# Dockerfile for tangle_gate_agent
# Multi-stage build: Rust NIF compilation → Elixir build → minimal runtime
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build Elixir + Rust NIF
# ---------------------------------------------------------------------------
FROM hexpm/elixir:1.18.3-erlang-27.3.4.8-debian-bookworm-20260202 AS build

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      build-essential \
      git \
      curl \
      ca-certificates \
      cmake \
      pkg-config \
      libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# Install Rust (needed for iota_nif compilation) 
# Uncomment only if you want to build the NIF from source in this Dockerfile. If you have precompiled NIFs, you can skip this step.

# ENV RUSTUP_HOME=/usr/local/rustup \
#     CARGO_HOME=/usr/local/cargo \
#     PATH=/usr/local/cargo/bin:$PATH
# RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
#       sh -s -- -y --default-toolchain stable --profile minimal

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./

RUN mix deps.get --only $MIX_ENV

COPY config/config.exs config/prod.exs config/runtime.exs config/

RUN mix deps.compile

COPY lib lib

RUN mix compile

RUN mix release

# ---------------------------------------------------------------------------
# Stage 2: Runtime (minimal image, no build tools)
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      libncurses5 \
      locales \
      ca-certificates \
      curl && \
    rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app

RUN groupadd --system agent && useradd --system --gid agent agent

COPY --from=build --chown=agent:agent /app/_build/prod/rel/tangle_gate_agent ./

USER agent

EXPOSE 8800

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:8800/api/health || exit 1

ENV HOME=/app
CMD ["bin/tangle_gate_agent", "start"]
