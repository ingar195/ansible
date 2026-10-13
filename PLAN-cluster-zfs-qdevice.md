# Plan: Ceph to local ZFS + replication, 4 nodes + QDevice

Goal: drop Ceph/CephFS/NFS, run VMs on local ZFS with replication every minute
(up to 1 minute of data loss is accepted, it is a home lab), survive any 2
machines failing, and fix the iowait caused by pve01's slow drive.

Commands are run by you in the UI or shell on the Proxmox hosts. Claude does not
touch pve01-03 unasked (see memory: no direct access to hypervisors).

## Target

| Machine | Role | Votes |
|---|---|---|
| pve01 (10.11.0.11) | VM node, ZFS pool `vm_pool` | 1 |
| pve02 (10.11.0.12) | VM node, ZFS pool `vm_pool` | 1 |
| pve03 (10.11.0.13) | VM node, ZFS pool `vm_pool` | 1 |
| New PC | 4th node, runs the PBS VMs only | 1 |
| Dedicated mini PC | QDevice (`corosync-qnetd`), outside the cluster | 1 |

5 votes, quorum 3, so any 2 can fail. mini01 stays on Z-Wave, the Asus and the
Dell are spares.

Pool name is `vm_pool` on **every** node: replication only works between
storages with the same ID.

## How it works

Each VM runs on one node and has a replication job to both other nodes (every
1 minute). Every node holds its own VMs plus a replica of the others. When a
node dies, HA restarts its VMs on a survivor that has the replica; replication
reverses direction by itself.

## Approach (option A): consolidate on pve02, then rebuild the others

Ceph cannot lose a second OSD while it holds VM disks (2 OSDs left, `min_size 2`,
I/O would stop). So all VM disks go onto pve02's `vm_pool` first, Ceph is then
destroyed completely, `vm_pool` is created on pve01 and pve03, and the VMs move
back. One big copy, one clear window, no limping Ceph.

Costs: a single live copy (plus PBS backups) while everything sits on pve02, and
the RAM limit below.

### RAM check (2026-10-11)

pve02 has 23 GB RAM and 8 threads (about 7 GB used by the host + pve-backup01).
Running VMs, configured RAM:

| Host | VMs |
|---|---|
| pve01 | pve-proxy-dmz01 (203, 2 GB), pve-wazuh (300, 8 GB), datacenter (501, 2 GB), tf-state01 (510, 2 GB), monitoring01 (512, 8 GB) |
| pve02 | pve-backup01 (202, 2 GB) |
| pve03 | pve-mgr01 (201, 2 GB), pve-docker-int01 (204, 8 GB) |
| stopped | nfs-gw01 (511), to be destroyed |

All of it is 34 GB configured. With pve-wazuh (300) stopped it is about 26 GB,
still over, but guests rarely use their full RAM. If pve02 runs short, also stop
monitoring01 (512) (8 GB) for the window. Check `free -h` on pve02 after each
VM arrives.

## Facts (checked 2026-10-08/11)

- Ceph: osd.1 (pve02) already removed, 2 OSDs left (osd.0 pve01 Intel
  SSDPEMKF010T8, slow at about 21 ms; osd.2 pve03), pools `vm_storage` (RBD,
  about 450 GB) and `shared-data` (CephFS). Health: degraded, 2 of 3 copies.
- pve02 `vm_pool`: ONLINE, single KIOXIA KXG80ZNV1T02 (serial Z3MC14TLEFOK),
  compression on, ashift 12, about 967 GB free.
- pve02 also has `storage_pool`, a single 6 TB HDD ZFS pool (pve02 only), which
  holds pve-backup01 (202)'s 1000 GB data disk. Not part of this plan.
- HA resources: vm:201, vm:203, vm:204, vm:501, vm:512. vm:300 is not HA.
- Drives: all consumer NVMe, no power-loss protection. Wear: pve03 KIOXIA 47%,
  pve01 Toshiba 256 GB (OS) 48%, others 5-21%. Monitoring and alerts for this
  are in the compose repo (pc-health dashboard, rules-smart.yaml).
- Proxmox only clones a template to another node if its disk is on shared
  storage; Terraform clones template (101) across nodes today.

## Status

- [x] pve02: osd.1 destroyed, `vm_pool` created (2026-10-11).
- [x] pve-wazuh (300) shut down (2026-10-11) to free RAM. Start it again at the
      end of step 5.
- [ ] Everything else below.

## Step 0 - Before starting

- Last PBS backups of every VM succeeded (check, do not trust).
- Remove the HA services so HA does not move VMs back while you work:

```bash
ha-manager remove vm:201
```

  (repeat for vm:203, vm:204, vm:501, vm:512; note their state, all `started`).
- Stop nfs-gw01 (511) for good: it is the only user of CephFS (see
  `PLAN-vm-backup-restore.md` for removing the role and the firewall rule).

## Step 1 - pve-backup01 (202) disk to vm_pool

VM 202 -> Hardware -> `scsi0` (32 GB) -> Disk Action -> Move Storage ->
`vm_pool`, Delete source ticked (works while running). Leave the 1000 GB disk on
`storage_pool`.

