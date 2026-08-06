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
| 02W | `02W-upgrade-fsv2-inplace-to-v6-windows.sh` / `.ps1` | **Windows** MID servers: F4s_v2 -> F4**ald**s_v6 / F8**ald**s_v6 | In-place **Gen2 + NVMe** resize to the local-temp-disk v6 twin |
| 03W | `03W-fsv2-bluegreen-to-v6-windows.sh` | **Windows** MID servers: F4s_v2 -> F4als_v6 / F8als_v6 (no temp disk) | **Blue/green** rebuild (moves pagefile off `D:` first) |
| diagW | `diag-windows-v6-readiness.sh` | **Windows** F4s_v2 -> v6 | **READ-ONLY** readiness check (gen, firmware/GPT, BitLocker, StorNVMe, OS) |
| 11W | `11W-teams-guided-recover-and-migrate-windows.sh` | **Windows** F4s_v2 -> v6 | **Guided, gated** rollback-then-migrate for a live Teams session (per-step [OK]/[FAIL], pauses between steps) |
| 12W | `12W-teams-guided-migrate-to-f4als_v6-windows.sh` | **Windows** F4s_v2 -> **GA `F4als_v6`** (no temp disk) | **Guided, self-service** blue/green to the GA diskless size: safety snapshot -> pagefile-off-`D:` + MBR->GPT -> Gen2 flip + verify boot -> tag NVMe -> rebuild on `F4als_v6` (same name/IP) -> validate. Per-step [OK]/[FAIL], `DRYRUN=1`. Use when `F4alds_v6`/`FALDV6Series` preview is unavailable |
| 10 | `10-recover-and-upgrade.sh` | Any DSv2/Fsv2 -> v6 | **All-in-one**: rollback from a clean snapshot -> VERIFY SCSI boot -> hardened NVMe upgrade, with a printed banner per phase and PASS/FAIL per check |
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
- **WINDOWS MID servers F4s_v2 -> F-series v6:** a *Windows* VM **cannot** resize between a size
  **with** a local temp disk (`F4s_v2` has the `D:` drive) and one **without** (`F4als_v6` /
  `F8als_v6` have none). It fails with *"changing from resource disk to non-resource disk VM size
  and vice-versa is not allowed"* (https://aka.ms/AAah4sj). This is Windows-only (Linux may cross
  the boundary, which is why 02F/03F use `F4als_v6`). Recommended: Script `02W`
  (`02W-upgrade-fsv2-inplace-to-v6-windows.sh` / `.ps1`) which targets the **local-temp-disk twin**
  `Standard_F4alds_v6` / `Standard_F8alds_v6` (same vCPU/RAM as the `als` size, Gen2 + NVMe, but
  keeps a local NVMe `D:` for the pagefile) -- a "with temp disk -> with temp disk" resize that
  Windows allows, keeping the same OS disk, name and IP. If you specifically need the diskless
  `F4als_v6`, use Script `03W` (`03W-fsv2-bluegreen-to-v6-windows.sh`), which moves the pagefile
  off `D:` then **rebuilds** the VM on the diskless size from the existing OS disk.
- **`F4alds_v6` "not available to the current subscription" (RESTRICTED preview, NOT quota):**
  the local-temp-disk `Fadsv6` sizes can be gated behind the `Microsoft.Compute/FALDV6Series`
  preview, which in most subscriptions is **not self-registerable** -- `az feature register
  --namespace Microsoft.Compute --name FALDV6Series` returns `FeatureRegistrationUnsupported`
  ("does not support registration"). This is **not** a quota/vCPU limit and **cannot** be fixed by
  the subscription owner; access must be granted by Microsoft. **Preferred path:** switch the
  target to the **GA diskless `Standard_F4als_v6`** (Falsv6, already available) via the blue/green
  rebuild (`03W`) -- this avoids both the preview gate and the resource-disk in-place resize rule.
  `diag-windows-v6-readiness.sh` reports SKU availability and the `FALDV6Series` feature state.
