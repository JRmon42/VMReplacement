#!/usr/bin/env bash
# MID-SERVER (MFG) - OPTION 1: In-place upgrade F4s_v2 (Gen1/SCSI) -> F-series v6 (Gen2/NVMe).
# Fixes "target size not offered in resize list" caused by a Gen1 (V1) OS disk.
# Keeps the SAME OS disk & all system-disk config. Requires Gen1->Gen2 + NVMe enablement.
# Longer downtime than a plain resize; snapshots from 00-* are your rollback.
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

  # 1) Pre-req: ensure the guest OS has NVMe drivers (modern Linux does: Ubuntu 20.04+,
  #    RHEL/Alma/Rocky 8+, SLES 15+). ServiceNow MID servers on these images are fine.
  # 2) Convert Gen1 -> Trusted Launch / Gen2 IN PLACE (no disk rebuild):
  az vm deallocate -g "$RG" -n "$VM" -o none
  az vm update -g "$RG" -n "$VM" --security-type TrustedLaunch \
      --enable-secure-boot true --enable-vtpm true -o none || {
      echo "    Trusted Launch upgrade not applicable; verify OS Gen2 readiness."; }

  # 3) Resize to the F-series v6 SKU AND switch the disk controller to NVMe in a SINGLE update.
  #    NVMe cannot be set while the VM is still on a SCSI-only size (e.g. F4s_v2), so both
  #    properties must change together in the same 'az vm update' call.
  az vm update -g "$RG" -n "$VM" \
      --set hardwareProfile.vmSize="$TARGET" storageProfile.diskControllerType=NVMe -o none

  # 4) Start:
  az vm start  -g "$RG" -n "$VM" -o none
  echo "    upgraded & started. Validate boot + MID service health."
done
echo "MID-server (in-place) complete. If boot fails, restore from snapshot (see 99-rollback)."
