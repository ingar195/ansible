# Restoring files from the CephFS backup

Everything on the shared CephFS (`shared-data`) — Komodo's Mongo, Home Assistant,
NPM, Z-Wave JS, the pve-docker-int01 stacks — is backed up nightly at 02:00 by
`nfs-gw01` (`10.11.0.53`) to PBS (`10.11.0.31`, datastore `cephfs-data`).

## Small stuff (a file or a folder): use the PBS web UI

1. Open PBS → Datastore **cephfs-data** → **Content**.
2. Expand `host/cephfs-shared-data`, pick the snapshot (date) you want.
3. Select `shared-data.pxar` → **File Restore**.
4. Browse to the file/folder → **Download**.
5. Copy it back to where it belongs (e.g. `scp` it to the Docker host and into
   the container's volume, or use the steps below to put it straight into CephFS).

## Bigger restore (a whole service folder)

All on `nfs-gw01`, as root:

```bash
ssh user@10.11.0.53
sudo -i
set -a; . /etc/pbs-backup.env; set +a
```

**1. Find the snapshot:**

```bash
proxmox-backup-client snapshot list
```

**2. Mount it (read-only):**

```bash
mkdir -p /mnt/pbs-restore
proxmox-backup-client mount host/cephfs-shared-data/<time> shared-data.pxar /mnt/pbs-restore
```

Paths inside match CephFS, e.g. `/mnt/pbs-restore/komodo-manager/mongo-data`,
`/mnt/pbs-restore/pve-docker-int01/ha/ha`, `/mnt/pbs-restore/npm/data`.

**3. Mount CephFS writable** (`/mnt/cephfs-backup` is read-only on purpose):

```bash
mkdir -p /mnt/cephfs-rw
ceph-fuse --id nfs-gw /mnt/cephfs-rw
```

**4. Stop the service that uses the folder** (in Komodo, or `docker compose down`
on its host) so nothing writes while you copy.

**5. Copy back:**

```bash
# Make the folder identical to the backup (removes files not in the backup):
rsync -aHAX --delete /mnt/pbs-restore/<path>/ /mnt/cephfs-rw/<path>/

# Or just put back/overwrite files, keeping anything newer:
rsync -aHAX /mnt/pbs-restore/<path>/ /mnt/cephfs-rw/<path>/
```

Keep the trailing `/` on both paths.

**6. Clean up and start the service again:**

```bash
umount /mnt/pbs-restore /mnt/cephfs-rw
```

## Good to know

- **Databases** (Komodo Mongo, InfluxDB, SQLite in NPM / Uptime Kuma / Home
  Assistant) are copied while running, so a restored copy may need a repair or
  be slightly inconsistent. Config folders restore cleanly.
- **Check the backup actually has data:** `proxmox-backup-client snapshot list`
  shows the size — a tiny snapshot means the CephFS mount wasn't there.
- **Run a backup right now:** `sudo systemctl start pbs-backup.service`
  (on `nfs-gw01`), then `sudo journalctl -u pbs-backup.service -n 30`.
