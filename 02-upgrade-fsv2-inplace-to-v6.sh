#!/usr/bin/env bash
# MID-SERVER (MFG) - OPTION 1: In-place upgrade F4s_v2 (Gen1/SCSI) -> F-series v6 (Gen2/NVMe).
# Fixes "target size not offered in resize list" caused by a Gen1 (V1) OS disk.
# Keeps the SAME OS disk & all system-disk config. Requires Gen1->Gen2 + NVMe enablement.
# Longer downtime than a plain resize; the snapshot taken in step 0 is your rollback.
#
# NOTE: an older F4s_v2 OS disk does NOT advertise NVMe support, so a naive resize fails with
#   "Disk Controller Type property 'NVMe' is not supported by the OS image or disk ...".
# The two extra steps vs a plain resize are (a) prepare the guest OS for NVMe and
# (b) tag the OS disk's supportedCapabilities with NVMe. Both are handled below.
set -euo pipefail
RG="${RG:-myResourceGroup}"

# VM name -> target size.
#   Standard machines (4 vCPU / 8 GiB)  -> Standard_F4als_v6
#   Enhanced machines (8 vCPU / 16 GiB) -> Standard_F8als_v6
# Use the local-disk variants (F4alds_v6 / F8alds_v6) if you want built-in NVMe swap/tmp.
declare -A MAP=(
  [azubw47011]=Standard_F4als_v6
  # [azubw47012]=Standard_F8als_v6
)

