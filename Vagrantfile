# -*- mode: ruby -*-
# Lab HA: HAProxy -> 2x (nginx + PHP-FPM + WordPress) + klaster MariaDB Galera + klaster Elasticsearch
# + S3 (SeaweedFS) + Zabbix. Każda maszyna konfiguruje się sama przez Ansible (ansible_local).
#
# Uruchomienie (kolejność ma znaczenie – VPS3 zakłada klaster Galery i trzyma repozytorium Git):
#   vagrant up --no-parallel
#
# Zmiana podsieci (gdy 192.168.57.0/24 jest już zajęta):
#   PowerShell:  $env:LAB_NET = "192.168.58"; vagrant up --no-parallel

LAB_NET = ENV.fetch("LAB_NET", "192.168.57")
LAB_BOX = ENV.fetch("LAB_BOX", "bento/debian-13")

# Kolejność na liście = kolejność tworzenia maszyn
MACHINES = [
  { name: "vps3", ip: 12, cpus: 2, memory: 6144 }, # dane: Galera, Elasticsearch, S3, Git, Zabbix
  { name: "vps1", ip: 10, cpus: 2, memory: 4096 }, # front WWW + węzeł klastrów
  { name: "vps2", ip: 11, cpus: 2, memory: 4096 }, # front WWW + węzeł klastrów
  { name: "lb",   ip: 5,  cpus: 1, memory: 1024 }, # load balancer (HAProxy)
].freeze

Vagrant.configure("2") do |config|
  config.vm.box = LAB_BOX
  config.vm.synced_folder ".", "/vagrant"

  MACHINES.each do |m|
    config.vm.define m[:name] do |node|
      node.vm.hostname = m[:name]
      node.vm.network "private_network", ip: "#{LAB_NET}.#{m[:ip]}"

      node.vm.provider "vmware_desktop" do |v|
        v.gui = false
        v.vmx["displayName"] = "wpgal-#{m[:name]}"
        v.vmx["memsize"] = m[:memory].to_s
        v.vmx["numvcpus"] = m[:cpus].to_s
      end

      node.vm.provider "virtualbox" do |v|
        v.name = "wpgal-#{m[:name]}"
        v.memory = m[:memory]
        v.cpus = m[:cpus]
      end

      # Ansible z pakietów Debiana (zawiera kolekcje ansible.posix i community.general)
      node.vm.provision "ansible-install", type: "shell", inline: <<~SHELL
        command -v ansible-playbook >/dev/null && exit 0
        apt-get update -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q ansible
      SHELL

      node.vm.provision "ansible", type: "ansible_local" do |a|
        a.install = false
        a.compatibility_mode = "2.0"
        a.provisioning_path = "/vagrant/ansible"
        a.playbook = "site.yml"
        a.inventory_path = "inventory.ini"
        a.limit = m[:name]
        a.extra_vars = { lab_net: LAB_NET }
      end
    end
  end
end
