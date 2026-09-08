# Terraform Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up Terraform-based VM provisioning on the Proxmox/Ceph cluster: a bootstrap VM running MinIO to hold remote Terraform state, then bring the existing VM fleet under Terraform management.

**Architecture:** A reusable `proxmox_vm` Terraform module (clone-from-template + cloud-init) is used twice — once by a local-state `bootstrap` config to create the MinIO VM, then by the main "fleet" config (S3 remote state backed by that MinIO) to import and manage the existing VMs. Ansible configures the MinIO VM's OS/Docker/compose exactly like it does every other host today.

**Tech Stack:** Terraform (>= 1.6), `bpg/proxmox` provider, MinIO (S3-compatible), Ansible (existing repo conventions), Docker Compose.

**Spec:** [docs/superpowers/specs/2026-09-06-terraform-ceph-komodo-design.md](../specs/2026-09-06-terraform-ceph-komodo-design.md)

## Global Constraints

- Terraform >= 1.6 (required for the `endpoints` map syntax in the S3 backend block).
- Provider `bpg/proxmox`, version constraint `>= 0.66, < 1.0.0`.
- Proxmox API endpoint uses a self-signed cert → provider must set `insecure = true`.
- Cloud-init template: VMID `101`, node `pve01` (`10.11.0.11`).
- VM disks target Proxmox storage ID `vm_storage` (Ceph RBD, shared, content type `Disk image`).
- CPU type: the module sets `cpu_type` (default `x86-64-v2-AES`), overriding Proxmox's `qemu64` default — `qemu64` lacks x86-64-v2 instructions (SSE4.2 etc.) that modern container images' glibc requires, found via a real crash (MinIO container looping with "Fatal glibc error: CPU does not support x86-64-v2"). Requires a VM reboot to take effect once changed.
- Network: bridge `vmbr0`, no VLAN tag, on the `10.11.0.x` segment. DNS: the module defaults to using the gateway itself as the resolver (`dns_servers` variable, defaults to `[var.gateway]`) — confirmed this network's gateway does resolve DNS. Cloud-init's `initialization` block must include a `dns { servers = [...] }` sub-block or VMs get no resolver at all (found via a real failure: apt couldn't reach `deb.debian.org` on the first-created VM).
- Cloud-init user is `user`, matching `ansible_user=user` already set in `[all:vars]` in `hosts`.
- SSH public keys: Windows (`C:\Users\ingar\.ssh\id_rsa.pub`) and WSL Ubuntu-20.04 (`~/.ssh/id_rsa.pub`) are two *different* keypairs — both are injected via cloud-init as a literal list (`ssh_public_keys` variable default in each config's `variables.tf`), since Terraform runs natively on Windows but Ansible/existing SSH connections run from WSL. Terraform itself: installed via `winget install HashiCorp.Terraform` (v1.15.8), not WSL/apt (apt install hit an unresolved HashiCorp-repo fetch issue).
- Proxmox API token: `terraform@pve!tf-token` (secret held by the user, never committed). The user already stores the full token string (`terraform@pve!tf-token=<secret>`) in a gitignored `.pve_api` file in the Terraform repo. Terraform reads it via the `TF_VAR_proxmox_api_token` environment variable (the user sources it from `.pve_api` themselves before running any `terraform` command) — not via `terraform.tfvars`. `proxmox_api_url` and `ssh_public_key_path` are non-secret and get `default` values directly in each config's `variables.tf` instead.
- Ansible repo conventions to follow exactly: `hosts` and `group_vars/**/vault.yml` are gitignored (real values live only locally); `group_vars/**/vault.example.yml` is the committed template; secrets are encrypted with `ansible-vault` via `crypt.sh`; roles follow the `defaults/`, `handlers/`, `tasks/`, `templates/` layout seen in `roles/komodo/`.
- The Terraform repo lives at `C:\Users\ingar\Documents\workspace\terraform`, separate from this Ansible repo, and is not yet a git repository.
- **Ansible control node:** must run from WSL (Ansible doesn't run natively on Windows). Two WSL distros exist (`Ubuntu-20.04`, `Ubuntu`) — use **`Ubuntu`**, not `Ubuntu-20.04`, despite the latter having Ansible pre-installed. Reason: `Ubuntu-20.04`'s system `ansible` is 2.9.6 (from 2020, apt-pinned, no newer version available), which can't manage nodes running Python 3.13 (the current cloud-init template's Python version) — hits `ModuleNotFoundError: No module named 'ansible.module_utils.six.moves'`. Fix: a modern `ansible-core` (2.15–2.17) lives in a venv at `~/.venvs/ansible` inside the `Ubuntu` distro (Python 3.11 via the deadsnakes PPA, since apt's default Python there is also too old for modern ansible-core). Use `~/.venvs/ansible/bin/ansible`/`ansible-playbook`, not the system `ansible`. Required collections (`community.docker`, `community.general`) must be installed into this venv separately (`~/.venvs/ansible/bin/ansible-galaxy collection install ...`) since it starts empty.
- **SSH identity used by the `Ubuntu` WSL distro:** its `~/.ssh/id_rsa` was overwritten to be a copy of the **Windows** private key (`C:\Users\ingar\.ssh\id_rsa`), per explicit preference, rather than generating/using a separate WSL-native key. Both the Windows and original-WSL public keys are still injected into every VM via cloud-init (see `ssh_public_keys` above) for flexibility, but note: **existing production hosts** (Wazuh, DMZ, Komodo manager, HA docker host) were only ever configured to trust the original WSL key, not the Windows one — Ansible runs against those hosts will fail on auth until the Windows public key is also added to their `authorized_keys`.
- **Locked-down network egress:** this network only allows specific outbound domains. For the `minio_hosts` play (Debian package install + Docker Engine install + pulling the `minio/minio` image) these must be allowed: `deb.debian.org`, `security.debian.org` (apt), `download.docker.com` (Docker Engine repo), `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` (Docker Hub image pulls). Future roles pulling other images/packages will need their own domains added.
- **pve01 was reimaged** during this plan's execution — its SSH host key changed (expected/confirmed legitimate by the user) and its `root` account's `authorized_keys` no longer trusts the previously-used key. Restoring that trust is a prerequisite for Ansible to manage `pve01` again and was not fully resolved as part of this plan.

### Known issue encountered: cloud-init doesn't apply DNS via ifupdown on this template

Even though Proxmox's VM config correctly received `nameserver=10.12.0.1` (confirmed via the API — the Terraform/provider side is correct), the guest never got a working `/etc/resolv.conf`. Root cause found on the guest: cloud-init's `ifupdown` renderer wrote the `dns-nameservers`/`dns-search` directives under the **`lo` (loopback) interface** instead of `eth0` in `/etc/network/interfaces.d/50-cloud-init` — and the `resolvconf` package (required for `dns-nameservers` to do anything at all) isn't even installed on this template. This reproduced identically on a fresh clone (the DMZ test VM), not just as a one-off — it's a real template/cloud-init limitation, not something Terraform config can fix.

**Fix (applied):** `roles/common/tasks/main.yml` now has a task, first in the file (before "Update apt cache", which would otherwise fail with no DNS on any fresh VM): `Ensure a DNS resolver is configured`, using `lineinfile` to guarantee `nameserver {{ ansible_default_ipv4.gateway }}` is present in `/etc/resolv.conf`. Uses Ansible's auto-gathered gateway fact rather than a new inventory variable, so it works generically across every network segment (validated on both `10.11.0.x` and the `dmz`/`10.12.0.x` segment) without needing per-host DNS config. This is the permanent fix — supersedes the manual one-off `echo nameserver ... > /etc/resolv.conf` used earlier on VM 510.

### Known issue encountered: PowerShell mangles unquoted `-backend-config=file` args

`terraform init -backend-config=backend.hcl` (unquoted) failed with `Too many command line arguments. Did you mean to use -chdir?` when run via this session's PowerShell tool — a PowerShell/argument-passing quirk, not a real Terraform error. Fix: quote the value explicitly, `terraform init -backend-config="backend.hcl"`.

### Known issue encountered: external MAC-based firewall rules break on VM recreation

After destroying and recreating the Komodo manager VM (same VMID, same IP) as
a real test, its Komodo agents (`mini01`, `pve-docker01`, `pve-docker02`)
showed as unreachable — TCP connections to their periphery port (8120)
timed out entirely from the manager. Not a Komodo/Ansible/Terraform config
issue: root cause was the user's **UniFi firewall**, which had a rule keyed
to the *old* VM's MAC address (Terraform's clone generates a fresh MAC every
time, unlike the long-lived original VM). Fixed by updating the UniFi rule.

**For any host known to have an external MAC-based rule** (firewall,
switch port security, static DHCP/ARP binding, etc.), the safer fix is
pinning the original MAC address in the Terraform module call (the
`bpg/proxmox` provider's `network_device` block supports a `mac_address`
argument) rather than relying on remembering to update external rules after
every recreation — this wasn't done for the Komodo manager this time (fixed
in UniFi instead, at the user's choice), but is worth adding to the module
as an optional variable if this pattern recurs.

### Known issue encountered: orphaned VM disk reference after a failed clone

The very first `terraform apply` for the MinIO VM failed because the module's `disk_size` default (20GB) was smaller than the template's actual disk (32GB) — Proxmox cannot shrink disks on clone. That failure left Proxmox's VM config referencing a disk (`vm_storage:vm-510-disk-0`) that no longer actually existed in Ceph (error: `rbd: error opening image ... No such file or directory`), which then blocked every cleanup path: `terraform destroy` (taint-triggered replace), Proxmox UI "Remove" (even after detaching to "unused disk"), and a direct Proxmox API config-delete all failed the same way, because each tries to verify/clean up the disk in storage first.

**Fix:** the only reliable path was direct CLI access on `pve01` (`qm set 510 --delete unused0` or, if that also fails, `sed -i '/^unused0:/d' /etc/pve/qemu-server/510.conf` to strip the stale config line directly, then `qm destroy 510 --purge`), followed by `terraform state rm module.minio_vm.proxmox_virtual_environment_vm.this` and a fresh `terraform apply`. If this happens again on a future VM: don't fight it through Terraform or the UI — fix it via `qm`/config-file edit on the node directly, then reconcile Terraform state.

---

## Task 1: Scaffold the Terraform repository

**Files:**
- Create: `C:\Users\ingar\Documents\workspace\terraform\.gitignore`

**Interfaces:**
- Produces: an initialized git repo other tasks commit into.

- [ ] **Step 1: Initialize the git repository**

```bash
cd "C:\Users\ingar\Documents\workspace\terraform"
git init
git config --local user.name "Ingar"
git config --local user.email "ingar195@gmail.com"
```

- [ ] **Step 2: Create the root `.gitignore`**

```gitignore
# Terraform local state / working files
*.tfstate
*.tfstate.*
.terraform/
crash.log
override.tf
override.tf.json

# Secrets — never commit real values
terraform.tfvars
backend.hcl
!terraform.tfvars.example
!backend.hcl.example
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: initialize terraform repo"
```

---

## Task 2: Write the reusable `proxmox_vm` module

**Files:**
- Create: `C:\Users\ingar\Documents\workspace\terraform\modules\proxmox_vm\versions.tf`
- Create: `C:\Users\ingar\Documents\workspace\terraform\modules\proxmox_vm\variables.tf`
- Create: `C:\Users\ingar\Documents\workspace\terraform\modules\proxmox_vm\main.tf`
- Create: `C:\Users\ingar\Documents\workspace\terraform\modules\proxmox_vm\outputs.tf`

**Interfaces:**
- Produces: module `proxmox_vm` with input variables `vm_name (string)`, `vm_id (number)`, `target_node (string)`, `template_vm_id (number)`, `template_node (string)`, `cores (number, default 2)`, `memory (number, default 2048)`, `disk_size (number, default 32 — template VMID 101 already has a 32GB disk and Proxmox cannot shrink disks on clone)`, `disk_datastore (string, default "vm_storage")`, `network_bridge (string, default "vmbr0")`, `vlan_id (number, default null)`, `ip_address (string)`, `gateway (string)`, `ci_username (string, default "user")`, `ssh_public_keys (list(string))`; outputs `vm_id (number)`, `ipv4_address (string)`.

- [ ] **Step 1: Write `versions.tf`** (child modules must declare their own provider source, or Terraform assumes the nonexistent `hashicorp/proxmox`)

```hcl
terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}
```

- [ ] **Step 2: Write `variables.tf`**

```hcl
variable "vm_name" {
  type        = string
  description = "VM name shown in Proxmox"
}

variable "vm_id" {
  type        = number
  description = "Proxmox VMID to assign to the new VM"
}

variable "target_node" {
  type        = string
  description = "Proxmox node the VM will run on"
}

variable "template_vm_id" {
  type        = number
  description = "VMID of the cloud-init template to clone"
}

variable "template_node" {
  type        = string
  description = "Proxmox node the template lives on"
}

variable "cores" {
  type        = number
  default     = 2
  description = "Number of vCPU cores"
}

variable "memory" {
  type        = number
  default     = 2048
  description = "Memory in MB"
}

variable "disk_size" {
  type        = number
  default     = 32
  description = "Root disk size in GB (template VMID 101 already has a 32GB disk; Proxmox cannot shrink disks on clone, so this must be >= 32)"
}

variable "disk_datastore" {
  type        = string
  default     = "vm_storage"
  description = "Proxmox storage ID backing the VM disk"
}

variable "network_bridge" {
  type        = string
  default     = "vmbr0"
  description = "Proxmox network bridge"
}

variable "vlan_id" {
  type        = number
  default     = null
  description = "Optional VLAN tag for the network device"
}

variable "ip_address" {
  type        = string
  description = "Static IPv4 address in CIDR form, e.g. 10.11.0.50/24"
}

variable "gateway" {
  type        = string
  description = "Default gateway for the VM's network segment"
}

variable "ci_username" {
  type        = string
  default     = "user"
  description = "Cloud-init user account (must match ansible_user)"
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "SSH public keys injected via cloud-init"
}
```

- [ ] **Step 3: Write `main.tf`**

```hcl
resource "proxmox_virtual_environment_vm" "this" {
  name      = var.vm_name
  node_name = var.target_node
  vm_id     = var.vm_id

  clone {
    vm_id     = var.template_vm_id
    node_name = var.template_node
    full      = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.disk_datastore
    interface    = "scsi0"
    size         = var.disk_size
  }

  network_device {
    bridge  = var.network_bridge
    vlan_id = var.vlan_id
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    user_account {
      username = var.ci_username
      keys     = var.ssh_public_keys
    }
  }
}
```

- [ ] **Step 4: Write `outputs.tf`**

```hcl
output "vm_id" {
  value = proxmox_virtual_environment_vm.this.vm_id
}

output "ipv4_address" {
  value = split("/", var.ip_address)[0]
}
```

- [ ] **Step 5: Commit**

```bash
cd "C:\Users\ingar\Documents\workspace\terraform"
git add modules/
git commit -m "feat: add reusable proxmox_vm module"
```

---

## Task 3: Write the bootstrap config for the MinIO VM

**Files:**
- Create: `C:\Users\ingar\Documents\workspace\terraform\bootstrap\providers.tf`
- Create: `C:\Users\ingar\Documents\workspace\terraform\bootstrap\variables.tf`
- Create: `C:\Users\ingar\Documents\workspace\terraform\bootstrap\main.tf`
- Create: `C:\Users\ingar\Documents\workspace\terraform\bootstrap\terraform.tfvars.example`

**Interfaces:**
- Consumes: module `proxmox_vm` from Task 2 (`../modules/proxmox_vm`).
- Produces: a single VM, `vm_id = 510`, name `tf-state01`, reachable at `10.11.0.50`.

- [ ] **Step 1: Write `providers.tf`**

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66, < 1.0.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = var.proxmox_api_token
  insecure  = true
}
```

- [ ] **Step 2: Write `variables.tf`**

```hcl
variable "proxmox_api_url" {
  type        = string
  default     = "https://10.11.0.11:8006/api2/json"
  description = "Proxmox API endpoint"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token in the form user@realm!token-id=secret. Set via the TF_VAR_proxmox_api_token environment variable, sourced from the gitignored .pve_api file — do not put this in a .tfvars file."
}

variable "ssh_public_key_path" {
  type        = string
  default     = "C:/Users/ingar/.ssh/id_rsa.pub"
  description = "Path to the SSH public key injected via cloud-init"
}

variable "minio_vm_ip_address" {
  type        = string
  default     = "10.11.0.50/24"
  description = "Static IPv4 address (CIDR) for the MinIO VM"
}

variable "minio_vm_gateway" {
  type        = string
  default     = "10.11.0.1"
  description = "Default gateway for the MinIO VM's network segment — confirm this matches your actual router/gateway before applying"
}
```

- [ ] **Step 3: Write `main.tf`**

```hcl
module "minio_vm" {
  source = "../modules/proxmox_vm"

  vm_name         = "tf-state01"
  vm_id           = 510
  target_node     = "pve01"
  template_vm_id  = 101
  template_node   = "pve01"
  disk_datastore  = "vm_storage"
  network_bridge  = "vmbr0"
  ip_address      = var.minio_vm_ip_address
  gateway         = var.minio_vm_gateway
  ssh_public_keys = [file(var.ssh_public_key_path)]
}

output "minio_vm_ip" {
  value = module.minio_vm.ipv4_address
}
```

- [ ] **Step 4: Export the API token from `.pve_api` before running any `terraform` command in this directory**

```bash
export TF_VAR_proxmox_api_token=$(cat "C:\Users\ingar\Documents\workspace\terraform\.pve_api")
```

Confirm `minio_vm_gateway`'s default (`10.11.0.1`, in `variables.tf`) is correct for your network — edit the default in `variables.tf` if not (no `.tfvars` file needed since nothing else here is secret).

- [ ] **Step 5: Commit**

```bash
cd "C:\Users\ingar\Documents\workspace\terraform"
git add bootstrap/providers.tf bootstrap/variables.tf bootstrap/main.tf
git commit -m "feat: add bootstrap config for MinIO state-backend VM"
```

---

## Task 4: Apply the bootstrap config and verify the VM

**Files:** none (execution only)

**Interfaces:**
- Consumes: `bootstrap/` config from Task 3.
- Produces: a running VM reachable over SSH at `10.11.0.50` as user `user`.

- [ ] **Step 1: Initialize and validate**

```bash
cd "C:\Users\ingar\Documents\workspace\terraform\bootstrap"
terraform init
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 2: Plan and review**

```bash
terraform plan
```

Expected: a plan showing 1 resource to add (`module.minio_vm.proxmox_virtual_environment_vm.this`). Confirm the VMID (510), node (pve01), disk (vm_storage), and IP (10.11.0.50/24) all match what you expect before proceeding.

- [ ] **Step 3: Apply**

```bash
terraform apply
```

Type `yes` when prompted. Expected: `Apply complete! Resources: 1 added, 0 changed, 0 destroyed.`

- [ ] **Step 4: Verify the VM booted and cloud-init applied correctly**

```bash
ssh -o StrictHostKeyChecking=accept-new user@10.11.0.50 "hostname && whoami"
```

Expected output: `tf-state01` then `user`. If this hangs or is refused, wait ~30s for cloud-init to finish and retry — do not proceed to Task 5 until this succeeds.

---

## Task 5: Add the MinIO host to the Ansible inventory

**Files:**
- Modify: `hosts` (gitignored, real IPs — edit directly, this change is not committed)
- Modify: `inventory_public` (committed, sanitized example — keep in sync)

**Interfaces:**
- Produces: inventory group `minio_hosts` containing `10.11.0.50`.

- [ ] **Step 1: Add the group to `hosts`**

Add `minio_hosts` to the `[all:children]` block at the top, and a new section:

```ini
[minio_hosts]
10.11.0.50 # tf-state01
```

- [ ] **Step 2: Mirror the change in `inventory_public` with a placeholder IP**

Add `minio_hosts` to its `[all:children]` block, and:

```ini
[minio_hosts]
192.168.1.50
```

- [ ] **Step 3: Verify Ansible can reach the new host**

```bash
ansible -i hosts minio_hosts -m ping
```

Expected: `"ping": "pong"` from `10.11.0.50`.

- [ ] **Step 4: Commit the public inventory change only**

```bash
git add inventory_public
git commit -m "chore: add minio_hosts group to public inventory example"
```

---

## Task 6: Write the `minio` Ansible role

**Files:**
- Create: `roles/minio/defaults/main.yml`
- Create: `roles/minio/handlers/main.yml`
- Create: `roles/minio/tasks/main.yml`
- Create: `roles/minio/templates/compose-minio.yaml.j2`
- Create: `roles/minio/templates/env-minio.j2`
- Create: `group_vars/minio_hosts/vault.example.yml`
- Modify: `site.yml`

**Interfaces:**
- Consumes: `minio_root_user`, `minio_root_password` (from `group_vars/minio_hosts/vault.yml`, created locally per Step 6 below — not committed).
- Produces: a running `minio` container on `tf-state01`, API on port 9000, console on port 9001.

- [ ] **Step 1: Write `roles/minio/defaults/main.yml`**

```yaml
---
minio_dir: /opt/docker/minio
```

- [ ] **Step 2: Write `roles/minio/templates/compose-minio.yaml.j2`**

```yaml
services:
  minio:
    container_name: minio
    image: minio/minio:${COMPOSE_MINIO_IMAGE_TAG:-latest}
    command: server /data --console-address ":9001"
    restart: unless-stopped
    ports:
      - "9000:9000"
      - "9001:9001"
    env_file: .env
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    volumes:
      - minio-data:/data

volumes:
  minio-data:
```

- [ ] **Step 3: Write `roles/minio/templates/env-minio.j2`**

```
COMPOSE_MINIO_IMAGE_TAG=latest
MINIO_ROOT_USER={{ minio_root_user }}
MINIO_ROOT_PASSWORD={{ minio_root_password }}
```

- [ ] **Step 4: Write `roles/minio/tasks/main.yml`**

```yaml
---
- name: Create MinIO directory
  file:
    path: "{{ minio_dir }}"
    state: directory
    mode: '0755'

- name: Deploy MinIO Docker Compose file
  template:
    src: compose-minio.yaml.j2
    dest: "{{ minio_dir }}/compose.yaml"
    mode: '0644'
  notify: Restart MinIO

- name: Deploy MinIO .env file
  template:
    src: env-minio.j2
    dest: "{{ minio_dir }}/.env"
    mode: '0644'
  notify: Restart MinIO

- name: Allow MinIO API port
  ufw:
    rule: allow
    port: '9000'
    proto: tcp

- name: Allow MinIO Console port
  ufw:
    rule: allow
    port: '9001'
    proto: tcp

- name: Start MinIO
  community.docker.docker_compose_v2:
    project_src: "{{ minio_dir }}"
    state: present
```

- [ ] **Step 5: Write `roles/minio/handlers/main.yml`**

```yaml
---
- name: Restart MinIO
  community.docker.docker_compose_v2:
    project_src: "{{ minio_dir }}"
    state: restarted
```

- [ ] **Step 6: Write `group_vars/minio_hosts/vault.example.yml`**

```yaml
# Copy this file to vault.yml and encrypt it with ansible-vault.
minio_root_user: REPLACE_ME
minio_root_password: REPLACE_ME
```

Then, locally (not committed — matches the existing `group_vars/**/vault.yml` gitignore pattern):

```bash
mkdir -p group_vars/minio_hosts
cp group_vars/minio_hosts/vault.example.yml group_vars/minio_hosts/vault.yml
```

Edit `group_vars/minio_hosts/vault.yml` with real values, then encrypt it:

```bash
./crypt.sh
```

- [ ] **Step 7: Add the play to `site.yml`**

Append to `site.yml`:

```yaml
- name: Setup MinIO for Terraform state
  hosts: minio_hosts
  become: true
  roles:
    - docker
    - minio
```

- [ ] **Step 8: Commit**

```bash
git add roles/minio/ group_vars/minio_hosts/vault.example.yml site.yml
git commit -m "feat: add minio role for terraform state backend"
```

---

## Task 7: Run Ansible and verify MinIO is up

**Files:** none (execution only)

**Interfaces:**
- Consumes: role `minio` and play from Task 6.
- Produces: MinIO reachable at `http://10.11.0.50:9000` (API) and `http://10.11.0.50:9001` (console).

- [ ] **Step 1: Decrypt the vault for this run (if your workflow re-encrypts between runs)**

```bash
ansible-vault view group_vars/minio_hosts/vault.yml
```

Confirms the file decrypts correctly before running the play.

- [ ] **Step 2: Run the playbook against the new host**

```bash
ansible-playbook -i hosts site.yml --limit minio_hosts --ask-vault-pass
```

- [ ] **Step 3: Verify the container is running**

```bash
ssh user@10.11.0.50 "docker ps --filter name=minio --format '{{.Names}}: {{.Status}}'"
```

Expected: `minio: Up ...`

- [ ] **Step 4: Verify the API responds**

```bash
curl -sf http://10.11.0.50:9000/minio/health/live && echo OK
```

Expected: `OK` printed.

---

## Task 8: Create the Terraform state bucket in MinIO

**Files:** none (manual UI step)

**Interfaces:**
- Produces: a bucket named `tf-state` in MinIO, ready for Task 9's S3 backend.

- [ ] **Step 1: Log into the MinIO console**

Open `http://10.11.0.50:9001` in a browser, log in with the `minio_root_user` / `minio_root_password` values from `group_vars/minio_hosts/vault.yml`.

- [ ] **Step 2: Create the bucket**

Buckets → Create Bucket → name it `tf-state` → Create.

> Using the root credentials directly for Terraform's S3 backend is acceptable for this single-operator homelab bootstrap. A scoped access key with a bucket-limited policy is a reasonable future hardening step (same category as the `vault.yml`-should-be-encrypted-at-rest item flagged earlier) — not required for this plan.

---

## Task 9: Point the main fleet config at the MinIO remote state backend

**Files:**
- Create: `C:\Users\ingar\Documents\workspace\terraform\providers.tf`
- Create: `C:\Users\ingar\Documents\workspace\terraform\backend.tf`
- Create: `C:\Users\ingar\Documents\workspace\terraform\variables.tf`
- Create: `C:\Users\ingar\Documents\workspace\terraform\backend.hcl` (non-secret values only — bucket/region/endpoint; committed, since it holds no credentials)

**Interfaces:**
- Consumes: bucket `tf-state` from Task 8, module `proxmox_vm` from Task 2.
- Produces: a root Terraform config (at the repo root, sibling to `bootstrap/` and `modules/`) using remote state — this becomes the config Task 10 imports existing VMs into.

- [ ] **Step 1: Write `backend.tf`** (partial config — credentials supplied via environment variables, never committed)

```hcl
terraform {
  backend "s3" {}
}
```

- [ ] **Step 2: Write `backend.hcl`** — no secrets in this file; MinIO credentials come from `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` environment variables instead (same `.pve_api`-style pattern as the Proxmox token)

```hcl
bucket = "tf-state"
key    = "fleet/terraform.tfstate"
region = "us-east-1"

endpoints = {
  s3 = "http://10.11.0.50:9000"
}

skip_credentials_validation = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_requesting_account_id  = true
use_path_style              = true
```

- [ ] **Step 3: Write `providers.tf`** (same provider requirements as bootstrap)

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66, < 1.0.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = var.proxmox_api_token
  insecure  = true
}
```

- [ ] **Step 4: Write `variables.tf`**

```hcl
variable "proxmox_api_url" {
  type        = string
  default     = "https://10.11.0.11:8006/api2/json"
  description = "Proxmox API endpoint"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token in the form user@realm!token-id=secret. Set via TF_VAR_proxmox_api_token, sourced from .pve_api."
}

