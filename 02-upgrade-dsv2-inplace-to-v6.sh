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

  # 1) Prepare the guest OS for NVMe (nvme in initramfs, GRUB timeout). Do this while running.
  #    Windows / non-Linux: adapt or use Microsoft's Azure-NVMe-Conversion.ps1 instead.
  #    Also ensure /etc/fstab uses UUIDs (not /dev/sdX) before rebooting on NVMe.
  az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts '
    set -e
    if command -v update-initramfs >/dev/null 2>&1; then
      grep -q "^nvme" /etc/initramfs-tools/modules || echo nvme >> /etc/initramfs-tools/modules
      update-initramfs -u
    elif command -v dracut >/dev/null 2>&1; then
      echo "add_drivers+=\" nvme \"" > /etc/dracut.conf.d/nvme.conf; dracut -f
    fi
    grep -q "nvme_core.io_timeout=240" /etc/default/grub || \
      sed -i "s/\(GRUB_CMDLINE_LINUX=\"\)/\1nvme_core.io_timeout=240 /" /etc/default/grub
    if command -v update-grub >/dev/null 2>&1; then update-grub; \
    else grub2-mkconfig -o /boot/grub2/grub.cfg; fi
    grep -Eq "^[[:space:]]*/dev/sd" /etc/fstab && echo "WARN: /etc/fstab uses /dev/sdX - convert to UUID" || true
    echo "OS NVMe prep done"' -o none || {
      echo "    OS prep run-command failed; verify NVMe readiness manually."; }

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
