defmodule ContainerTest do
  require Logger
  use Kleened.API.ConnCase
  alias Kleened.Core.{Container, Exec, Utils, MetaData}
  alias Kleened.API.Schemas

  @moduletag :capture_log

  setup do
    on_exit(fn ->
      Logger.info("Cleaning up after test...")
      MetaData.list_containers() |> Enum.map(fn %{id: id} -> Container.remove(id) end)

      MetaData.list_images()
      |> Enum.filter(fn %Schemas.Image{id: id} -> id != "base" end)
      |> Enum.map(fn %Schemas.Image{id: id} -> Kleened.Core.Image.destroy(id) end)
    end)

    :ok
  end

  test "create, destroy and list containers", %{
    api_spec: api_spec
  } do
    assert [] == TestHelper.container_list(api_spec)

    %Schemas.Container{id: container_id, name: name, image_id: img_id} =
      container_succesfully_create(api_spec, %{name: "testcont"})

    %Schemas.Image{id: id} = Kleened.Core.MetaData.get_image("base")
    assert id == img_id

    assert [%{id: ^container_id, name: ^name, image_id: ^img_id}] =
             TestHelper.container_list(api_spec)

    %Schemas.Container{id: container_id2, name: name2, image_id: ^img_id} =
      container_succesfully_create(api_spec, %{name: "testcont2"})

    assert [%{id: ^container_id2, name: ^name2, image_id: ^img_id}, %{id: ^container_id}] =
             TestHelper.container_list(api_spec)

    %{id: ^container_id} = TestHelper.container_remove(api_spec, container_id)
    assert [%{id: ^container_id2}] = TestHelper.container_list(api_spec)

    %{id: ^container_id2} = TestHelper.container_remove(api_spec, container_id2)
    assert [] = TestHelper.container_list(api_spec)

    assert %{message: "no such container"} ==
             TestHelper.container_remove(api_spec, container_id2)
  end

  test "prune containers", %{
    api_spec: api_spec
  } do
    %Schemas.Container{id: container_id1} =
      container_succesfully_create(api_spec, %{name: "testprune1", cmd: ["/bin/sleep", "10"]})

    %Schemas.Container{id: container_id2} =
      container_succesfully_create(api_spec, %{name: "testprune2", cmd: ["/bin/sleep", "10"]})

    %Schemas.Container{id: container_id3} =
      container_succesfully_create(api_spec, %{name: "testprune2", cmd: ["/bin/sleep", "10"]})

    {:ok, exec_id} = Exec.create(%Schemas.ExecConfig{container_id: container_id2})
    TestHelper.valid_execution(%{exec_id: exec_id, start_container: true, attach: false})

    assert [^container_id1, ^container_id3] = TestHelper.container_prune(api_spec)

    assert [%{id: ^container_id2}] = TestHelper.container_list(api_spec)

    Container.stop(container_id2)
  end

  test "Inspect a container", %{api_spec: api_spec} do
    %Schemas.Container{} = container_succesfully_create(api_spec, %{name: "testcontainer"})
    response = TestHelper.container_inspect_raw("notexist")
    assert response.status == 404
    response = TestHelper.container_inspect_raw("testcontainer")
    assert response.status == 200
    result = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert %{container: %{name: "testcontainer"}} = result
    assert_schema(result, "ContainerInspect", api_spec)
  end

  test "updating a container", %{
    api_spec: api_spec
  } do
    %Schemas.Container{id: container_id} =
      container =
      container_succesfully_create(api_spec, %{
        name: "testcontainer",
        user: "ntpd",
        cmd: ["/bin/sleep", "10"],
        env: ["TESTVAR=testval"],
        jail_param: ["allow.raw_sockets=true"]
      })

    config_nil = %{
      name: nil,
      user: nil,
      cmd: nil,
      env: nil,
      jail_param: nil
    }

    # Test a "nil-update"
    %{id: ^container_id} = TestHelper.container_update(api_spec, container_id, config_nil)
    %{container: container_upd} = TestHelper.container_inspect(container_id)
    assert container_upd == container

    # Test changing name
    %{id: ^container_id} =
      TestHelper.container_update(api_spec, container_id, %{config_nil | name: "testcontupd"})

    %{container: container_upd} = TestHelper.container_inspect(container_id)

    assert container_upd.name == "testcontupd"

    # Test changing env and cmd
    %{id: ^container_id} =
      TestHelper.container_update(api_spec, container_id, %{
        config_nil
        | env: ["TESTVAR=testval2"],
          cmd: ["/bin/sleep", "20"]
      })

    %{container: container_upd} = TestHelper.container_inspect(container_id)
    assert container_upd.env == ["TESTVAR=testval2"]
    assert container_upd.command == ["/bin/sleep", "20"]

    # Test changing jail-param
    %{id: ^container_id} =
      TestHelper.container_update(api_spec, container_id, %{
        config_nil
        | user: "root",
          jail_param: ["allow.raw_sockets=false"]
      })

    %{container: container_upd} = TestHelper.container_inspect(container_id)

    assert container_upd.jail_param == ["allow.raw_sockets=false"]
    assert container_upd.user == "root"
  end

  test "updating on a running container", %{api_spec: api_spec} do
    %Schemas.Container{id: container_id} =
      container_succesfully_create(api_spec, %{
        name: "testcontainer",
        user: "root",
        cmd: ["/bin/sh", "/etc/rc"],
        jail_param: ["mount.devfs"]
      })

    config_nil = %{
      name: nil,
      user: nil,
      cmd: nil,
      env: nil,
      jail_param: nil
    }

    # Test changing a jail-param that can be modfied while running
    {:ok, exec_id} = Exec.create(%Schemas.ExecConfig{container_id: container_id})

    TestHelper.valid_execution(%{exec_id: exec_id, start_container: true, attach: true})

    %{id: ^container_id} =
      TestHelper.container_update(api_spec, container_id, %{
        config_nil
        | jail_param: ["mount.devfs", "host.hostname=testing.local"]
      })

    %{container: container_upd} = TestHelper.container_inspect(container_id)
    assert container_upd.jail_param == ["mount.devfs", "host.hostname=testing.local"]

    {:ok, exec_id} =
      Exec.create(%Kleened.API.Schemas.ExecConfig{
        container_id: container_id,
        cmd: ["/bin/hostname"]
      })

    {_closing_msg, output} =
      TestHelper.valid_execution(%{
        exec_id: exec_id,
        attach: true,
        start_container: false
      })

    assert output == ["testing.local\n"]

    assert %{
             message:
               "an error ocurred while updating the container: '/usr/sbin/jail' returned non-zero exitcode 1 when attempting to modify the container 'jail: vnet cannot be changed after creation\n'"
           } ==
             TestHelper.container_update(api_spec, container_id, %{
               config_nil
               | jail_param: ["vnet"]
             })

    Container.stop(container_id)
  end

  test "start and stop a container (using devfs)", %{api_spec: api_spec} do
    config = %{name: "testcont", cmd: ["/bin/sleep", "10"]}

    {%Schemas.Container{id: container_id} = cont, exec_id} =
      TestHelper.container_start_attached(api_spec, config)

    assert TestHelper.devfs_mounted(cont)

    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)

    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 1}}}
    refute TestHelper.devfs_mounted(cont)
  end

  test "start container without attaching to it", %{api_spec: api_spec} do
    %Schemas.Container{id: container_id} =
      container =
      container_succesfully_create(api_spec, %{
        name: "ws_test_container",
        image: "base",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    {:ok, exec_id} = Exec.create(container.id)
    config = %{exec_id: exec_id, attach: false, start_container: true}

    assert "succesfully started execution instance in detached mode" ==
             TestHelper.valid_execution(config)

    {:ok, ^container_id} = Container.remove(container_id)
  end

  test "start a container (using devfs), attach to it and receive output", %{api_spec: api_spec} do
    cmd_expected = ["/bin/echo", "test test"]

    %Schemas.Container{id: container_id, command: command} =
      container = container_succesfully_create(api_spec, %{name: "testcont", cmd: cmd_expected})

    assert cmd_expected == command

    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: true, start_container: true})

    assert_receive {:container, ^exec_id, {:jail_output, "test test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}, 5_000
    refute TestHelper.devfs_mounted(container)
  end

  test "start a container and force-stop it", %{api_spec: api_spec} do
    %Schemas.Container{id: container_id} =
      container_succesfully_create(api_spec, %{name: "testcont", cmd: ["/bin/sleep", "10"]})

    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: false, start_container: true})

    :timer.sleep(500)
    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)

    refute Utils.is_container_running?(container_id)
  end

  test "start and stop a container with '/etc/rc' (using devfs)", %{
    api_spec: api_spec
  } do
    config = %{
      name: "testcont",
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs", "exec.stop=\"/bin/sh /etc/rc.shutdown\""],
      user: "root"
    }

    {%Schemas.Container{id: container_id} = cont, exec_id} =
      TestHelper.container_start_attached(api_spec, config)

    assert TestHelper.devfs_mounted(cont)
    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 1}}}
    assert not TestHelper.devfs_mounted(cont)
  end

  test "create container from non-existing image", %{api_spec: api_spec} do
    assert %{message: "no such image 'nonexisting'"} ==
             TestHelper.container_create(api_spec, %{name: "testcont", image: "nonexisting"})
  end

  test "start a container as non-root", %{api_spec: api_spec} do
    {_cont, exec_id} =
      TestHelper.container_start_attached(api_spec, %{
        name: "testcont",
        cmd: ["/usr/bin/id"],
        user: "ntpd"
      })

    assert_receive {:container, ^exec_id,
                    {:jail_output, "uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"}}

    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}
  end

  test "jail parameters 'mount.devfs' and 'exec.clean' defaults can be replaced with jailparams",
       %{api_spec: api_spec} do
    # Override mount.devfs=true with mount.nodevfs
    config =
      container_config(%{
        jail_param: ["mount.nodevfs"],
        cmd: ["/bin/sh", "-c", "ls /dev"]
      })

    # With mount.devfs=true you get:
    # ["fd\nnull\npts\nrandom\nstderr\nstdin\nstdout\nurandom\nzero\nzfs\n"]
    assert {_, []} = TestHelper.container_valid_run(api_spec, config)

    # Override mount.devfs=true/exec.clean=true with mount.devfs=false/exec.noclean
    config =
      container_config(%{
        jail_param: ["mount.devfs=false", "exec.noclean"],
        cmd: ["/bin/sh", "-c", "ls /dev && printenv"]
      })

    {_container_id, output} = TestHelper.container_valid_run(api_spec, config)
    environment = TestHelper.from_environment_output(output)
    assert MapSet.member?(environment, "EMU=beam")

    # Override mount.devfs=true with mount.devfs=true
    config =
      container_config(%{
        jail_param: ["mount.devfs"],
        cmd: ["/bin/sh", "-c", "ls /dev"]
      })

    {_container_id, output} = TestHelper.container_valid_run(api_spec, config)
    assert ["fd\nnull\npts\nrandom\nstderr\nstdin\nstdout\nurandom\nzero\nzfs\n"] == output

    # Override exec.clean=true with exec.clean=true
    config =
      container_config(%{
        jail_param: ["exec.clean=true"],
        cmd: ["/bin/sh", "-c", "printenv"]
      })

    {_container_id, output} = TestHelper.container_valid_run(api_spec, config)
    environment = TestHelper.from_environment_output(output)
    assert environment == TestHelper.jail_environment([])
  end

  test "test that jail-param 'exec.jail_user' overrides ContainerConfig{user:}", %{
    api_spec: api_spec
  } do
    config =
      container_config(%{
        jail_param: ["exec.jail_user=ntpd"],
        user: "root",
        cmd: ["/usr/bin/id"]
      })

    {_container_id, output} = TestHelper.container_valid_run(api_spec, config)
    assert ["uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"] == output
  end

  test "start a container with environment variables set", %{api_spec: api_spec} do
    config = %{
      image: "FreeBSD:testing",
      name: "testcont",
      cmd: ["/bin/sh", "-c", "printenv"],
      env: ["LOL=test", "LOOL=test2"],
      user: "root",
      attach: true
    }

    {_container_id, output} = TestHelper.container_valid_run(api_spec, config)
    TestHelper.compare_environment_output(output, ["LOOL=test2", "LOL=test"])
  end

  test "start a container with environment variables", %{api_spec: api_spec} do
    dockerfile = """
    FROM FreeBSD:testing
    ENV TEST=lol
    ENV TEST2="lool test"
    CMD printenv
    """

    TestHelper.create_tmp_dockerfile(dockerfile, "tmp_dockerfile")

    {image, _build_log} =
      TestHelper.image_valid_build(%{
        context: "./",
        dockerfile: "tmp_dockerfile",
        tag: "test:latest"
      })

    config =
      container_config(%{
        image: image.id,
        env: ["TEST3=loool"]
      })

    {_container_id, output} = TestHelper.container_valid_run(api_spec, config)

    TestHelper.compare_environment_output(output, [
      "TEST=lol",
      "TEST2=lool test",
      "TEST3=loool"
    ])
  end

  test "start a container with environment variables and overwrite one of them", %{
    api_spec: api_spec
  } do
    dockerfile = """
    FROM FreeBSD:testing
    ENV TEST=lol
    ENV TEST2="lool test"
    CMD /bin/sh -c "printenv"
    """

    TestHelper.create_tmp_dockerfile(dockerfile, "tmp_dockerfile")

    {image, _build_log} =
      TestHelper.image_valid_build(%{
        context: "./",
        dockerfile: "tmp_dockerfile",
        tag: "test:latest"
      })

    config =
      container_config(%{
        image: image.id,
        env: ~w"TEST=new_value"
      })

    {_container_id, output} = TestHelper.container_valid_run(api_spec, config)
    TestHelper.compare_environment_output(output, ["TEST=new_value", "TEST2=lool test"])
  end

  test "try to remove a running container", %{api_spec: api_spec} do
    config = %{
      name: "remove_while_running",
      image: "FreeBSD:testing",
      user: "root",
      cmd: ~w"/bin/sh /etc/rc",
      attach: true
    }

    {container_id, _output} = TestHelper.container_valid_run(api_spec, config)

    assert %{message: "you cannot remove a running container"} ==
             TestHelper.container_remove(api_spec, container_id)

    Container.stop(container_id)
  end

  test "start container quickly several times to verify reproducibility", %{api_spec: api_spec} do
    container =
      container_succesfully_create(api_spec, %{
        name: "ws_test_container",
        image: "base",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    container_id = container.id
    :ok = start_n_attached_containers_and_receive_output(container.id, 20)
    {:ok, ^container_id} = Container.remove(container_id)
  end

  defp container_config(config) do
    defaults = %{
      name: "container_testing",
      image: "FreeBSD:testing",
      user: "root",
      attach: true
    }

    Map.merge(defaults, config)
  end

  defp container_succesfully_create(api_spec, config) do
    %{id: container_id} = TestHelper.container_create(api_spec, config)
    MetaData.get_container(container_id)
  end

  defp start_n_attached_containers_and_receive_output(_container_id, 0) do
    :ok
  end

  defp start_n_attached_containers_and_receive_output(container_id, number_of_starts) do
    {:ok, exec_id} = Exec.create(container_id)
    stop_msg = "executable #{exec_id} and its container exited with exit-code 0"

    assert {stop_msg, ["FreeBSD\n"]} ==
             TestHelper.valid_execution(%{exec_id: exec_id, attach: true, start_container: true})

    start_n_attached_containers_and_receive_output(container_id, number_of_starts - 1)
  end
end
