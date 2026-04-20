# Ansible repo

Collection of ansible playbooks and tasks i use. Use at you own risk.

## Prerequisites
- Debian/Ubuntu targets
- Python installed
- Ansible >= 2.15
- Collections: community.general, community.docker

## Roles
- **common**: Baseline server hardening and maintenance, including package updates, unattended upgrades, NTP/Chrony setup, timezone configuration, Fail2Ban, and UFW defaults.
- **docker**: Installs Docker Engine and compose tooling from Docker's repo, then adjusts UFW forwarding so container networking works correctly.
- **homeassistant**: Currently only refreshes apt cache and acts as a minimal placeholder for future Home Assistant host-specific setup.
- **komodo**: Deploys Komodo manager/agent Docker Compose stacks with environment files, opens required ports, and starts services.
- **mini_pc**: Optimizes Mini PC reliability and storage endurance with log2ram, journald limits, and zram-based swap configuration.
- **pegaprox**: Opens and manages firewall rules for PegaProx-related services using the shared allowed-port definitions.
- **proxmox**: Applies Proxmox-specific firewall rules and ensures UFW is enabled on Proxmox hosts.
- **proxmox_snapshot**: Creates timestamped VM snapshots for listed Proxmox VMs and optionally runs manual snapshot cleanup tasks.
- **template**: Placeholder role that currently only updates apt cache and is intended as a starter for new host-role implementations.
- **usb_ip_server**: Configures USB/IP server support, including package install, sudo permissions, kernel modules, service startup, and firewall ports.
- **wazuh_agent**: Installs and configures the Wazuh agent (plus Sysmon for Linux), sets manager address, and enables required services.
- **zwavejs**: Opens firewall ports required by Z-Wave JS UI and websocket services.


## 🚨 Critical Warnings
**Firewall & Security**
By default, these playbooks will **enable UFW and Fail2Ban**.
* **Connection Risk:** Ensure you have configured your own SSH allow rules in the firewall settings before running these playbooks, or you may lock yourself out of your server.
* **Custom Rules:** You must add your own firewall rules on top of the defaults provided here.


## Commands
```bash
# Run normally
ansible-playbook -i your_inventory_file playbook_name # add -Kk to use password auth

# This runs ONLY tasks tagged with 'update'
ansible-playbook -i your_inventory_file site.yml --tags "update"

# Cleanup ansible generated snapshots
ansible-playbook -i your_inventory_file site.yml --tags "manual_cleanup"