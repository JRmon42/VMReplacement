# Azure VM Migration Scripts

Replacement of Reserved-Instance VMs with latest-generation PAYGO equivalents,
preserving all configuration stored on the system (OS) disk. Region: West Europe.

> Edit `RG`, the VM names, and (for blue/green) the snapshot names before running.
> Test in a non-production subscription first.

| # | Script | Scope | Method |
|---|--------|-------|--------|
| 00 | `00-snapshot-all.sh` | All VMs | Pre-step: incremental rollback snapshots (no downtime) |
| 01 | `01-resize-bseries-to-bsv2.sh` / `.ps1` | B4ms,B8ms,B1ms,B1s,B16ms | **In-place resize** to Bsv2 |
| 02 | `02-upgrade-dsv2-inplace-to-v6.sh` | DS1_v2, DS11_v2 | In-place **Gen1->Gen2 + NVMe** then resize to v6 |
| 03 | `03-dsv2-bluegreen-to-v6.sh` | DS1_v2, DS11_v2 | **Blue/green** from snapshot (lowest service interruption) |
| 02F | `02-upgrade-fsv2-inplace-to-v6.sh` | MID servers: F4s_v2 -> F4als_v6 / F8als_v6 | In-place **Gen1->Gen2 + NVMe** then resize to F-series v6 |
| 03F | `03-fsv2-bluegreen-to-v6.sh` | MID servers: F4s_v2 -> F4als_v6 / F8als_v6 | **Blue/green** from snapshot (lowest service interruption) |
| 99 | `99-rollback.sh` | Any | Restore OS disk from a snapshot |

## Recommended path per VM
- **B-series -> Bsv2:** Script 01. Same SCSI controller + Gen1/Gen2 support, so a plain
  resize keeps the system disk untouched. Lowest risk.
- **DS1_v2 / DS11_v2 -> v6:** v6 requires **Gen2 + NVMe**, so a plain resize is blocked.
  Use Script 02 (keep same disk) or, for near-zero downtime + instant rollback, Script 03.
- **MID servers F4s_v2 -> F-series v6 (F4als_v6 / F8als_v6):** F-series v6 requires **Gen2 + NVMe**.
  A **Gen1 (V1) OS disk hides the v6 size from the resize list** - this is the expected cause,
  not a quota/region issue. Remediate the OS disk to Gen2/NVMe first: use Script `02F`
  (`02-upgrade-fsv2-inplace-to-v6.sh`, keeps the same disk) or, for near-zero downtime +
  instant rollback, Script `03F` (`03-fsv2-bluegreen-to-v6.sh`). Enhanced (MfgTransNonProd)
  VMs target `Standard_F8als_v6`; standard VMs target `Standard_F4als_v6`.

> **In-place NVMe note (scripts 02 / 02F):** an older Gen1 OS disk does not advertise NVMe,
> so a naive resize fails with *"Disk Controller Type property 'NVMe' is not supported by the
> OS image or disk"*. The 02 scripts handle this: they (0) snapshot the OS disk, (1) prepare
> the guest OS for NVMe (nvme in initramfs, GRUB `nvme_core.io_timeout=240`, fstab UUIDs),
> (2) convert Gen1->Gen2/Trusted Launch, (3) tag the OS disk
> `supportedCapabilities.diskControllerTypes='SCSI, NVMe'`, then (4) change size + NVMe in a
> single `az vm update`. Microsoft's `Azure-NVMe-Conversion.ps1 -FixOperatingSystemSettings`
> is the supported alternative.
>
> **Blue/green NVMe note (scripts 03 / 03F and Terraform `groupB-v6-bluegreen`):** the same
> requirement applies. The OS disk copied from an old SCSI snapshot does not advertise NVMe,
> so before building the v6 VM the scripts tag it with
> `supportedCapabilities.diskControllerTypes='SCSI, NVMe'` (the Terraform config does this via
> a `null_resource` + `az disk update`). Also prepare the **source** guest OS for NVMe (script
> 02 step 1) *before* snapshotting, otherwise the new VM will not boot.
>
> **Guest verification is now enforced (scripts 02 / 02F):** step 1 rebuilds the initramfs for
> **all installed kernels** with the `nvme`/`nvme_core` drivers (`dracut -f --regenerate-all` on
> RHEL/SLES, `update-initramfs -u -k all` on Debian/Ubuntu), sets `nvme_core.io_timeout=240`, and
> — when the root is on **LVM** — adds `rd.lvm.lv=<vg>/<lv>` to the kernel cmdline (via `grubby`
> on RHEL/BLS) so the LVM root auto-activates. It then **verifies** that the *newest* kernel's
> initramfs really contains `nvme`, that `rd.lvm.lv` is present for LVM roots, and that
> `/etc/fstab` uses UUIDs. If the guest is not NVMe-ready the script **aborts that VM without
> deallocating**, so it stays bootable on SCSI. Never skip or rush this step: a VM converted to
> an NVMe-only v6 size with an unprepared guest boots to a stuck state — on RHEL/LVM it drops to
> a *dracut emergency shell* with `system-lv_root does not exist` (portal shows *running*, but no
> SSH/console).
>
> **Rollback of an already-converted VM (script 99):** once a VM is on an NVMe-only v6 size, a
> plain OS-disk *swap* back to the original SCSI disk is rejected
> (*"Swapping OS Disk is not allowed since Disk Controller Type property 'NVMe' ..."*).
> `99-rollback.sh` now detects this, then **deletes the converted VM (keeping NIC + disks) and
> recreates the original Gen1/SCSI VM** from the rollback disk on the original NIC/private IP.
> Usage: `./99-rollback.sh <VM> <SNAPSHOT> [ORIGINAL_SIZE]` (e.g. `Standard_DS1_v2`).

Always run **00** first.
