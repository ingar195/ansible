# Ansible repo

Collection of ansible playbooks and tasks i use. Use at you own risk.

VM provisioning lives in a separate repo: [github.com/ingar195/terraform](https://github.com/ingar195/terraform). This repo only configures hosts once they already exist.

## Prerequisites
- Debian/Ubuntu targets
- Python installed
- Ansible >= 2.15
- Collections: community.general, community.docker, ansible.posix

## Inventory Notes
- Keep group names aligned with playbook targets (for example: `komodo_manager_servers`, `service_wazuh`, `zwavejs`).
- Prefer host key checking defaults (`accept-new`) instead of disabling verification entirely.

## Roles
- **common**: Baseline server hardening and maintenance, including package updates, unattended upgrades, NTP/Chrony setup, timezone configuration, Fail2Ban, and UFW defaults.
- **docker**: Installs Docker Engine and compose tooling from Docker's repo, then adjusts UFW forwarding so container networking works correctly.
- **homeassistant**: Applies to `pve-docker-int01` (the internal/non-DMZ docker host — was `pve-docker02`). Refreshes apt cache and, when `bus_id_zigbee`/`remote_ip` are set (`hosts.ini` `[home_assistant:vars]`), installs a USB/IP client that attaches the ConBee II Zigbee dongle from `mini01` on boot (with an automatic unbind/rebind-and-retry fallback if the server-side usbip session is stuck — a real failure mode after any hard VM recreation). Neither Zigbee nor the (unused) Z-Wave dongle are Proxmox USB passthrough — both live physically on `mini01` and reach this VM over USB/IP.
- **komodo**: Deploys Komodo manager/agent Docker Compose stacks with environment files, opens required ports, and starts services.
- **mini_pc**: Optimizes Mini PC reliability and storage endurance with log2ram, journald limits, and zram-based swap configuration.
- **minio**: Deploys MinIO via Docker Compose, used as the S3-compatible remote state backend for the Terraform repo.
- **nfs_gateway**: Runs NFS-Ganesha (Ceph-backed), exporting one subdirectory per host/service with per-export IP allowlists. Current exports (`group_vars/nfs_gateway/main.yml`):
  - `/komodo-manager` — client `10.11.0.51` (Komodo manager)
  - `/zwavejs` — client `10.13.0.61` (mini01, standalone Z-Wave JS UI host)
  - `/npm` — client `10.12.0.11` (DMZ PC's nginx-proxy-manager). DMZ was originally excluded from this trust tier by design; this one export is a deliberate, narrow exception (port 2049 only, single host).
  - `/pve-docker-int01` — client `10.13.0.12` (all 11 services on that host: Home Assistant, Node-RED, Grafana, InfluxDB, Mosquitto, ESPHome, zwavejs2mqtt (unused), Homarr, Uptime Kuma, Speedtest-tracker). One export for the whole host, not per-service, since it's all the same client anyway.
- **npm**: Deploys nginx-proxy-manager (DMZ PC only) via Docker Compose, NFS-backed volumes (`/npm` export above). No default admin in current NPM versions — first run bootstraps via an unauthenticated `POST /api/users`. Opens UFW 80/443/81.
- **pbs_backup**: Nightly backup of the whole `shared-data` CephFS tree from `nfs-gw01` to Proxmox Backup Server (`10.11.0.31`, datastore `cephfs-data`), via a native read-only CephFS mount (independent of Ganesha) + `proxmox-backup-client` on a systemd timer (02:00 daily). Retention (`keep-daily 7`/`keep-weekly 4`/`keep-monthly 6`) is set server-side on PBS's prune job, not in this repo. Posts to Discord on failure (`pbs-backup-notify.service`, webhook in vault).
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

# Run only one group
ansible-playbook -i your_inventory_file playbook_name --limit group_name

# This runs ONLY tasks tagged with 'update'
ansible-playbook -i your_inventory_file site.yml --tags "update"

# Cleanup ansible generated snapshots
ansible-playbook -i your_inventory_file site.yml --tags "manual_cleanup"
```

## Common Tags
- `update`: package refresh/upgrade tasks
- `manual_cleanup`: removes old Proxmox ansible snapshots
- `setup`: first-time provisioning tasks in roles that expose setup tags

## Secrets
- Keep secrets in Vault files under `group_vars/<group>/vault.yml` and do not commit decrypted secret files.
- Example templates are included in this repo as `vault.example.yml` files.
- Encrypt/decrypt vault files with `./crypt.sh` (encrypt) / `./crypt.sh d` (decrypt).
- PBS API tokens use privilege separation: an ACL granted to the token alone isn't enough, the owning user needs the same grant or the effective permission is empty. Hit this setting up `pbs_backup`'s token.
- `ansible_become` (`sudo`) can't be narrowly scoped via `sudoers.d` — Ansible always wraps the real command in `/bin/sh -c '...'`, so a command-specific NOPASSWD rule never matches. Pre-Terraform hosts without full `NOPASSWD:ALL` can't run `ansible-playbook` at all; either grant full NOPASSWD or fall back to direct SSH + scoped sudo commands for one-off work.
- For any Komodo agent host, the *real* compose file for a Komodo-managed stack lives at `/etc/komodo/stacks/<project>/compose.yaml` (find it via `docker inspect`'s `com.docker.compose.project.config_files` label) — not under `/opt/docker/`, which is only where bind-mounted data sits. Edit the wrong one and Komodo will just overwrite it later.
- The Terraform `proxmox_vm` module supports pinning `mac_address` — use it whenever recreating a VM on a network segment that might have a MAC-keyed switch/firewall/DHCP rule (a fresh clone gets a new MAC every time). Grab the old VM's MAC from its Proxmox config *before* destroying it.


## Commands 

- Tmp mount nfs
```bash
sudo apt install -y nfs-common
sudo mkdir -p /mnt/zwavejs
sudo mount -t nfs4 -o vers=4.2 10.11.0.53:/zwavejs /mnt/zwavejs
```

- Manually trigger / check the CephFS backup (nfs-gw01)
```bash
ssh user@10.11.0.53 sudo systemctl start pbs-backup.service   # run now
ssh user@10.11.0.53 systemctl list-timers pbs-backup.timer    # next scheduled run
ssh user@10.11.0.53 sudo systemctl start pbs-backup-notify.service  # test Discord alert
```