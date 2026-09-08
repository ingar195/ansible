# Ceph-Backed NFS-Ganesha Gateway — Implementation Notes

**Spec:** [docs/superpowers/specs/2026-09-06-terraform-ceph-komodo-design.md](../specs/2026-09-06-terraform-ceph-komodo-design.md) (Component 2)

This is a running log, not a formal bite-sized plan (unlike
[2026-09-06-terraform-foundation.md](2026-09-06-terraform-foundation.md)) — the work is being done live, one decision at a time, prompted by a real test (recreating the Komodo manager VM). Updated as we go.

## Why some steps here are manual (Proxmox Shell), not Ansible

This repo's Ansible does not manage Ceph cluster administration at all today —
`roles/proxmox` only applies firewall rules, `roles/proxmox_snapshot` only
handles VM snapshots. There's no existing pattern for "manage Ceph
auth/pools/filesystems via Ansible" here, and commands like `ceph auth
get-or-create` or `pveceph fs destroy` are one-off cluster admin actions, not
repeatable per-host config in the way Ansible roles in this repo are built.

More practically: Claude does not have root SSH access to any Proxmox node in
this session (`pve01`'s key trust broke after a reimage; `pve03` also denied
the same key when tried directly) — even a hypothetical Ansible task
targeting `proxmox_hosts` (which connects as `root`) couldn't be executed by
Claude without that access. If this is worth formalizing later, it would mean
setting up a root-capable key for Ansible/Claude against the Proxmox nodes
specifically — a separate, bigger decision than this gateway build.

## Progress so far

1. **Old `docker` CephFS removed.** It existed from an earlier abandoned
   attempt, unused for its intended purpose. Destroyed via Proxmox Shell:
   `pveceph fs destroy docker --remove-storages --remove-pools`.
2. **New CephFS `shared-data` created** via the Proxmox UI (Ceph → CephFS →
   Create CephFS), 128 PGs, registered as Proxmox storage
   (`/mnt/pve/shared-data`). Required creating a Metadata Server first
   (Ceph → CephFS → Metadata Servers → Create) since the old one was removed
   with the old filesystem.
3. **Design decision confirmed:** NFS-Ganesha will export **one subdirectory
   per host/service** (e.g. `/wazuh`, `/homeassistant`, `/komodo-manager`),
   each as a **separate NFS export** with its own client ACL — not one
   shared export mounted everywhere. This is enforced at the NFS export
   level (a host is never granted an export for a path it shouldn't see),
   not just left to Unix permissions on a shared mount.
4. **Orchestrator check:** `ceph orch status` confirmed no orchestrator is
   configured (expected — Proxmox manages Ceph natively, not via `cephadm`).
   This rules out `ceph nfs cluster create` (which needs the orchestrator to
   deploy the Ganesha daemon). Decision: run `nfs-ganesha` as a plain
   systemd service with a hand-written config instead — the traditional,
   orchestrator-independent way to export CephFS via NFS.
5. **Dedicated gateway VM created** via Terraform (not run directly on a
   Proxmox node, to keep the hypervisors themselves minimal): `nfs-gw01`,
   VMID `511`, `10.11.0.53`, same `bpg/proxmox`-cloned-from-template-101
   pipeline as every other VM in this project. Base Ansible config
   (`roles/common`) applied successfully.
6. **Ceph client credential created** for this gateway, scoped to only the
   `shared-data` filesystem (not the VM disk pool or anything else), via
   Proxmox Shell:
   ```
   ceph auth get-or-create client.nfs-gw mon 'allow r' mds 'allow rw' osd 'allow rw tag cephfs data=shared-data'
   ```
   The resulting key is stored in `group_vars/nfs_gateway/vault.yml`
   (`ceph_nfs_gw_client_name`, `ceph_nfs_gw_client_key`) — gitignored, not
   committed. `vault.example.yml` documents the shape without the real key.

## Milestone: full destroy-and-recreate test passed (2026-09-08)

The actual point of this whole Ceph/NFS effort got proven end-to-end:

1. Migrated the live Komodo manager's MongoDB data (`mongo-data`/`mongo-config`)
   onto the `/komodo-manager` NFS export, using Docker's native NFS volume
   driver (see "Resolved" section below for the `vers=4.2` fix that made
   this actually work).
2. `roles/komodo`'s `compose-manager.yaml.j2` template updated to generate
   NFS-backed volumes automatically when `komodo_nfs_server` is set
   (`host_vars/10.11.0.51.yml`) — not just a manual one-off edit.
3. **Destroyed the real VM 201 entirely** (hit and resolved a real
   Proxmox issue along the way — see "Resolved: stuck VM from a
   snapshot-delete lock" below) and **recreated it from scratch via
   Terraform** (`komodo_manager.tf`, matching the original's `x86-64-v3`
   CPU type).
4. Ran the full Ansible playbook against the fresh VM — Docker,
   `nfs-common`, and the NFS-backed compose file all deployed
   automatically, zero manual steps.
5. **Verified real data survived:** `Tag` collection returned its actual
   pre-existing document count, not zero/empty. This VM is now genuinely
   disposable — rebuilding it is a Terraform+Ansible run, not a
   restore-from-backup exercise.

### Resolved: stuck VM from a snapshot-delete lock (unrelated to CephFS/NFS)

Destroying VM 201 initially got stuck: Proxmox UI "Remove" failed with the
same `rbd: listing images failed` class of error seen with VM 510 — but
this time the underlying Ceph pool (`vm_storage`) was actually completely
healthy (`rbd ls vm_storage` succeeded cleanly at the native Ceph level,
and `rbd_directory`'s omap data was intact). The real cause: the VM was
**locked** (`qm destroy` reported `VM is locked (snapshot-delete)`) — a
snapshot-deletion operation (likely from the automated snapshot role,
`roles/proxmox_snapshot`, which manages this VM per `backup_vm_ids` in
`hosts`) had been interrupted and left a stale lock. Fix: `qm unlock 201`
then `qm destroy 201` (run on `pve02`, the node actually hosting the VM —
running `qm destroy` on the wrong node fails with a confusing "config file
does not exist" error, since `qm` isn't always cluster-aware about which
node to search). A separate, likely-unrelated `pvestatd` staleness also
appeared (Proxmox's storage-content API kept erroring after the fact) but
didn't end up blocking Terraform's own VM creation, which uses different
API calls than the diagnostic storage-content endpoint.

## Next steps (not yet done)

- Create per-host subdirectories inside the CephFS for remaining services
  (Wazuh, Home Assistant, mini_pc) and add their `EXPORT {}` blocks /
  `nfs_exports` entries, same pattern as `/komodo-manager`.
- Update `roles/komodo`'s (and future Docker-based roles') compose templates
  to use Docker's native NFS volume driver instead of plain named volumes —
  see "Docker volume → NFS pattern" below. Apply the same pattern repo-wide
  as new services move to shared storage.
- Add the NFS mount as a proper Ansible-managed step (not a manual `mount`
  command) for any host consuming an export, so a freshly recreated VM
  mounts it automatically rather than relying on someone remembering to run
  it by hand.
- **Offsite backup of CephFS data (deferred, not yet built):** VM-level
  Proxmox Backup Server jobs no longer cover this data once it's moved off a
  VM's own disk onto CephFS — a per-VM backup only backs up that VM's disk.
  The right tool is `proxmox-backup-client` (PBS's standalone client for
  backing up arbitrary directory trees, not just VM/CT images), run as a
  scheduled job (cron/systemd timer) from a host with the CephFS mounted
  (`nfs-gw01` is the natural candidate — already mounts it to serve NFS).
  Recommended: a **new dedicated PBS datastore** for this (not the existing
  VM-backup datastore), keeping shared-data backups organized separately
  with their own retention policy and a least-privilege-scoped token. Host
  to run the job from and the datastore itself still need to be decided when
  this is picked up.

## Docker volume → NFS pattern (for scaling this across many services)

Rather than bind-mounting an OS-level NFS path into each container (what was
done manually for the first Komodo manager test), use Docker's built-in
`local` volume driver's native NFS support — every service keeps its
existing `- mongo-data:/data/db`-style volume reference unchanged; only the
`volumes:` block at the bottom of the compose file gains a small
`driver_opts` addition:

```yaml
volumes:
  mongo-data:
    driver: local
    driver_opts:
      type: nfs4
      o: addr=10.11.0.53,rw,vers=4.2
      device: ":/komodo-manager/mongo-data"
