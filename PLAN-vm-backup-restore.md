# Plan: go back to restoring from normal Proxmox (PBS) VM backups

**Goal:** a broken VM is fixed by *Restore* in the Proxmox/PBS UI. No NFS gateway, no
CephFS, no "rebuild with Terraform + Ansible and hope the data is on the share".

**Why:** the 2026-10-05 power cut showed the cost. Every Docker host depends on
`nfs-gw01` -> Ganesha -> CephFS -> Ceph, all being healthy, in that order, at boot. A
stuck Ganesha (not caught by its health check) blocked all stacks, and restore means
rsync from a PBS file backup, not a one-click VM restore.

## What changes

| Today | After |
|---|---|
| Docker data on CephFS, mounted via NFS volumes | Docker data on the VM's own disk (bind mounts / local volumes) |
| Restore = `proxmox-backup-client mount` + rsync (RESTORE.md) | Restore = PBS/Proxmox UI, whole VM or single files |
| `pbs_backup` role backs up CephFS from nfs-gw01 | Proxmox backup job backs up the VMs (datastore `vm-backup`) |
| VMs are "disposable" | VMs are backed up; Terraform still creates them |

**Stays:** Ceph (RBD) for VM disks, Terraform for provisioning, Ansible roles for config,
Komodo, monitoring, PBS.

## Phase 0 - Check backups exist (before touching anything)

1. In PBS, datastore `vm-backup`: confirm a recent snapshot of every VM that will get data
   back: 201 pve-mgr01, 203 pve-proxy-dmz01, 204 pve-docker-int01.
