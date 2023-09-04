defmodule Kleened.API.Schemas do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule ContainerConfig do
    OpenApiSpex.schema(%{
      summary:
        "Configuration for a container. Some of the configuration parameters will overwrite the corresponding parameters in the specified image.",
      type: :object,
      properties: %{
        image: %Schema{
          type: :string,
          description: "The name or id of the image used for creating the container",
          example: "FreeBSD-13.0"
        },
        cmd: %Schema{
          description:
            "Command to execute when the container is started. If no command is specified the command from the image is used.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["/bin/sh", "-c", "ls /"]
        },
        user: %Schema{
          type: :string,
          description:
            "User that executes the command (cmd). If no user is set the user from the image will be used (which in turn is 'root' if no user is specified there).",
          default: ""
        },
        env: %Schema{
          description:
            "List of environment variables when using the container. This list will be merged with environment variables defined by the image. The values in this list takes precedence if the variable is defined in both.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
        },
        volumes: %Schema{
          description: "List of volumes that should be mounted into the container",
          type: :array,
          items: %Schema{type: :string},
          default: []
        },
        jail_param: %Schema{
          description: "List of `jail(8)` parameters to use for the container.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["allow.raw_sockets=true", "osrelease=kleenejail"]
        }
      }
    })
  end

  defmodule ExecConfig do
    OpenApiSpex.schema(%{
      description:
        "Configuration of an executable to run within a container. Some of the configuration parameters will overwrite the corresponding parameters if they are defined in the container.",
      type: :object,
      properties: %{
        container_id: %Schema{
          type: :string,
          description: "Id of the container used for creating the exec instance."
        },
        cmd: %Schema{
          description:
            "Command to execute whithin the container. If no command is specified the command from the container is used.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["/bin/sh", "-c", "ls /"]
        },
        user: %Schema{
          type: :string,
          description:
            "User that executes the command in the container. If no user is set the user from the container will be used.",
          default: ""
        },
        env: %Schema{
          description: """
          A list of environment variables in the form `["VAR=value", ...]` that is set when the command is executed.
          This list will be merged with environment variables defined by the container.
          The values in this list takes precedence if the variable is defined in both places.",
          """,
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
        },
        tty: %Schema{description: "Allocate a pseudo-TTY", type: :boolean, default: false}
      }
    })
  end

  defmodule ExecStartConfig do
    OpenApiSpex.schema(%{
      description: "Options for starting an execution instance.",
      type: :object,
      properties: %{
        exec_id: %Schema{
          type: :string,
          description: "id of the execution instance to start"
        },
        attach: %Schema{
          description: "Whether to receive output from `stdin` and `stderr`.",
          type: :boolean
        },
        start_container: %Schema{
          type: :boolean,
          description: "Whether to start the container if it is not running."
        }
      },
      required: [:exec_id, :attach, :start_container]
    })
  end

  defmodule EndPointConfig do
    OpenApiSpex.schema(%{
      description: "Configuration of a connection between a network to a container.",
      type: :object,
      properties: %{
        container: %Schema{
          type: :string,
          description: "Name or (possibly truncated) id of the container"
        },
        ip_address: %Schema{
          type: :string,
          description:
            "The ip(v4) address that should be assigned to the container. If this field is not set (or null) an unused ip contained in the subnet is auto-generated.",
          default: nil,
          example: "10.13.37.33"
        }
      },
      required: [:container]
    })
  end

  defmodule NetworkConfig do
    OpenApiSpex.schema(%{
      description: "Network configuration",
      type: :object,
      properties: %{
        name: %Schema{
          type: :string,
          description: "Name of the network.",
          example: "westnet"
        },
        subnet: %Schema{
          type: :string,
          description: "The subnet (in CIDR-format) that is used for the network.",
          example: "10.13.37.0/24"
        },
        ifname: %Schema{
          type: :string,
          description:
            "Name of the loopback interface that is being used for the network. Only used with the 'loopback' driver.",
          example: "kleene0"
        },
        driver: %Schema{
          type: :string,
          description: """
          Which driver to use for the network. Possible values are 'vnet', 'loopback', and 'host'.
          See jails(8) and the networking documentation for details.
          """,
          example: "vnet"
        }
      },
      required: [:name, :subnet, :driver]
    })
  end

  defmodule ImageBuildConfig do
    OpenApiSpex.schema(%{
      description: "make a description of the websocket endpoint here.",
      type: :object,
      properties: %{
        context: %Schema{type: :string, description: "description here"},
        dockerfile: %Schema{type: :string, description: "description here", default: "Dockerfile"},
        quiet: %Schema{type: :boolean, description: "description here", default: false},
        cleanup: %Schema{type: :boolean, description: "description here", default: true},
        tag: %Schema{type: :string, description: "description here", default: ""},
        buildargs: %Schema{
          description:
            "Object of string pairs for build-time variables. Users pass these values at build-time. Kleened uses the buildargs as the environment context for commands run via the Dockerfile RUN instruction, or for variable expansion in other Dockerfile instructions. This is not meant for passing secret values.",
          type: :object,
          default: %{},
          example: %{"USERNAME" => "Stephen", "JAIL_MGMT_ENGINE" => "kleene"}
        }
      },
      required: [:context]
    })
  end

  defmodule ImageCreateConfig do
    OpenApiSpex.schema(%{
      description: "Configuration for the creation of base images.",
      type: :object,
      required: [:method],
      properties: %{
        tag: %Schema{
          description: "Name and optionally a tag in the 'name:tag' format",
          type: :string,
          default: ""
        },
        method: %Schema{
          description:
            "Method used for creating a new base image: If 'fetch' is selected, kleened will fetch a release/snapshot of the base system and use it for image creation. When 'zfs' is used, a copy of the supplied zfs dataset is used for the image.",
          type: :string,
          enum: ["fetch", "zfs"]
        },
        zfs_dataset: %Schema{
          description:
            "Dataset path on the host used for the image (required for method 'zfs' only).",
          type: :string,
          default: ""
        },
        url: %Schema{
          description:
            "URL to a remote location where the base system (as a base.txz file) is stored. If an empty string is supplied kleened will try to fetch a version of the base sytem from download.freebsd.org using information from uname(1) (required for method 'fetch').",
          type: :string,
          default: ""
        },
        force: %Schema{
          description:
            "Ignore any discrepancies detected when using uname(1) to fetch the base system (method 'fetch' only).",
          type: :boolean,
          default: false
        }
      }
    })
  end

  defmodule Image do
    OpenApiSpex.schema(%{
      description: "the image metadata",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of the image", type: :string},
        name: %Schema{description: "Name of the image", type: :string},
        tag: %Schema{description: "Tag of the image", type: :string},
        command: %Schema{
          description: "Default command used when creating a container from this image",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["/bin/sh", "-c", "/bin/ls"]
        },
        env: %Schema{
          description: "Environment variables and their values to set before running command.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["PWD=/roo/", "JAIL_MGMT_ENGINE=kleene"]
        },
        buildargs: %Schema{
          description:
            "Object of string pairs for build-time variables. Users pass these values at build-time. Kleened uses the buildargs as the environment context for commands run via the Dockerfile RUN instruction, or for variable expansion in other Dockerfile instructions. This is not meant for passing secret values.",
          type: :object,
          default: %{},
          example: %{"USERNAME" => "Stephen", "JAIL_MGMT_ENGINE" => "kleene"}
        },
        layer_id: %Schema{description: "Id of the layer containing the image", type: :string},
        user: %Schema{description: "user used when executing the command", type: :string},
        created: %Schema{description: "When the image was created", type: :string}
      }
    })
  end

  defmodule ImageList do
    OpenApiSpex.schema(%{
      description: "List of images.",
      type: :array,
      items: Kleened.API.Schemas.Image
    })
  end

  defmodule Network do
    OpenApiSpex.schema(%{
      description: "summary description of a network",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of the network", type: :string},
        name: %Schema{description: "Name of the network", type: :string},
        subnet: %Schema{description: "Subnet used for the network", type: :string},
        driver: %Schema{
          description: "Type of network.",
          type: :string
        },
        loopback_if: %Schema{
          description: "Name of the loopback interface (used for a 'loopback' network).",
          type: :string,
          default: ""
        },
        bridge_if: %Schema{
          description: "Name of the bridge interface (used for a 'vnet' network).",
          type: :string,
          default: ""
        }
      }
    })
  end

  defmodule NetworkList do
    OpenApiSpex.schema(%{
      description: "List of networks.",
      type: :array,
      items: Kleened.API.Schemas.Network
    })
  end

  defmodule Volume do
    OpenApiSpex.schema(%{
      description: "Volume object used for persistent storage in containers.",
      type: :object,
      properties: %{
        name: %Schema{description: "Name of the volume", type: :string},
        dataset: %Schema{description: "underlying zfs dataset of the volume", type: :string},
        mountpoint: %Schema{
          description:
            "mountpoint of the volume's underlying zfs-dataset (the mountpoint shown with 'zfs list')",
          type: :string
        },
        created: %Schema{description: "when the volume was created", type: :string}
      }
    })
  end

  defmodule VolumeConfig do
    OpenApiSpex.schema(%{
      description: "Volume configuration",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Name of the volume."}
      },
      required: [:name]
    })
  end

  defmodule VolumeList do
    OpenApiSpex.schema(%{
      description: "List of volumes.",
      type: :array,
      items: Kleened.API.Schemas.Volume
    })
  end

  defmodule Container do
    OpenApiSpex.schema(%{
      description: "summary description of a container",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of the container", type: :string},
        name: %Schema{description: "Name of the container.", type: :string},
        image_id: %Schema{
          description: "The id of the image that this container was created from",
          type: :string
        },
        command: %Schema{
          description: "Command being used when starting the container",
          type: :array,
          items: :string,
          default: []
        },
        layer_id: %Schema{
          description: "The id of the layer used by the container.",
          type: :string
        },
        user: %Schema{
          description:
            "The default user used when creating execution instances in the container.",
          type: :string
        },
        env: %Schema{
          description:
            "List of environment variables used when the container is used. This list will be merged with environment variables defined by the image. The values in this list takes precedence if the variable is defined in both places.",
          type: :array,
          items: :string,
          default: [],
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
        },
        jail_param: %Schema{
          description: "List of jail parameters (see jail(8) for details)",
          type: :array,
          items: :string,
          default: [],
          example: ["allow.raw_sockets=true", "osrelease=kleenejail"]
        },
        created: %Schema{description: "When the container was created", type: :string},
        running: %Schema{description: "whether or not the container is running", type: :boolean}
      }
    })
  end

  defmodule ContainerSummary do
    OpenApiSpex.schema(%{
      description: "summary description of a container",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of this container", type: :string},
        name: %Schema{description: "Name of the container", type: :string},
        image_id: %Schema{
          description: "The id of the image that this container was created from",
          type: :string
        },
        image_name: %Schema{
          description: "Name of the image that this container was created from",
          type: :string
        },
        image_tag: %Schema{
          description: "Tag of the image that this container was created from",
          type: :string
        },
        command: %Schema{
          description: "Command being used when starting the container",
          type: :string
        },
        created: %Schema{description: "When the container was created", type: :string},
        running: %Schema{description: "whether or not the container is running", type: :boolean}
      }
    })
  end

  defmodule ContainerSummaryList do
    OpenApiSpex.schema(%{
      description: "List of summarised containers.",
      type: :array,
      items: Kleened.API.Schemas.ContainerSummary
    })
  end

  defmodule WebSocketMessage do
    OpenApiSpex.schema(%{
      description: "The request have been validated and the request is being processed.",
      type: :object,
      properties: %{
        msg_type: %Schema{
          description:
            "Any data that might have been created in pre-processing (e.g., a build_id).",
          type: :string
        },
        message: %Schema{
          description:
            "Any data that might have been created in pre-processing (e.g., a build_id).",
          type: :string,
          default: ""
        },
        data: %Schema{
          description:
            "Any data that might have been created in pre-processing (e.g., a build_id).",
          type: :string,
          default: ""
        }
      },
      required: [:msg_type, :message, :data]
    })
  end

  defmodule ErrorResponse do
    OpenApiSpex.schema(%{
      description: "Represents an error and (possibly) its reason.",
      type: :object,
      properties: %{
        message: %Schema{
          description: "The error message, if any.",
          type: :string,
          nullable: false
        }
      },
      example: %{
        message: "Something went wrong."
      },
      required: [:message]
    })
  end

  defmodule IdResponse do
    OpenApiSpex.schema(%{
      title: "IdResponse",
      description: "Response to an API call that returns just an Id",
      type: :object,
      properties: %{
        id: %Schema{
          description: "The id of the created/modified/destroyed object.",
          type: :string,
          nullable: false
        }
      },
      required: [:id]
    })
  end
end
