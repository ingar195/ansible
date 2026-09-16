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

## Quick start order

1. Fill in `.pve_api` and `.minio_credentials` (Terraform).
2. `terraform apply` the VM.
3. Add the VM to `hosts.ini`.
4. Copy the relevant `vault.example.yml` → `vault.yml`, fill it in, `./crypt.sh`.
5. Run `ansible-playbook -i hosts.ini site.yml --limit <group-name>`.
