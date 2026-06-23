#!/usr/bin/env bash
# GROUP B - OPTION B1: In-place upgrade DSv2 (Gen1/SCSI) -> Dsv6/Esv6 (Gen2/NVMe).
# Keeps the SAME OS disk & all system-disk config. Requires Gen1->Gen2 + NVMe enablement.
# Longer downtime than a plain resize; snapshots from 00-* are your rollback.
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

  # 1) Pre-req: ensure the guest OS has NVMe drivers (modern Linux/Windows do).
  #    Tag the OS image as NVMe-supported if not already (one-time, per image).
  # 2) Convert Gen1 -> Trusted Launch / Gen2 IN PLACE (no disk rebuild):
  az vm deallocate -g "$RG" -n "$VM" -o none
  az vm update -g "$RG" -n "$VM" --security-type TrustedLaunch \
      --enable-secure-boot true --enable-vtpm true -o none || {
      echo "    Trusted Launch upgrade not applicable; verify OS Gen2 readiness."; }

  # 3) Switch disk controller to NVMe (Gen2 + NVMe-capable OS required):
  az vm update -g "$RG" -n "$VM" --set storageProfile.diskControllerType=NVMe -o none

  # 4) Resize to the v6 SKU and start:
  az vm resize -g "$RG" -n "$VM" --size "$TARGET" -o none
  az vm start  -g "$RG" -n "$VM" -o none
  echo "    upgraded & started. Validate boot + app health."
done
echo "Group B (in-place) complete. If boot fails, restore from snapshot (see 99-rollback)."
