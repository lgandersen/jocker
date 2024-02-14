import Config

config :logger, :console,
  format: "$time [$level] $metadata:$message\n",
  metadata: [:pid, :file]

config :kleened, env: Mix.env()