for VM in "${!MAP[@]}"; do
  TARGET="${MAP[$VM]}"
  echo "==> $VM -> $TARGET (Gen2 + NVMe path)"

  OSDISK=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.name" -o tsv)
  OSDISK_ID=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.managedDisk.id" -o tsv)

  # 0) Snapshot the OS disk (instant rollback, no downtime):
  az snapshot create -g "$RG" -n "${VM}-os-$(date +%Y%m%d-%H%M%S)" \
      --source "$OSDISK_ID" --incremental true -o none

  # 1) Prepare the guest OS for NVMe AND VERIFY it before touching the VM. This is the step
  #    that, if skipped or left unverified, leaves the VM UNBOOTABLE after the switch to NVMe
  #    (portal shows "running" but there is no SSH/console because the kernel cannot mount root).
  #    Handles BOTH Debian/Ubuntu (update-initramfs) and RHEL/SLES + LVM (dracut). It:
  #      - rebuilds the initramfs for ALL installed kernels with the nvme drivers,
  #      - adds nvme_core.io_timeout=240 and, when root is on LVM, rd.lvm.lv=<vg>/<lv>
  #        (via grubby on RHEL/BLS, else /etc/default/grub) so the LVM root auto-activates,
  #      - VERIFIES the NEWEST kernel's initramfs really contains nvme, that rd.lvm.lv is present
  #        when root is LVM, and that /etc/fstab does not use /dev/sdX.
  #    If not NVMe-ready we ABORT for this VM (no deallocate) so it stays bootable on SCSI.
  #    Windows / non-Linux: use Microsoft's Azure-NVMe-Conversion.ps1 instead.
  # shellcheck disable=SC2016  # $(...) and $VARs must run inside the guest, not expand locally
  PREP_MSG=$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts '
    set -e
    # rebuild initramfs for ALL kernels with the nvme drivers
    if command -v dracut >/dev/null 2>&1; then
      echo "add_drivers+=\" nvme nvme_core \"" > /etc/dracut.conf.d/nvme.conf
      dracut -f --regenerate-all --add-drivers "nvme nvme_core"
    elif command -v update-initramfs >/dev/null 2>&1; then
      grep -q "^nvme" /etc/initramfs-tools/modules || echo nvme >> /etc/initramfs-tools/modules
      update-initramfs -u -k all
    fi
    # detect LVM root and build rd.lvm.lv=<vg>/<lv>
    ROOT_SRC=$(findmnt -no SOURCE / || true)
    RDLVM=""
    if command -v lvs >/dev/null 2>&1 && lvs "$ROOT_SRC" >/dev/null 2>&1; then
      VG=$(lvs --noheadings -o vg_name "$ROOT_SRC" | tr -d " ")
      LV=$(lvs --noheadings -o lv_name "$ROOT_SRC" | tr -d " ")
      RDLVM="rd.lvm.lv=${VG}/${LV}"
    fi
    ARGS="nvme_core.io_timeout=240 ${RDLVM}"
    # apply kernel cmdline args (grubby for RHEL/BLS, else /etc/default/grub)
    if command -v grubby >/dev/null 2>&1; then
      grubby --update-kernel=ALL --args="$ARGS" || true
    else
      for a in $ARGS; do
        grep -q "$a" /etc/default/grub || sed -i "s#\(GRUB_CMDLINE_LINUX=\"\)#\1$a #" /etc/default/grub
      done
      if command -v update-grub >/dev/null 2>&1; then update-grub
      elif [ -d /boot/grub2 ]; then grub2-mkconfig -o /boot/grub2/grub.cfg; fi
    fi
    # VERIFY the NEWEST kernel initramfs actually contains nvme
    if command -v lsinitramfs >/dev/null 2>&1; then
      IMG=$(ls -1v /boot/initrd.img-* 2>/dev/null | grep -v -- -rescue | tail -n1); LISTER=lsinitramfs
    else
      IMG=$(ls -1v /boot/initramfs-*.img 2>/dev/null | grep -v kdump | tail -n1); LISTER=lsinitrd
    fi
    NVME_INITRAMFS=MISSING
    [ -n "$IMG" ] && "$LISTER" "$IMG" 2>/dev/null | grep -q nvme && NVME_INITRAMFS=OK
    # verify rd.lvm.lv is present when root is LVM
    LVM_OK=OK
    if [ -n "$RDLVM" ]; then
      if grep -rq "rd.lvm.lv" /boot/loader/entries/ 2>/dev/null \
         || grep -q "rd.lvm.lv" /boot/grub2/grub.cfg 2>/dev/null \
         || grep -q "rd.lvm.lv" /boot/grub/grub.cfg 2>/dev/null; then LVM_OK=OK; else LVM_OK=MISSING; fi
    fi
    # fstab must not reference /dev/sdX
    FSTAB_OK=OK
    grep -Eq "^[[:space:]]*/dev/sd" /etc/fstab && FSTAB_OK=BAD
    echo "KERNEL_IMG=$IMG"
    echo "NVME_INITRAMFS=$NVME_INITRAMFS"
    echo "RDLVM=${RDLVM:-none} LVM_OK=$LVM_OK"
    echo "FSTAB_OK=$FSTAB_OK"
    if [ "$NVME_INITRAMFS" = OK ] && [ "$LVM_OK" = OK ] && [ "$FSTAB_OK" = OK ]; then echo NVME_READY=YES; else echo NVME_READY=NO; fi
    ' --query "value[0].message" -o tsv 2>/dev/null || true)
  echo "$PREP_MSG"
  if ! grep -q "NVME_READY=YES" <<<"$PREP_MSG"; then
    echo "    !! ABORT $VM: guest is NOT NVMe-ready (nvme missing from newest-kernel initramfs,"
    echo "       rd.lvm.lv missing for an LVM root, or /etc/fstab uses /dev/sdX)."
    echo "       Remediate inside the guest, then re-run. The VM was NOT deallocated and stays bootable on SCSI."
    continue
  fi

  # 2) Convert Gen1 -> Trusted Launch / Gen2 IN PLACE (no disk rebuild):
  az vm deallocate -g "$RG" -n "$VM" -o none
  az vm update -g "$RG" -n "$VM" --security-type TrustedLaunch \
      --enable-secure-boot true --enable-vtpm true -o none || {
      echo "    Trusted Launch upgrade not applicable; verify OS Gen2 readiness."; }

  # 3) Tag the OS disk as NVMe-capable (missing capability is what blocks the resize):
  az disk update -g "$RG" -n "$OSDISK" \
      --set supportedCapabilities.diskControllerTypes='SCSI, NVMe' -o none

  # 4) Resize to the F-series v6 SKU AND switch the disk controller to NVMe in a SINGLE update.
  #    NVMe cannot be set while the VM is still on a SCSI-only size (e.g. F4s_v2), so both
  #    properties must change together in the same 'az vm update' call.
  az vm update -g "$RG" -n "$VM" \
      --set hardwareProfile.vmSize="$TARGET" storageProfile.diskControllerType=NVMe -o none

  # 5) Start:
  az vm start  -g "$RG" -n "$VM" -o none
  echo "    upgraded & started. Validate boot + MID service health."
done
echo "MID-server (in-place) complete. If boot fails, restore from snapshot (see 99-rollback)."
