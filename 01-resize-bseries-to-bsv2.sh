#!/usr/bin/env bash
# GROUP A: B-series (v1) -> Bsv2  | In-place resize. OS/data disks & config preserved.
# Lowest risk. Downtime ~2-5 min per VM (deallocate -> resize -> start).
# Bsv2 supports the same SCSI controller and Gen1/Gen2, so no disk conversion needed.
set -euo pipefail
RG="${RG:-myResourceGroup}"

# VM name  ->  target size
declare -A MAP=(
  [vm-b4ms]=Standard_B4s_v2
  [vm-b8ms]=Standard_B8s_v2
  [vm-b1ms]=Standard_B2ls_v2
  [vm-b1s]=Standard_B2ts_v2
  [vm-b16ms]=Standard_B16s_v2
)

for VM in "${!MAP[@]}"; do
  TARGET="${MAP[$VM]}"
  echo "==> $VM -> $TARGET"
  # Verify the target size is offered in this VM's cluster/zone before deallocating:
  if ! az vm list-vm-resize-options -g "$RG" -n "$VM" --query "[].name" -o tsv | grep -qx "$TARGET"; then
    echo "    NOTE: $TARGET not in live resize list; will rely on deallocated resize (region capacity)."
  fi
  az vm deallocate -g "$RG" -n "$VM" -o none
  az vm resize     -g "$RG" -n "$VM" --size "$TARGET" -o none
  az vm start      -g "$RG" -n "$VM" -o none
  echo "    resized & started."
  # Optional: enable Accelerated Networking (Bsv2 supports it)
  # NIC=$(az vm show -g "$RG" -n "$VM" --query "networkProfile.networkInterfaces[0].id" -o tsv)
  # az network nic update --ids "$NIC" --accelerated-networking true -o none
done
echo "Group A complete."
