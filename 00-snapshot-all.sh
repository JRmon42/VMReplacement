#!/usr/bin/env bash
# Pre-step: take rollback snapshots of OS + data disks for every VM in the list.
# Run this BEFORE any resize/migration. Safe, non-disruptive (no downtime).
set -euo pipefail

RG="${RG:-myResourceGroup}"                 # <-- set your resource group
LOCATION="${LOCATION:-westeurope}"
VMS=( "vm-b4ms" "vm-ds11v2" "vm-ds1v2" "vm-b8ms" "vm-b1ms" "vm-b1s" "vm-b16ms" )  # <-- your VM names
STAMP="$(date +%Y%m%d-%H%M%S)"

for VM in "${VMS[@]}"; do
  echo "==> Snapshotting disks for $VM"
  OSDISK=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.managedDisk.id" -o tsv)
  az snapshot create -g "$RG" -l "$LOCATION" -n "${VM}-os-${STAMP}" \
      --source "$OSDISK" --incremental true -o none
  for DD in $(az vm show -g "$RG" -n "$VM" --query "storageProfile.dataDisks[].managedDisk.id" -o tsv); do
    DDNAME=$(basename "$DD")
    az snapshot create -g "$RG" -l "$LOCATION" -n "${DDNAME}-${STAMP}" \
        --source "$DD" --incremental true -o none
  done
  echo "    done."
done
echo "All snapshots created (suffix ${STAMP})."
