#!/usr/bin/env bash
# MID-SERVER (MFG) - OPTION 2: Blue/green from snapshot. Lowest SERVICE interruption + instant rollback.
# Builds a NEW Gen2/NVMe F-series v6 VM from the OS-disk snapshot; original keeps serving until cutover.
# Use this when the F4s_v2 VM is Gen1 (V1 OS disk) and cannot resize to v6 directly.
set -euo pipefail
RG="${RG:-myResourceGroup}"
LOCATION="${LOCATION:-westeurope}"
ZONE="${ZONE:-}"   # optional, e.g. 1

# Set to "true" to keep the ORIGINAL VM name (delete old VM, recreate new with same name).
# Azure VM names are immutable, so preserving the name requires recreating the resource.
PRESERVE_NAME="${PRESERVE_NAME:-true}"

# Edit per VM you are migrating:
SRC_VM="azubw47011"
TARGET="Standard_F4als_v6"    # Standard = F4als_v6 (4/8); Enhanced (MfgTransNonProd) = Standard_F8als_v6 (8/16)
OS_SNAPSHOT="azubw47011-os-YYYYMMDD-HHMMSS"   # from 00-snapshot-all.sh

# Staging name used while the original VM is still serving traffic.
STAGE_VM="${SRC_VM}-v6"

echo "==> Creating Gen2/NVMe OS disk from snapshot $OS_SNAPSHOT"
SNAP_ID=$(az snapshot show -g "$RG" -n "$OS_SNAPSHOT" --query id -o tsv)
az disk create -g "$RG" -l "$LOCATION" -n "${SRC_VM}-osdisk-v6" \
    --source "$SNAP_ID" --hyper-v-generation V2 --sku Premium_LRS -o none

echo "==> Creating staging $TARGET VM '$STAGE_VM' from the copied OS disk (attach, no reimage)"
az vm create -g "$RG" -n "$STAGE_VM" --size "$TARGET" --location "$LOCATION" \
    ${ZONE:+--zone "$ZONE"} \
    --attach-os-disk "${SRC_VM}-osdisk-v6" --os-type Linux \
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true \
    --disk-controller-type NVMe -o none

echo "==> Staging VM up. VALIDATE the MID server on '$STAGE_VM' before cutover."

if [[ "$PRESERVE_NAME" != "true" ]]; then
  cat <<NOTE
  Cutover (keep NEW name '$STAGE_VM'):
    1. Stop the MID service on the OLD VM '$SRC_VM'.
    2. Move the private IP (reassign NIC ipconfig) OR repoint DNS / MID registration to '$STAGE_VM'.
    3. Reattach the swap/tmp data disk (detach from old, attach to new) if not snapshot-copied.
    4. Verify, then deallocate the OLD VM (keep it for a few days as rollback).
NOTE
  exit 0
fi

# ----- PRESERVE ORIGINAL NAME: delete old VM, recreate with same name on the migrated disk -----
echo "==> PRESERVE_NAME=true: cutting over while keeping the original name '$SRC_VM'"
read -r -p "    Validation passed on '$STAGE_VM'? Type YES to proceed with name-preserving cutover: " OK
[[ "$OK" == "YES" ]] || { echo "    Aborted."; exit 1; }

# 1) Free the migrated OS disk from the staging VM (delete the VM resource only; keep the disk).
echo "    Deleting staging VM resource '$STAGE_VM' (its OS disk is retained)..."
az vm delete -g "$RG" -n "$STAGE_VM" --yes -o none

# 2) Delete the OLD VM resource to free the original name (keep its disks/NIC for rollback).
echo "    Deleting OLD VM resource '$SRC_VM' to release the name (disks/NIC retained)..."
OLD_NIC=$(az vm show -g "$RG" -n "$SRC_VM" --query "networkProfile.networkInterfaces[0].id" -o tsv)
az vm delete -g "$RG" -n "$SRC_VM" --yes -o none

# 3) Recreate the VM with the ORIGINAL name, attaching the migrated v6 OS disk and the original NIC
#    (the original NIC keeps the original private IP).
echo "    Recreating '$SRC_VM' on the migrated disk + original NIC..."
az vm create -g "$RG" -n "$SRC_VM" --size "$TARGET" --location "$LOCATION" \
    ${ZONE:+--zone "$ZONE"} \
    --attach-os-disk "${SRC_VM}-osdisk-v6" --os-type Linux \
    --nics "$OLD_NIC" \
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true \
    --disk-controller-type NVMe -o none

echo "==> Done. '$SRC_VM' now runs $TARGET with its original name and private IP."
cat <<'NOTE'
  Post-cutover:
    1. Reattach the swap/tmp data disk to the recreated VM (detach from old disk set / attach by ID).
    2. Re-apply VM extensions, boot diagnostics, tags, and identities not carried by the disk/NIC.
    3. Verify the MID server registers in ServiceNow, then clean up the OLD OS disk and snapshots
       after a safe rollback window.
  Rollback: recreate the VM from the retained OLD OS disk (see 99-rollback.sh).
NOTE
