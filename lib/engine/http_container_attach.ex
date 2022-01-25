defmodule Jocker.Engine.HTTPContainerAttach do
  alias Jocker.Engine.Container
  require Logger

  # Called on connection initialization
  def init(req, _opts) do
    state = %{request: req}
    {:cowboy_websocket, req, state, %{idle_timeout: 60000}}
  end

  # Called on websocket connection initialization.
  def websocket_init(%{request: %{bindings: %{container_id: container_id}}} = state) do
    case Container.attach(container_id) do
      :ok ->
        Logger.debug("succesfully attached to container #{container_id}")
        {[{:text, "ok:"}], state}

      {:error, :not_found} ->
        Logger.debug("could not attach to container #{container_id}: not found")
        {[{:text, "exit:container not found"}, {:close, 1000, ""}], state}
    end
  end

  def websocket_handle({:text, "ping"}, state) do
    # ping messages should be handled by cowboy
    {:ok, state}
  end

  def websocket_handle({:text, _message}, state) do
    # Ignore messages from the client (i.e. no interactive possibility atm.
    Logger.debug("Received input from client. Cannot handle this yet.")
    {:ok, state}
  end

  def websocket_handle(msg, state) do
    # Ignore messages from the client (i.e. no interactive possibility atm.
    Logger.warn("Unknown message received: #{inspect(msg)}")
    {:ok, state}
  end

  def websocket_info({:container, container_id, {:shutdown, :jail_stopped}}, state) do
    {[{:close, 1000, "exit:container #{container_id} stopped"}], state}
  end

  def websocket_info({:container, container_id, {:shutdown, :jail_root_process_exited}}, state) do
    {[{:close, 1001, "exit:container #{container_id}'s root process exited"}], state}
  end

  def websocket_info({:container, _container_id, {:jail_output, msg}}, state) do
    {[{:text, "io:" <> msg}], state}
  end

  def websocket_info(message, state) do
    Logger.warn("unknown message received: #{inspect(message)}")
    {:ok, state}
  end

  # No matter why we terminate, remove all of this pids subscriptions
  def websocket_terminate(reason, _state) do
    Logger.info("websocket terminated: #{inspect(reason)}")
    :ok
  end
end
