import Config

config :tangle_gate_agent,
  port: 8801,
  start_web: false

config :tangle_gate_agent, TangleGateAgent.WS.Client,
  autostart: false
