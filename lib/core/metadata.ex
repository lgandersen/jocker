defmodule Kleened.Core.MetaData do
  require Logger
  alias Exqlite.Basic
  alias Kleened.Core.{Config, Image, Container, Network, Volume, OS}
  alias Kleened.API.Schemas

  use Agent

  @table_network """
  CREATE TABLE IF NOT EXISTS
  networks (
    id      TEXT PRIMARY KEY,
    network TEXT
  )
  """

  @table_endpoint_configs """
  CREATE TABLE IF NOT EXISTS
  endpoint_configs (
    container_id TEXT,
    network_id   TEXT,
    config       TEXT,
    UNIQUE(container_id, network_id)
  )
  """

  @table_images """
  CREATE TABLE IF NOT EXISTS
  images (
    id    TEXT PRIMARY KEY,
    image TEXT
    )
  """

  @table_containers """
  CREATE TABLE IF NOT EXISTS
  containers (
    id        TEXT PRIMARY KEY,
    container TEXT
    )
  """

  @table_volumes """
  CREATE TABLE IF NOT EXISTS
  volumes ( name TEXT PRIMARY KEY, volume TEXT )
  """

  @table_mounts """
  CREATE TABLE IF NOT EXISTS
  mounts ( mount TEXT )
  """

  @view_api_list_containers """
  CREATE VIEW IF NOT EXISTS api_list_containers
  AS
  SELECT
    json_insert(containers.container,
      '$.id', containers.id,
      '$.image_name', json_extract(images.image, '$.name'),
      '$.image_tag', json_extract(images.image, '$.tag')
      ) AS container_ext
  FROM
    containers
  INNER JOIN images ON json_extract(containers.container, '$.image_id') = images.id;
  """

  @type db_conn() :: Sqlitex.connection()

  @spec start_link([]) :: Agent.on_start()
  def start_link([]) do
    filepath = Config.get("metadata_db")

    case Basic.open(filepath) do
      {:error, reason} ->
        Logger.error("unable to open database at #{filepath}: #{inspect(reason)}")

        raise RuntimeError, message: "failed to start kleened"

      {:ok, conn} ->
        OS.cmd(~w"/bin/chmod 600 #{filepath}")
        create_tables(conn)
        Agent.start_link(fn -> conn end, name: __MODULE__)
    end
  end

  def stop() do
    Agent.stop(__MODULE__)
  end

  @spec add_network(%Schemas.Network{}) :: :ok
  def add_network(network) do
    {id, json} = to_db(network)
    [] = sql("INSERT OR REPLACE INTO networks(id, network) VALUES (?, ?)", [id, json])
    :ok
  end

  @spec remove_network(String.t()) :: :ok
  def remove_network(network_id) do
    [] = sql("DELETE FROM networks WHERE id = ?", [network_id])
    :ok
  end

  @spec get_network(String.t()) :: %Schemas.Network{} | :not_found
  def get_network(name_or_id) do
    query = """
    SELECT id, network FROM networks WHERE substr(id, 1, ?) = ?
    UNION
    SELECT id, network FROM networks WHERE json_extract(network, '$.name') = ?
    """

    case sql(query, [String.length(name_or_id), name_or_id, name_or_id]) do
      [row] -> row
      [] -> :not_found
    end
  end

  @spec list_networks() :: [%Schemas.Network{}]
  def list_networks() do
    sql("SELECT id, network FROM networks ORDER BY json_extract(network, '$.name')")
  end

  def list_unused_networks() do
    sql("""
    SELECT
      networks.id AS network_id,
      endpoint_configs.container_id AS endpoint
    FROM networks
    LEFT JOIN endpoint_configs ON networks.id = endpoint_configs.network_id
    WHERE networks.id != 'host' AND ifnull(endpoint_configs.container_id, 'empty') = 'empty';
    """)
  end

  @spec add_endpoint(
          Container.container_id(),
          Network.network_id(),
          %Schemas.EndPoint{}
        ) :: :ok
  def add_endpoint(container_id, network_id, endpoint_config) do
    sql(
      "INSERT OR REPLACE INTO endpoint_configs(container_id, network_id, config) VALUES (?, ?, ?)",
      [container_id, network_id, to_db(endpoint_config)]
    )

    :ok
  end

  @spec get_endpoint(Container.container_id(), Network.network_id()) ::
          %Schemas.EndPoint{} | :not_found
  def get_endpoint(container_id, network_id) do
    reply =
      sql(
        "SELECT config FROM endpoint_configs WHERE container_id = ? AND network_id = ?",
        [container_id, network_id]
      )

    case reply do
      [endpoint_cfg] -> endpoint_cfg
      [] -> :not_found
    end
  end

  @spec get_endpoints_from_network(Network.network_id()) :: [%Schemas.EndPoint{}]
  def get_endpoints_from_network(network_id) do
    sql(
      "SELECT config FROM endpoint_configs WHERE network_id = ?",
      [network_id]
    )
  end

  @spec get_endpoints_from_container(Container.container_id()) :: [%Schemas.EndPoint{}]
  def get_endpoints_from_container(container_id) do
    sql(
      "SELECT config FROM endpoint_configs WHERE container_id = ?",
      [container_id]
    )
  end

  @spec remove_endpoint_config(Container.container_id(), Network.network_id()) :: :ok
  def remove_endpoint_config(container_id, network_id) do
    sql("DELETE FROM endpoint_configs WHERE container_id = ? AND network_id = ?", [
      container_id,
      network_id
    ])

    :ok
  end

  @spec connected_containers(Network.network_id()) :: [Container.container_id()]
  def connected_containers(network_id) do
    sql("SELECT container_id FROM endpoint_configs WHERE network_id = ?", [network_id])
  end

  @spec connected_networks(Container.container_id()) :: [Network.network_id()]
  def connected_networks(container_id) do
    sql(
      "SELECT id, network FROM endpoint_configs INNER JOIN networks ON networks.id = network_id WHERE container_id = ?",
      [
        container_id
      ]
    )
  end

  @spec add_image(Image.t()) :: :ok
  def add_image(image) do
    Agent.get(__MODULE__, fn db -> add_image_transaction(db, image) end)
  end

  @spec get_image(String.t()) :: %Schemas.Image{} | :not_found
  def get_image(id_or_nametag) do
    {name, tag} = Kleened.Core.Utils.decode_tagname(id_or_nametag)

    query = """
    SELECT id, image FROM images WHERE substr(id, 1, ?) = ?
    UNION
    SELECT id, image FROM images WHERE json_extract(image, '$.name') = ? AND json_extract(image, '$.tag') = ?
    """

    case sql(query, [String.length(id_or_nametag), id_or_nametag, name, tag]) do
      [] -> :not_found
      [row | _rest] -> row
    end
  end

  @spec delete_image(String.t()) :: :ok
  def delete_image(id) do
    sql("DELETE FROM images WHERE id = ?", [id])
    :ok
  end

  @spec list_images() :: [Image.t()]
  def list_images() do
    sql("SELECT id, image FROM images ORDER BY json_extract(image, '$.created') DESC")
  end

  @spec add_container(Container.t()) :: :ok
  def add_container(container) do
    {id, json} = to_db(container)
    [] = sql("INSERT OR REPLACE INTO containers(id, container) VALUES (?, ?)", [id, json])
    :ok
  end

  @spec delete_container(Container.t()) :: :ok
  def delete_container(id) do
    [] = sql("DELETE FROM containers WHERE id = ?", [id])
    :ok
  end

  @spec get_container(String.t()) :: Container.t() | :not_found
  def get_container(id_or_name) do
    query = """
    SELECT id, container FROM containers WHERE substr(id, 1, ?) = ?
    UNION
    SELECT id, container FROM containers WHERE json_extract(container, '$.name') = ?
    """

    case sql(query, [String.length(id_or_name), id_or_name, id_or_name]) do
      [] -> :not_found
      [row | _rest] -> row
    end
  end

  @spec list_containers() :: [%{}]
  def list_containers() do
    sql("SELECT id, container FROM containers ORDER BY container -> '$.created'")
  end

  @spec container_listing() :: [%{}]
  def container_listing() do
    sql("SELECT * FROM api_list_containers ORDER BY container_ext -> '$.created' DESC")
  end

  @spec add_volume(Volume.t()) :: :ok
  def add_volume(volume) do
    {name, volume} = to_db(volume)
    [] = sql("INSERT OR REPLACE INTO volumes(name, volume) VALUES (?, ?)", [name, volume])
    :ok
  end

  @spec get_volume(String.t()) :: Volume.t() | :not_found
  def get_volume(name) do
    result = sql("SELECT name, volume FROM volumes WHERE name = ?", [name])

    case result do
      [] -> :not_found
      [row] -> row
    end
  end

  @spec remove_volume(Volume.t()) :: :ok | :not_found
  def remove_volume(%{name: name}) do
    sql("DELETE FROM volumes WHERE name = ?", [name])
    :ok
  end

  @spec list_volumes() :: [Volume.t()]
  def list_volumes() do
    sql("SELECT name, volume FROM volumes ORDER BY json_extract(volume, '$.created') DESC")
  end

  @spec list_unused_volumes() :: [String.t()]
  def list_unused_volumes() do
    sql("""
    SELECT volumes.name AS volume_name
    FROM volumes
    LEFT JOIN mounts ON volumes.name = json_extract(mounts.mount, '$.source')
    WHERE ifnull(mounts.mount, 'empty') = 'empty';
    """)
  end

  @spec get_mounts_from_container(Container.container_id()) :: [%Schemas.MountPoint{}]
  def get_mounts_from_container(container_id) do
    sql("SELECT mount FROM mounts WHERE json_extract(mount,'$.container_id') = ?", [container_id])
  end

  @spec add_mount(%Schemas.MountPoint{}) :: :ok
  def add_mount(mount) do
    sql("INSERT OR REPLACE INTO mounts VALUES (?)", [to_db(mount)])
    :ok
  end

  @spec remove_mounts(Container.t() | Volume.t()) :: :ok | :not_found
  def remove_mounts(container_or_volume) do
    Agent.get(__MODULE__, fn db -> remove_mounts_transaction(db, container_or_volume) end)
  end

  @spec list_mounts(Volume.t()) :: [%Schemas.MountPoint{}]
  def list_mounts(%Schemas.Volume{name: name}) do
    sql("SELECT mount FROM mounts WHERE json_extract(mount, '$.source') = ?", [name])
  end

  @spec list_mounts_by_container(String.t()) :: [%Schemas.MountPoint{}] | :not_found
  def list_mounts_by_container(container_id) do
    sql("SELECT mount FROM mounts WHERE json_extract(mount, '$.container_id') = ?", [container_id])
  end

  @spec list_image_datasets() :: [%{}]
  def list_image_datasets() do
    sql("""
    SELECT images.id AS id,
         json_extract(images.image, '$.name') AS name,
         json_extract(images.image, '$.tag') AS tag,
         json_extract(images.image, '$.dataset') AS dataset
    FROM images;
    """)
  end

  ##########################
  ### Internal functions ###
  ##########################
  defp sql(sql, param \\ []) do
    Agent.get(__MODULE__, fn db -> execute_sql(db, sql, param) end)
  end

  defp execute_sql(conn, sql, param) do
    {:ok, _query, %Exqlite.Result{} = result, ^conn} = Basic.exec(conn, sql, param)
    from_db(result)
  end

  @spec add_image_transaction(db_conn(), Image.t()) :: [term()]
  defp add_image_transaction(db, %Schemas.Image{name: new_name, tag: new_tag} = image) do
    query = """
    SELECT id, image FROM images
      WHERE json_extract(image, '$.name') != ''
        AND json_extract(image, '$.tag') != ''
        AND json_extract(image, '$.name') = ?
        AND json_extract(image, '$.tag') = ?
    """

    case execute_sql(db, query, [new_name, new_tag]) do
      [] ->
        :ok

      [existing_image] ->
        {id, json} = to_db(%{existing_image | name: "", tag: ""})
        execute_sql(db, "INSERT OR REPLACE INTO images(id, image) VALUES (?, ?)", [id, json])
    end

    {id, json} = to_db(image)
    execute_sql(db, "INSERT OR REPLACE INTO images(id, image) VALUES (?, ?)", [id, json])
    :ok
  end

  @spec remove_mounts_transaction(
          db_conn(),
          Volume.t() | Container.t()
        ) :: :ok
  def remove_mounts_transaction(db, %Schemas.Container{id: id}) do
    sql = "SELECT mount FROM mounts WHERE json_extract(mount, '$.container_id') = ?"
    result = execute_sql(db, sql, [id])

    [] =
      execute_sql(db, "DELETE FROM mounts WHERE json_extract(mount, '$.container_id') = ?;", [id])

    result
  end

  def remove_mounts_transaction(db, %Schemas.Volume{name: name}) do
    result =
      execute_sql(db, "SELECT mount FROM mounts WHERE json_extract(mount, '$.source') = ?", [
        name
      ])

    [] = execute_sql(db, "DELETE FROM mounts WHERE json_extract(mount, '$.source') = ?;", [name])

    result
  end

  @spec to_db(
          Schemas.Image.t()
          | Schemas.Container.t()
          | %Schemas.Volume{}
          | %Schemas.MountPoint{}
        ) ::
          String.t()
  defp to_db(struct) do
    map = Map.from_struct(struct)

    case struct.__struct__ do
      Schemas.Image ->
        {id, map} = Map.pop(map, :id)
        {:ok, json} = Jason.encode(map)
        {id, json}

      Schemas.Network ->
        {id, map} = Map.pop(map, :id)
        {:ok, json} = Jason.encode(map)
        {id, json}

      Schemas.Container ->
        {id, map} = Map.pop(map, :id)
        {:ok, json} = Jason.encode(map)
        {id, json}

      Schemas.Volume ->
        {name, map} = Map.pop(map, :name)
        {:ok, json} = Jason.encode(map)
        {name, json}

      type when type == Schemas.MountPoint or type == Schemas.EndPoint ->
        {:ok, json} = Jason.encode(map)
        json
    end
  end

  @spec from_db(%Exqlite.Result{}) :: [%Schemas.Image{}]
  defp from_db(%Exqlite.Result{columns: columns, rows: rows}) do
    rows |> Enum.map(&transform_row(&1, columns))
  end

  _ = :image_name

  defp transform_row(row, columns) do
    row = Map.new(Enum.zip(columns, row))
    columns = MapSet.new(columns)

    cond do
      columns == MapSet.new(["container", "id"]) ->
        container = Map.put(from_json(row["container"]), :id, row["id"])
        container = struct(Schemas.Container, container)
        pub_ports = Enum.map(container.public_ports, &struct(Schemas.PublishedPort, &1))
        %Schemas.Container{container | public_ports: pub_ports}

      # view api_list_containers for container_listing
      columns == MapSet.new(["container_ext"]) ->
        from_json(row["container_ext"])

      columns == MapSet.new(["id", "name", "tag", "dataset"]) ->
        row
        |> Map.to_list()
        |> Enum.map(fn {key, val} -> {String.to_atom(key), val} end)
        |> Map.new()

      columns == MapSet.new(["network", "id"]) ->
        network = Map.put(from_json(row["network"]), :id, row["id"])
        struct(Schemas.Network, network)

      columns == MapSet.new(["image", "id"]) ->
        image = Map.put(from_json(row["image"]), :id, row["id"])
        struct(Schemas.Image, image)

      columns == MapSet.new(["volume", "name"]) ->
        image = Map.put(from_json(row["volume"]), :name, row["name"])
        struct(Schemas.Volume, image)

      columns == MapSet.new(["mount"]) ->
        struct(Schemas.MountPoint, from_json(row["mount"]))

      columns == MapSet.new(["config"]) ->
        struct(Schemas.EndPoint, from_json(row["config"]))

      columns == MapSet.new(["volume_name"]) ->
        row["volume_name"]

      columns == MapSet.new(["container_id"]) ->
        row["container_id"]

      columns == MapSet.new(["endpoint", "network_id"]) ->
        row["network_id"]

      true ->
        msg = "could not decode database row #{inspect(row)}"
        Logger.error(msg)
        raise RuntimeError, message: msg
    end
  end

  defp from_json(obj) do
    Jason.decode!(obj, [{:keys, :atoms}])
  end

  def pid2str(""), do: ""
  def pid2str(pid), do: List.to_string(:erlang.pid_to_list(pid))

  def str2pid(""), do: ""
  def str2pid(pidstr), do: :erlang.list_to_pid(String.to_charlist(pidstr))

  def drop_tables(db) do
    {:ok, []} = Basic.exec(db, "DROP VIEW api_list_containers")
    {:ok, []} = Basic.exec(db, "DROP TABLE images")
    {:ok, []} = Basic.exec(db, "DROP TABLE containers")
    {:ok, []} = Basic.exec(db, "DROP TABLE volumes")
    {:ok, []} = Basic.exec(db, "DROP TABLE mounts")
    {:ok, []} = Basic.exec(db, "DROP TABLE networks")
    {:ok, []} = Basic.exec(db, "DROP TABLE endpoint_configs")
  end

  def create_tables(conn) do
    {:ok, _, _, _} = Basic.exec(conn, @table_network)
    {:ok, _, _, _} = Basic.exec(conn, @table_endpoint_configs)
    {:ok, _, _, _} = Basic.exec(conn, @table_images)
    {:ok, _, _, _} = Basic.exec(conn, @table_containers)
    {:ok, _, _, _} = Basic.exec(conn, @table_volumes)
    {:ok, _, _, _} = Basic.exec(conn, @table_mounts)
    {:ok, _, _, _} = Basic.exec(conn, @view_api_list_containers)
  end
end