2. Proxmox: Datacenter -> Backup. One job, all VMs (not just a list), mode **snapshot**,
   daily, QEMU guest agent enabled on each VM (gives a filesystem-frozen, consistent snapshot
   - better than today's copy-while-running for Mongo/InfluxDB/SQLite).
3. **Do a test restore** of one VM to a spare VMID and boot it. Don't decommission anything
   until this has worked.

## Phase 1 - Move data back to local disks (one host at a time)

Order: easiest/least critical first. For each host:

1. Check size: `du -sh` the export on nfs-gw01, and free space on the VM. Grow the VM disk in
   Proxmox first if needed (pve-docker-int01 was shrunk from 100G to 32G; resize before copying).
2. Stop the stack (Komodo UI or `docker compose down`).
3. `rsync -aHAX` from a temporary NFS mount into the local path (`/opt/docker/...`). Keep the
   NFS copy untouched.
4. Switch the compose file from NFS `driver_opts` to bind mounts / plain named volumes.
5. Start, verify the app has its real data (not a fresh empty install), then take a manual PBS
   backup of that VM.
6. Keep the old CephFS folder for ~1 week as a fallback.

| Order | Host | Where the compose is edited |
|---|---|---|
| 1 | 203 pve-proxy-dmz01 (NPM, 10.12.0.11) | **DONE 2026-10-05.** Compose is `compose` repo `proxymanager/compose.yaml` (bind mounts `/opt/docker/npm`); NFS vars and `nfs-common` task removed from ansible. Old NFS Docker volumes on the host still to remove, `/npm` export stays until nfs-gw01 is destroyed. |
| 2 | 201 pve-mgr01 (Komodo, 10.11.0.51) | **DONE 2026-10-06.** Mongo on bind mounts `/opt/docker/komodo/mongo-{data,config}`; template/host_vars/`nfs-common` task cleaned up. Old `komodo_mongo-*` volumes and a PBS backup still to do on the host. |
| 3 | 204 pve-docker-int01 (10.13.0.12, 11 services) | **Komodo UI**: stacks `ha` and `it_stack` (not in this repo) |
| 4 | mini01 (10.13.0.61, Z-Wave JS) | Komodo stack on mini01. **Last, after 204. Not skipped; still needs a plan.** It still mounts `/zwavejs` from nfs-gw01, so **nfs-gw01 can't be destroyed until this is done** (or the Z-Wave data is accepted as lost). |

**Gotcha - mini01 is a bare-metal PC, not a VM,** so PBS VM backups don't cover it. Pick one:
(a) back up `/opt/docker` with `proxmox-backup-client` on a timer (reuse the `pbs_backup` role
pattern, different host and datastore), or (b) accept the risk, it only holds Z-Wave JS config.

Also: Mongo/InfluxDB/SQLite need stopped containers during the rsync (as before), and the
esphome `.esphome/` cache was excluded last time - it regenerates.

## Phase 2 - Remove the NFS/CephFS layer

Only after Phase 0's test restore and ~1 week of stable running:

1. `site.yml`/`hosts.ini`: remove the `nfs_gateway` group and the `pbs_backup` and
   `nfs_gateway` roles (delete `roles/nfs_gateway`, `roles/pbs_backup`, `group_vars/nfs_gateway`).
2. Remove the NFS/Ceph client bits that were added for it (`nfs-common` in `roles/komodo`,
   `roles/npm`; the `docker-start-failed` helper in `roles/komodo/files/` if it only exists
   for NFS).
3. Firewall (UniFi): close **DMZ -> nfs-gw01:2049** (10.12.0.11) and the internal 2049 allowlist.
4. Terraform repo: destroy `nfs_gateway.tf` (VM 511). Optionally later: remove the `shared-data`
   CephFS and its pools (keep the RBD pool; VM disks use it).
5. PBS: the `cephfs-data` datastore can be pruned/removed once nothing needs it.
6. Uptime Kuma: remove the `nfs-gw01` monitor in `group_vars/uptime_kuma/main.yml`.

## Phase 3 - Docs and guardrails

- Replace `RESTORE.md` with the new procedure: PBS -> `vm-backup` -> pick VM -> Restore (or
  File Restore for single files).
- Update `Readme.md` role list (nfs_gateway, pbs_backup, npm/komodo NFS wording).
- Terraform guardrails: see the Terraform section below (`prevent_destroy`, **after** nfs-gw01 is gone).
- Boot ordering still matters (separate from this plan): Ceph being slow at boot made
  `qmstart` time out on VMs 202, 300 and 510 on 2026-10-05. Put VMs under HA `state=started`
  or add `startup order/up` delay.

## Terraform repo (`C:\Users\ingar\Documents\workspace\terraform`)

Current state: every VM comes from `modules/proxmox_vm` (clone of template 101, guest agent
already **enabled**, `ignore_changes = [clone, node_name]`) and the module also creates a
`proxmox_haresource` (`state=started`, `max_restart=3`, `max_relocate=3`) per VM. Files:
`komodo_manager.tf` (201), `dmz_pc.tf` (203), `pve_docker_int01.tf` (204), `nfs_gateway.tf` (511),
`monitoring01.tf` (512), `bootstrap/main.tf` (510 tf-state01). VMs 202 (pve-backup01) and 300
(pve-wazuh) are **not** in Terraform.

Order matters, run `terraform plan` and check it shows only what's listed before each apply.

**T1 - during Phase 1: give pve-docker-int01 room (`pve_docker_int01.tf`)**
- Raise `disk_size` from 32 (grow only; Proxmox can't shrink) to cover Docker images + the data
  that is currently in `/pve-docker-int01` (check `du -sh` on nfs-gw01 first, old VM was 100G).
  Expected plan: `1 to change` (in-place), no destroy. After apply, grow the partition and
  filesystem inside the guest (`growpart` + `resize2fs`).
- Alternative that mirrors `monitoring01.tf`: leave root at 32 and set `data_disk_size` (scsi1) for
  `/opt/docker`, so an OS rebuild can't touch the data. Costs an Ansible role to format/mount it
  (`roles/monitoring_server` already does this). Pick this if you still want the OS disposable.
- Fix the stale comments/notes in that file ("all real data lives on CephFS... fully disposable").
- 201, 203: check their disks have room for the data coming back (Mongo / NPM are small).

**T2 - Phase 2: remove the gateway**
- Delete `nfs_gateway.tf` and apply (or `terraform destroy -target=module.nfs_gateway`). This
  also removes its HA resource. Do it **before** T3, otherwise `prevent_destroy` blocks it.
- Update the example in `Readme.md` that says "copy `nfs_gateway.tf`" to point at a file that
  still exists (e.g. `dmz_pc.tf`).

**T3 - after T2: guardrails in the module**
- Add `prevent_destroy = true` to the `lifecycle` block in `modules/proxmox_vm/main.tf`. It must
  be a literal (can't be a variable), so it applies to all VMs; that's fine now that none are
  disposable. To really destroy one later, remove the line for that apply.
- Add a `startup` block (`order`, `up_delay`) to the VM resource, as variables with defaults,
  so Ceph-dependent infra (monitoring, docker hosts) starts after a delay.

**T4 - fix the autostart failure from 2026-10-05**
- The module already puts every Terraform VM under HA with `max_restart=3`. Hypothesis: HA
  retried while Ceph was still down, used up the restarts and left the VM in `error`. Verify
  before changing anything (user runs it on a node):
  `ha-manager status | grep -E "vm:(510|511|512)"`, and for 202/300 check whether they're in HA at all.
- Likely fix: raise `max_restart`/`max_relocate`, or add an HA rule so the VM keeps retrying;
  202 (pve-backup01) and 300 (pve-wazuh) are not in Terraform or (likely) HA, so add them to HA
  in Proxmox, or `terraform import` them (Wazuh was skipped on purpose earlier, so only if you
  want to).

**T5 - backup job as code (optional)**
- If the `bpg/proxmox` provider (currently 0.112.0) has a backup-job resource, define one job
  for all VMs there so new VMs are covered automatically. If not, set it once in the Proxmox UI
  (Phase 0 step 2). Verify against the provider docs before writing it.

## Later: second backup server

All backups currently live on VM 202 (pve-backup01, the PBS). Dedicated hardware for a separate
PBS server is waiting on a NIC. When it's up: add a PBS sync job from 202 to it (or a second target
in the backup job) so a lost 202 doesn't take every backup with it.

## Decisions

1. **mini01: decided, leave as is** (option b). No backup added. Phase 1 still moves its
   Z-Wave JS data off NFS, so it keeps working once the gateway is gone.
2. **nfs-gw01: decided, destroy after one week** of stable running on local disks.
3. **Still open:** drop the "disposable VM" workflow for stateful hosts (assumed above)?
   tf-state01 holds Terraform state, so it should be in the backup job too.

## Rollback

Until Phase 2, every phase is reversible: the CephFS data stays untouched, so pointing a
compose file back at the NFS volume restores the old setup.
