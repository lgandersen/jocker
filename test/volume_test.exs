defmodule VolumeTest do
  use Jocker.API.ConnCase
  require Logger

  alias Jocker.Engine.{MetaData, Container, Volume}
  alias Jocker.API.Router

  @moduletag :capture_log
  @opts Router.init([])

  setup do
    on_exit(fn ->
      Jocker.Engine.MetaData.list_volumes()
      |> Enum.map(&Volume.destroy(&1.name))
    end)

    :ok
  end

  test "test filesystem operations when creating and deleting volumes", %{
    api_spec: api_spec
  } do
    %{dataset: dataset, mountpoint: mountpoint} = volume = volume_create(api_spec, "test")
    assert {:ok, %File.Stat{:type => :directory}} = File.stat(mountpoint)
    assert {"#{dataset}\n", 0} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
    volume_destroy(api_spec, volume.name)
    assert {:error, :enoent} = File.stat(mountpoint)
    assert {"", 1} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
  end

  test "list when there are zero volumes", %{
    api_spec: api_spec
  } do
    assert [] == volume_list(api_spec)
  end

  test "list with one volume then with zero volumes", %{
    api_spec: api_spec
  } do
    volume = volume_create(api_spec, "test-one-zero")
    response = volume_list(api_spec)
    assert [volume] == response
    volume_destroy(api_spec, volume.name)
    response = volume_list(api_spec)
    assert [] == response
  end

  test "list with two volumes then with one volume", %{
    api_spec: api_spec
  } do
    volume1 = volume_create(api_spec, "test-two-one1")
    volume2 = volume_create(api_spec, "test-two-one2")
    assert [volume2, volume1] == volume_list(api_spec)
    volume_destroy(api_spec, volume2.name)
    assert [volume1] == volume_list(api_spec)
    volume_destroy(api_spec, volume1.name)
  end

  test "verify volume binding", %{api_spec: api_spec} do
    # use /mnt since this is empty in the basejail by default
    location = "/mnt"
    file = "/mnt/test"
    volume = Volume.create("testvol")

    %Container{id: id} =
      con = TestHelper.container_create(api_spec, "volume_test", %{cmd: ["/usr/bin/touch", file]})

    {:ok, exec_id} = Jocker.Engine.Exec.create(id)
    :ok = Volume.bind_volume(con, volume, location)
    Jocker.Engine.Exec.start(exec_id, %{attach: true, start_container: true})

    receive do
      {:container, ^exec_id, {:shutdown, :jail_stopped}} -> :ok
    end

    assert {:ok, %File.Stat{:type => :regular}} = File.stat(Path.join(volume.mountpoint, "test"))
    Volume.destroy(volume.name)
    Container.destroy(id)
  end

  defp volume_destroy(api_spec, name) do
    response =
      conn(:delete, "/volumes/#{name}")
      |> Router.call(@opts)

    assert response.status == 200
    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "IdResponse", api_spec)
  end

  defp volume_create(api_spec, name) do
    response =
      conn(:post, "/volumes/create", %{name: name})
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert response.status == 201
    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "IdResponse", api_spec)
    MetaData.get_volume(json_body.id) |> Map.drop([:__struct__])
  end

  defp volume_list(api_spec) do
    response = conn(:get, "/volumes/list") |> Router.call(@opts)
    assert response.status == 200
    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "VolumeList", api_spec)
    json_body
  end
end
