# Design: Terraform Provisioning + Ceph-Backed Storage + Git-Synced Komodo Stacks

## Goals

- Bring VM provisioning under version control (Terraform), matching the rigor
  Ansible already applies to configuration.
- Use the existing 3-node Ceph cluster for shared container/compose data
  instead of leaving it on each VM's local disk.
- Move Komodo compose definitions out of ad-hoc Web UI edits into git.
- Secondary goal: do this the way it would be done professionally, as a
  skill-building exercise — clear separation of concerns, remote state with
  locking, least-privilege access boundaries.

## Current State (as of this design)

- 3-node Proxmox cluster, Ceph-backed shared storage on separate drives per
  node (`hosts` inventory: `pve01`/`pve02`/`pve03`, plus `pbs01` for backup).
- VMs are cloned from existing cloud-init templates (not installed from ISO).
- Ansible (`site.yml` + roles) configures hosts post-boot: `common` hardening,
  `docker`, `komodo` (agent/manager compose deploy), `wazuh_agent`,
  `usb_ip_server`, `mini_pc`, `home_assistant` (placeholder today).
- Komodo today: compose stacks edited through the Komodo Web UI, files stored
  on each VM's local disk. No shared storage, no version control on stacks.
- Known VMs/hosts: Wazuh (1TB, `service_wazuh`), DMZ PC (`pve-docker01`,
  `komodo_nodes` agent), Komodo manager (`pve-mgn01`), Home Assistant docker
  host (`pve-docker02`), plus a physical (non-VM) mini PC running
  zwave2mqtt + USB/IP that stays out of Terraform's scope entirely.
- No Terraform/IaC exists yet for VM provisioning.

## Architecture Overview

Three layers, each with one clear owner — this mirrors how most
infrastructure teams split "what exists" from "how it's configured" from
"what runs on it":

1. **Terraform** — declares VM shape (CPU/RAM/disk/network/node placement) on
   the Proxmox/Ceph cluster, clones from existing cloud-init templates.
2. **Ansible** — configures the OS once Terraform hands it a booted VM
   (unchanged responsibility, gains one new role for NFS mounts).
3. **Komodo** — deploys compose stacks, synced from git instead of the Web UI;
   persistent data volumes point at Ceph-backed NFS instead of local disk.

## 1. Terraform for VM Provisioning

- **Provider:** `bpg/proxmox` (actively maintained, first-class cloud-init
  support), not the older Telmate provider.
- **Repo location:** a separate repo at
  `C:\Users\ingar\Documents\workspace\terraform` (currently empty, not yet a
  git repository) — kept separate from this Ansible repo, matching the
  separate-repo pattern also used for Komodo stacks below.
- **Module design:** one module parameterized by VM (name, cores, memory,
  disk size, target Proxmox node, IP/VLAN, cloud-init SSH key). Each existing
  VM (Wazuh, DMZ PC, Komodo manager, Home Assistant docker host) becomes a
  resource block calling that module. VM disks explicitly target the Ceph RBD
  storage pool so HA/live-migration keeps working exactly as it does today —
  Terraform makes this explicit instead of implicit.
- **Cloud-init → Ansible handoff:** Terraform sets hostname, static IP, and
  SSH key via cloud-init. Once applied, the new host is added to the existing
  `hosts` inventory and configured by Ansible the normal way. Auto-generating
  inventory from Terraform output is a possible future improvement, not part
  of this design.
- **State backend — bootstrap sequencing** (avoids the chicken-and-egg problem
  of needing the state backend up before Terraform can create it):
  1. A small **bootstrap** Terraform config, using local state, provisions
     one VM on the Ceph cluster to host MinIO.
  2. MinIO is deployed on that VM via Docker Compose, tracked in git (see
     Komodo git-sync below — this MinIO compose stack becomes one of the
     internal-tier stacks).
  3. All other Terraform configs (the actual VM fleet) are pointed at an S3
     backend backed by that MinIO instance, giving remote state with native
     locking.
- **Bringing existing VMs under management:** existing VMs are imported into
  Terraform state (`terraform import`) rather than recreated, so history and
  data are preserved.

