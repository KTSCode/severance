import Config

config :severance,
  shutdown_time: ~T[17:00:00],
  system_adapter: Severance.System.Real,
  overtime_notifications: true,
  shutdown_on_late_start: false

import_config "#{config_env()}.exs"
