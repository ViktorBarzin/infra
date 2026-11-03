# Proxmox CSI: a disk that attached "successfully" but isn't there

A pod is stuck and the cluster believes its disk is attached. It is in the VM's
config, the LVM volume is intact, an event says `SuccessfulAttachVolume` — and
the guest kernel cannot see the device. The attach half-failed.

This has happened five times: aiostreams 2026-06-27, tripit twice on
2026-07-04, roundcubemail 2026-07-06, and node5 again on 2026-07-13. Data has
never been lost. What costs time is that the obvious fix does not work.

## Two variants, and which one cleans itself up

There are two ways a slot ends up like this. Both show the same pod symptom.

| | Leaked block node (2026-11-02) | Missing device (June–July 2026) |
|---|---|---|
| Starts with | a **detach** whose `query-pci` check timed out | an **attach** whose `device_add` never reached the running qemu |
| PVE journal | `qmp command 'query-pci' failed - got timeout`, later `object-add failed - attempt to add duplicate property 'throttle-drive-scsiN'` | no duplicate-property error |
| `qm config` | slot absent | slot present |
| `qom-list /objects` | `throttle-drive-scsiN` present with no device attached | normal |
| Fixed by | `csi-leak-reconcile` on the PVE host, within ~10 minutes | the steps below |

**Leaked block node.** qemu-server 9.2.x unplugs a disk with `device_del`,
then polls QMP `query-pci` (5s timeout) before removing the block node. When
the shared HDD `sdc` is saturated, the poll times out, so the block node
`drive-scsiN` and its `throttle-drive-scsiN` object stay inside QEMU. The CSI
retries the detach; Proxmox sees the device gone and reports success, so
nothing cleans it. Every later attach that draws that slot fails with
`duplicate property`, and the CSI always draws the lowest free slot. On
2026-11-02 the k8s upgrade drains overlapped `nfs-mirror` on the same RAID
volume: 8 failed detaches left exactly 8 poisoned slots on VMs 204 and 205.

`csi-leak-reconcile` (PVE host, `playbooks/pve-host.yml` tag `csi-leak`, every
5 minutes) clears a slot once it has looked leaked on two runs in a row: a
throttle object, no config entry, no attached device, checked under the same
per-VM lock `qm set` takes. It runs the step qemu-server skipped. By hand:

```sh
echo 'drive_del drive-scsiN'           | qm monitor <vmid>
echo 'object_del throttle-drive-scsiN' | qm monitor <vmid>
```

`pve_csi_leaked_slots` and `pve_csi_leak_cleaned_total` (node_exporter on the
host) show what it found and removed; `journalctl -t csi-leak-reconcile` logs
each removal.

The rest of this runbook covers the missing-device variant.

## Recognising it

- A pod sits in `ContainerCreating` or `Init:0/N` and does not progress.
- kubelet events read
  `MountVolume.MountDevice failed … device /dev/disk/by-id/wwn-0x… is not found`.
- **And yet** `kubectl get volumeattachment` shows `attached=true`, and a
  `SuccessfulAttachVolume` event has fired. That event is not trustworthy here —
  it reports that `qm set` returned, not that the device appeared.
- cluster-health check 47 reports it as `wedged=N`, which is a different number
  from `ghosts=N`.

## Confirming it, if you want certainty before acting

The node's Proxmox VMID comes from its providerID:

```sh
kubectl get node <node> -o jsonpath='{.spec.providerID}'   # proxmox://pve/<vmid>
```

`k8s-node5` is VM 205. Then on the PVE host (`root@192.168.1.127`):

```sh
qm config <vmid> | grep scsi                     # the disk IS in the config
echo "info block" | qm monitor <vmid> | grep scsiN   # ...and ABSENT from the running qemu
lvs | grep <pvc-uuid>                            # Vwi-a = LV active and intact, data safe
```

Config has it, the live qemu does not: that is the wedge. The WWN decodes as
ASCII — `0x5056432d4944xxxx` is `PVC-IDxx`.

## What does not work

Worth stating first, because both are the natural first instinct.

- **Rescanning SCSI in the guest** (`echo "- - -" > /sys/class/scsi_host/host*/scan`).
  There is nothing on the bus to find; the device was never added to the running
  qemu process.
- **Deleting and recreating the VolumeAttachment on its own.** CSI re-runs the
  same `qm set` against the same wedged VM, hits the same failure, and fires
  `SuccessfulAttachVolume` again. This looks like progress and is not.

## What works

The wedge belongs to the **VM**, not the disk. So the fix is to get the workload
onto a different node, or to clear the VM.

**First choice — scale to zero and back.** No PVE access needed. The
external-attacher's `ControllerUnpublishVolume` removes `scsiN` from the VM
config *and* deletes the VolumeAttachment cleanly, then a fresh attach happens
on whichever node the pod lands on.

```sh
kubectl scale deploy <deployment> -n <ns> --replicas=0
kubectl scale deploy <deployment> -n <ns> --replicas=1
```

Mounted in about 22 seconds when it lands on a healthy node. Proven on
aiostreams, 2026-06-27.

**If it lands back on the wedged node**, take that node out of the running
first:

```sh
kubectl cordon <wedged-node>
kubectl delete pod <pod> -n <ns>
# ...pod lands elsewhere and mounts
kubectl uncordon <wedged-node>
```

About 90 seconds. Proven on roundcubemail, 2026-07-06. Expect a transient
`Multi-Attach error` while Kubernetes waits for the RWO detach — that is the
normal handover, not a new fault.

This is safe to do even on the wedged VM: only `device_add` was wedged, so
detaching the other, already-live volumes still works.

**The node stays wedged** until its VM reboots. Disks attach at boot, so a
reboot clears it — but it evicts everything else on that node, so it is a
maintenance-window action rather than an incident one. node5 was cleared this
way on 2026-07-13 via kured.

## Why the automatic cleanup does not catch the missing-device variant

`csi-ghost-reconcile` (namespace `proxmox-csi`, every 30 minutes) remediates
**ghosts**: a VolumeAttachment that exists while the disk is absent from the VM
config. A half-attach has both the VolumeAttachment *and* the config entry, so
it looks reconciled and the job reports `ghosts=0`.

The check that does see it compares VM config against the live qemu runtime.
That is detection only — extending the CronJob to remediate wedges is a known
gap, deliberately not taken on as of 2026-09-02 because automatically detaching
disks carries more risk than the wedge does.

## When it is more likely

On VMs near the ~28-LUN ceiling. Check 47 warns in the 20–24 band.

```sh
kubectl get volumeattachments -o json | jq -r '.items[].spec.nodeName' | sort | uniq -c | sort -rn
```

Counts on 2026-09-02: node2 19, node5 14, node4 13, node3 13, node1 4. If one
node is at the top of that band, rebalancing away from it is worth more than
any per-application protection.
