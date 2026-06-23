#!/usr/bin/env bash
# Rollback: recreate an OS disk from a snapshot and swap it back onto the VM.
set -euo pipefail
RG="${RG:-myResourceGroup}"; LOCATION="${LOCATION:-westeurope}"
VM="$1"; SNAPSHOT="$2"   # usage: ./99-rollback.sh vm-ds11v2 vm-ds11v2-os-YYYYMMDD-HHMMSS
SNAP_ID=$(az snapshot show -g "$RG" -n "$SNAPSHOT" --query id -o tsv)
az disk create -g "$RG" -l "$LOCATION" -n "${VM}-rollback-osdisk" --source "$SNAP_ID" -o none
az vm deallocate -g "$RG" -n "$VM" -o none
az vm update -g "$RG" -n "$VM" --os-disk "${VM}-rollback-osdisk" -o none
az vm start -g "$RG" -n "$VM" -o none
echo "Rolled back $VM to snapshot $SNAPSHOT."
