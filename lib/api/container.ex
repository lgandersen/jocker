defmodule Kleened.API.Container do
  alias OpenApiSpex.{Operation, Schema}
  alias Kleened.Core.Container
  alias Kleened.API.Schemas
  require Logger

  import OpenApiSpex.Operation,
    only: [parameter: 4, parameter: 5, request_body: 4, response: 3, response: 4]

  def container_identifier() do
    "Container identifier, i.e., the name, ID, or an initial unique segment of the ID."
  end

  defmodule List do
    use Plug.Builder

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.List"
    )

    plug(:list)

    def open_api_operation(_) do
      %Operation{
        summary: "container list",
        description: """
        Returns a list of container summaries. For detailed information about a container,
        use [Container.Inspect](#operation/Container.Inspect).
        """,
        operationId: "Container.List",
        parameters: [
          parameter(
            :all,
            :query,
            %Schema{type: :boolean},
            "Return all containers. By default, only running containers are shown."
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.ContainerSummaryList)
        }
      }
    end

    def list(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)

      opts =
        case conn.query_params do
          %{"all" => "true"} -> [all: true]
          _ -> [all: false]
        end

      container_list = Container.list(opts) |> Jason.encode!()

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, container_list)
    end
  end

  defmodule Create do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason
    )

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.Create"
    )

    plug(:create)

    def open_api_operation(_) do
      %Operation{
        summary: "container create",
        description: """
        Create a container.

        Note that it is not possible to set any of the properties in the request body to `null`.
        This is only possible when updating containers using the [Container.Update](#operation/Container.Update) endpoint.
        """,
        operationId: "Container.Create",
        requestBody:
          request_body(
            "Container configuration.",
            "application/json",
            Schemas.ContainerConfig,
            required: true
          ),
        responses: %{
          201 => response("no error", "application/json", Schemas.IdResponse),
          404 => response("no such image", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def create(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

      container_config = conn.body_params

      case Container.create(container_config) do
        {:ok, %Schemas.Container{id: id}} ->
          send_resp(conn, 201, Utils.id_response(id))

        {:error, reason} ->
          send_resp(conn, 404, Utils.error_response(reason))
      end
    end
  end

  defmodule Update do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason
    )

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.Update"
    )

    plug(:update)

    def open_api_operation(_) do
      %Operation{
        summary: "container update",
        description: """
        Re-configure a container.

        The JSON request body is identical to [Container.Create](#operation/Container.Create),
        and is being interpreted as follows:

        - The `image` property is ignored.
        - All other properties will replace the existing ones, if they are not `null`.

        Some of the changes might require a running container to be restarted.
        """,
        operationId: "Container.Update",
        parameters: [
          parameter(
            :container_id,
            :path,
            %Schema{type: :string},
            Kleened.API.Container.container_identifier(),
            required: true
          )
        ],
        requestBody:
          request_body(
            "Container configuration.",
            "application/json",
            Schemas.ContainerConfig,
            required: true
          ),
        responses: %{
          201 => response("no error", "application/json", Schemas.IdResponse),
          409 => response("error processing update", "application/json", Schemas.ErrorResponse),
          404 => response("no such container", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def update(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      container_id = conn.params.container_id
      container_config = conn.body_params

      case Container.update(container_id, container_config) do
        {:ok, %Schemas.Container{id: id}} ->
          send_resp(conn, 201, Utils.id_response(id))

        {:warning, msg} ->
          resp_msg = Utils.error_response("an error ocurred while updating the container: #{msg}")
          send_resp(conn, 409, resp_msg)

        {:error, :container_not_found} ->
          send_resp(conn, 404, Utils.error_response("no such container '#{container_id}'"))

        {:error, reason} ->
          send_resp(conn, 500, Utils.error_response(reason))
      end
    end
  end

  defmodule Remove do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.Remove"
    )

    plug(:remove)

    def open_api_operation(_) do
      %Operation{
        summary: "container remove",
        description: "Remove a container.",
        operationId: "Container.Remove",
        parameters: [
          parameter(
            :container_id,
            :path,
            %Schema{type: :string},
            Kleened.API.Container.container_identifier(),
            required: true
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.IdResponse),
          404 =>
            response("no such container", "application/json", Schemas.ErrorResponse,
              example: %{message: "No such container: df6ed453357b"}
            ),
          409 => response("container running", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def remove(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

      case Container.remove(conn.params.container_id) do
        {:ok, container_id} ->
          send_resp(conn, 200, Utils.id_response(container_id))

        {:error, :not_found} ->
          send_resp(conn, 404, Utils.error_response("no such container"))

        {:error, :is_running} ->
          send_resp(conn, 409, Utils.error_response("you cannot remove a running container"))
      end
    end
  end

  defmodule Prune do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.Prune"
    )

    plug(:prune)

    def open_api_operation(_) do
      %Operation{
        summary: "container prune",
        description: "Remove all stopped containers.",
        operationId: "Container.Prune",
        responses: %{
          200 => response("no error", "application/json", Schemas.IdListResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def prune(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      {:ok, pruned_containers} = Container.prune()
      Plug.Conn.send_resp(conn, 200, Utils.idlist_response(pruned_containers))
    end
  end

  defmodule Stop do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.Stop"
    )

    plug(:stop)

    def open_api_operation(_) do
      %Operation{
        summary: "container stop",
        description:
          "Stop a container. Alle execution instances running in the container will be shut down.",
        operationId: "Container.Stop",
        parameters: [
          parameter(
            :container_id,
            :path,
            %Schema{type: :string},
            Kleened.API.Container.container_identifier(),
            required: true
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.IdResponse),
          404 =>
            response("no such container", "application/json", Schemas.ErrorResponse,
              example: %{message: "no such container"}
            ),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def stop(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

      case Container.stop(conn.params.container_id) do
        {:ok, container} ->
          send_resp(conn, 200, Utils.id_response(container.id))

        {:error, msg} ->
          send_resp(conn, 404, Utils.error_response(msg))
      end
    end
  end

  defmodule Inspect do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.Inspect"
    )

    plug(:inspect_)

    def open_api_operation(_) do
      %Operation{
        summary: "container inspect",
        description: "Inspect a container and its endpoints.",
        operationId: "Container.Inspect",
        parameters: [
          parameter(
            :container_id,
            :path,
            %Schema{type: :string},
            "Identifier of the container",
            required: true
          )
        ],
        responses: %{
          200 => response("container retrieved", "application/json", Schemas.ContainerInspect),
          404 => response("no such container", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def inspect_(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      container_ident = conn.params.container_id

      case Container.inspect_(container_ident) do
        {:ok, container_inspect} ->
          container_inspect = Jason.encode!(container_inspect)
          send_resp(conn, 200, container_inspect)

        {:error, msg} ->
          msg_json = Utils.error_response(msg)
          send_resp(conn, 404, msg_json)
      end
    end
  end
end
