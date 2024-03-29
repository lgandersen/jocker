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
    socket_configurations = Kleened.Core.Config.bootstrap()

    children = [
      Kleened.Core.Config,
      Kleened.Core.MetaData,
      Kleened.Core.Network,
      {Registry, keys: :unique, name: Kleened.Core.ExecInstances},
      {DynamicSupervisor, name: Kleened.Core.ExecPool, strategy: :one_for_one, max_restarts: 0}
      | api_socket_listeners(socket_configurations)
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

  def api_socket_listeners(listeners) do
    indexed_listeners = Enum.zip(Enum.to_list(1..length(listeners)), listeners)

    Enum.map(indexed_listeners, fn {index, {scheme, cowboy_options}} ->
      Plug.Cowboy.child_spec(
        scheme: scheme,
        plug: String.to_atom("Listener#{index}"),
        options: [{:dispatch, Kleened.API.Router.dispatch()} | cowboy_options]
      )
    end)
  end
end
