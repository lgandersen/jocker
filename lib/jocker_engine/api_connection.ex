defmodule Jocker.Engine.APIConnection do
  defmodule State do
    defstruct socket: nil,
              transport: nil,
              buffer: ""
  end

  alias :erlang, as: Erlang
  require Logger
  use GenServer

  @behaviour :ranch_protocol

  def start_link(ref, transport, _opts) do
    pid = :proc_lib.spawn_link(__MODULE__, :init, [ref, transport])
    {:ok, pid}
  end

  def init(ref, transport) do
    Logger.info("Connection established")
    {:ok, socket} = :ranch.handshake(ref)
    :ok = transport.setopts(socket, [{:active, :once}])
    :gen_server.enter_loop(__MODULE__, [], %State{socket: socket, transport: transport})
  end

  def init(init_arg) do
    {:ok, init_arg}
  end

  def handle_info({:tcp_closed, socket}, state) do
    Logger.debug("Closing connection: #{inspect(socket)}")
    state.transport.close(socket)
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, _reason}, state) do
    Logger.info("TCP-error occured with connection: #{inspect(socket)}")
    {:stop, :normal, state}
  end

  def handle_info({:tcp, socket, data}, %State{transport: transport} = state) do
    # Logger.debug("receiving data")

    case Jocker.Engine.Utils.decode_buffer(state.buffer <> data) do
      {:no_full_msg, new_buffer} ->
        :ok = transport.setopts(socket, [{:active, :once}])
        {:noreply, %State{state | :buffer => new_buffer}}

      {command, new_buffer} ->
        Logger.debug("decoded command #{inspect(command)}")
        reply = evaluate_command(command)
        transport.send(socket, Erlang.term_to_binary(reply))
        :ok = transport.setopts(socket, [{:active, :once}])
        {:noreply, %State{state | :buffer => new_buffer}}
    end
  end

  def handle_info(
        {:container, id, {:shutdown, :jail_stopped}} = container_msg,
        %State{transport: transport, socket: socket} = state
      ) do
    Logger.info("Container #{inspect(id)} is shutting down. Closing client connection")
    transport.send(socket, Erlang.term_to_binary(container_msg))
    {:noreply, state}
  end

  def handle_info(container_msg, %State{transport: transport, socket: socket} = state) do
    Logger.debug("Receiving message from container: #{inspect(container_msg)}")
    transport.send(socket, Erlang.term_to_binary(container_msg))
    {:noreply, state}
  end

  def handle_info(
        {:image_builder, _pid, {:image_finished, _img}} = imgbuild_msg,
        %State{transport: transport, socket: socket} = state
      ) do
    Logger.debug("Image builder done!")
    transport.send(socket, Erlang.term_to_binary(imgbuild_msg))
    transport.shutdown(socket, :read_write)
    {:stop, :normal, state}
  end

  def handle_info(
        {:image_builder, _pid, _msg} = imgbuild_msg,
        %State{transport: transport, socket: socket} = state
      ) do
    Logger.debug("Receiving message from image builder: #{inspect(imgbuild_msg)}")
    transport.send(socket, Erlang.term_to_binary(imgbuild_msg))
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warn("Unknown message received #{inspect(msg)}")
    {:noreply, state}
  end

  defp evaluate_command([module, function, args]) do
    :erlang.apply(module, function, args)
  end
end
