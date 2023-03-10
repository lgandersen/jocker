defmodule Kleened.Core.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  require Logger

  use Application

  def start_link() do
    start(nil, nil)
  end

  def start(_type, _args) do
    # FIXME: This is a dirty-hack to fetch "api_listener_options" before supervisor is started, as it is used to configure ranch supervisor.
    {:ok, pid} = Kleened.Core.Config.start_link([])
    cowboy_options = Kleened.Core.Config.get("api_listener_options")
    GenServer.stop(pid)

    children = [
      Kleened.Core.Config,
      Kleened.Core.MetaData,
      Kleened.Core.Layer,
      Kleened.Core.Network,
      {Registry, keys: :unique, name: Kleened.Core.ExecInstances},
      {DynamicSupervisor, name: Kleened.Core.ExecPool, strategy: :one_for_one, max_restarts: 0},
      {Plug.Cowboy,
       scheme: :http,
       plug: HTTP.API,
       options: [{:dispatch, Kleened.API.Router.dispatch()} | cowboy_options]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kleened.Core.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error,
       {:shutdown,
        {:failed_to_start_child, Kleened.Core.Config, {%RuntimeError{message: msg}, _}}}} ->
        {:error, "could not start kleened: #{msg}"}

      unknown_return ->
        {:error, "could not start kleened: #{inspect(unknown_return)}"}
    end
  end
end
