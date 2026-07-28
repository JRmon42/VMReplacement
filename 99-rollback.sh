#!/usr/bin/env bash
# Rollback a VM to a pre-migration OS-disk snapshot.
#
# Handles BOTH situations:
#   A) VM is still SCSI/Gen1  -> simple in-place OS-disk swap.
#   B) VM was already converted to a v6 NVMe-only size  -> the swap is REJECTED with
#      "Swapping OS Disk is not allowed since Disk Controller Type property 'NVMe' is not
#       supported by the OS Disk ... supported ... are 'SCSI'."
#      In that case we DELETE the converted VM (keeping its NIC + disks) and RECREATE the
#      original Gen1/SCSI VM from the rollback disk, reusing the original NIC (same private IP).
#
# Usage: ./99-rollback.sh <VM> <SNAPSHOT> [ORIGINAL_SIZE]
#   ORIGINAL_SIZE defaults to $ORIG_SIZE or Standard_DS1_v2 (the pre-migration size).
set -euo pipefail
RG="${RG:-myResourceGroup}"; LOCATION="${LOCATION:-westeurope}"
VM="$1"; SNAPSHOT="$2"; ORIG_SIZE="${3:-${ORIG_SIZE:-Standard_DS1_v2}}"

SNAP_ID=$(az snapshot show -g "$RG" -n "$SNAPSHOT" --query id -o tsv)
ROLLBACK_DISK="${VM}-rollback-osdisk"

# Recreate the rollback OS disk from the snapshot (inherits the snapshot's generation = original Gen1).
if ! az disk show -g "$RG" -n "$ROLLBACK_DISK" >/dev/null 2>&1; then
  az disk create -g "$RG" -l "$LOCATION" -n "$ROLLBACK_DISK" --source "$SNAP_ID" -o none
fi

az vm deallocate -g "$RG" -n "$VM" -o none

echo "==> Attempting in-place OS-disk swap..."
if az vm update -g "$RG" -n "$VM" --os-disk "$ROLLBACK_DISK" -o none 2>/tmp/rb_err.$$; then
  az vm start -g "$RG" -n "$VM" -o none
  echo "Rolled back $VM via OS-disk swap to snapshot $SNAPSHOT."
  rm -f "/tmp/rb_err.$$"
  exit 0
fi

echo "==> Swap rejected (the VM is on an NVMe-only v6 size). Falling back to RECREATE:"
sed 's/^/    /' "/tmp/rb_err.$$" 2>/dev/null || true
rm -f "/tmp/rb_err.$$"

# Preserve the original NIC (and therefore the original private IP).
NIC=$(az vm show -g "$RG" -n "$VM" --query "networkProfile.networkInterfaces[0].id" -o tsv)

echo "    Deleting the converted VM '$VM' (its NIC and disks are retained)..."
az vm delete -g "$RG" -n "$VM" --yes -o none

echo "    Recreating the original Gen1/SCSI VM '$VM' ($ORIG_SIZE) from the rollback disk..."
az vm create -g "$RG" -n "$VM" \
    --attach-os-disk "$ROLLBACK_DISK" --os-type Linux \
    --size "$ORIG_SIZE" --nics "$NIC" -o none

echo "Rolled back $VM by recreating the original VM on snapshot $SNAPSHOT."
cat <<'NOTE'
  Post-rollback: a recreated VM does not automatically carry data-disk attachments,
  extensions, boot diagnostics, tags or managed identities. Re-apply:
    - reattach the swap/tmp (and any other) data disks,
    - re-add VM extensions and boot diagnostics,
    - re-apply tags and managed identities.
  The OS disk and NIC (private IP) are already restored, so the VM boots on SCSI as before.
NOTE