variable "ssh_public_key_path" {
  type        = string
  default     = "C:/Users/ingar/.ssh/id_rsa.pub"
  description = "Path to the SSH public key injected via cloud-init"
}
```

- [ ] **Step 5: Create a gitignored `.minio_credentials` file for the MinIO access key/secret**

Add `.minio_credentials` to `.gitignore` alongside `.pve_api`. Create the file yourself with the root credentials from Task 8 (or a scoped access key if you created one):

```bash
AWS_ACCESS_KEY_ID=<minio_root_user>
AWS_SECRET_ACCESS_KEY=<minio_root_password>
```

- [ ] **Step 6: Export both sets of credentials before running terraform in this directory**

```bash
export TF_VAR_proxmox_api_token=$(cat "C:\Users\ingar\Documents\workspace\terraform\.pve_api")
export $(cat "C:\Users\ingar\Documents\workspace\terraform\.minio_credentials" | xargs)
```

- [ ] **Step 7: Initialize with the remote backend**

```bash
cd "C:\Users\ingar\Documents\workspace\terraform"
terraform init -backend-config=backend.hcl
```

Expected: `Successfully configured the backend "s3"!` with no errors.

- [ ] **Step 8: Verify remote state works**

```bash
terraform state list
```

Expected: empty output (no error) — proves Terraform can read/write state in MinIO even though no resources are defined yet.

- [ ] **Step 9: Commit**

```bash
git add providers.tf backend.tf variables.tf backend.hcl
git commit -m "feat: configure fleet root module with MinIO-backed remote state"
```

---

## Task 10: Import existing VMs into Terraform state

**Files:**
- Create: `C:\Users\ingar\Documents\workspace\terraform\vms.tf`

**Interfaces:**
- Consumes: module `proxmox_vm` from Task 2, remote state from Task 9.
- Produces: the existing Komodo manager VM (and, repeating the same procedure, DMZ PC / Home Assistant docker host / Wazuh VM) tracked in Terraform state with zero drift.

This task is a repeatable procedure applied once per existing VM, because each VM's exact current cores/memory/disk size must be read from live Proxmox state rather than guessed. It's worked fully here for the Komodo manager (`pve-mgn01`, `10.11.0.51`); repeat Steps 1–5 for the DMZ PC (`pve-docker01`, `10.12.0.11`), the Home Assistant docker host (`pve-docker02`, `10.13.0.12`), and the Wazuh VM (`10.13.0.127`).

- [ ] **Step 1: Look up the VM's real VMID, node, and hardware specs**

In the Proxmox UI (Server View tree, same place VM 101/203/204/501/901 were visible earlier): click the VM → note its VMID and node. Then Hardware tab: note Memory (MB), Processors (cores), and the Hard Disk's storage ID + size (GB).

- [ ] **Step 2: Add a resource block to `vms.tf` using the module, with a placeholder disk size to be corrected in Step 4**

```hcl
module "komodo_manager" {
  source = "./modules/proxmox_vm"

