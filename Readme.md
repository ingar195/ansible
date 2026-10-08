# Ansible repo

Collection of ansible playbooks and tasks i use. Use at you own risk.

VM provisioning lives in a separate repo: [github.com/ingar195/terraform](https://github.com/ingar195/terraform). This repo only configures hosts once they already exist.

## Prerequisites
- Debian/Ubuntu targets
- Python installed
- Ansible >= 2.15
- Collections: community.general, community.docker, ansible.posix

## Commands
```bash
# Run normally
ansible-playbook -i your_inventory_file playbook_name # add -Kk to use password auth

# Prompt for the vault password (needed whenever a vault.yml is encrypted)
ansible-playbook -i your_inventory_file site.yml --ask-vault-pass

# Run only one group
ansible-playbook -i your_inventory_file playbook_name --limit group_name

# Run only one host (by IP -- the "# hostname" comments in hosts.ini never match)
ansible-playbook -i your_inventory_file site.yml --limit 10.13.0.12

# Several targets, or a group minus a host
ansible-playbook -i your_inventory_file site.yml --limit 'group_name,10.13.0.12'
ansible-playbook -i your_inventory_file site.yml --limit 'all:!template'

# This runs ONLY tasks tagged with 'update'
ansible-playbook -i your_inventory_file site.yml --tags "update"

# Faster run: skip the slow apt upgrade/autoremove tasks tagged 'update'
ansible-playbook -i your_inventory_file site.yml --skip-tags "update"

# Cleanup ansible generated snapshots
ansible-playbook -i your_inventory_file site.yml --tags "manual_cleanup"

# Vault: encrypt / decrypt every group_vars/*/vault.yml
./crypt.sh
./crypt.sh d

# Vault: edit or view a single file in place (stays encrypted on disk)
ansible-vault edit group_vars/all/vault.yml
ansible-vault view group_vars/all/vault.yml
```

## Common Tags
- `update`: package refresh/upgrade tasks
- `manual_cleanup`: removes old Proxmox ansible snapshots
- `setup`: first-time provisioning tasks in roles that expose setup tags
- `monitoring_agent`: only the Alloy agent play (all hosts)
- `uptime_kuma`: only the Uptime Kuma monitor sync

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
- **monitoring_agent**: Installs Grafana Alloy (from Grafana's apt repo) on every host and pushes metrics and logs to `monitoring01`. See [Monitoring stack](#monitoring-stack).
- **monitoring_server**: Only prepares `monitoring01`'s data disk (partition, format, mount at `/data`, per-service directories with each image's non-root uid). The services themselves are a Komodo-managed compose stack, not this role.
- **nfs_gateway** and **pbs_backup**: **retired.** Data used to live on a CephFS share served by an NFS gateway (nfs-gw01, 10.11.0.53) and was backed up from there. All hosts now keep their data on local disk, covered by whole-VM backups, so these two roles (and the `nfs_gateway` group) are only kept until nfs-gw01 is destroyed. See [RESTORE.md](RESTORE.md) and `PLAN-vm-backup-restore.md`.
- **npm**: Deploys nginx-proxy-manager (DMZ PC only) via a Komodo-managed compose stack (`compose` repo, `proxymanager/`), data on the VM's local disk (`/opt/docker/npm`). No default admin in current NPM versions — first run bootstraps via an unauthenticated `POST /api/users`. Opens UFW 80/443/81.
- **pegaprox**: Opens and manages firewall rules for PegaProx-related services using the shared allowed-port definitions.
- **proxmox**: Applies Proxmox-specific firewall rules and ensures UFW is enabled on Proxmox hosts.
- **proxmox_snapshot**: Creates timestamped VM snapshots for listed Proxmox VMs and optionally runs manual snapshot cleanup tasks.
- **template**: Placeholder role that currently only updates apt cache and is intended as a starter for new host-role implementations.
- **uptime_kuma**: Syncs monitors into the already-running Uptime Kuma instance (`10.13.0.12:3001`, deployed via Komodo, not this role) from `kuma_monitors` in `group_vars/uptime_kuma/main.yml` — same "list of desired state" pattern as `npm_proxy_hosts`. Each entry is a host ping, or a TCP port check if `port` is set; an optional `group` nests it under a Kuma group monitor (auto-created). Idempotent by name — reruns add what's missing, retrofit the alert notification, and correct the URL of an existing HTTP monitor if `group_vars` differs from it. Run just this play with `--tags uptime_kuma --limit 10.13.0.12`. Uptime Kuma has no REST API, only Socket.IO, so this drives it via the `uptime-kuma-api` Python package installed into an isolated venv (the host has no system pip, and PEP 668 blocks a bare install).
- **usb_ip_server**: Configures USB/IP server support, including package install, sudo permissions, kernel modules, service startup, and firewall ports.
- **wazuh_agent**: Installs and configures the Wazuh agent (plus Sysmon for Linux), sets manager address, and enables required services.
- **zwavejs**: Opens firewall ports for Z-Wave JS UI (8091) and its websocket (3000/3501) on pve-docker-int01 (10.13.0.12), which runs Z-Wave JS UI as a Komodo stack (`compose` repo, `zwave/`) with its store in `/opt/docker/zwavejs2mqtt`.
- **ser2net**: On mini01 (10.13.0.61), exposes the Z-Wave stick as a raw TCP port (3333, allowed only from 10.13.0.12) so Z-Wave JS can run on another host with serial port `tcp://10.13.0.61:3333`. Used instead of USB/IP for Z-Wave because a dropped connection simply reconnects.


## Monitoring stack

Metrics, logs and alerts for the whole fleet. It is push-based: each host's Alloy sends out, nothing scrapes in.

- **Server**: `monitoring01` (`10.13.0.20`, VM from the terraform repo) runs Prometheus, Loki and a dedicated Grafana as a Komodo-managed compose stack (the `monitoring/` folder of the compose repo). Data sits on its second disk at `/data`, 14-day retention.
- **Alloy** (`monitoring_agent`, every host): host metrics plus container metrics (cAdvisor) go to Prometheus over `remote_write`; journald and Docker logs, labelled by container name, go to Loki. Runs as root because cAdvisor needs the Docker and containerd sockets.
- **Custom logs**: put an app's logs in `/var/log/apps/<app>/*.log` and the subfolder name becomes the `app` label in Loki. No per-app config.
- **Ceph**: hosts in `[ceph_nodes]` (`hosts.ini`) also push the Ceph mgr Prometheus module (`ceph mgr module enable prometheus`, once).
- **Alerts** (Grafana → Discord, provisioned from `compose/monitoring/grafana-alerting/`): low disk, disk filling fast, host stopped reporting, high CPU temperature, container down or restarting, ZFS pool not online, and Ceph health, OSD, pool and mon quorum. Proxmox's own events (failed backups, PBS GC/verify, HA fencing) reach Discord through Proxmox VE and PBS's built-in notifications instead. Setup steps are in [ACCOUNTS_SETUP.md](ACCOUNTS_SETUP.md).
- **Dashboards**: Node Exporter Full, cAdvisor, Critical Errors and Docker Logs, provisioned from `compose/monitoring/dashboards/`.

```bash
# Roll the agent out (or re-apply its config) without touching any other role
ansible-playbook -i hosts.ini site.yml --tags monitoring_agent --limit 'all:!template'
```

## 🚨 Critical Warnings
**Firewall & Security**
By default, these playbooks will **enable UFW and Fail2Ban**.
* **Connection Risk:** Ensure you have configured your own SSH allow rules in the firewall settings before running these playbooks, or you may lock yourself out of your server.
* **Custom Rules:** You must add your own firewall rules on top of the defaults provided here.


## Secrets
- See [ACCOUNTS_SETUP.md](ACCOUNTS_SETUP.md) for the full checklist of accounts/tokens/secrets needed before Terraform or Ansible will run.
- Keep secrets in Vault files under `group_vars/<group>/vault.yml` and do not commit decrypted secret files.
- Example templates are included in this repo as `vault.example.yml` files.
- Encrypt/decrypt vault files with `./crypt.sh` (encrypt) / `./crypt.sh d` (decrypt).
- `ansible_become` (`sudo`) can't be narrowly scoped via `sudoers.d` — Ansible always wraps the real command in `/bin/sh -c '...'`, so a command-specific NOPASSWD rule never matches. Pre-Terraform hosts without full `NOPASSWD:ALL` can't run `ansible-playbook` at all; either grant full NOPASSWD or fall back to direct SSH + scoped sudo commands for one-off work.
- For any Komodo agent host, the *real* compose file for a Komodo-managed stack lives at `/etc/komodo/stacks/<project>/compose.yaml` (find it via `docker inspect`'s `com.docker.compose.project.config_files` label) — not under `/opt/docker/`, which is only where bind-mounted data sits. Edit the wrong one and Komodo will just overwrite it later.
- `group_vars/all/main.yml` sets `ansible_become_password: "{{ fleet_sudo_password }}"` for every host, and that beats `--ask-become-pass`. For a host with a different sudo password, override it with `-e ansible_become_password=...`.
- `--limit` takes an IP or group name; the `# hostname` text in `hosts.ini` is only a comment and never matches.
- `uptime_kuma`'s credential is a full Kuma admin login (username/password) — Kuma has no scoped API token, so `group_vars/uptime_kuma/vault.yml` holds a standing admin credential same as everything else in this section.
- The Terraform `proxmox_vm` module supports pinning `mac_address` — use it whenever recreating a VM on a network segment that might have a MAC-keyed switch/firewall/DHCP rule (a fresh clone gets a new MAC every time). Grab the old VM's MAC from its Proxmox config *before* destroying it.


## Backups and restore

Every important VM is backed up whole by Proxmox to PBS (nightly 02:00, `vm-backup`). Restore a VM
or a single file from the Proxmox/PBS UI. See [RESTORE.md](RESTORE.md) for the steps, what's covered
and what isn't (mini01, monitoring01, PBS itself).