- **Permissions to run the migration (`AuthorizationFailed`):** the operator needs **Contributor**
  on the resource group (covers `Microsoft.Compute/snapshots/write`, `disks/write`,
  `virtualMachines/write|delete|deallocate|start`, `virtualMachines/runCommand/action`, and the
  NIC actions). A narrower custom role also works, but Contributor scoped to the RG is the simplest
  least-privilege ask (it excludes RBAC/policy changes). Assign it with:
  `az role assignment create --assignee <upn-or-objectId> --role Contributor --scope /subscriptions/<sub>/resourceGroups/<rg>`.
  `12W` does a best-effort permission preflight and hard-stops if the safety snapshot cannot be created.

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
> **all installed kernels** with the `nvme nvme_core pci_hyperv hv_vmbus hv_storvsc hv_netvsc
> hv_utils` drivers (`dracut -f --regenerate-all` on RHEL/SLES, `update-initramfs -u -k all` on
> Debian/Ubuntu), sets `nvme_core.io_timeout=240`, and — when the root is on **LVM** — adds
> `rd.lvm.vg=<vg>` (the **whole** root VG, so a separate `/usr` or `/var` LV also activates) to the
> kernel cmdline via `grubby` on RHEL/BLS. It then **verifies** that the *newest* kernel's
> initramfs really contains `nvme` **and `pci_hyperv`**, that `rd.lvm.vg` is present for LVM roots,
> and that `/etc/fstab` uses UUIDs. If the guest is not NVMe-ready the script **aborts that VM
> without deallocating**, so it stays bootable on SCSI. Never skip or rush this step: a VM
> converted to an NVMe-only v6 size with an unprepared guest boots to a stuck state — on RHEL/LVM
> it drops to a *dracut emergency shell* with `system-lv_root does not exist` (portal shows
> *running*, but no SSH/console).
>
> **`pci_hyperv` is mandatory (Azure Boost vPCI):** on v6 sizes the remote NVMe disk is exposed
> through a *synthetic Hyper-V vPCI bus*. Without `pci_hyperv` in the initramfs the guest sees an
> **empty PCI bus** (`/sys/bus/pci/devices/` empty), so `/dev/nvme0n1` never appears even though
> the `nvme` driver loads — identical dracut emergency shell. RHEL's **hostonly** initramfs drops
> `pci_hyperv` when rebuilt on a SCSI VM (no vPCI device present at build time), which is why the
> scripts **force-add** it and now gate on `PCI_HYPERV=OK`.
>
> **Windows resource-disk restriction (scripts 02W / 03W):** Azure blocks a *Windows* VM from
> resizing between a "with local temp disk" size and a "without local temp disk" size in either
> direction (`OperationNotAllowed ... resource disk to non-resource disk ... not allowed`,
> https://aka.ms/AAah4sj). `F4s_v2` has a temp disk; `F4als_v6`/`F8als_v6` do not. `02W` therefore
> targets the `alds` local-temp-disk twins (`F4alds_v6`/`F8alds_v6`) so the resize stays
> "with-disk -> with-disk".
>
> **Windows Gen1 -> Gen2 needs MBR2GPT IN-GUEST (scripts 02W / 03W):** v6 sizes are **Gen2/UEFI +
> NVMe only**. A Gen1 Windows OS disk is **MBR/BIOS** and will *not* boot on a Gen2 VM — the portal
> **"Swap OS Disk"** even greys the Gen1 disk out with *"Disk generation is not compatible with VM
> generation"*. Azure does **not** convert the boot layout for you: you must run the in-box
> **`mbr2gpt /convert /allowFullOS`** inside the running Gen1 guest first (adds the EFI system
> partition), *then* `az vm update --security-type TrustedLaunch` flips the VM to Gen2/UEFI. The
> 02W/03W guest-prep now does this automatically (validate → defrag → convert), plus sets StorNVMe
> boot-start. Caveats: **Windows Server 2016 has no MBR2GPT** (upgrade the guest to 2019/2022
> first), **disable BitLocker** before converting, you **cannot extend the system volume after**
> conversion, and a VM converted to Trusted Launch/Gen2 **cannot be rolled back to Gen1** except by
> restoring the pre-conversion snapshot. Do **not** try to build a fresh marketplace Gen2 v6 VM and
> *swap in* the untouched Gen1 disk — that path is blocked by the generation mismatch.
>
> **Rollback of an already-converted VM (script 99):** once a VM is on an NVMe-only v6 size, a
> plain OS-disk *swap* back to the original SCSI disk is rejected
> (*"Swapping OS Disk is not allowed since Disk Controller Type property 'NVMe' ..."*).
> `99-rollback.sh` now detects this, then **deletes the converted VM (keeping NIC + disks) and
> recreates the original Gen1/SCSI VM** from the rollback disk on the original NIC/private IP.
> Usage: `./99-rollback.sh <VM> <SNAPSHOT> [ORIGINAL_SIZE]` (e.g. `Standard_DS1_v2`).

Always run **00** first.

### One-shot recover-and-upgrade (`10-recover-and-upgrade.sh`)

If a VM was already broken by a failed NVMe conversion (dracut emergency shell,
`system-lv_root does not exist`), use **10** to recover *and* redo the upgrade safely in a
single, fully-instrumented run. Every phase prints a `==> PHASE` banner and every check prints
`[  OK  ]` / `[ FAIL ]` with the observed value, so you always know where you are.

Flow: **rollback** from a *clean pre-edit* snapshot -> **verify** it boots on SCSI ->
**prep+verify** the guest (nvme **and pci_hyperv** in newest-kernel initramfs, `rd.lvm.vg`, fstab
UUID; aborts if not ready, VM stays on SCSI) -> **proof reboot** on SCSI with the rebuilt
initramfs -> **convert** to the v6 size + NVMe in one atomic update -> **verify** the NVMe boot
(auto-suggests rollback if it fails).

```bash
# one line:
RG=RG-RNDDEV-CFI01 VM=azurl41015 SNAPSHOT=azurl41015-os-PRE \
TARGET_SIZE=Standard_D2s_v6 ROLLBACK_SIZE=Standard_DS1_v2 \
bash 10-recover-and-upgrade.sh
```

Modes: `MODE=full` (default), `MODE=rollback-only`, `MODE=upgrade-only`. Set `DRYRUN=1` to print
the state-changing az commands without running them. **SNAPSHOT must be a snapshot taken BEFORE
any guest edit** — this is the lesson from the field failure (a snapshot captured after the guest
was modified bakes in the broken initramfs and rollback then also fails).
