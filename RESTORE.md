# Restoring from Proxmox backups

Every important VM is backed up as a whole by Proxmox to PBS. A broken VM is fixed with
**Restore** in the Proxmox/PBS UI. No rebuild, no copying files back from a share.

## What is backed up

| Item | Value |
|---|---|
| Job | Proxmox: Datacenter -> Backup, nightly **02:00**, mode **snapshot**, ZSTD |
| Target | storage `vm-backup` on pve-backup01 (PBS, 10.11.0.31, https://10.11.0.31:8007) |
| Consistency | VMs run the QEMU guest agent, so the filesystem is frozen for the snapshot (safe for Mongo, InfluxDB and SQLite) |
| Retention | set by the prune job on PBS (check there for the current numbers) |

Covered (the job is a hand-picked list, so a **new VM must be added to it**):

| Host | IP | VM ID | Data lives in |
|---|---|---|---|
| pve-mgr01 (Komodo) | 10.11.0.51 | 201 | `/opt/docker/komodo/mongo-data`, `mongo-config`, `backups` |
| pve-proxy-dmz01 (NPM) | 10.12.0.11 | 203 | `/opt/docker/npm/data`, `/opt/docker/npm/letsencrypt` |
| pve-docker-int01 (Home Assistant, Grafana, Uptime Kuma, Z-Wave JS, ...) | 10.13.0.12 | 204 | `/opt/docker/ha/...`, `/opt/docker/itstack/...`, `/opt/docker/zwavejs2mqtt` |
| pve-wazuh | 10.13.0.127 | 300 | inside the VM |
| tf-state01 (Terraform state, MinIO) | 10.11.0.50 | 510 | inside the VM |

**Not covered:** mini01 (10.13.0.61, only holds the Z-Wave stick; its `ser2net` config is in Ansible),
monitoring01 (10.13.0.20, metrics/logs only; dashboards and alerts come from the `compose` repo),
the test VM `datacenter` (501), and pve-backup01 itself (PBS cannot back itself up; a second PBS
server is planned).

## Restore a whole VM (the normal case)

1. In Proxmox open **Datacenter -> Backup -> `vm-backup`** (or the VM -> Backup tab) and pick the snapshot.
2. If the VM is HA-managed (all Terraform-created VMs are), set its HA state to **disabled**
   (Datacenter -> HA) first, and **stop** the VM. HA would otherwise restart it during the restore.
3. Click **Restore**. Restoring over the same VM ID brings back the disk **and** the VM config
   (including its MAC address, which matters because the network has MAC-keyed rules).
4. Start the VM, then set HA back to **started**.
5. Check it came up: the Docker stacks start by themselves (`restart: unless-stopped`).
   On pve-docker-int01 also check the Zigbee dongle (`ls /dev/serial/by-id/`) and that Z-Wave JS
   still shows the controller.

You get the state at the time of the backup, so up to a day of changes can be lost.

## Restore one file or folder

1. PBS (https://10.11.0.31:8007) -> datastore **vm-backup** -> Content -> `vm/<id>` -> pick the snapshot.
2. Choose the disk (`drive-scsi0`) -> **File Restore** -> browse -> **Download**.
3. Put the file back on the host (paths in the table above), with the container stopped.
   Keep ownership as it was (Mongo uses uid 999). If you copy SQLite databases by hand
   (Home Assistant, Grafana, Uptime Kuma), stop the container first and remove stale
   `-wal`/`-shm` files, or just restore the whole VM instead.

## Run a backup now / test a restore

- Backup now: Datacenter -> Backup -> select the job -> **Run now**, or on the node
  `vzdump <vmid> --storage vm-backup --mode snapshot`.
- Test a restore (do this now and then): restore to a **spare VM ID**, remove or disable its
  network device **before the first boot** (it would clash with the live IP and MAC), check it boots,
  then delete it.

## If a VM and its backups are both gone

Rebuild the VM from the Terraform repo (it only creates the machine), configure it with
`ansible-playbook -i hosts.ini site.yml --limit <ip>`, and deploy the stacks from Komodo. The
data is **not** recreated by that: it comes only from a backup. This is why a second PBS server
(offsite or on separate hardware) matters.

## Old CephFS backups

Before the move back to local disks, `pve-docker-int01`, `pve-mgr01`, `pve-proxy-dmz01` and
`mini01` kept their data on CephFS, backed up nightly by nfs-gw01 into the PBS datastore
`cephfs-data` (until nfs-gw01 was retired). That datastore only holds old snapshots; it can be
deleted once you no longer need them.
