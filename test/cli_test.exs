defmodule CLITest do
  use ExUnit.Case
  alias Jocker.Engine.Container
  alias Jocker.Engine.Image
  alias Jocker.Engine.MetaData
  alias Jocker.Engine.Volume
  alias Jocker.Engine.Config
  import Jocker.Engine.Records
  require Logger

  @moduletag :capture_log

  setup_all do
    Application.stop(:jocker)
    start_supervised(Config)
    remove_volume_mounts()
    TestUtils.clear_zroot()
    Jocker.Engine.Volume.create_volume_dataset()
    start_supervised(MetaData)
    start_supervised(Jocker.Engine.Layer)
    start_supervised(Jocker.Engine.Network)

    start_supervised(
      {DynamicSupervisor,
       name: Jocker.Engine.ContainerPool, strategy: :one_for_one, max_restarts: 0}
    )

    start_supervised(Jocker.Engine.APIServer)
    :ok
  end

  setup do
    register_as_cli_master()
    MetaData.clear_tables()
    :ok
  end

  test "escript main help" do
    {:ok, path} = File.cwd()
    {output, 0} = System.cmd("#{path}/jocker", [])
    assert "\nUsage:\tjocker [OPTIONS] COMMAND" == String.slice(output, 0, 32)
  end

  test "jocker <no arguments or options>" do
    spawn_link(Jocker.CLI.Main, :main_, [[]])
    [msg] = collect_output([])
    stop_client()
    assert "\nUsage:\tjocker [OPTIONS] COMMAND" == String.slice(msg, 0, 32)
  end

  test "api_server MetaData.list_images()" do
    {:ok, _pid} = Jocker.CLI.EngineClient.start_link([])
    rpc = [MetaData, :list_images, []]
    :ok = Jocker.CLI.EngineClient.command(rpc)
    assert_receive {:server_reply, []}
  end

  test "splitting up of data sent over the API-socket into several messages" do
    Enum.map(
      1..10,
      fn n -> Jocker.Engine.Container.create(name: "testcontainer#{n}", cmd: "bin/ls") end
    )

    {:ok, _pid} = Jocker.CLI.EngineClient.start_link([])
    rpc = [MetaData, :list_containers, [[all: true]]]
    :ok = Jocker.CLI.EngineClient.command(rpc)
    assert_receive {:server_reply, _containers}, 1_000
  end

  test "jocker image ls <irrelevant argument>" do
    [msg1, _] = jocker_cmd("image ls irrelevant_argument")
    assert "\"jocker image ls\" requires no arguments." == msg1
  end

  test "jocker image ls" do
    img_id1 = "test-img-id1"
    img_id2 = "test-img-id2"

    img1 =
      image(
        id: img_id1,
        name: "test-image",
        tag: "latest",
        command: "/bin/ls",
        created: epoch(1)
      )

    img2 = image(img1, created: epoch(2), id: img_id2, name: "lol")

    header = "NAME           TAG          IMAGE ID       CREATED           \n"
    row1 = "test-image     latest       #{img_id1}   51 years          \n"
    row2 = "lol            latest       #{img_id2}   51 years          \n"

    # Test list one
    MetaData.add_image(img1)
    listing = jocker_cmd("image ls")
    assert [header, row1] == listing

    # Test list two
    MetaData.add_image(img2)

    assert [header, row2, row1] == jocker_cmd("image ls")
  end

  test "build and remove an image with a tag" do
    path = "./test/data/test_cli_build_image"

    [msg] = jocker_cmd("image build #{path}")
    id = String.slice(msg, 34, 12)
    assert image(name: "<none>", tag: "<none>") = MetaData.get_image(id)
    assert ["#{id}\n"] == jocker_cmd("image rm #{id}")
    assert :not_found == MetaData.get_image(id)
  end

  test "build and remove a tagged image" do
    path = "./test/data/test_cli_build_image"

    [msg] = jocker_cmd("image build -t lol:test #{path}")
    id = String.slice(msg, 34, 12)
    assert image(name: "lol", tag: "test") = MetaData.get_image(id)
    assert ["#{id}\n"] == jocker_cmd("image rm #{id}")
    assert :not_found == MetaData.get_image(id)
  end

  test "jocker container ls" do
    MetaData.add_image(image(id: "img_id", name: "", tag: "latest", created: epoch(1)))
    MetaData.add_image(image(id: "lel", name: "img_name", tag: "latest", created: epoch(2)))

    MetaData.add_container(
      container(
        id: "1337",
        image_id: "img_id",
        name: "test1",
        command: ["some_command"],
        created: epoch(10)
      )
    )

    MetaData.add_container(
      container(
        id: "1338",
        running: true,
        image_id: "lel",
        name: "test2",
        command: ["some_command"],
        created: epoch(11)
      )
    )

    MetaData.add_container(
      container(
        id: "1339",
        image_id: "base",
        name: "test3",
        command: ["some_command"],
        created: epoch(12)
      )
    )

    header =
      "CONTAINER ID   IMAGE                       COMMAND                   CREATED              STATUS    NAME\n"

    row_no_image_name =
      "1337           img_id                      some_command              51 years             stopped   test1\n"

    row_running =
      "1338           img_name:latest             some_command              51 years             running   test2\n"

    row_base =
      "1339           base                        some_command              51 years             stopped   test3\n"

    assert [header, row_running] == jocker_cmd(["container", "ls"])
    assert [header, row_base, row_running, row_no_image_name] == jocker_cmd("container ls -a")
  end

  test "create and remove a container" do
    [id_n] = jocker_cmd("container create base")
    id = String.trim(id_n)
    assert container(id: ^id, layer_id: layer_id) = MetaData.get_container(id)
    layer(mountpoint: mountpoint) = MetaData.get_layer(layer_id)
    assert is_directory?(mountpoint)
    [^id_n] = jocker_cmd("container rm #{id}")
    assert not is_directory?(mountpoint)
  end

  test "create a container with devfs disabled" do
    [id_n] = jocker_cmd("container create --no-mount.devfs base /bin/sleep 100")
    id = String.trim(id_n)
    cont = MetaData.get_container(id)
    assert [id_n] == jocker_cmd("container start #{id}")
    assert not TestUtils.devfs_mounted(cont)
    assert [id_n] == jocker_cmd("container stop #{id}")
  end

  test "create a container with a custom command" do
    [id_n] = jocker_cmd("container create base /bin/mkdir /loltest")
    id = String.trim(id_n)
    assert container(id: ^id, layer_id: layer_id, pid: pid) = cont = MetaData.get_container(id)

    # We '--attach' to make sure the jail is done

    [] = jocker_cmd("container start --attach #{id}")
    layer(mountpoint: mountpoint) = MetaData.get_layer(layer_id)
    assert not TestUtils.devfs_mounted(cont)
    assert is_directory?(mountpoint)
    assert is_directory?(Path.join(mountpoint, "loltest"))
    [^id_n] = jocker_cmd("container rm #{id}")
    assert not is_directory?(mountpoint)
  end

  test "jocker adding and removing a container with writable volumes" do
    instructions = [
      from: "base",
      run: ["/bin/sh", "-c", "mkdir /testdir1"],
      run: ["/bin/sh", "-c", "mkdir /testdir2"],
      run: ["/usr/bin/touch", "/loltest"]
    ]

    {:ok, image(id: image_id)} = Image.create_image(instructions)
    volume(name: vol_name, mountpoint: mountpoint_vol) = vol1 = Volume.create_volume("testvol-1")
    assert is_directory?(mountpoint_vol)
    assert touch(Path.join(mountpoint_vol, "testfile"))

    [id_n] =
      jocker_cmd(
        "container create --volume testvol-1:/testdir1 -v /testdir2 #{image_id} /usr/bin/touch /testdir2/testfile2"
      )

    id = String.trim(id_n)
    [] = jocker_cmd("container start --attach #{id}")

    container(layer_id: layer_id) = MetaData.get_container(id)
    layer(mountpoint: mountpoint) = MetaData.get_layer(layer_id)
    assert is_file?(Path.join(mountpoint, "testdir1/testfile"))
    assert is_file?(Path.join(mountpoint, "/loltest"))
    assert is_file?(Path.join(mountpoint, "/testdir2/testfile2"))

    [vol2] =
      Enum.reject(MetaData.list_volumes([]), fn
        volume(name: ^vol_name) -> true
        _ -> false
      end)

    Container.destroy(id)
    Volume.destroy_volume(vol1)
    Volume.destroy_volume(vol2)
    assert not is_directory?(mountpoint)
  end

  test "jocker adding and removing a container with read-only volumes" do
    instructions = [
      from: "base",
      run: ["/bin/sh", "-c", "mkdir /testdir1"],
      run: ["/bin/sh", "-c", "mkdir /testdir2"]
    ]

    {:ok, image(id: image_id)} = Image.create_image(instructions)
    volume(name: vol_name, mountpoint: mountpoint_vol) = vol1 = Volume.create_volume("testvol-1")
    assert is_directory?(mountpoint_vol)
    assert touch(Path.join(mountpoint_vol, "testfile_writable_from_mountpoint_vol"))

    [id_n] =
      jocker_cmd(
        "container create --volume testvol-1:/testdir1:ro -v /testdir2:ro #{image_id} /usr/bin/touch /testdir2/testfile2"
      )

    id = String.trim(id_n)

    jocker_cmd("container start --attach #{id}")

    container(layer_id: layer_id) = MetaData.get_container(id)
    layer(mountpoint: mountpoint) = MetaData.get_layer(layer_id)

    assert is_file?(Path.join(mountpoint, "testdir1/testfile_writable_from_mountpoint_vol"))
    assert not is_file?(Path.join(mountpoint, "/testdir2/testfile2"))
    assert not touch(Path.join(mountpoint, "/testdir2/testfile2"))
    assert not touch(Path.join(mountpoint, "/testdir1/testfile1"))

    [vol2] =
      Enum.reject(MetaData.list_volumes([]), fn
        volume(name: ^vol_name) -> true
        _ -> false
      end)

    Container.destroy(id)
    Volume.destroy_volume(vol1)
    Volume.destroy_volume(vol2)
    assert not is_directory?(mountpoint)
  end

  test "starting a long-running container and stopping it" do
    [id_n] = jocker_cmd("container create base /bin/sleep 10000")
    id = String.trim(id_n)
    container(name: name) = cont = MetaData.get_container(id)
    MetaData.add_container(container(cont, created: epoch(1)))

    header =
      "CONTAINER ID   IMAGE                       COMMAND                   CREATED              STATUS    NAME\n"

    row =
      "#{id}   base                        /bin/sleep 10000          51 years             stopped   #{
        name
      }\n"

    row_running =
      "#{id}   base                        /bin/sleep 10000          51 years             running   #{
        name
      }\n"

    output = jocker_cmd("container ls --all")
    assert output == [header, row]
    assert [header] == jocker_cmd("container ls")
    assert ["#{id}\n"] == jocker_cmd("container start #{id}")
    assert [header, row_running] == jocker_cmd("container ls --all")
    assert [id_n] == jocker_cmd("container stop #{id}")
    assert [header, row] == jocker_cmd("container ls --all")
  end

  test "start and attach to a container that produces some output" do
    [id_n] = jocker_cmd("container create base echo lol")
    id = String.trim(id_n)
    assert ["lol\n"] == jocker_cmd("container start -a #{id}")
  end

  test "jocker volume create" do
    assert ["testvol\n"] == jocker_cmd("volume create testvol")
    # Check for idempotency:
    assert ["testvol\n"] == jocker_cmd("volume create testvol")

    volume(name: "testvol", dataset: dataset, mountpoint: mountpoint) =
      MetaData.get_volume("testvol")

    assert {:ok, %File.Stat{:type => :directory}} = File.stat(mountpoint)
    assert {"#{dataset}\n", 0} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
  end

  test "jocker volume rm" do
    [vol1_n] = jocker_cmd("volume create test1")
    [vol2_n] = jocker_cmd("volume create test2")
    [_vol3_n] = jocker_cmd("volume create test3")
    mock_volume_creation_time()
    header = "VOLUME NAME      CREATED           \n"

    assert jocker_cmd("volume rm test1") == [vol1_n]

    assert jocker_cmd("volume ls") == [
             header,
             "test3            51 years          \n",
             "test2            51 years          \n"
           ]

    assert jocker_cmd("volume rm test2 test5 test3") ==
             [vol2_n, "Error: No such volume: test5\n", "test3\n"]

    assert jocker_cmd("volume ls") == [header]
  end

  test "jocker volume ls" do
    assert jocker_cmd(["volume", "ls"]) == ["VOLUME NAME      CREATED           \n"]
    jocker_cmd("volume create test1")
    jocker_cmd("volume create test2")
    mock_volume_creation_time()
    output = jocker_cmd(["volume", "ls"])

    assert output == [
             "VOLUME NAME      CREATED           \n",
             "test2            51 years          \n",
             "test1            51 years          \n"
           ]

    assert ["test2\n", "test1\n"] == jocker_cmd(["volume", "ls", "--quiet"])
    assert ["test2\n", "test1\n"] == jocker_cmd(["volume", "ls", "-q"])
  end

  defp jocker_cmd(command) when is_binary(command) do
    jocker_cmd(String.split(command))
  end

  defp jocker_cmd(command) do
    Logger.info("Executing cli-command 'jocker #{Enum.join(command, " ")}'")
    spawn_link(Jocker.CLI.Main, :main_, [["--debug" | command]])
    output = collect_output([])
    stop_client()
    output
  end

  defp stop_client() do
    if is_client_alive?() do
      GenServer.stop(Jocker.CLI.EngineClient)
    end
  end

  defp is_client_alive?() do
    case Enum.find(Process.registered(), fn x -> x == Jocker.CLI.EngineClient end) do
      Jocker.CLI.EngineClient -> true
      nil -> false
    end
  end

  defp remove_volume_mounts() do
    case System.cmd("/bin/sh", ["-c", "mount | grep nullfs"]) do
      {output, 0} ->
        mounts = String.split(output, "\n")
        Enum.map(mounts, &remove_mount/1)

      _ ->
        :ok
    end
  end

  defp remove_mount(mount) do
    case mount |> String.replace(" on ", " ") |> String.split() do
      [src, dst | _] ->
        case String.starts_with?(src, "/" <> Config.get(:volume_root)) do
          true ->
            # Logger.warn("Removing nullfs-mount #{dst}")
            System.cmd("/sbin/umount", [dst])

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp epoch(n) do
    DateTime.to_iso8601(DateTime.from_unix!(n))
  end

  def mock_volume_creation_time() do
    volumes = MetaData.list_volumes()
    Enum.map(volumes, fn vol -> MetaData.add_volume(volume(vol, created: epoch(1))) end)
  end

  defp register_as_cli_master() do
    # Sometimes the last test did not release the ':cli_master' atom before the next
    # hence this function.
    case Process.whereis(:cli_master) do
      nil -> Process.register(self(), :cli_master)
      _ -> register_as_cli_master()
    end
  end

  defp touch(path) do
    case System.cmd("/usr/bin/touch", [path], stderr_to_stdout: true) do
      {"", 0} -> true
      _ -> false
    end
  end

  defp is_directory?(filepath) do
    case File.stat(filepath) do
      {:ok, %File.Stat{type: :directory}} -> true
      _notthecase -> false
    end
  end

  defp is_file?(filepath) do
    case File.stat(filepath) do
      {:ok, %File.Stat{type: :regular}} -> true
      _notthecase -> false
    end
  end

  defp collect_output(output) do
    receive do
      {:msg, :eof} ->
        Enum.reverse(output)

      {:msg, msg} ->
        collect_output([msg | output])

      other ->
        Logger.warn(
          "Unexpected message received while waiting for cli-messages: #{inspect(other)}"
        )

        exit(:shutdown)
    end
  end
end
