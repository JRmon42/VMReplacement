#!/usr/bin/env bash
# GROUP B - OPTION B1: In-place upgrade DSv2 (Gen1/SCSI) -> Dsv6/Esv6 (Gen2/NVMe).
# Keeps the SAME OS disk & all system-disk config. Requires Gen1->Gen2 + NVMe enablement.
# Longer downtime than a plain resize; the snapshot taken in step 0 is your rollback.
#
# NOTE: an older DSv2 OS disk does NOT advertise NVMe support, so a naive resize fails with
#   "Disk Controller Type property 'NVMe' is not supported by the OS image or disk ...".
# The two extra steps vs a plain resize are (a) prepare the guest OS for NVMe and
# (b) tag the OS disk's supportedCapabilities with NVMe. Both are handled below.
set -euo pipefail
RG="${RG:-myResourceGroup}"

# VM name -> target size
declare -A MAP=(
  [vm-ds1v2]=Standard_D2s_v6
  [vm-ds11v2]=Standard_E2s_v6
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
  #    We rebuild the initramfs with the nvme driver and set the GRUB timeout, then CHECK that
  #    nvme is actually inside the initramfs and that /etc/fstab uses UUIDs. If the guest is not
  #    NVMe-ready we ABORT for this VM (no deallocate) so it stays bootable on SCSI.
  #    Windows / non-Linux: use Microsoft's Azure-NVMe-Conversion.ps1 instead.
  # shellcheck disable=SC2016  # $(...) must run inside the guest, not expand locally
  PREP_MSG=$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts '
    set -e
    if command -v update-initramfs >/dev/null 2>&1; then
      grep -q "^nvme" /etc/initramfs-tools/modules || echo nvme >> /etc/initramfs-tools/modules
      update-initramfs -u -k all
    elif command -v dracut >/dev/null 2>&1; then
      echo "add_drivers+=\" nvme \"" > /etc/dracut.conf.d/nvme.conf; dracut -f --regenerate-all
    fi
    grep -q "nvme_core.io_timeout=240" /etc/default/grub || \
      sed -i "s/\(GRUB_CMDLINE_LINUX=\"\)/\1nvme_core.io_timeout=240 /" /etc/default/grub
    if command -v update-grub >/dev/null 2>&1; then update-grub; \
    else grub2-mkconfig -o /boot/grub2/grub.cfg; fi
    NVME_IN_INITRAMFS=no
    if command -v lsinitramfs >/dev/null 2>&1; then
      lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -q nvme && NVME_IN_INITRAMFS=yes
    elif command -v lsinitrd >/dev/null 2>&1; then
      lsinitrd 2>/dev/null | grep -q nvme && NVME_IN_INITRAMFS=yes
    fi
    FSTAB_OK=yes
    grep -Eq "^[[:space:]]*/dev/sd" /etc/fstab && FSTAB_OK=no
    echo "NVME_IN_INITRAMFS=$NVME_IN_INITRAMFS"; echo "FSTAB_OK=$FSTAB_OK"
    if [ "$NVME_IN_INITRAMFS" = yes ] && [ "$FSTAB_OK" = yes ]; then echo NVME_READY=YES; else echo NVME_READY=NO; fi
    ' --query "value[0].message" -o tsv 2>/dev/null || true)
  echo "$PREP_MSG"
  if ! grep -q "NVME_READY=YES" <<<"$PREP_MSG"; then
    echo "    !! ABORT $VM: guest is NOT NVMe-ready (nvme missing from initramfs or /etc/fstab uses /dev/sdX)."
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

  # 4) Resize to the v6 SKU AND switch the disk controller to NVMe in a SINGLE update.
  #    NVMe cannot be set while the VM is still on a SCSI-only size (e.g. DSv2), so both
  #    properties must change together in the same 'az vm update' call.
  az vm update -g "$RG" -n "$VM" \
      --set hardwareProfile.vmSize="$TARGET" storageProfile.diskControllerType=NVMe -o none

  # 5) Start:
  az vm start  -g "$RG" -n "$VM" -o none
  echo "    upgraded & started. Validate boot + app health."
done
echo "Group B (in-place) complete. If boot fails, restore from snapshot (see 99-rollback)."
