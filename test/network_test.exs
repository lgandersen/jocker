defmodule NetworkTest do
  use Kleened.Test.ConnCase
  require Logger
  alias Kleened.Core.{Network, MetaData, OS, ZFS}
  alias Kleened.API.Schemas

  @moduletag :capture_log

  # @dns_lookup_cmd ["/usr/bin/host", "-t", "A", "freebsd.org", "1.1.1.1"]
  # @dns_lookup_success "Using domain server:\nName: 1.1.1.1\nAddress: 1.1.1.1#53\nAliases: \n\nfreebsd.org has address 96.47.72.84\n"
  # @dns_lookup_failure ";; connection timed out; no servers could be reached\n"

  @cant_connect_vnet_with_loopback %{
    message: "containers using the 'vnet' network-driver can't connect to loopback networks"
  }

  @cant_connect_vnet_with_custom %{
    message: "containers using the 'vnet' network-driver can't connect to custom networks"
  }

  @cant_connect_host_with_any %{
    message: "containers with the 'host' network-driver cannot connect to networks."
  }
  @cant_connect_disabled_with_any %{
    message: "containers with the 'disabled' network-driver cannot connect to networks."
  }
  setup do
    TestHelper.cleanup()

    on_exit(fn ->
      TestHelper.cleanup()
    end)

    :ok
  end

  test "create, inspect, connect, and remove a 'loopback' network with custom interface name", %{
    api_spec: api_spec
  } do
    interface = "testnet"
    Network.destroy_interface(interface)

    network =
      create_network(%{
        name: "loopback_net",
        interface: interface,
        subnet: "172.19.1.0/24",
        type: "loopback"
      })

    # Verify that ipnet containers can connect to loopback networks
    {container_id, _, addresses} =
      netstat_in_container(%{network_driver: "ipnet", network: network.name})

    assert [%{"address" => "172.19.1.1", "network" => "172.19.1.1/32"}] =
             filter_by_interface(addresses, interface)

    ip_and_network_on_interface("172.19.1.1", "172.19.1.1/32", interface)

    # Inspect container
    assert %{
             container: %Schemas.Container{network_driver: "ipnet"},
             container_endpoints: [
               %Schemas.EndPoint{
                 epair: nil,
                 ip_address: "172.19.1.1",
                 ip_address6: "",
                 network_id: "loopback_net"
               }
             ]
           } = TestHelper.container_inspect(container_id)

    assert :ok == TestHelper.network_disconnect(api_spec, network.name, container_id)

    # Verifying that vnet containers can't connect to loopback networks
    output = failing_to_connect_container(["loopback_net"], "vnet")
    assert output == [@cant_connect_vnet_with_loopback]

    # Cleanup
    assert TestHelper.network_remove(api_spec, network.name) == %{id: network.id}
    assert not Network.interface_exists(interface)
    assert MetaData.get_network(network.id) == :not_found
  end

  test "create, inspect, connect, and remove a 'bridge' network with auto-generated interface name",
       %{
         api_spec: api_spec
       } do
    interface = "kleene0"
    Network.destroy_interface(interface)

    network =
      create_network(%{
        name: "bridge_net",
        subnet: "172.19.2.0/24",
        gateway: "",
        type: "bridge"
      })

    # Verify that ipnet containers can connect to bridge networks
    {container_id_ipnet, _, addresses} =
      netstat_in_container(%{network: network.name, network_driver: "ipnet"})

    assert [%{"address" => "172.19.2.1", "network" => "172.19.2.1/32"}] =
             filter_by_interface(addresses, interface)

    # Inspect container
    assert %{
             container: %Schemas.Container{network_driver: "ipnet"},
             container_endpoints: [
               %Schemas.EndPoint{
                 epair: nil,
                 ip_address: "172.19.2.1",
                 ip_address6: "",
                 network_id: "bridge_net"
               }
             ]
           } = TestHelper.container_inspect(container_id_ipnet)

    # Verifying that vnet containers can connect to bridge networks
    {container_id_vnet, _, addresses} =
      netstat_in_container(%{network: network.name, network_driver: "vnet"})

    assert [%{"address" => "172.19.2.2", "network" => "172.19.2.0/24"}] =
             filter_by_interface(addresses, "epair0b")

    # Inspect container
    assert %{
             container: %Schemas.Container{network_driver: "vnet"},
             container_endpoints: [
               %Schemas.EndPoint{
                 # Because the container is not running there is no 'epair' allocated.
                 epair: nil,
                 ip_address: "172.19.2.2",
                 ip_address6: "",
                 network_id: "bridge_net"
               }
             ]
           } = TestHelper.container_inspect(container_id_vnet)

    assert :ok == TestHelper.network_disconnect(api_spec, network.name, container_id_vnet)
    assert :ok == TestHelper.network_disconnect(api_spec, network.name, container_id_ipnet)

    # Cleanup
    assert TestHelper.network_remove(api_spec, network.name) == %{id: network.id}
    assert not Network.interface_exists("kleene0")
    assert MetaData.get_network(network.id) == :not_found
  end

  test "create, inspect, connect and remove a 'custom' network", %{
    api_spec: api_spec
  } do
    interface = "custom_if"
    Network.destroy_interface(interface)
    Network.create_interface("lo", interface)

    network =
      create_network(%{
        name: "custom_net",
        subnet: "172.19.3.0/24",
        interface: interface,
        gateway: "",
        type: "custom"
      })

    # Verify that ipnet containers can connect to bridge networks
    {container_id, _, addresses} =
      netstat_in_container(%{network: network.name, network_driver: "ipnet"})

    assert [%{"address" => "172.19.3.1", "network" => "172.19.3.1/32"}] =
             filter_by_interface(addresses, interface)

    # Inspect container
    assert %{
             container: %Schemas.Container{network_driver: "ipnet"},
             container_endpoints: [
               %Schemas.EndPoint{
                 epair: nil,
                 ip_address: "172.19.3.1",
                 ip_address6: "",
                 network_id: "custom_net"
               }
             ]
           } = TestHelper.container_inspect(container_id)

    # Verifying that vnet containers can't connect to custom networks
    output = failing_to_connect_container(["custom_net"], "vnet")
    assert output == [@cant_connect_vnet_with_custom]
    assert :ok == TestHelper.network_disconnect(api_spec, network.name, container_id)

    # Cleanup
    assert TestHelper.network_remove(api_spec, network.name) == %{id: network.id}
    assert Network.interface_exists("custom_if")
    assert MetaData.get_network(network.id) == :not_found
    Network.destroy_interface(interface)
  end

  test "listing networks", %{api_spec: api_spec} do
    Network.destroy_interface("kleene1")

    assert [] = TestHelper.network_list(api_spec)

    network1 = create_network(%{name: "testnet1", type: "bridge"})
    create_network(%{name: "testnet2", type: "bridge"})

    assert [
             %{name: "testnet1"},
             %{name: "testnet2"}
           ] = TestHelper.network_list(api_spec)

    assert TestHelper.network_remove(api_spec, network1.name) == %{id: network1.id}

    assert [
             %{name: "testnet2"}
           ] = TestHelper.network_list(api_spec)
  end

  test "prune networks", %{api_spec: api_spec} do
    network1 = create_network(%{name: "testnet1", type: "loopback"})

    %Schemas.Network{id: network2_id} = create_network(%{name: "testnet2", type: "bridge"})

    %{id: container_id} =
      TestHelper.container_create(api_spec, %{
        name: "network_prune_test",
        cmd: ["/bin/sleep", "10"],
        network_driver: "ipnet",
        network: "testnet1"
      })

    assert [network2_id] == TestHelper.network_prune(api_spec)
    assert [%{name: "testnet1"}] = TestHelper.network_list(api_spec)
    assert :ok == TestHelper.network_disconnect(api_spec, network1.id, container_id)
  end

  test "inspecting a network that doesn't exist" do
    %Schemas.Network{} = create_network(%{type: "loopback"})
    response = TestHelper.network_inspect_raw("notexist")
    assert response.status == 404
    assert response.resp_body == "{\"message\":\"network not found\"}"
  end

  test "remove a non-existing network", %{api_spec: api_spec} do
    network = create_network(%{ifname: "kleene1", driver: "loopback"})
    assert TestHelper.network_remove(api_spec, network.name) == %{id: network.id}
    assert TestHelper.network_remove(api_spec, network.name) == %{message: "network not found."}
  end

  test "create a network with same name twice", %{api_spec: api_spec} do
    network = create_network(%{type: "loopback"})

    assert %{message: "network name is already taken"} ==
             TestHelper.network_create(api_spec, %{
               name: "testnet",
               subnet: "172.19.0.0/16",
               type: "loopback"
             })

    assert TestHelper.network_remove(api_spec, network.name) == %{id: network.id}
  end

  test "try to create a network with an invalid subnet", %{api_spec: api_spec} do
    assert %{message: "invalid subnet: einval"} =
             TestHelper.network_create(api_spec, %{
               # Only CIDR-notation allowed
               name: "testnet",
               subnet: "172.18.0.0-16",
               type: "bridge"
             })
  end

  test "try to connect twice", %{api_spec: api_spec} do
    network = create_network(%{})

    %{id: container_id} =
      TestHelper.container_create(api_spec, %{
        name: "network_test",
        cmd: ["/bin/sleep", "10"],
        network_driver: "ipnet",
        network: ""
      })

    assert :ok == TestHelper.network_connect(api_spec, network.name, container_id)

    assert %{message: "container already connected to the network"} ==
             TestHelper.network_connect(api_spec, network.name, container_id)
  end

  test "try to disconnect twice", %{api_spec: api_spec} do
    network = create_network(%{})

    %{id: container_id} =
      TestHelper.container_create(api_spec, %{
        name: "network_test",
        cmd: ["/bin/sleep", "10"],
        network: network.name,
        network_driver: "ipnet"
      })

    assert :ok == TestHelper.network_disconnect(api_spec, network.id, container_id)

    assert %{message: "endpoint configuration not found"} ==
             TestHelper.network_disconnect(api_spec, network.id, container_id)
  end

  test "create a container that uses the 'host' network driver" do
    ip_addresses_on_host = only_ip_addresses(host_addresses())

    {_container_id, _routing_info, addresses} = netstat_in_container(%{network_driver: "host"})

    ip_addresses_in_container = only_ip_addresses(trim_adresses(addresses))

    assert MapSet.new(ip_addresses_on_host) == MapSet.new(ip_addresses_in_container)
  end

  test "a container using the 'host' network driver can't connect to networks" do
    network =
      create_network(%{
        name: "loopback_net",
        subnet: "172.19.1.0/24",
        type: "loopback"
      })

    assert [@cant_connect_host_with_any] ==
             failing_to_connect_container([network.name], "host")

    network =
      create_network(%{
        name: "bridge_net",
        subnet: "172.19.2.0/24",
        type: "bridge"
      })

    assert [@cant_connect_host_with_any] ==
             failing_to_connect_container([network.name], "host")

    network =
      create_network(%{
        name: "custom_net",
        interface: "em0",
        subnet: "172.19.3.0/24",
        gateway: "",
        type: "custom"
      })

    assert [@cant_connect_host_with_any] ==
             failing_to_connect_container([network.name], "host")
  end

  test "create a container that uses the 'disabled' network driver" do
    {_container_id, routing_info, addresses} = netstat_in_container(%{network_driver: "disabled"})

    assert %{"route-table" => %{"rt-family" => []}} = routing_info
    assert [] == remove_link_addresses(addresses)
  end

  test "a container using the 'disabled' network driver can't connect to networks" do
    network =
      create_network(%{
        name: "loopback_net",
        subnet: "172.19.1.0/24",
        type: "loopback"
      })

    assert [@cant_connect_disabled_with_any] ==
             failing_to_connect_container([network.name], "disabled")

    network =
      create_network(%{
        name: "bridge_net",
        subnet: "172.19.2.0/24",
        type: "bridge"
      })

    assert failing_to_connect_container([network.name], "disabled") ==
             [@cant_connect_disabled_with_any]

    network =
      create_network(%{
        name: "custom_net",
        interface: "em0",
        subnet: "172.19.3.0/24",
        gateway: "",
        type: "custom"
      })

    assert [@cant_connect_disabled_with_any] =
             failing_to_connect_container([network.name], "disabled")
  end

  test "Gateways of 'loopback' networks are not used" do
    Network.destroy_interface("kleene0")

    network =
      create_network(%{
        subnet: "172.19.1.0/24",
        subnet6: "fdef:1234:5678::/48",
        # Gateways should have no effect on a loopback network.
        gateway: "172.19.1.99",
        gateway6: "fdef:1234:5678:9999::",
        type: "loopback"
      })

    ## ipnet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{network: network.name, network_driver: "ipnet"})

    assert [%{"address" => "172.19.1.1", "network" => "172.19.1.1/32"}] =
             filter_by_interface(addresses, "kleene0")

    assert [%{"destination" => "172.19.1.1", "interface-name" => "kleene0"}] =
             routes(routing_info)
  end

  test "Gateways of 'custom' networks are not used" do
    interface = "custom0"
    Network.destroy_interface(interface)
    Network.create_interface("lo", interface)

    network =
      create_network(%{
        interface: interface,
        subnet: "172.19.1.0/24",
        subnet6: "fdef:1234:5678::/48",
        # Gateways should have no effect on a loopback network.
        gateway: "172.19.1.99",
        gateway6: "fdef:1234:5678:9999::",
        type: "custom"
      })

    ## ipnet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{network: network.name, network_driver: "ipnet"})

    assert [%{"address" => "172.19.1.1", "network" => "172.19.1.1/32"}] =
             filter_by_interface(addresses, interface)

    assert [%{"destination" => "172.19.1.1", "interface-name" => ^interface}] =
             routes(routing_info)
  end

  test "Manually set gateways for (IPv4 + 6) 'bridge' networks" do
    Network.destroy_interface("kleene0")

    network =
      create_network(%{
        name: "bridge_net",
        subnet: "172.19.1.0/24",
        subnet6: "fdef:1234:5678::/48",
        gateway: "172.19.1.99",
        gateway6: "fdef:1234:5678:9999::",
        type: "bridge"
      })

    ## ipnet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{
        network: network.name,
        network_driver: "ipnet",
        ip_address: "auto",
        ip_address6: "auto"
      })

    assert [
             %{"address" => "172.19.1.1", "network" => "172.19.1.1/32"},
             %{"address" => "fdef:1234:5678::1", "network" => "fdef:1234:5678::1/128"}
           ] = filter_by_interface(addresses, "kleene0")

    assert [
             %{"address" => "172.19.1.1", "network" => "172.19.1.1/32"},
             %{"address" => "fdef:1234:5678::1", "network" => "fdef:1234:5678::1/128"}
           ] = filter_by_interface(host_addresses(), "kleene0")

    # Unsure why it ends up being "lo0" and not "kleene0"
    assert [%{"destination" => "172.19.1.1", "interface-name" => "lo0"}] = routes(routing_info)

    assert [%{"destination" => "fdef:1234:5678::1", "interface-name" => "lo0"}] =
             routes6(routing_info)

    ## VNet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{
        network: network.name,
        network_driver: "vnet",
        ip_address: "auto",
        ip_address6: "auto"
      })

    assert [
             %{"address" => "172.19.1.2", "network" => "172.19.1.0/24"},
             %{"address" => "fdef:1234:5678::2", "network" => "fdef:1234:5678::/48"},
             %{"network" => "fe80::%epair0b/64"}
           ] = filter_by_interface(addresses, "epair0b")

    assert [
             %{
               "destination" => "default",
               "interface-name" => "epair0b",
               "gateway" => "172.19.1.99"
             },
             %{
               "destination" => "172.19.1.0/24",
               "gateway" => "link#2",
               "interface-name" => "epair0b"
             },
             %{
               "destination" => "172.19.1.2",
               "gateway" => "link#2",
               "interface-name" => "lo0"
             }
           ] = routes(routing_info)

    assert [
             %{
               "destination" => "fdef:1234:5678::/48",
               "interface-name" => "epair0b"
             },
             %{
               "destination" => "fdef:1234:5678::2",
               "interface-name" => "lo0"
             },
             %{
               "destination" => "fe80::%epair0b/64",
               "interface-name" => "epair0b"
             },
             # IPv6 link-local ip:
             %{
               "interface-name" => "lo0"
             }
           ] = routes6(routing_info)
  end

  test "Automatically set gateways for (IPv4 + 6) 'bridge' networks" do
    Network.destroy_interface("kleene0")

    network =
      create_network(%{
        name: "bridge_net",
        subnet: "172.19.1.0/24",
        subnet6: "fdef:1234:5678::/48",
        gateway: "<auto>",
        gateway6: "<auto>",
        type: "bridge"
      })

    assert [
             %{"address" => "172.19.1.1", "network" => "172.19.1.0/24"},
             %{"address" => "fdef:1234:5678::1", "network" => "fdef:1234:5678::/48"}
           ] = filter_by_interface(host_addresses(), "kleene0")

    OS.cmd(~w"ifconfig")

    ## ipnet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{
        network: network.name,
        network_driver: "ipnet",
        ip_address: "auto",
        ip_address6: "auto"
      })

    assert [
             %{"address" => "172.19.1.2", "network" => "172.19.1.2/32"},
             %{"address" => "fdef:1234:5678::2", "network" => "fdef:1234:5678::2/128"}
           ] = filter_by_interface(addresses, "kleene0")

    testing = filter_by_interface(host_addresses(), "kleene0")

    assert [
             %{"address" => "172.19.1.1", "network" => "172.19.1.0/24"},
             %{"address" => "fdef:1234:5678::1", "network" => "fdef:1234:5678::/48"},
             %{"address" => "172.19.1.2", "network" => "172.19.1.2/32"},
             %{"address" => "fdef:1234:5678::2", "network" => "fdef:1234:5678::2/128"}
           ] = testing

    assert [%{"destination" => "172.19.1.2", "interface-name" => "lo0"}] = routes(routing_info)

    assert [%{"destination" => "fdef:1234:5678::2", "interface-name" => "lo0"}] =
             routes6(routing_info)

    ## VNet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{
        network: network.name,
        network_driver: "vnet",
        ip_address: "auto",
        ip_address6: "auto"
      })

    assert [
             %{"address" => "172.19.1.3", "network" => "172.19.1.0/24"},
             %{"address" => "fdef:1234:5678::3", "network" => "fdef:1234:5678::/48"},
             %{"network" => "fe80::%epair0b/64"}
           ] = filter_by_interface(addresses, "epair0b")

    assert [
             %{
               "destination" => "default",
               "interface-name" => "epair0b",
               "gateway" => "172.19.1.1"
             },
             %{
               "destination" => "172.19.1.0/24",
               "gateway" => "link#2",
               "interface-name" => "epair0b"
             },
             %{
               "destination" => "172.19.1.3",
               "gateway" => "link#2",
               "interface-name" => "lo0"
             }
           ] = routes(routing_info)

    assert [
             %{
               "destination" => "fdef:1234:5678::/48",
               "interface-name" => "epair0b"
             },
             %{
               "destination" => "fdef:1234:5678::3",
               "interface-name" => "lo0"
             },
             %{
               "destination" => "fe80::%epair0b/64",
               "interface-name" => "epair0b"
             },
             # IPv6 link-local ip:
             %{
               "interface-name" => "lo0"
             }
           ] = routes6(routing_info)
  end

  test "'ipnet' containers can communicate with each other over all networks" do
    interface = "kleened0"
    Network.destroy_interface(interface)

    # Loopback
    network =
      create_network(%{
        name: "testnet1",
        subnet: "172.18.1.0/24",
        type: "loopback"
      })

    inter_container_connectivity_test(
      %{network_driver: "ipnet"},
      %{network_driver: "ipnet"},
      network.id,
      "inet"
    )

    # Bridge (using IPv6)
    ## FIXME: doesn't work. Easier to debug when Klee have been updated
    # network =
    #  create_network(%{
    #    name: "testnet2",
    #    # subnet: "172.19.1.0/24",
    #    subnet6: "fdef:1234:5678::/48",
    #    type: "bridge"
    #  })

    # inter_container_connectivity_test(
    #  %{ip_address: "", ip_address6: "auto", network_driver: "ipnet"},
    #  %{ip_address: "", ip_address6: "auto", network_driver: "ipnet"},
    #  network.id,
    #  "inet6"
    # )

    # Custom
    network =
      create_network(%{
        name: "testnet3",
        subnet: "172.20.1.0/24",
        interface: "em0",
        type: "custom"
      })

    inter_container_connectivity_test(
      %{network_driver: "ipnet"},
      %{network_driver: "ipnet"},
      network.id,
      "inet"
    )
  end

  # test "'vnet' containers can communicate over a 'bridge' network" do
  #  # FIXME: doesn't work. Easier to debug when Klee have been updated
  #  api_spec = Kleened.API.Spec.spec()
  #  Network.destroy_interface(interface)

  #  network =
  #  interface = "kleened0"
  #    create_network(%{
  #      subnet: "172.19.1.0/24",
  #      type: "bridge"
  #    })

  #  inter_container_connectivity_test(
  #    %{network_driver: "vnet"},
  #    %{network_driver: "vnet"},
  #    network.id,
  #    "inet"
  #  )
  # end

  # test "'vnet' and 'ipnet' containers can communicate over a 'bridge' network" do
  #  # FIXME: doesn't work. Easier to debug when Klee have been updated
  #  api_spec = Kleened.API.Spec.spec()
  #  interface = "kleened0"
  #  Network.destroy_interface(interface)

  #  network =
  #    create_network(%{
  #      subnet: "172.19.1.0/24",
  #      type: "bridge"
  #    })

  #  inter_container_connectivity_test(
  #    %{network_driver: "vnet"},
  #    %{network_driver: "vnet"},
  #    network.id,
  #    "inet"
  #  )
  # end

  test "exhaust all ips in a network", %{api_spec: api_spec} do
    create_network(%{name: "smallnet", subnet: "172.19.0.0/30", type: "loopback"})

    config = %{cmd: ["/bin/ls"], network: "smallnet", network_driver: "ipnet"}

    %{id: _id} = TestHelper.container_create(api_spec, Map.put(config, :name, "exhaust1"))
    %{id: _id} = TestHelper.container_create(api_spec, Map.put(config, :name, "exhaust2"))
    %{id: _id} = TestHelper.container_create(api_spec, Map.put(config, :name, "exhaust3"))

    assert {:error, %{message: "no more inet IP's left in the network"}} =
             TestHelper.container_create(api_spec, Map.put(config, :name, "exhaust4"))
  end

  defp routes(%{
         "route-table" => %{
           "rt-family" => route_groups
         }
       }) do
    get_route_group("Internet", route_groups)
  end

  defp routes6(%{
         "route-table" => %{
           "rt-family" => route_groups
         }
       }) do
    get_route_group("Internet6", route_groups)
  end

  defp get_route_group(type, route_groups) do
    %{"rt-entry" => routes} =
      Enum.find(route_groups, fn
        %{"address-family" => ^type} -> true
        _ -> false
      end)

    routes
  end

  defp create_network(config) do
    api_spec = Kleened.API.Spec.spec()

    config_default = %{
      name: "testnet",
      subnet: "172.18.0.0/16",
      subnet6: "",
      type: "loopback",
      gateway: "",
      gateway6: ""
    }

    config = Map.merge(config_default, config)
    %{id: network_id} = TestHelper.network_create(api_spec, config)
    network = MetaData.get_network(network_id)
    network_inspected = TestHelper.network_inspect(network.name)
    assert_schema(network_inspected, "NetworkInspect", api_spec)

    assert network.name == config.name
    assert network.id == network_inspected.network.id
    assert network.name == network_inspected.network.name
    assert interface_exists?(network.interface)
    network
  end

  defp inter_container_connectivity_test(config_server, config_client, network_id, protocol) do
    api_spec = Kleened.API.Spec.spec()

    config_server_default = %{
      ip_address: "auto",
      ip_address6: ""
    }

    cmd_server = ["/bin/sh", "-c", "nc -l 4000 > /test_connection"]
    config_server = Map.merge(config_server_default, config_server)
    config_server = Map.put(config_server, :attach, false)
    config_server = Map.put(config_server, :name, "server")
    config_server = Map.put(config_server, :network, network_id)
    config_server = Map.put(config_server, :cmd, cmd_server)

    config_client_default = %{
      ip_address: "auto",
      ip_address6: ""
    }

    config_client = Map.merge(config_client_default, config_client)
    config_client = Map.put(config_client, :name, "client")
    config_client = Map.put(config_client, :network, network_id)

    {container_id_server, _output} = TestHelper.container_valid_run(api_spec, config_server)

    endpoint = MetaData.get_endpoint(container_id_server, network_id)

    address =
      case protocol do
        "inet" -> endpoint.ip_address
        "inet6" -> endpoint.ip_address6
      end

    cmd_client = ["/bin/sh", "-c", "echo \"traffic\" | nc -v -N #{address} 4000"]
    config_client = Map.put(config_client, :cmd, cmd_client)

    {_container_id, _output} = TestHelper.container_valid_run(api_spec, config_client)
    container = MetaData.get_container(container_id_server)
    mountpoint = ZFS.mountpoint(container.dataset)
    assert {:ok, "traffic\n"} == File.read(Path.join(mountpoint, "/test_connection"))
  end

  defp netstat_in_container(config) do
    api_spec = Kleened.API.Spec.spec()

    all_in_one_netstat =
      "echo \"SPLIT HERE\" && netstat --libxo json -rn && echo \"SPLIT HERE\" && netstat --libxo json -i"

    config_default = %{
      name: "nettest",
      cmd: ["/bin/sh", "-c", all_in_one_netstat],
      ip_address: "auto",
      ip_adress6: ""
    }

    config = Map.merge(config_default, config)

    {container_id, output} = TestHelper.container_valid_run(api_spec, config)

    [_init_stuff, route_info, interface_info] =
      Enum.join(output, "") |> String.split("SPLIT HERE\n")

    %{"statistics" => %{"route-information" => routing}} = Jason.decode!(route_info)

    %{"statistics" => %{"interface" => addresses}} = Jason.decode!(interface_info)
    {container_id, routing, addresses}
  end

  defp failing_to_connect_container(networks, driver) do
    api_spec = Kleened.API.Spec.spec()

    %{id: container_id} =
      TestHelper.container_create(api_spec, %{
        name: "nettest",
        network: "",
        network_driver: driver
      })

    Enum.map(networks, &TestHelper.network_connect(api_spec, &1, container_id))
  end

  defp interface_exists?(interface_name) do
    {output_json, 0} = OS.cmd(["/usr/bin/netstat", "--libxo", "json", "-n", "-I", interface_name])

    {:ok, %{"statistics" => %{"interface" => if_properties}}} = Jason.decode(output_json)
    # No properties => no interface named 'interface_name' exists
    length(if_properties) != 0
  end

  defp ip_and_network_on_interface(ip, network, interface) do
    {output_json, 0} =
      System.cmd("/usr/bin/netstat", ["--libxo", "json", "-4", "-n", "-I", interface])

    %{"statistics" => %{"interface" => if_info}} = Jason.decode!(output_json)

    ips = MapSet.new(Enum.map(if_info, &Map.get(&1, "address")))
    networks = MapSet.new(Enum.map(if_info, &Map.get(&1, "network")))

    assert MapSet.member?(ips, ip)
    assert MapSet.member?(networks, network)
  end

  defp remove_link_addresses(addresses) do
    Enum.filter(addresses, fn %{"network" => network} ->
      String.slice(network, 0, 6) != "<Link#"
    end)
  end

  defp only_ip_addresses(addresses) do
    Enum.filter(addresses, fn %{"address" => address} ->
      case CIDR.parse(address) do
        %CIDR{} -> true
        _ -> false
      end
    end)
  end

  defp host_addresses() do
    {output, 0} = OS.cmd(~w"/usr/bin/netstat --libxo json -i")
    %{"statistics" => %{"interface" => addresses}} = Jason.decode!(output)
    trim_adresses(addresses)
  end

  defp trim_adresses(addresses) do
    Enum.map(addresses, fn address ->
      Map.drop(address, ["flags", "sent-packets", "received-packets"])
    end)
  end

  defp filter_by_interface(addresses, interface) do
    Enum.filter(addresses, fn %{"network" => network, "name" => name} ->
      # != "<link#" to avoid entries related to '<Link#n>' networks

      String.slice(network, 0, 6) != "<Link#" and name == interface
    end)
  end
end
