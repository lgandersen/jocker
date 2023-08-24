defmodule ExecTest do
  require Logger
  use Kleened.API.ConnCase
  alias Kleened.Core.{Container, Exec, Utils, Network}
  alias Kleened.API.Schemas

  @moduletag :capture_log

  setup do
    {:ok, %Schemas.Network{name: "default"} = testnet} =
      Network.create(%Schemas.NetworkConfig{
        name: "default",
        subnet: "192.168.83.0/24",
        ifname: "kleene1",
        driver: "loopback"
      })

    on_exit(fn ->
      Kleened.Core.Network.remove(testnet.id)

      Kleened.Core.MetaData.list_containers()
      |> Enum.map(fn %{id: id} -> Container.remove(id) end)
    end)

    :ok
  end

  test "attach to a container and receive some output from it", %{api_spec: api_spec} do
    %{id: container_id} =
      TestHelper.container_create(api_spec, "test_container1", %{cmd: ["/bin/sh", "-c", "uname"]})

    {:ok, exec_id} = Exec.create(container_id)
    stop_msg = "executable #{exec_id} and its container exited with exit-code 0"

    assert ["OK", "FreeBSD\n", stop_msg] ==
             TestHelper.exec_start_sync(exec_id, %{attach: true, start_container: true})

    {:ok, ^container_id} = Container.remove(container_id)
  end

  test "start a second process in a container and receive output from it", %{
    api_spec: api_spec
  } do
    %{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    {:ok, root_exec_id} = Exec.create(container_id)
    :ok = Exec.start(root_exec_id, %{attach: false, start_container: true})

    {:ok, exec_id} =
      Exec.create(%Kleened.API.Schemas.ExecConfig{
        container_id: container_id,
        cmd: ["/bin/echo", "test test"]
      })

    :timer.sleep(100)
    :ok = Exec.start(exec_id, %{attach: true, start_container: false})
    assert_receive {:container, ^exec_id, {:jail_output, "test test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jailed_process_exited, 0}}}

    stop_opts = %{stop_container: true, force_stop: false}
    assert {:ok, ^container_id} = Exec.stop(root_exec_id, stop_opts)
    refute Utils.is_container_running?(container_id)
  end

  test "start a second process in a container and terminate it using 'stop_container: false'", %{
    api_spec: api_spec
  } do
    %{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    %{id: root_exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    {:ok, _stream_ref, root_conn} =
      TestHelper.exec_start(root_exec_id, %{attach: false, start_container: true})

    assert [:not_attached] == TestHelper.receive_frames(root_conn)

    %{id: exec_id} =
      TestHelper.exec_create(api_spec, %{
        container_id: container_id,
        cmd: ["/bin/sleep", "99"]
      })

    {:ok, _stream_ref, conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: false})

    assert {:text, "OK"} == TestHelper.receive_frame(conn)
    assert number_of_jailed_processes(container_id) == 2

    assert %{id: exec_id} ==
             TestHelper.exec_stop(api_spec, exec_id, %{stop_container: false, force_stop: true})

    error_msg = "#{exec_id} has exited with exit-code 137"
    assert [error_msg] == TestHelper.receive_frames(conn)

    assert number_of_jailed_processes(container_id) == 1

    assert Utils.is_container_running?(container_id)

    assert %{id: root_exec_id} ==
             TestHelper.exec_stop(api_spec, root_exec_id, %{
               stop_container: true,
               force_stop: false
             })

    refute Utils.is_container_running?(container_id)
  end

  test "start a second process in a container and terminate it using 'stop_container: true'", %{
    api_spec: api_spec
  } do
    %{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    %{id: root_exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    assert [:not_attached] ==
             TestHelper.exec_start_sync(root_exec_id, %{attach: false, start_container: true})

    %{id: exec_id} =
      TestHelper.exec_create(api_spec, %{
        container_id: container_id,
        cmd: ["/bin/sleep", "11"]
      })

    {:ok, _stream_ref, conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: false})

    assert {:text, "OK"} == TestHelper.receive_frame(conn)

    :timer.sleep(500)
    assert number_of_jailed_processes(container_id) == 2

    assert %{id: ^exec_id} =
             TestHelper.exec_stop(api_spec, exec_id, %{
               stop_container: true,
               force_stop: false
             })

    msg = "executable #{exec_id} and its container exited with exit-code 143"
    assert [msg] == TestHelper.receive_frames(conn)
    assert number_of_jailed_processes(container_id) == 0
    refute Utils.is_container_running?(container_id)
  end

  test "Create a exec instance that allocates a pseudo-TTY", %{
    api_spec: api_spec
  } do
    %{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/usr/bin/tty"]})

    # Start a process without attaching a PTY
    %{id: exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    {:ok, _stream_ref, conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: true})

    assert {:text, "OK"} == TestHelper.receive_frame(conn)

    {:text, msg} = TestHelper.receive_frame(conn)
    assert <<"not a tty\n", _rest::binary>> = msg

    # Start a process with a PTY attach
    %{id: exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id, tty: true})

    {:ok, _stream_ref, conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: true})

    assert {:text, "OK"} == TestHelper.receive_frame(conn)
    {:text, msg} = TestHelper.receive_frame(conn)
    assert <<"/dev/pts/", _rest::binary>> = msg
  end

  test "Create an interactive exec instance (allocatiing a pseudo-TTY)", %{
    api_spec: api_spec
  } do
    %{id: container_id} = TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sh"]})

    # Start a process with a PTY attach
    %{id: exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id, tty: true})

    {:ok, stream_ref, conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: true})

    assert {:text, "OK"} == TestHelper.receive_frame(conn)
    assert {:text, "# "} == TestHelper.receive_frame(conn)
    TestHelper.send_data(conn, stream_ref, "ls && exit\r\n")
    frames = TestHelper.receive_frames(conn)
    frames_as_string = Enum.join(frames, "")

    expected =
      "ls && exit\r\n.cshrc\t\tboot\t\tlibexec\t\tproc\t\tsys\r\n.profile\tdev\t\tmedia\t\trescue\t\ttmp\r\nCOPYRIGHT\tetc\t\tmnt\t\troot\t\tusr\r\nbin\t\tlib\t\tnet\t\tsbin\t\tvar\r\nexecutable #{
        exec_id
      } and its container exited with exit-code 0"

    assert expected == frames_as_string
  end

  test "use execution instance created with container name instead of container id", %{
    api_spec: api_spec
  } do
    %{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    %{id: exec_id} = TestHelper.exec_create(api_spec, %{container_id: "testcont"})

    assert [:not_attached] ==
             TestHelper.exec_start_sync(exec_id, %{attach: false, start_container: true})

    # seems like '/usr/sbin/jail' returns before the kernel reports it as running?
    :timer.sleep(500)
    assert Utils.is_container_running?(container_id)

    assert %{id: exec_id} ==
             TestHelper.exec_stop(api_spec, exec_id, %{stop_container: true, force_stop: false})

    refute Utils.is_container_running?(container_id)
  end

  test "cases where Exec.* should return errors (e.g., start a non-existing container and start non-existing exec-instance",
       %{
         api_spec: api_spec
       } do
    {:error, "invalid value/missing parameter(s)"} =
      TestHelper.exec_start("nonexisting", %{attach: "mustbeboolean", start_container: true})

    {:error, "invalid value/missing parameter(s)"} =
      TestHelper.initialize_websocket(
        "/exec/nonexisting/start?nonexisting_param=true&start_container=true"
      )

    %{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    assert %{message: "container not found"} ==
             TestHelper.exec_create(api_spec, %{container_id: "nottestcont"})

    %{id: root_exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    assert [
             "ERROR:could not find a execution instance matching 'wrongexecid'",
             "Failed to execute command."
           ] ==
             TestHelper.exec_start_sync("wrongexecid", %{attach: false, start_container: true})

    assert [
             "ERROR:cannot start container when 'start_container' is false.",
             "Failed to execute command."
           ] ==
             TestHelper.exec_start_sync(root_exec_id, %{attach: false, start_container: false})

    assert [:not_attached] ==
             TestHelper.exec_start_sync(root_exec_id, %{attach: false, start_container: true})

    assert ["ERROR:executable already started", "Failed to execute command."] ==
             TestHelper.exec_start_sync(root_exec_id, %{attach: false, start_container: true})

    :timer.sleep(100)
    assert Utils.is_container_running?(container_id)

    %{id: exec_id} =
      TestHelper.exec_create(api_spec, %{
        container_id: container_id,
        cmd: ["/bin/sleep", "99"]
      })

    assert %{id: exec_id} ==
             TestHelper.exec_stop(api_spec, exec_id, %{stop_container: true, force_stop: false})

    assert Utils.is_container_running?(container_id)

    assert %{id: root_exec_id} ==
             TestHelper.exec_stop(api_spec, root_exec_id, %{
               stop_container: true,
               force_stop: false
             })

    assert %{message: "no such container"} ==
             TestHelper.exec_stop(api_spec, root_exec_id, %{
               stop_container: true,
               force_stop: false
             })

    refute Utils.is_container_running?(container_id)
    {:ok, ^container_id} = Container.remove(container_id)
  end

  defp number_of_jailed_processes(container_id) do
    case System.cmd("/bin/ps", ~w"--libxo json -J #{container_id}") do
      {jailed_processes, 0} ->
        %{"process-information" => %{"process" => processes}} = Jason.decode!(jailed_processes)
        length(processes)

      {_, _nonzero} ->
        0
    end
  end
end
