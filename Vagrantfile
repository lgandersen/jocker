# -*- mode: ruby -*-
# vim: set ft=ruby :

$host = "/host"

$configure_zfs = <<-SCRIPT
kldload zfs
sysrc -f /boot/loader.conf zfs_load="YES"
sysrc zfs_enable="YES"
truncate -s 1700M /home/vagrant/zpool.disk
zpool create -f zroot /home/vagrant/zpool.disk
zfs create -o compression=gzip-9 -o mountpoint=/zroot/kleene zroot/kleene
zfs create zroot/kleene_basejail
SCRIPT

$create_kleene_jailbase = "tar -xf #{$host}/amd64_13.1-RELEASE_base.txz -C /zroot/kleene_basejail"

$make_utf8_default = "cp #{$host}/kleened/vagrant_data/login.conf /etc/ && cap_mkdb /etc/login.conf"


Vagrant.configure("2") do |config|
  ### Basic configuration across VM's
  config.vm.box = "generic/freebsd13"
  config.vm.box_check_update = false
  config.vm.network "private_network", ip: "192.168.58.2"

  config.vm.synced_folder "..", $host,
    type: "nfs",
    mount_options: ['nolockd,vers=3,udp,rsize=32768,wsize=32768']

  config.vm.provider "virtualbox" do |vb|
    #vb.gui = true
    vb.memory = "4096"
  end

  config.vm.provision "shell", inline: $configure_zfs
  config.vm.provision "shell", inline: $create_kleene_jailbase
  #config.vm.provision "shell", inline: $make_utf8_default


  ########################################
  ### VM used for development purposes ###
  ########################################
  config.vm.define "dev", primary: true do |dev|
    dev.vm.hostname = "kleene-dev"

    dev.vm.provision "shell", inline: <<-SHELL
      ## Setup my development environment
      ln -s #{$host}/kleened/example/kleened_config.yaml /usr/local/etc/kleened_config.yaml
      ln -s #{$host}/kleened /home/vagrant/kleened
      ln -s #{$host}/klee /home/vagrant/klee

      ## Install packages
      ## Use 'erlang-wx' instead of 'erlang', if the observer gui is needed.
      ## Also remember to tweak ssh to X-forwarding etc.
      pkg install -y zsh bash tmux git-lite vim erlang elixir elixir-hex jq
      pkg install -y py39-pipenv py39-pipx
      su - vagrant -c 'pipx install openapi-python-client --include-deps'
      su - vagrant -c 'cd klee && pipenv install'

      pw usermod -s /usr/local/bin/zsh -n vagrant
      export HOME=/home/vagrant
      rm ~/.profile # we remove this to avoid error from yadm
      git clone -b with_my_bootstrap https://github.com/lgandersen/yadm.git ~/.yadm-project
      .yadm-project/bootstrap_dotfiles.sh
      chown -R vagrant /home/vagrant/.vim_runtime
    SHELL
  end

  ######################################################
  ### VM used for testing a build from a ports file ####
  ######################################################
  config.vm.define "test", autostart: false do |test|
    test.vm.hostname = "kleene-test"

    test.vm.provision "shell", inline: <<-SHELL
      pkg install -y git-lite erlang elixir elixir-hex
      cp -r #{$host}/kleened/ports /home/vagrant/
      cd /home/vagrant/kleened
      portsnap --interactive fetch extract
    SHELL
  end
end
