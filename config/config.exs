import Config

config :severance,
  shutdown_time: ~T[16:30:00],
  system_adapter: Severance.System.Real,
  overtime_notifications: true

import_config "#{config_env()}.exs"