## Step 2 - Move the VMs to pve02

One at a time, smallest first, each: Migrate -> target pve02 (online, instant
since the disk is on shared Ceph), then Hardware -> disk -> Move Storage ->
`vm_pool`, Delete source ticked, online. Check `free -h` and `zpool list` on
pve02 after each.

Order: pve-proxy-dmz01 (203), datacenter (501), tf-state01 (510), pve-mgr01
(201), pve-docker-int01 (204), monitoring01 (512), pve-wazuh (300, stopped,
232 GB, move offline).

Also move template (101) and template-debian (103) to `vm_pool` (they live on
pve02, so only the storage changes). Afterwards `vm_storage` must be empty:

```bash
rbd ls vm_storage
```

Expect no output. Do not continue until it is.

## Step 3 - Destroy Ceph

Only after step 2 is verified:

1. Remove the CephFS: Datacenter -> Storage -> delete `shared-data`, then on a
   node `pveceph fs destroy shared-data --remove-storages --remove-pools`.
2. Remove the RBD storage `vm_storage` and its pool.
3. Destroy osd.0 (pve01) and osd.2 (pve03): Ceph -> OSD -> Out, Stop, Destroy
   with Cleanup. Then the MDS, mgr and mons, and `pveceph purge` on each node.

Result: pve01's Intel NVMe and pve03's KIOXIA are free.

## Step 4 - Pools on pve01 and pve03

On each: Disks -> ZFS -> Create: ZFS, name `vm_pool`, RAID Single Disk,
compression on, ashift 12, Add Storage ticked. Then Datacenter -> Storage ->
`vm_pool` -> edit nodes to include all three.

## Step 5 - Move the VMs back

Per VM: Migrate -> target node, tick "Target storage" `vm_pool` (online, local
disks are copied). Original placement:

| Node | VMs |
|---|---|
| pve01 | pve-proxy-dmz01 (203), pve-wazuh (300), datacenter (501), tf-state01 (510), monitoring01 (512) |
| pve02 | pve-backup01 (202) |
| pve03 | pve-mgr01 (201), pve-docker-int01 (204) |

Pin the MAC of VMs on MAC-keyed segments if anything goes unreachable (see the
Terraform `mac_address` variable). Start pve-wazuh (300) again.

## Step 6 - Replication and HA

Datacenter -> Replication -> Add, per VM: both other nodes, schedule `*/1`. Or:

```bash
pvesr create-local-job <vmid>-0 <target-node> --schedule '*/1'
```

Datacenter -> HA -> Resources: add each VM again, state started. Restrict HA to
the three VM nodes so nothing is scheduled on the new PC.

Test: shut one node down and confirm its VMs restart elsewhere.

## Step 7 - New PC and QDevice (any time after step 4)

New PC: install Proxmox VE 9 (same major version), join with Datacenter ->
Cluster -> Join Cluster. Create the PBS VMs there, pinned, not in HA, not in
replication, datastore disk passed through:

```bash
qm set <vmid> -scsi1 /dev/disk/by-id/<disk-id>
```

QDevice on the mini PC (Debian 13, fixed IP on 10.11.0.x):

```bash
apt install corosync-qnetd
```

```bash
apt install corosync-qdevice
```

(second command on every cluster node), then from one cluster node:

```bash
pvecm qdevice setup <mini-ip>
```

Check `pvecm status`: `Flags: Quorate Qdevice`, 5 votes, quorum 3. If the mini PC
is on another subnet, open TCP 5403 from all nodes to it.

## Step 8 - Cleanup

- Templates: decide how Terraform clones now that Ceph is gone (a template per
  node, or clone on the template's node and migrate).
- Remove `nfs-gw01` and the `pbs_backup` role, and the DMZ -> nfs-gw01 firewall
  rule.
- Update `RESTORE.md`, Terraform storage IDs (`vm_storage` -> `vm_pool`) and
  module defaults.
- Add a monitoring check for the QDevice flag and `pvesr status`.

## Risks

- One live copy of every VM (plus PBS) while all disks sit on pve02, from step 1
  until the pools exist on pve01/pve03 (step 4) and the VMs are copied back.
- Ceph is already degraded (2 of 3 copies): if pve01 or pve03 goes down before
  step 2 is done, Ceph I/O stops until it is back. Keep that window short.
- pve02's RAM (23 GB) is below the configured total; watch it in step 2.
- Failover loses up to the replication interval (1 minute).
- Each pool is a single NVMe with no mirror; the replica and PBS are the
  redundancy. pve03's 47% worn KIOXIA is the next drive to replace.
- Disk space: replicating every VM to both other nodes means each node holds
  all VMs (about 450 GB today against about 900 GB per pool).
- QDevice host down: back to 4 votes, one failure survivable.

## Open questions

- Which mini PC is the QDevice, and on which switch/power?
- Network for the new PC (onboard NIC or USB Realtek 0bda:8156)?
- Friends: PBS clients or plain files? Decides what `pbs-friends` really is.
