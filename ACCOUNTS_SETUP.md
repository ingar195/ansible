# Accounts & Secrets — Setup Guide

Everything you need before Terraform or Ansible will actually run. Two repos, one checklist.

## 1. Proxmox API token (Terraform)

- Where: Proxmox UI → Datacenter → Permissions → API Tokens → Add
- Save it as `user@realm!token-id=secret` into:
  `C:\Users\ingar\Documents\workspace\terraform\.pve_api`

## 2. MinIO credentials (Terraform state backend)

- MinIO runs on `tf-state01` (10.11.0.50). Create an access key in its console.
- Save into `C:\Users\ingar\Documents\workspace\terraform\.minio_credentials`:
  ```
  AWS_ACCESS_KEY_ID=...
  AWS_SECRET_ACCESS_KEY=...
  ```

## 3. SSH key (Terraform + Ansible)

- Your own SSH keypair, public half already in `variables.tf` → `ssh_public_keys`.
- Add a new key there if you set up on a new machine.

## 4. Ansible Vault password

- Vault files (`group_vars/*/vault.yml`) are encrypted with `ansible-vault`.
- `crypt.sh` prompts for the vault password interactively — no password file needed, just remember it (or store it in a password manager).

## 5. Per-service secrets (Ansible vault.yml files)

Each group under `group_vars/` has a `vault.example.yml` showing what's needed. Copy it to `vault.yml`, fill in real values, then `./crypt.sh` to encrypt.

| Group | What to fill in | Where to get it |
|---|---|---|
| `komodo_all` | `komodo_passkey`, db user/pass, webhook secret, jwt secret, admin password | make these up yourself (strong random values) |
| `dmz_pc` (nginx proxy manager) | `npm_admin_email`, `npm_admin_password`, `komodo_passkey` | set on first NPM login; passkey must match `komodo_all` |
| `minio_hosts` | `minio_root_user`, `minio_root_password` | make these up yourself |
| `nfs_gateway` | `ceph_nfs_gw_client_key` | `ceph auth get-or-create client.nfs-gw ...` on a Ceph node |
| `nfs_gateway` | `pbs_backup_token_secret` | PBS web UI → Datastore `cephfs-data` → Permissions → API Token |
| `nfs_gateway` | `pbs_backup_discord_webhook` | Discord channel → Edit Channel → Integrations → Webhooks |
| `uptime_kuma` | `kuma_username`, `kuma_password` | set on first Uptime Kuma login |
| `service_wazuh` | many API keys | **skipped for now, not deployed** |

## 6. Monitoring stack (`monitoring01`)

Secrets that live outside git:

| What | Where | How |
|---|---|---|
| `DISCORD_WEBHOOK_URL` | Komodo → stack `logging` → Environment (never in git) | Discord channel → Edit Channel → Integrations → Webhooks |
| Grafana admin password | Grafana UI, first login (default `admin` / `admin`) | change it straight away; not stored anywhere in the repos |

### Manual steps (one-time, in order)

1. **VM**: in the terraform repo, `terraform apply -target="module.monitoring01"` (the quotes are needed in PowerShell).
2. **Base + disk**: `ansible-playbook -i hosts.ini site.yml --limit monitoring_server` (mounts the data disk at `/data`, installs Docker + Komodo agent).
3. **Komodo UI**: create stack `logging` from the compose repo. **Run Directory** = `monitoring` (the folder that holds `compose.yaml`, not `monitoring/compose`), File Path = `compose.yaml`, server = `monitoring01`. Set `DISCORD_WEBHOOK_URL` in its Environment, then deploy.
4. **UniFi firewall**:
   - Every host outside `10.13.0.0/24` needs to reach `10.13.0.20` on tcp/9090 (Prometheus) and tcp/3100 (Loki). Nodes on the Proxmox network (`pbs01`, `pve01-03`) needed explicit rules.
   - `pve-docker-int01` needs internet egress for the speedtest container: `speedtest.net`, `*.ookla.com` on tcp 80/443, plus tcp 8080, tcp 5060, udp 8080 (the test servers vary by ISP, so allow by source host, not by domain).
5. **Agents**: `ansible-playbook -i hosts.ini site.yml --tags monitoring_agent --limit 'all:!template'`.
   - `--limit` takes an IP or group name. The `# pbs01` text in `hosts.ini` is only a comment.
   - `group_vars/all` hardcodes `ansible_become_password`, so `--ask-become-pass` is ignored. For a host whose sudo password differs from the vault one, pass it explicitly: `-e ansible_become_password="$PW"` (`read -s PW` first, so it stays out of shell history).
6. **Proxmox VE UI** (Proxmox's own events: failed backups, HA fencing):
   - Datacenter → Notifications → Notification Targets → Add → Webhook. Name `discord-infra`, method `POST`, header `Content-Type: application/json`, URL = the Discord webhook, body:
     ```
     {"content": "**{{ escape title }}** ({{ severity }})"}
     ```
     Keep the body to the title. Full logs exceed Discord's 2,000-character limit and the whole message is rejected. Press **Test**.
   - Notification Matchers → Add → `errors-to-discord`, severity **warning** + **error**, target `discord-infra`.
   - Datacenter → Backup → each job → notification mode = **Notification system**, not legacy sendmail.
7. **PBS UI** (`https://10.11.0.31:8007`): same target and matcher under Configuration → Notifications. Each datastore → Options → notification settings = **Errors**.
8. **Ceph metrics**: enable the exporter once (cluster-wide), then re-run step 5 on the Proxmox nodes:
   ```bash
   ansible 10.11.0.11 -i hosts.ini -m command -a "ceph mgr module enable prometheus"
   ansible-playbook -i hosts.ini site.yml --tags monitoring_agent --limit 10.11.0.11,10.11.0.12,10.11.0.13
   ```
9. **After changing alert rules**: Grafana only reads `grafana-alerting/*` at startup, so restart the container (`docker restart grafana` on `monitoring01`) or redeploy the stack in Komodo.

## Quick start order

1. Fill in `.pve_api` and `.minio_credentials` (Terraform).
2. `terraform apply` the VM.
3. Add the VM to `hosts.ini`.
4. Copy the relevant `vault.example.yml` → `vault.yml`, fill it in, `./crypt.sh`.
5. Run `ansible-playbook -i hosts.ini site.yml --limit <group-name>`.
