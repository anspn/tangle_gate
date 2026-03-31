# =============================================================================
# Dockerfile for tangle_gate
# Multi-stage build: SPA frontend → Rust NIF compilation → Elixir build → minimal runtime
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build React SPA frontend
# ---------------------------------------------------------------------------
FROM node:22-slim AS spa

WORKDIR /spa

# Copy package manifests first for layer caching
COPY web_tangle_gate/package.json web_tangle_gate/package-lock.json* ./

# Install dependencies
RUN npm ci --ignore-scripts 2>/dev/null || npm install

# Copy frontend source
COPY web_tangle_gate/ .

# Copy mix.exs so vite can read the app version
COPY mix.exs /mix.exs

# Build SPA (outputs to ../priv/static/spa/ relative to web_tangle_gate,
# but inside Docker we override to ./dist)
RUN npx vite build --outDir dist

# ---------------------------------------------------------------------------
# Stage 2: Build Elixir + Rust NIF
# ---------------------------------------------------------------------------
FROM hexpm/elixir:1.18.3-erlang-27.3.4.8-debian-bookworm-20260202 AS build

# Install build dependencies (C compiler for NIFs, Rust toolchain, git)
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
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --default-toolchain stable --profile minimal

WORKDIR /app

# Install hex + rebar (build tools)
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build environment
ENV MIX_ENV=prod

# Copy dependency manifests first for layer caching
COPY mix.exs mix.lock ./

# Fetch dependencies
RUN mix deps.get --only $MIX_ENV

# Copy config (needed for compilation and release)
COPY config/config.exs config/prod.exs config/runtime.exs config/

# Compile dependencies first (heavy Rust NIF build — cached unless deps change)
RUN mix deps.compile

# Copy application source
COPY lib lib
COPY priv priv

# Copy SPA build output from Stage 1 into priv/static/spa/
COPY --from=spa /spa/dist priv/static/spa

# Compile the application
RUN mix compile

# Build release
RUN mix release

# ---------------------------------------------------------------------------
# Stage 3: Runtime (minimal image, no build tools)
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

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app

# Create non-root user
RUN groupadd --system iota && useradd --system --gid iota iota

# Copy the release from the build stage
COPY --from=build --chown=iota:iota /app/_build/prod/rel/tangle_gate ./

# Copy entrypoint script (reads wallet-generated IOTA key from shared volume)
COPY --chown=iota:iota priv/scripts/docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x ./docker-entrypoint.sh

# Create sessions directory (shared volume mount point)
RUN mkdir -p /data/sessions/pending && chown -R iota:iota /data/sessions

USER iota

# Default port (matches config)
EXPOSE 4000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:4000/api/health || exit 1

ENV HOME=/app
CMD ["./docker-entrypoint.sh"]
