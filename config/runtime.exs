import Config

# SEVERANCE_SHUTDOWN_TIME is parsed in Severance.Application.resolve_config/2
# (Layer 3) which handles both HH:MM and HH:MM:SS formats gracefully.
# Do not duplicate that parsing here.
_ = Config
