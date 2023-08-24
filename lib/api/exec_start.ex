defmodule Kleened.API.ExecStartWebSocket do
  alias OpenApiSpex.{Operation, Schema}
  alias Kleened.Core.Exec
  require Logger

  import OpenApiSpex.Operation,
    only: [parameter: 5, response: 3]

  def open_api_operation(_) do
    %Operation{
      # tags: ["users"],
      summary: "exec start",
      description: "make a description of the websocket endpoint here.",
      operationId: "ExecStartWebSocket",
      parameters: [
        parameter(
          :exec_id,
          :path,
          %Schema{type: :string},
          "id of the execution instance being started",
          required: true
        ),
        parameter(
          :attach,
          :query,
          %Schema{type: :boolean},
          "Whether to receive output from `stdin` and `stderr`.",
          required: true
        ),
        parameter(
          :start_container,
          :query,
          %Schema{type: :boolean},
          "Whether to start the container if it is not running.",
          required: true
        )
      ],
      responses: %{
        1000 => response("invalid parameters", "text/plain", nil)
      }
    }
  end

  # Called on connection initialization
  def init(req0, _opts) do
    case validate_request(req0) do
      {:ok, state} ->
        {:cowboy_websocket, req0, state, %{idle_timeout: 60000}}

      {:error, msg} ->
        req = :cowboy_req.reply(400, %{"content-type" => "text/plain"}, msg, req0)
        {:ok, req, %{}}
    end
  end

  # Called on websocket connection initialization.
  def websocket_init(
        %{exec_id: exec_id, attach: attach, start_container: start_container} = state
      ) do
    case Exec.start(exec_id, %{attach: attach, start_container: start_container}) do
      :ok ->
        case attach do
          true ->
            Logger.debug("succesfully started executable #{exec_id}. Await output.")
            {[{:text, "OK"}], state}

          false ->
            Logger.debug("succesfully started executable #{exec_id}. Closing websocket.")
            {[{:close, 1001, ""}], state}
        end

      {:error, msg} ->
        Logger.debug("could not start attached executable #{exec_id}: #{msg}")
        {[{:text, "ERROR:#{msg}"}, {:close, 1000, "Failed to execute command."}], state}
    end
  end

  def websocket_handle({:text, message}, %{exec_id: exec_id} = state) do
    Exec.send(exec_id, message)
    {:ok, state}
  end

  def websocket_handle({:ping, _}, state) do
    {:ok, state}
  end

  def websocket_handle(msg, state) do
    # Ignore unknown messages
    Logger.warn("unknown message received: #{inspect(msg)}")
    {:ok, state}
  end

  def websocket_info({:container, exec_id, {:shutdown, {:jail_stopped, exit_code}}}, state) do
    {[
       {:close, 1000,
        "executable #{exec_id} and its container exited with exit-code #{exit_code}"}
     ], state}
  end

  def websocket_info(
        {:container, exec_id, {:shutdown, {:jailed_process_exited, exit_code}}},
        state
      ) do
    {[{:close, 1001, "#{exec_id} has exited with exit-code #{exit_code}"}], state}
  end

  def websocket_info({:container, _container_id, {:jail_output, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info(message, state) do
    Logger.warn("unknown message received: #{inspect(message)}")
    {:ok, state}
  end

  def terminate(reason, _partial_req, %{exec_id: exec_id, attach: attach}) do
    Logger.debug("connection closed #{inspect(reason)}")

    case attach do
      true ->
        Logger.debug("stopping container since it is an attached websocket")
        Exec.stop(exec_id, %{force_stop: false, stop_container: false})

      false ->
        :ok
    end
  end

  def terminate(reason, _partial_req, _state) do
    Logger.debug("connection closed #{inspect(reason)}")
    :ok
  end

  defp validate_request(%{bindings: %{exec_id: exec_id}} = req0) do
    opts =
      :cowboy_req.parse_qs(req0)
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> {key, string2bool(value)} end)

    case opts do
      # Everything should be good, proceed with the websocket!
      [{"attach", attach}, {"start_container", start_container}]
      when is_boolean(attach) and is_boolean(start_container) ->
        state = %{
          request: req0,
          attach: attach,
          start_container: start_container,
          exec_id: exec_id
        }

        {:ok, state}

      _invalid_parameter_tuple ->
        msg = "invalid value/missing parameter(s)"
        {:error, msg}
    end
  end

  defp string2bool("true") do
    true
  end

  defp string2bool("false") do
    false
  end

  defp string2bool(invalid) do
    invalid
  end
end
