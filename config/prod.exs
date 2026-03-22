import Config

# Production-specific compile-time configuration.
# Runtime configuration goes in config/runtime.exs.

config :tangle_gate,
  port: 4000,
  start_web: true,
  login_required: true