  vm_name         = "pve-mgn01"
  vm_id           = 501
  target_node     = "pve01"
  template_vm_id  = 101
  template_node   = "pve01"
  disk_datastore  = "vm_storage"
  network_bridge  = "vmbr0"
  ip_address      = "10.11.0.51/24"
  gateway         = "10.11.0.1"
  ssh_public_keys = [file(var.ssh_public_key_path)]
  # cores, memory, disk_size: defaults (2, 2048, 20) — corrected in Step 4
  # once terraform plan shows the real values from the lookup in Step 1.
}
```

Adjust `vm_id`, `target_node`, and `ip_address` to match what Task 1's lookup actually showed if they differ from the values above.

- [ ] **Step 3: Import the existing VM into state**

```bash
cd "C:\Users\ingar\Documents\workspace\terraform"
terraform import module.komodo_manager.proxmox_virtual_environment_vm.this pve01/501
```

Expected: `Import successful!`

- [ ] **Step 4: Plan and reconcile drift**

```bash
terraform plan
```

Expected: a diff showing where the resource block's `cores`, `memory`, `disk_size` (and possibly `disk_datastore` or `network_bridge`) don't match the real VM. Edit the values in `vms.tf` to match what the plan says the *real* infrastructure has (not the other way around — the goal here is zero drift, not changing the running VM). Re-run `terraform plan` until it reports:

```
No changes. Your infrastructure matches the configuration.
```

- [ ] **Step 5: Commit**

```bash
git add vms.tf
git commit -m "feat: import pve-mgn01 (komodo manager) into terraform state"
```

- [ ] **Step 6: Repeat Steps 1–5 for the remaining three VMs**

DMZ PC (`pve-docker01`, `10.12.0.11`), Home Assistant docker host (`pve-docker02`, `10.13.0.12`), Wazuh VM (`10.13.0.127`) — each gets its own `module "..." { source = "./modules/proxmox_vm" ... }` block in `vms.tf`, its own `terraform import`, and its own plan-reconcile-commit cycle. Use each VM's real node/network bridge from the Proxmox UI — the DMZ PC in particular is likely on the `dmz` bridge seen earlier, not `vmbr0`.

- [ ] **Step 7: Final verification — full fleet has zero drift**

```bash
terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.` with all four VMs listed in `terraform state list`.
