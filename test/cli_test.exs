defmodule CLITest do
  use ExUnit.Case

  alias Jocker.Engine.{
    Container,
    Image,
    MetaData,
    Volume,
    Config,
    Utils,
    Layer
  }

  require Logger

  @moduletag :capture_log

  setup do
    register_as_cli_master()

    on_exit(fn ->
      MetaData.list_containers()
      |> Enum.map(fn %{:id => id} -> Container.destroy(id) end)
    end)

    on_exit(fn ->
      # To ensure that all containers have been destroyed (apparantly it is async)
      MetaData.list_images() |> Enum.map(fn %Image{id: id} -> Image.destroy(id) end)
    end)

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
    {:ok, _pid} = Jocker.CLI.Config.start_link([:default])
    {:ok, pid} = Jocker.CLI.EngineClient.start_link([])
    rpc = [MetaData, :list_images, []]
    :ok = Jocker.CLI.EngineClient.command(pid, rpc)
    assert_receive {:server_reply, []}
  end

  test "splitting up of data sent over the API-socket into several messages" do
    Enum.map(
      1..10,
      fn n -> Jocker.Engine.Container.create(name: "testcontainer#{n}", cmd: "bin/ls") end
    )

    {:ok, _pid} = Jocker.CLI.Config.start_link([:default])
    {:ok, pid} = Jocker.CLI.EngineClient.start_link([])
    rpc = [Container, :list, [[all: true]]]
    :ok = Jocker.CLI.EngineClient.command(pid, rpc)
    assert_receive {:server_reply, _containers}, 1_000
  end

  test "jocker image ls <irrelevant argument>" do
    [msg1, _] = cmd("image ls irrelevant_argument")
    assert "\"jocker image ls\" requires no arguments." == msg1
  end

  test "jocker image ls" do
    header = "NAME           TAG          IMAGE ID       CREATED           \n"

    # Test list one
    img_id1 = create_image_at_timestamp("test-image:latest", epoch(1))
    row1 = "test-image     latest       #{img_id1}   52 years          \n"
    assert cmd("image ls") == [header, row1]

    # Test list two
    img_id2 = create_image_at_timestamp("lol:latest", epoch(2))
    row2 = "lol            latest       #{img_id2}   52 years          \n"
    assert cmd("image ls") == [header, row2, row1]

    MetaData.delete_image(img_id1)
    MetaData.delete_image(img_id2)
  end

  test "build and remove an image with a tag" do
    path = "./test/data/test_cli_build_image"

    id = cmd("image build --quiet #{path}")
    assert %Image{name: "<none>", tag: "<none>"} = MetaData.get_image(id)
    assert cmd("image rm #{id}") == id
    assert :not_found == MetaData.get_image(id)
  end

  test "build and remove a tagged image" do
    path = "./test/data/test_cli_build_image"

    id = cmd("image build --quiet -t lol:test #{path}")
    assert %Image{name: "lol", tag: "test"} = MetaData.get_image(id)
    assert cmd("image rm #{id}") == id
    assert :not_found == MetaData.get_image(id)
  end

  test "jocker container ls" do
    img_id1_tag = "lol1:latest"
    img_id2_tag = "lol2:latest"
    img_id1 = create_image_at_timestamp(img_id1_tag, epoch(1))
    img_id2 = create_image_at_timestamp(img_id2_tag, epoch(2))

    MetaData.add_container(%Container{
      id: "1337",
      image_id: img_id1,
      name: "test1",
      command: ["some_command"],
      created: epoch(10)
    })

    MetaData.add_container(%Container{
      id: "1338",
      image_id: img_id2,
      name: "test2",
      command: ["some_command"],
      created: epoch(11)
    })

    MetaData.add_container(%Container{
      id: "1339",
      image_id: "base",
      name: "test3",
      command: ["some_command"],
      created: epoch(12)
    })

    header =
      "CONTAINER ID   IMAGE                       COMMAND                   CREATED              STATUS    NAME\n"

    row_no_image_name =
      "1337           #{img_id1_tag}                 some_command              52 years             stopped   test1\n"

    row_with_tag =
      "1338           #{img_id2_tag}                 some_command              52 years             stopped   test2\n"

    row_base =
      "1339           base                        some_command              52 years             stopped   test3\n"

    assert [header] == jocker_cmd("container ls")
    assert [header, row_base, row_with_tag, row_no_image_name] == jocker_cmd("container ls -a")

    MetaData.delete_image("img_id")
    MetaData.delete_image("lel")
    MetaData.delete_container("1337")
    MetaData.delete_container("1338")
    MetaData.delete_container("1339")
  end

  test "create and remove a container" do
    id = cmd("container create base")
    assert %Container{id: ^id, layer_id: layer_id} = MetaData.get_container(id)
    %Layer{mountpoint: mountpoint} = MetaData.get_layer(layer_id)
    assert is_directory?(mountpoint)
    assert cmd("container rm #{id}") == id
    assert not is_directory?(mountpoint)
  end

  test "create a container with a specific jail parameter" do
    id = cmd("container create --jailparam allow.raw_sockets=true base ping -c 1 localhost")
    assert [<<"PING localhost", _::binary>> | _] = jocker_cmd("container start --attach #{id}")
  end

  test "create a container with devfs disabled" do
    id = cmd("container create --no-mount.devfs base /bin/sleep 100")
    assert cmd("container start #{id}") == id
    assert not TestHelper.devfs_mounted(MetaData.get_container(id))
    assert cmd("container stop #{id}") == id
  end

  test "create a container with both ways of setting mount.devfs (testing precedence)" do
    id = cmd("container create --mount.devfs --jailparam mount.devfs=false base /bin/sleep 100")
    cont = MetaData.get_container(id)
    assert cmd("container start #{id}") == id
    assert not TestHelper.devfs_mounted(cont)
    assert cmd("container stop #{id}") == id
  end

  test "create a container with a custom command" do
    id = cmd("container create base /bin/mkdir /loltest")
    assert %Container{id: ^id, layer_id: layer_id, pid: pid} = cont = MetaData.get_container(id)

    # We '--attach' to make sure the jail is done

    assert jocker_cmd("container start --attach #{id}") == []
    %Layer{mountpoint: mountpoint} = MetaData.get_layer(layer_id)
    assert not TestHelper.devfs_mounted(cont)
    assert is_directory?(mountpoint)
    assert is_directory?(Path.join(mountpoint, "loltest"))
    assert cmd("container rm #{id}") == id
    assert not is_directory?(mountpoint)
  end

  test "create a container with custom environment variables" do
    dockerfile = """
    FROM scratch
    ENV TESTVARIABLE1="some test content"
    ENV TESTVARIABLE2=some other test content
    CMD printenv
    """

    %Image{id: image_id} = create_image(dockerfile)
    id = cmd("container create #{image_id}")

    output = cmd("container start --attach #{id}")

    assert output ==
             "PWD=/\nTESTVARIABLE1=some test content\nTESTVARIABLE2=some other test content"

    cmd("container rm #{id}")
  end

  # test "creating nginx-container" do
  #  # :timer.sleep(19000)
  #  {:ok, path} = File.cwd()

  #  {output, 0} =
  #    System.cmd("#{path}/jocker", [
  #      "image",
  #      "build",
  #      "-t",
  #      "nginx:latest",
  #      "/host/image_examples/nginx"
  #    ])

  #  ["", second_last | _] = output |> String.split("\n") |> Enum.reverse()
  #  assert String.slice(second_last, 0, 33) == "Image succesfully created with id"
  # end

  test "jocker adding and removing a container with writable volumes" do
    dockerfile = """
    FROM scratch
    RUN mkdir /testdir1
    RUN mkdir /testdir2
    RUN /usr/bin/touch /loltest
    """

    %Image{id: image_id} = create_image(dockerfile)

    %Volume{name: vol_name, mountpoint: mountpoint_vol} = vol1 = Volume.create_volume("testvol-1")
    assert is_directory?(mountpoint_vol)
    assert Utils.touch(Path.join(mountpoint_vol, "testfile"))

    id =
      cmd(
        "container create --volume testvol-1:/testdir1 -v /testdir2 #{image_id} /usr/bin/touch /testdir2/testfile2"
      )

    assert jocker_cmd("container start --attach #{id}") == []
    %Container{layer_id: layer_id} = MetaData.get_container(id)
    %Layer{mountpoint: mountpoint} = MetaData.get_layer(layer_id)
    assert is_file?(Path.join(mountpoint, "testdir1/testfile"))
    assert is_file?(Path.join(mountpoint, "/loltest"))
    assert is_file?(Path.join(mountpoint, "/testdir2/testfile2"))

    [vol2] =
      Enum.reject(MetaData.list_volumes(), fn
        %Volume{name: ^vol_name} -> true
        _ -> false
      end)

    Container.destroy(id)
    Volume.destroy_volume(vol1)
    Volume.destroy_volume(vol2)
    assert not is_directory?(mountpoint)
    System.cmd("rm", ["./tmp_dockerfile"])
  end

  test "jocker adding and removing a container with read-only volumes" do
    dockerfile = """
    FROM scratch
    RUN mkdir /testdir1
    RUN mkdir /testdir2
    """

    %Image{id: image_id} = create_image(dockerfile)
    %Volume{name: vol_name, mountpoint: mountpoint_vol} = vol1 = Volume.create_volume("testvol-1")
    assert is_directory?(mountpoint_vol)
    assert Utils.touch(Path.join(mountpoint_vol, "testfile_writable_from_mountpoint_vol"))

    id =
      cmd(
        "container create --volume testvol-1:/testdir1:ro -v /testdir2:ro #{image_id} /usr/bin/touch /testdir2/testfile2"
      )

    jocker_cmd("container start --attach #{id}")

    %Container{layer_id: layer_id} = MetaData.get_container(id)
    %Layer{mountpoint: mountpoint} = MetaData.get_layer(layer_id)

    assert is_file?(Path.join(mountpoint, "testdir1/testfile_writable_from_mountpoint_vol"))
    assert not is_file?(Path.join(mountpoint, "/testdir2/testfile2"))
    assert not Utils.touch(Path.join(mountpoint, "/testdir2/testfile2"))
    assert not Utils.touch(Path.join(mountpoint, "/testdir1/testfile1"))

    [vol2] =
      Enum.reject(MetaData.list_volumes(), fn
        %Volume{name: ^vol_name} -> true
        _ -> false
      end)

    Container.destroy(id)
    Volume.destroy_volume(vol1)
    Volume.destroy_volume(vol2)
    assert not is_directory?(mountpoint)
    System.cmd("rm", ["./tmp_dockerfile"])
  end

  test "try stopping a container that is already stopped" do
    id = cmd("container create base echo lol")
    assert cmd("container stop #{id}") == "Container '#{id}' is not running"
  end

  test "starting a long-running container and stopping it" do
    id = cmd("container create base /bin/sleep 10000")
    %Container{name: name} = cont = MetaData.get_container(id)
    MetaData.add_container(%Container{cont | created: epoch(1)})

    header =
      "CONTAINER ID   IMAGE                       COMMAND                   CREATED              STATUS    NAME\n"

    row =
      "#{id}   base                        /bin/sleep 10000          52 years             stopped   #{
        name
      }\n"

    row_running =
      "#{id}   base                        /bin/sleep 10000          52 years             running   #{
        name
      }\n"

    assert cmd("container ls --all") == [header, row]
    assert cmd("container ls") == [header]
    assert cmd("container start #{id}") == id
    # It does take some time from the OS to return jail -c and to the jail is actually running:
    :timer.sleep(500)
    assert cmd("container ls --all") == [header, row_running]
    assert cmd("container stop #{id}") == id
    assert cmd("container ls --all") == [header, row]
  end

  test "start and attach to a container that produces some output" do
    id = cmd("container create base echo lol")
    assert cmd("container start -a #{id}") == "lol"
  end

  test "basic creation, removal and listing of networks" do
    network = MetaData.get_network("default")

    expected_output = """
    NETWORK ID     NAME                        DRIVER
    #{network.id}   default                     loopback
    host           host                        host
    """

    output = cmd("network ls")
    assert expected_output == Enum.join(output, "")

    network_id = cmd("network create --ifname jocker1 --subnet 172.19.0.0/24 testnet")
    network = MetaData.get_network("testnet")
    assert network_id == network.id

    expected_output_testnet =
      expected_output <>
        """
        #{network.id}   testnet                     loopback
        """

    output = cmd("network ls")
    assert expected_output_testnet == Enum.join(output, "")

    network_id = cmd("network rm testnet")
    assert network_id == network.id

    output = cmd("network ls")
    assert expected_output == Enum.join(output, "")
  end

  test "connecting a container to a custom network at creation time" do
    cmd("network create --ifname jocker1 --subnet 172.19.0.0/24 testnet")
    id = cmd("container create --network testnet base netstat --libxo json -4 -i")
    interfaces = cmd("container start -a #{id}") |> decode_netstat_interface_status()
    assert interfaces["jocker1"]["address"] == "172.19.0.0"
    assert [] == cmd("network disconnect testnet #{id}")
    interfaces = cmd("container start -a #{id}") |> decode_netstat_interface_status()
    assert interfaces == %{}
    cmd("network rm testnet")
  end

  test "connect a container to a custom network after it has been created with the default network" do
    _network_id = cmd("network create --ifname jocker1 --subnet 172.19.0.0/24 testnet")
    id = cmd("container create base netstat --libxo json -4 -i")
    cmd("network connect testnet #{id}")
    interfaces = cmd("container start -a #{id}") |> decode_netstat_interface_status()
    assert interfaces["jocker1"]["address"] == "172.19.0.0"
    assert interfaces["jocker0"]["address"] == "172.17.0.0"
    cmd("network rm testnet")
    interfaces = cmd("container start -a #{id}") |> decode_netstat_interface_status()
    assert interfaces["jocker0"]["address"] == "172.17.0.0"
    assert length(Map.keys(interfaces)) == 1
  end

  test "jocker volume create" do
    assert ["testvol\n"] == jocker_cmd("volume create testvol")
    # Check for idempotency:
    assert ["testvol\n"] == jocker_cmd("volume create testvol")

    %Volume{name: "testvol", dataset: dataset, mountpoint: mountpoint} =
      MetaData.get_volume("testvol")

    assert {:ok, %File.Stat{:type => :directory}} = File.stat(mountpoint)
    assert {"#{dataset}\n", 0} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
    cmd("volume rm testvol")
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
             "test3            52 years          \n",
             "test2            52 years          \n"
           ]

    assert jocker_cmd("volume rm test2 test5 test3") ==
             [vol2_n, "Error: No such volume: test5\n", "test3\n"]

    assert jocker_cmd("volume ls") == [header]
  end

  test "jocker volume ls" do
    assert jocker_cmd("volume ls") == ["VOLUME NAME      CREATED           \n"]
    jocker_cmd("volume create test1")
    jocker_cmd("volume create test2")
    mock_volume_creation_time()
    output = jocker_cmd("volume ls")

    assert output == [
             "VOLUME NAME      CREATED           \n",
             "test2            52 years          \n",
             "test1            52 years          \n"
           ]

    assert ["test2\n", "test1\n"] == jocker_cmd("volume ls --quiet")
    assert ["test2\n", "test1\n"] == jocker_cmd("volume ls -q")
  end

  defp create_image_at_timestamp(name_tag, timestamp) do
    path = "./test/data/test_cli_build_image"
    img_id2 = cmd("image build -t #{name_tag} --quiet #{path}")
    img2 = MetaData.get_image(img_id2)
    MetaData.add_image(%Image{img2 | created: timestamp})
    img_id2
  end

  def create_image(content) do
    :ok = File.write(Path.join("./", "tmp_dockerfile"), content, [:write])
    {:ok, pid} = Image.build("./", "tmp_dockerfile", "test:latest", true)

    receive do
      {:image_builder, ^pid, {:image_finished, img}} -> img
    end
  end

  defp cmd(<<"image build", _::binary>> = command) do
    [msg] = jocker_cmd(command)
    id = String.slice(msg, 34, 12)
    id
  end

  defp cmd(<<"image rm", _::binary>> = command) do
    String.trim(List.first(jocker_cmd(command)))
  end

  defp cmd(<<"container start", _::binary>> = command) do
    String.trim(List.first(jocker_cmd(command)))
  end

  defp cmd(<<"container rm", _::binary>> = command) do
    String.trim(List.first(jocker_cmd(command)))
  end

  defp cmd(<<"container stop", _::binary>> = command) do
    String.trim(List.first(jocker_cmd(command)))
  end

  defp cmd(<<"container create", _::binary>> = command) do
    String.trim(List.first(jocker_cmd(command)))
  end

  defp cmd(<<"network create", _::binary>> = command) do
    String.trim(List.first(jocker_cmd(command)))
  end

  defp cmd(<<"network rm", _::binary>> = command) do
    String.trim(List.first(jocker_cmd(command)))
  end

  defp cmd(command) do
    jocker_cmd(command)
  end

  defp jocker_cmd(command) do
    command = String.split(command)
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

  def decode_netstat_interface_status(output_json) do
    {:ok, output} = Jason.decode(output_json)
    interface_list = output["statistics"]["interface"]
    Enum.reduce(interface_list, %{}, &Map.put(&2, &1["name"], &1))
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
        case String.starts_with?(src, "/" <> Config.get("volume_root")) do
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
    Enum.map(volumes, fn vol -> MetaData.add_volume(%Volume{vol | created: epoch(1)}) end)
  end

  defp register_as_cli_master() do
    # Sometimes the last test did not release the ':cli_master' atom before the next
    # hence this function.
    case Process.whereis(:cli_master) do
      nil -> Process.register(self(), :cli_master)
      _ -> register_as_cli_master()
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
