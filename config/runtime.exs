import Config

if shutdown_time = System.get_env("SEVERANCE_SHUTDOWN_TIME") do
  config :severance, shutdown_time: Time.from_iso8601!(shutdown_time)
end