```

This scales cleanly since Ansible already templates these compose files —
parameterizing `device: ":/{{ nfs_subpath }}/<volume-name>"` once makes this
the standard pattern for every Docker-based role, without restructuring
individual service mount lines each time. Still needs, per service: its own
CephFS subdirectory + Ganesha export (isolation design unchanged), and a
one-time copy of existing volume data into that path before cutover.

### Resolved: Docker's NFS volume driver needs `type: nfs4` + explicit `vers=4.2`

First attempt used `type: nfs, o: addr=...,nfsvers=4` (Docker's documented
example) and failed: `mount ... protocol not supported`. This reproduced
consistently — including via a throwaway `docker volume create` test,
isolated from the real Komodo stack, which made iterating safe. Root cause:
Docker's `local` driver issues a more minimal/raw mount than the interactive
`mount -t nfs4 ...` command (which uses the full `mount.nfs4` userspace
helper to negotiate version/transport automatically) — the driver's version
of the call needs the exact negotiated version spelled out explicitly, and
`nfsvers=4` alone wasn't enough; it had to be `vers=4.2` (matching the exact
minor version the manual mount negotiated, visible via `mount | grep
shared-data` after a manual mount). Also note: `rw` alone, without an
explicit `vers=`, appeared to get silently dropped from what Docker actually
passed to the kernel (visible in the error's `data:` field showing only
`addr=...`, missing `,rw`) — always include an explicit `vers=` when using
this pattern, don't rely on defaults.

**Working, confirmed-correct `driver_opts` for this environment:**
```yaml
    driver_opts:
      type: nfs4
      o: addr=10.11.0.53,rw,vers=4.2
      device: ":/<service>/<volume-name>"
```

**Debugging technique worth repeating:** rather than iterating on the real
compose file/containers (real downtime each attempt), test with a throwaway
volume first: `docker volume create --driver local --opt type=nfs4 --opt
o=addr=...,vers=4.2,rw --opt device=:/path testvol && docker run --rm -v
testvol:/mnt busybox ls -la /mnt` — confirms the exact `driver_opts`
combination works before touching production containers.

**Access note:** Claude got direct SSH access to `pve-mgr01` (Komodo
manager) partway through this work, once the user added a key. That host
had only password `sudo` (no passwordless sudo, unlike Terraform-created
VMs) — worked around by adding `user` to the `docker` group
(`sudo usermod -aG docker user`, one-time, user ran it themselves) so Claude
could run `docker`/`docker compose` commands directly without needing the
sudo password for every command. Writing to `/opt/docker/komodo/` itself
(root-owned) still needed the user to `chmod 777` it temporarily — worth
reverting to `750` after this kind of session.
