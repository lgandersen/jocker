defmodule Kleened.Core.Network do
  use GenServer
  alias Kleened.Core.{Config, Container, Utils, MetaData, OS, FreeBSD}
  alias Kleened.API.Schemas
  require Logger

  alias __MODULE__, as: Network

  defmodule State do
    defstruct pf_config_path: nil
  end

  @type t() :: %Schemas.Network{}
  @type network_id() :: String.t()
  @type network_config() :: %Schemas.NetworkConfig{}
  @type endpoint() :: %Schemas.EndPoint{}
  @type protocol() :: String.t()

  @default_pf_configuration """
  # This is the pf(4) configuration file template that is used by Kleened.
  # Feel free to add additional rules as long as the tags (and their ordering) below are preserved.
  # Modify with care: It can potentially affect Kleened in unpredictable ways.
  # The resulting configuration file that is loaded into pf is defined at the 'pf_config_path'
  # entry in the kleene engine configuration file (kleened_config.yaml).

  ### KLEENED MACROS START ###
  <%= kleene_macros %>
  ### KLEENED MACROS END #####

  ### KLEENED TRANSLATION RULES START ###
  <%= kleene_translation %>
  ### KLEENED TRANSLATION RULES END #####

  ### KLEENED FILTERING RULES START #####
  # block everything
  #block log all

  # skip loopback interface(s)
  set skip on lo0

  <%= kleene_filtering %>
  ### KLEENED FILTERING RULES END #######
  """

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  ### Docker Core style API's
  @spec create(network_config()) ::
          {:ok, Network.t()} | {:error, String.t()}
  def create(config) do
    GenServer.call(__MODULE__, {:create, config})
  end

  @spec connect(String.t(), %Schemas.EndPointConfig{}) ::
          {:ok, endpoint()} | {:error, String.t()}
  def connect(network_idname, config) do
    GenServer.call(__MODULE__, {:connect, network_idname, config}, 30_000)
  end

  @spec connect(String.t(), String.t()) :: :ok | {:error, String.t()}
  def disconnect(container_idname, network_idname) do
    GenServer.call(__MODULE__, {:disconnect, container_idname, network_idname})
  end

  @spec disconnect_all(String.t()) :: :ok
  def disconnect_all(container_id) do
    GenServer.call(__MODULE__, {:disconnect_all, container_id})
  end

  @spec list() :: [Network.t()]
  def list() do
    GenServer.call(__MODULE__, :list)
  end

  @spec remove(String.t()) :: {:ok, Network.network_id()} | {:error, String.t()}
  def remove(idname) do
    GenServer.call(__MODULE__, {:remove, idname}, 30_000)
  end

  @spec prune() :: {:ok, [Network.network_id()]}
  def prune() do
    GenServer.call(__MODULE__, :prune, 30_000)
  end

  @spec inspect_(String.t()) :: {:ok, %Schemas.NetworkInspect{}} | {:error, String.t()}
  def inspect_(network_idname) do
    GenServer.call(__MODULE__, {:inspect, network_idname})
  end

  def inspect_endpoint(container_id, network_id) do
    GenServer.call(__MODULE__, {:inspect_endpoint, container_id, network_id})
  end

  ### Callback functions
  @impl true
  def init([]) do
    pf_config_path = Config.get("pf_config_path")

    FreeBSD.enable_ip_forwarding()

    if not Utils.touch(pf_config_path) do
      Logger.error("Unable to access Kleeneds PF configuration file located at #{pf_config_path}")
    end

    create_network_interfaces()
    state = %State{:pf_config_path => pf_config_path}

    enable_pf()
    configure_pf(pf_config_path)
    {:ok, state}
  end

  @impl true
  def handle_call({:create, config}, _from, state) do
    reply =
      case validate_create_config(config) do
        :ok -> create_(config, state)
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:connect, net_ident, %Schemas.EndPointConfig{container: con_ident} = config},
        _from,
        state
      ) do
    reply =
      with {:container, %Schemas.Container{} = container} <-
             {:container, MetaData.get_container(con_ident)},
           {:network, %Schemas.Network{} = network} <-
             {:network, MetaData.get_network(net_ident)},
           {:endpoint, :not_found} <-
             {:endpoint, MetaData.get_endpoint(container.id, network.id)},
           :ok <- validate_connection_config(network, config) do
        connect_with_driver(container, network, config)
      else
        {:network, :not_found} ->
          Logger.debug(
            "cannot connect container #{config.container} to #{net_ident}: network not found"
          )

          {:error, "network not found"}

        {:container, :not_found} ->
          Logger.debug(
            "cannot connect container #{config.container} to #{net_ident}: container not found"
          )

          {:error, "container not found"}

        {:endpoint, _} ->
          {:error, "container already connected to the network"}
      end

    {:reply, reply, state}
  end

  def handle_call({:disconnect, container_idname, network_idname}, _from, state) do
    reply = disconnect_(container_idname, network_idname)
    {:reply, reply, state}
  end

  def handle_call({:disconnect_all, container_id}, _from, state) do
    network_ids =
      MetaData.connected_networks(container_id) |> Enum.map(fn network -> network.id end)

    Enum.map(network_ids, &disconnect_(container_id, &1))
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    networks = MetaData.list_networks(:include_host)
    {:reply, networks, state}
  end

  def handle_call({:remove, identifier}, _from, state) do
    reply = remove_(identifier, state.pf_config_path)
    {:reply, reply, state}
  end

  def handle_call(:prune, _from, state) do
    pruned_networks = MetaData.list_unused_networks()
    pruned_networks |> Enum.map(&remove_(&1, state.pf_config_path))
    {:reply, {:ok, pruned_networks}, state}
  end

  def handle_call({:inspect, idname}, _from, state) do
    reply =
      case MetaData.get_network(idname) do
        :not_found ->
          {:error, "network not found"}

        network ->
          endpoints = MetaData.get_endpoints_from_network(network.id)
          {:ok, %Schemas.NetworkInspect{network: network, network_endpoints: endpoints}}
      end

    {:reply, reply, state}
  end

  def handle_call({:inspect_endpoint, container_id, network_id}, _from, state) do
    endpoint = MetaData.get_endpoint(container_id, network_id)
    {:reply, endpoint, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  ##########################
  ### Internal functions ###
  ##########################
  def validate_create_config(%Schemas.NetworkConfig{
        name: name,
        subnet: subnet,
        subnet6: subnet6,
        gateway: gateway,
        gateway6: gateway6
      }) do
    with {:subnet, :ok} <- {:subnet, validate_ip(subnet, :subnet)},
         {:subnet6, :ok} <- {:subnet6, validate_ip(subnet6, :subnet)},
         {:gateway, :ok} <- {:gateway, validate_ip(gateway, :gateway)},
         {:gateway6, :ok} <- {:gateway6, validate_ip(gateway6, :gateway)},
         :not_found <- MetaData.get_network(name) do
      :ok
    else
      %Schemas.Network{} ->
        {:error, "network name is already taken"}

      {:subnet, {:error, reason}} ->
        {:error, "invalid subnet: #{reason}"}

      {:subnet6, {:error, reason}} ->
        {:error, "invalid subnet6: #{reason}"}

      {:gateway, {:error, reason}} ->
        {:error, "invalid gateway: #{reason}"}

      {:gateway6, {:error, reason}} ->
        {:error, "invalid gateway6: #{reason}"}
    end
  end

  defp create_(
         %Schemas.NetworkConfig{
           interface: ""
         } = config,
         state
       ) do
    interface = generate_interface_name()
    create_(%Schemas.NetworkConfig{config | interface: interface}, state)
  end

  defp create_(
         %Schemas.NetworkConfig{
           nat: "<host-gateway>"
         } = config,
         state
       ) do
    case detect_gateway_if() do
      {:ok, nat_if} ->
        create_(%Schemas.NetworkConfig{config | nat: nat_if}, state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_(
         %Schemas.NetworkConfig{type: "loopback"} = config,
         state
       ) do
    create_interface("lo", config.interface)
    {:ok, config} = configure_gateways(config)
    network = create_network_metadata(config, state)
    configure_pf(state.pf_config_path)
    {:ok, network}
  end

  defp create_(
         %Schemas.NetworkConfig{type: "bridge"} = config,
         state
       ) do
    create_interface("bridge", config.interface)
    {:ok, config} = configure_gateways(config)
    network = create_network_metadata(config, state)
    configure_pf(state.pf_config_path)
    {:ok, network}
  end

  defp create_(
         %Schemas.NetworkConfig{type: "custom"} = config,
         state
       ) do
    {:ok, config} = configure_gateways(config)
    network = create_network_metadata(config, state)
    configure_pf(state.pf_config_path)
    {:ok, network}
  end

  defp create_(%Schemas.NetworkConfig{type: driver}, _state) do
    {:error, "Unknown driver #{inspect(driver)}"}
  end

  defp create_network_interfaces() do
    MetaData.list_networks(:exclude_host)
    |> Enum.map(fn
      %Schemas.Network{type: "bridge", interface: interface} ->
        create_interface("bridge", interface)

      %Schemas.Network{type: "loopback", interface: interface} ->
        create_interface("lo", interface)

      _ ->
        :ok
    end)
  end

  defp configure_gateways(
         %Schemas.NetworkConfig{
           type: "bridge",
           gateway: "<auto>"
         } = config
       ) do
    gateway = first_ip_address(config.subnet, "inet")

    case ifconfig_cidr_alias(gateway, config.subnet, config.interface, "inet") do
      :ok -> configure_gateways(%Schemas.NetworkConfig{config | gateway: gateway})
      {:error, output} -> {:error, output}
    end
  end

  defp configure_gateways(
         %Schemas.NetworkConfig{
           type: "bridge",
           gateway6: "<auto>"
         } = config
       ) do
    gateway6 = first_ip_address(config.subnet6, "inet6")

    case ifconfig_cidr_alias(gateway6, config.subnet6, config.interface, "inet6") do
      :ok -> configure_gateways(%Schemas.NetworkConfig{config | gateway6: gateway6})
      {:error, output} -> {:error, output}
    end
  end

  defp configure_gateways(config) do
    {:ok, config}
  end

  def create_interface(if_type, interface) do
    if Utils.interface_exists(interface) do
      Utils.destroy_interface(interface)
    end

    OS.cmd(~w"ifconfig #{if_type} create name #{interface}")
  end

  defp create_network_metadata(
         %Schemas.NetworkConfig{
           name: name,
           type: type,
           subnet: subnet,
           subnet6: subnet6,
           interface: interface,
           external_interfaces: ext_ifs,
           gateway: gateway,
           nat: nat,
           icc: icc
         },
         _state
       ) do
    network = %Schemas.Network{
      id: Utils.uuid(),
      name: name,
      type: type,
      subnet: subnet,
      subnet6: subnet6,
      interface: interface,
      external_interfaces: ext_ifs,
      gateway: gateway,
      nat: nat,
      icc: icc
    }

    MetaData.add_network(network)
    network
  end

  defp remove_(idname, pf_config_path) do
    case MetaData.get_network(idname) do
      %Schemas.Network{type: "custom"} = network ->
        _remove_metadata_and_pf(network, pf_config_path)
        {:ok, network.id}

      %Schemas.Network{type: "loopback"} = network ->
        _remove_metadata_and_pf(network, pf_config_path)
        Utils.destroy_interface(network.interface)
        {:ok, network.id}

      %Schemas.Network{type: "bridge"} = network ->
        _remove_metadata_and_pf(network, pf_config_path)
        # Just in case there are more members added:
        remove_bridge_members(network.interface)
        Utils.destroy_interface(network.interface)
        {:ok, network.id}

      :not_found ->
        {:error, "network not found."}
    end
  end

  def _remove_metadata_and_pf(%Schemas.Network{id: id}, pf_config_path) do
    container_ids = MetaData.connected_containers(id)
    Enum.map(container_ids, &disconnect_(&1, id))
    MetaData.remove_network(id)
    configure_pf(pf_config_path)
  end

  defp connect_with_driver(%Schemas.Container{network_driver: "disabled"}, _network, _config) do
    {:error, "containers with the 'disabled' network-driver cannot connect to networks."}
  end

  defp connect_with_driver(%Schemas.Container{network_driver: "host"}, _network, _config) do
    {:error, "containers with the 'host' network-driver cannot connect to networks."}
  end

  defp connect_with_driver(
         %Schemas.Container{network_driver: "vnet"},
         %Schemas.Network{type: type},
         _config
       )
       when type == "loopback" or type == "custom" do
    {:error, "containers using the 'vnet' network-driver can't connect to #{type} networks"}
  end

  defp connect_with_driver(
         %Schemas.Container{network_driver: "ipnet"} = container,
         network,
         %Schemas.EndPointConfig{ip_address: ipv4_addr, ip_address6: ipv6_addr}
       ) do
    with {:ok, ip_address} <- create_ip_address(ipv4_addr, network, "inet"),
         {:ok, ip_address6} <- create_ip_address(ipv6_addr, network, "inet6"),
         :ok <- add_container_ip_alias(ip_address, container, network, "inet"),
         :ok <- add_container_ip_alias(ip_address6, container, network, "inet6") do
      endpoint = %Schemas.EndPoint{
        id: Utils.uuid(),
        network_id: network.name,
        container_id: container.id,
        ip_address: ip_address,
        ip_address6: ip_address6
      }

      MetaData.add_endpoint(container.id, network.id, endpoint)
      {:ok, endpoint}
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp connect_with_driver(
         %Schemas.Container{network_driver: "vnet"} = container,
         %Schemas.Network{type: "bridge"} = network,
         %Schemas.EndPointConfig{ip_address: ipv4_addr, ip_address6: ipv6_addr}
       ) do
    with {:running, false} <- {:running, Container.is_running?(container.id)},
         {:ok, ip_address} <- create_ip_address(ipv4_addr, network, "inet"),
         {:ok, ip_address6} <- create_ip_address(ipv6_addr, network, "inet6") do
      endpoint = %Schemas.EndPoint{
        id: Utils.uuid(),
        network_id: network.name,
        container_id: container.id,
        ip_address: ip_address,
        ip_address6: ip_address6
      }

      MetaData.add_endpoint(container.id, network.id, endpoint)
      {:ok, endpoint}
    else
      {:error, msg} -> {:error, msg}
      # NOTE: Does even matter? We can still set meta-data and then it should work on a restart.
      {:running, true} -> {:error, "cannot connect a running vnet container to a network"}
    end
  end

  defp connect_with_driver(container, network, _config) do
    Logger.warn(
      "Unknown error occured when connecting container '#{container.id}' to network '#{network.id}'"
    )

    {:error, "unknown error"}
  end

  def disconnect_(con_ident, net_ident) do
    with {:container, container = %Schemas.Container{}} <-
           {:container, MetaData.get_container(con_ident)},
         {:network, network = %Schemas.Network{}} <- {:network, MetaData.get_network(net_ident)},
         {:endpoint, config = %Schemas.EndPoint{}} <-
           {:endpoint, MetaData.get_endpoint(container.id, network.id)} do
      cond do
        container.network_driver == "ipnet" ->
          # Remove ip-addresses from the jail, network interface, and database
          ifconfig_alias_remove(config.ip_address, network.interface, "inet")
          ifconfig_alias_remove(config.ip_address6, network.interface, "inet6")

          if Container.is_running?(container.id) do
            remove_jail_ips(container.id, config.ip_address)
          end

          MetaData.remove_endpoint_config(container.id, network.id)

        container.network_driver == "vnet" ->
          if config.epair != nil do
            FreeBSD.destroy_bridged_vnet_epair(config.epair, network.interface, container.id)
          end

          MetaData.remove_endpoint_config(container.id, network.id)

        true ->
          Logger.warn("this should not happen!")
          {:error, "unknown error occured"}
      end
    else
      {:container, :not_found} -> {:error, "container not found"}
      {:network, :not_found} -> {:error, "network not found"}
      {:endpoint, :not_found} -> {:error, "endpoint configuration not found"}
    end
  end

  defp validate_connection_config(%Schemas.Network{subnet: ""}, %Schemas.EndPointConfig{
         ip_address: ip_address
       })
       when ip_address != "" do
    {:error, "no IPv4 subnet defined for this network"}
  end

  defp validate_connection_config(%Schemas.Network{subnet6: ""}, %Schemas.EndPointConfig{
         ip_address6: ip_address6
       })
       when ip_address6 != "" do
    {:error, "no IPv6 subnet defined for this network"}
  end

  defp validate_connection_config(_, _) do
    :ok
  end

  @spec create_ip_address(String.t(), %Schemas.Network{}, protocol()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp create_ip_address("", _network, _protocol) do
    {:ok, ""}
  end

  defp create_ip_address("auto", network, protocol) do
    case new_ip(network, protocol) do
      :out_of_ips ->
        {:error, "no more #{protocol} IP's left in the network"}

      ip_address ->
        create_ip_address(ip_address, network, protocol)
    end
  end

  defp create_ip_address(ip_address, _network, protocol) do
    case decode_ip(ip_address, protocol) do
      {:error, msg} ->
        {:error, "could not parse #{protocol} address #{ip_address}: #{msg}"}

      {:ok, _ip_tuple} ->
        {:ok, ip_address}
    end
  end

  @spec add_container_ip_alias(String.t(), %Schemas.Container{}, %Schemas.Network{}, protocol) ::
          :ok | {:error, String.t()}
  defp add_container_ip_alias("", _container, _network, _protocol) do
    :ok
  end

  defp add_container_ip_alias(ip_address, container, network, protocol) do
    netmask =
      case protocol do
        "inet" -> "32"
        "inet6" -> "128"
      end

    case OS.cmd(~w"ifconfig #{network.interface} #{protocol} #{ip_address}/#{netmask} alias") do
      {_, 0} ->
        if Container.is_running?(container.id) do
          add_jail_ip(container.id, ip_address)
        end

        :ok

      {error_output, _nonzero_exitcode} ->
        {:error, "could not add ip #{ip_address} to #{network.interface}: #{error_output}"}
    end
  end

  def decode_ip(ip, protocol) do
    ip_charlist = String.to_charlist(ip)

    case protocol do
      "inet" -> :inet.parse_ipv4_address(ip_charlist)
      "inet6" -> :inet.parse_ipv6_address(ip_charlist)
    end
  end

  defp remove_bridge_members(bridge) do
    remove_if_member = fn line ->
      case String.contains?(line, "member: ") do
        true ->
          [_, epair | _rest] = String.split(line)
          {_output, 0} = OS.cmd(~w"ifconfig #{bridge} deletem #{epair}")

        false ->
          :ok
      end
    end

    {output, 0} = OS.cmd(~w"ifconfig #{bridge}")
    lines = output |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1)
    Enum.map(lines, remove_if_member)
  end

  def configure_pf(pf_config_path) do
    networks = MetaData.list_networks(:exclude_host)

    state = %{
      :macros => [],
      :translation => [],
      :filtering => []
    }

    pf_config = create_pf_config(networks, state)
    load_pf_config(pf_config_path, pf_config)
  end

  def create_pf_config(
        [%Schemas.Network{id: network_id} = network | rest],
        %{macros: macros, translation: translation} = state
      ) do
    prefix = "kleene_network_#{network_id}"
    updated_macros = add_network_macros(network, macros, prefix)

    # "nat on $#{prefix}_nat_if from $#{prefix}_subnet to any -> ($#{prefix}_nat_if)"
    nat_network =
      "nat on $#{prefix}_nat_if inet from ($#{prefix}_interface:network) to any -> ($#{prefix}_nat_if)"

    new_state = %{state | :macros => updated_macros, :translation => [nat_network | translation]}
    create_pf_config(rest, new_state)
  end

  def create_pf_config([], %{
        :macros => macros,
        :translation => translation,
        :filtering => filtering
      }) do
    EEx.eval_string(@default_pf_configuration,
      kleene_macros: Enum.join(macros, "\n"),
      kleene_translation: Enum.join(translation, "\n"),
      kleene_filtering: Enum.join(filtering, "\n")
    )
  end

  defp add_network_macros(
         %Schemas.Network{
           interface: interface,
           subnet: subnet,
           nat: nat_interface
         },
         macros,
         prefix
       ) do
    macro_interface = "#{prefix}_interface=\"#{interface}\""
    macro_subnet = "#{prefix}_subnet=\"#{subnet}\""
    macro_nat_if = "#{prefix}_nat_if=\"#{nat_interface}\""
    [macro_interface, macro_subnet, macro_nat_if | macros]
  end

  def enable_pf() do
    System.cmd("/sbin/pfctl", ["-e"], stderr_to_stdout: true)
  end

  def load_pf_config(pf_config_path, config) do
    case File.write(pf_config_path, config, [:write]) do
      :ok ->
        case System.cmd("/sbin/pfctl", ["-f", pf_config_path]) do
          {_, 0} ->
            :ok

          {"", 1} ->
            Logger.error("Failed to load PF configuration file. 'pfctl' returned with an error.")

          {error_output, 1} ->
            Logger.error(
              "Failed to load PF configuration file. 'pfctl' returned the following error: #{
                inspect(error_output)
              }"
            )
        end

      {:error, reason} ->
        Logger.error("Failed to write PF configuration file with reason: #{inspect(reason)} ")
    end
  end

  defp generate_interface_name() do
    existing_interfaces =
      MetaData.list_networks(:exclude_host)
      |> Enum.map(fn
        %Schemas.Network{interface: interface} -> interface
      end)
      |> MapSet.new()

    find_new_interface_name(existing_interfaces, 0)
  end

  defp find_new_interface_name(existing_interfaces, counter) do
    interface = "kleene#{counter}"

    case MapSet.member?(existing_interfaces, interface) do
      true -> find_new_interface_name(existing_interfaces, counter + 1)
      false -> interface
    end
  end

  def detect_gateway_if() do
    case get_routing_table(:ipv4) do
      {:ok, routing_table} ->
        case Enum.find(routing_table, "", fn %{"destination" => dest} -> dest == "default" end) do
          # Extract the interface name of the default gateway
          %{"interface-name" => interface} -> {:ok, interface}
          _ -> {:error, "could not find a default gateway"}
        end

      _ ->
        {:error, "could not find routing table"}
    end
  end

  def get_routing_table(protocol) do
    address_family =
      case protocol do
        :ipv4 -> "Internet"
        :ipv6 -> "Internet6"
      end

    {output_json, 0} = System.cmd("netstat", ["--libxo", "json", "-rn"])
    {:ok, output} = Jason.decode(output_json)
    routing_table = output["statistics"]["route-information"]["route-table"]["rt-family"]

    case Enum.filter(
           routing_table,
           fn
             %{"address-family" => ^address_family} -> true
             %{"address-family" => _} -> false
           end
         ) do
      [%{"rt-entry" => routes}] ->
        {:ok, routes}

      _ ->
        {:error, "could not find an #{address_family} routing table"}
    end
  end

  defp validate_ip("<auto>", :gateway6) do
    :ok
  end

  defp validate_ip("<auto>", :gateway) do
    :ok
  end

  defp validate_ip("", _type) do
    :ok
  end

  defp validate_ip(ip, _type) do
    case CIDR.parse(ip) do
      %CIDR{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def add_jail_ip(container_id, ip) do
    ips = get_jail_ips(container_id)
    jail_modify_ips(container_id, [ip | ips])
  end

  def remove_jail_ips(container_id, ip) do
    ips = MapSet.new([ip])
    ips_old = MapSet.new(get_jail_ips(container_id))
    ips_new = MapSet.to_list(MapSet.difference(ips_old, ips))
    jail_modify_ips(container_id, ips_new)
  end

  defp get_jail_ips(container_id) do
    # jls --libxo json -v -j 83 produceres
    # {"__version": "2",
    #  "jail-information": {"jail": [{"jid":83,"hostname":"","path":"/zroot/kleene_basejail","name":"83","state":"ACTIVE","cpusetid":4, "ipv4_addrs": ["172.17.0.1","172.17.0.2"], "ipv6_addrs": []}]}
    # }
    case System.cmd("/usr/sbin/jls", ["--libxo", "json", "-v", "-j", container_id]) do
      {output_json, 0} ->
        {:ok, jail_info} = Jason.decode(output_json)
        [%{"ipv4_addrs" => ip_addrs}] = jail_info["jail-information"]["jail"]
        ip_addrs

      {error_msg, _error_code} ->
        Logger.warn("Could not retrieve jail-info on jail #{container_id}: '#{error_msg}'")
        []
    end
  end

  def jail_modify_ips(jail_name, ips) do
    ips = Enum.join(ips, ",")

    case System.cmd("/usr/sbin/jail", ["-m", "name=#{jail_name}", "ip4.addr=#{ips}"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {error, _} ->
        Logger.error("Some error occured while assigning IPs #{ips} to #{jail_name}: #{error}")
        :error
    end
  end

  defp ifconfig_cidr_alias("", _subnet, _interface, _protocol) do
    :ok
  end

  defp ifconfig_cidr_alias(ip, subnet, interface, protocol) do
    %CIDR{mask: mask} = CIDR.parse(subnet)
    ifconfig_alias_add("#{ip}/#{mask}", interface, protocol)
  end

  defp ifconfig_alias_add("", _interface, _proto) do
    :ok
  end

  defp ifconfig_alias_add(ip, interface, protocol) do
    Logger.debug("Adding #{protocol} #{ip} to #{interface}")

    case OS.cmd(~w"ifconfig #{interface} #{protocol} #{ip} alias") do
      {_output, 0} ->
        :ok

      {output, _nonzero_exitcode} ->
        {:error, "error adding #{protocol} alias to interface: #{output}"}
    end
  end

  defp ifconfig_alias_remove("", _interface, _protocol) do
    :ok
  end

  defp ifconfig_alias_remove(ip, interface, protocol) do
    Logger.debug("Removing #{protocol} #{ip} from #{interface}")

    case OS.cmd(~w"ifconfig #{interface} #{protocol} #{ip} -alias") do
      {_, 0} ->
        :ok

      {output, _nonzero_exit} ->
        {:error, "error adding #{protocol} alias to interface: #{output}"}
    end
  end

  defp new_ip(%Schemas.Network{interface: interface, id: network_id} = network, protocol) do
    subnet =
      case protocol do
        "inet" -> network.subnet
        "inet6" -> network.subnet6
      end

    ips_in_use = ips_on_interface(interface, protocol) ++ ips_from_endpoints(network_id, protocol)

    %CIDR{:last => last_ip} = CIDR.parse(subnet)
    first_ip = first_ip_address(subnet, protocol)
    generate_ip(first_ip, last_ip, ips_in_use, protocol)
  end

  defp first_ip_address(subnet, protocol) do
    %CIDR{:first => first_ip} = CIDR.parse(subnet)
    first_ip |> ip2int(protocol) |> (&(&1 + 1)).() |> int2ip(protocol)
  end

  def ips_from_endpoints(network_id, protocol) do
    configs = MetaData.get_endpoints_from_network(network_id)

    raw_ip_list =
      case protocol do
        "inet" -> Enum.map(configs, & &1.ip_address)
        "inet6" -> Enum.map(configs, & &1.ip_address6)
      end

    raw_ip_list |> Enum.filter(&(&1 != nil and &1 != ""))
  end

  defp ips_on_interface(interface, protocol) do
    {output_json, 0} = System.cmd("netstat", ["--libxo", "json", "-I", interface])
    %{"statistics" => %{"interface" => addresses}} = Jason.decode!(output_json)
    extract_ips(addresses, protocol)
  end

  defp extract_ips(addresses, protocol) do
    ip_len =
      case protocol do
        "inet" -> 4
        "inet6" -> 8
      end

    addresses
    |> Enum.filter(fn %{"address" => address} ->
      case CIDR.parse(address) do
        %CIDR{first: ip} when tuple_size(ip) == ip_len -> true
        _ -> false
      end
    end)
    |> Enum.map(& &1["address"])
  end

  defp generate_ip(first_ip, last_ip, ips_in_use, protocol) do
    first_ip = ip2int(first_ip, protocol)
    last_ip = ip2int(last_ip, protocol)
    ips_in_use = MapSet.new(Enum.map(ips_in_use, &ip2int(&1, protocol)))
    next_ip = first_ip

    case next_unused_int_ip(first_ip, last_ip, next_ip, ips_in_use) do
      :out_of_ips ->
        :out_of_ips

      ip_int ->
        int2ip(ip_int, protocol)
    end
  end

  defp next_unused_int_ip(_first_ip, last_ip, next_ip, _ips_in_use) when next_ip > last_ip do
    :out_of_ips
  end

  defp next_unused_int_ip(first_ip, last_ip, next_ip, ips_in_use) do
    case MapSet.member?(ips_in_use, next_ip) do
      true ->
        next_unused_int_ip(first_ip, last_ip, next_ip + 1, ips_in_use)

      false ->
        next_ip
    end
  end

  defp int2ip(n, "inet") do
    int2ip_(n, 3, [], "inet")
  end

  defp int2ip(n, "inet6") do
    int2ip_(n, 7, [], "inet6")
  end

  defp int2ip_(n, 0, prev, _protocol) do
    [n | prev]
    |> Enum.reverse()
    |> List.to_tuple()
    |> :inet.ntoa()
    |> to_string()
  end

  defp int2ip_(n, order, prev, "inet") do
    x = floor(n / pow_ipv4(order))
    n_next = n - x * pow_ipv4(order)
    int2ip_(n_next, order - 1, [x | prev], "inet")
  end

  defp int2ip_(n, order, prev, "inet6") do
    x = floor(n / pow_ipv6(order))
    n_next = n - x * pow_ipv6(order)
    int2ip_(n_next, order - 1, [x | prev], "inet6")
  end

  defp ip2int({a, b, c, d}, "inet") do
    d + c * pow_ipv4(1) + b * pow_ipv4(2) + a * pow_ipv4(3)
  end

  defp ip2int(ip, "inet") do
    {:ok, {a, b, c, d}} = ip |> to_charlist() |> :inet.parse_address()
    ip2int({a, b, c, d}, "inet")
  end

  defp ip2int({a, b, c, d, e, f, g, h}, "inet6") do
    h + g * pow_ipv6(1) + f * pow_ipv6(2) + e * pow_ipv6(3) + d * pow_ipv6(4) + c * pow_ipv6(5) +
      b * pow_ipv6(6) + a * pow_ipv6(7)
  end

  defp ip2int(ip, "inet6") do
    {:ok, {a, b, c, d, e, f, g, h}} = ip |> to_charlist() |> :inet.parse_address()
    ip2int({a, b, c, d, e, f, g, h}, "inet6")
  end

  defp pow_ipv6(n) do
    :erlang.round(:math.pow(65536, n))
  end

  defp pow_ipv4(n) do
    :erlang.round(:math.pow(256, n))
  end
end
