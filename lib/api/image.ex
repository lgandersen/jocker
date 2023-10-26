defmodule Kleened.API.Image do
  alias OpenApiSpex.{Operation, Schema}
  alias Kleened.Core
  alias Kleened.API.Utils
  alias Kleened.API.Schemas
  require Logger

  import OpenApiSpex.Operation,
    only: [parameter: 5, response: 3]

  defmodule List do
    use Plug.Builder

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Image.List"
    )

    plug(:list)

    def open_api_operation(_) do
      %Operation{
        # tags: ["users"],
        summary: "image list",
        description:
          "Returns a list of images on the server. Note that it uses a different, smaller representation of an image than inspecting a single image.",
        operationId: "Image.List",
        responses: %{
          200 => response("no error", "application/json", Schemas.ImageList)
        }
      }
    end

    def list(conn, _opts) do
      image_list = Kleened.Core.MetaData.list_images() |> Jason.encode!()

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, image_list)
    end
  end

  defmodule Remove do
    use Plug.Builder

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Image.List"
    )

    plug(:remove)

    def open_api_operation(_) do
      %Operation{
        # tags: ["users"],
        summary: "image remove",
        description: """
        Remove an image.

        Images can't be removed if they have descendant images or are being
        used by a running container.
        """,
        operationId: "Image.Remove",
        parameters: [
          parameter(
            :image_id,
            :path,
            %Schema{type: :string},
            "ID or name of the image. An initial segment of the id can be supplied if it uniquely determines the image.",
            required: true
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.IdResponse),
          404 => response("no such image", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def remove(%Plug.Conn{path_params: %{"image_id" => image_id}} = conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

      case Core.Image.destroy(image_id) do
        :ok ->
          Plug.Conn.send_resp(conn, 200, Utils.id_response(image_id))

        :not_found ->
          msg = "Error: No such image: #{image_id}\n"
          Plug.Conn.send_resp(conn, 404, Utils.error_response(msg))
      end
    end
  end

  defmodule Inspect do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Image.Inspect"
    )

    plug(:inspect_)

    def open_api_operation(_) do
      %Operation{
        summary: "image inspect",
        description: "Inspect a image and its endpoints.",
        operationId: "Image.Inspect",
        parameters: [
          parameter(
            :image_id,
            :path,
            %Schema{type: :string},
            "Identifier of the image",
            required: true
          )
        ],
        responses: %{
          200 => response("image retrieved", "application/json", Schemas.Image),
          404 => response("no such image", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def inspect_(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      image_ident = conn.params.image_id

      case Core.Image.inspect_(image_ident) do
        {:ok, image_inspect} ->
          image_inspect = Jason.encode!(image_inspect)
          send_resp(conn, 200, image_inspect)

        {:error, msg} ->
          msg_json = Utils.error_response(msg)
          send_resp(conn, 404, msg_json)
      end
    end
  end
end