## 2. Ceph-Backed Shared Storage via NFS-Ganesha

- Proxmox's Datacenter → Ceph → CephFS UI exports a CephFS as NFS (Ganesha
  gateway, built into Proxmox/Ceph — no separate NFS server to stand up).
- VMs mount the export as a normal NFS share. A new Ansible role
  (`nfs_client` or similar) installs `nfs-common` and manages the fstab
  mount — no Ceph client packages or cephx keys distributed to app VMs.
- **Trust boundary:** the NFS export is available only to the internal trust
  tier. The DMZ PC is excluded entirely — no NFS mount, keeps its own
  local/RBD-backed disk for any persistent data it needs. This preserves the
  DMZ's isolation instead of undermining it with a mount into internal shared
  storage.
- **Per-host scoping within the internal tier:** NFS/Ceph ACLs and directory
  permissions are used to limit each internal host's mount to the
  subdirectories its own stacks actually use (e.g. host A cannot read/write
  host B's data subfolder), rather than granting every internal host access
  to every other internal host's data. This is a configuration detail of the
  new Ansible role (which subpaths get mounted, and with what permissions,
  per host) — not a repo-splitting concern.
- Docker Compose stacks mount subpaths of this export for persistent volumes
  instead of bind-mounting to local VM paths.

## 3. Komodo Compose Definitions in Git

- Compose files move from Web-UI-edited/local-disk to git, synced by Komodo
  natively (Komodo's Periphery agent on whichever node runs a given stack
  clones/pulls the repo itself at deploy time — no manual per-host repo
  setup required).
- **Split by trust tier, not by stack** (avoids both "one repo per service"
  sprawl and "one repo for everything" blast-radius risk):
  - `komodo-stacks-internal` — everything except the DMZ PC (Wazuh, Home
    Assistant, the MinIO stack from part 1, etc.), one subdirectory per
    stack.
  - `komodo-stacks-dmz` — only what runs on the DMZ PC.
  - Each tier gets its own read-only, repo-scoped deploy key; the DMZ node's
    key cannot reach the internal repo even if extracted, matching the same
    trust boundary already applied to NFS access.
- **Secrets stay out of git entirely** — referenced via Komodo's built-in
  variables/secrets store or the existing Ansible vault pattern, not
  plaintext in `.env` files. This caps the blast radius of a leaked deploy
  key at topology (image names, ports, volume paths), not credentials.
- Compose files reference NFS-mounted paths (part 2) for persistent volumes.

## Rollout Order

1. Bootstrap MinIO VM (local-state Terraform config) → deploy MinIO via
   Compose.
2. Switch main Terraform configuration(s) to the MinIO-backed S3 state
   backend.
3. Set up CephFS + NFS-Ganesha export in Proxmox; configure trust-tier and
   per-host ACLs.
4. Add the Ansible `nfs_client` role; roll out to trusted internal hosts
   (not the DMZ PC).
5. Create `komodo-stacks-internal` and `komodo-stacks-dmz` repos; migrate one
   Komodo stack at a time — move its compose file to git, repoint its data
   volume at the NFS mount, verify, then proceed to the next.
6. Import existing VMs into Terraform state so the whole fleet is under
   management going forward.

## Out of Scope (deferred, not forgotten)

- Kubernetes/Rook or replacing Komodo with another orchestrator — the
  existing container platform stays; this design improves its storage and
  provisioning story without replacing it.
- Dynamic Ansible inventory generated from Terraform output.
- Terraform management of the physical (non-VM) mini PC — it stays
  Ansible-only, as today.

## Testing / Validation

- Bootstrap MinIO stack validated by a successful `terraform init` against
  the new S3 backend before any other config is migrated to it.
- NFS export validated by mounting from one non-production test host before
  rolling the Ansible role out fleet-wide.
- Each Komodo stack migration validated individually (stack starts, data
  persists across a container recreate) before moving to the next stack —
  no bulk cutover.
- DMZ isolation validated by confirming the DMZ PC cannot mount the internal
  NFS export and has no credentials for `komodo-stacks-internal`.
