#!/usr/bin/env bash
# MID-SERVER (MFG) - WINDOWS - OPTION 2: Blue/green rebuild onto a NO-TEMP-DISK v6 size
# (Standard_F4als_v6 / Standard_F8als_v6). Use this ONLY if you specifically need the diskless
# 'als' size; otherwise prefer the in-place 02W path onto the 'alds' local-temp-disk twin.
#
# WHY BLUE/GREEN FOR WINDOWS DISKLESS ----------------------------------------------------------
# A *Windows* VM cannot in-place resize from a "with temp disk" size (F4s_v2, has D:) to a
# "without temp disk" size (F4als_v6, no D:) -- see https://aka.ms/AAah4sj. The supported way to
# land on the diskless size is to (a) move the pagefile OFF the temp disk so nothing depends on
# D:, then (b) REBUILD the VM on the new size from the existing OS disk (delete + recreate keeping
# the OS disk + NIC), which bypasses the resize restriction entirely.
set -euo pipefail
RG="${RG:-myResourceGroup}"
LOCATION="${LOCATION:-westeurope}"
ZONE="${ZONE:-}"                       # optional, e.g. 1
PRESERVE_NAME="${PRESERVE_NAME:-true}" # recreate with the ORIGINAL name after validation

SRC_VM="azumw57012"
TARGET="Standard_F4als_v6"             # standard = F4als_v6 (4/8); enhanced = Standard_F8als_v6 (8/16)
OS_SNAPSHOT="azumw57012-os-YYYYMMDD-HHMMSS"   # from 00-snapshot-all.sh / 02W step 0
STAGE_VM="${SRC_VM}-v6"

# 1) Move the pagefile OFF the temp disk (D:) to C: on the SOURCE guest, so the OS no longer
#    depends on the local temp disk that the diskless size removes. Then confirm NVMe boot-start.
echo "==> Preparing source guest '$SRC_VM' (move pagefile off D:, ensure StorNVMe boot-start)"
# shellcheck disable=SC2016  # the PowerShell must run inside the guest, not expand locally
PREP_MSG=$(az vm run-command invoke -g "$RG" -n "$SRC_VM" --command-id RunPowerShellScript --scripts '
  $ErrorActionPreference = "Stop"
  # Switch to a system-managed pagefile on C: only (removes any D: pagefile dependency).
  $cs = Get-CimInstance Win32_ComputerSystem
  if ($cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{AutomaticManagedPagefile=$false} }
  Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -notlike "C:*" } | Remove-CimInstance -ErrorAction SilentlyContinue
  if (-not (Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -like "C:*" })) {
    Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{Name="C:\pagefile.sys"; InitialSize=0; MaximumSize=0} | Out-Null
  }
  Write-Output "PAGEFILE=C_only"
  # Ensure StorNVMe is boot-start so the rebuilt VM boots on the NVMe controller.
  $svc = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
  if (Test-Path $svc) {
    if ((Get-ItemProperty -Path $svc -Name Start).Start -ne 0) { Set-ItemProperty -Path $svc -Name Start -Value 0 }
    Write-Output "NVME_READY=YES"
  } else { Write-Output "NVME_READY=NO" }
' --query "value[0].message" -o tsv 2>/dev/null || true)
echo "$PREP_MSG"
grep -q "NVME_READY=YES" <<<"$PREP_MSG" || { echo "    !! ABORT: StorNVMe missing/not boot-start (need WS2016+)."; exit 1; }
echo "    NOTE: reboot '$SRC_VM' once so the pagefile change takes effect BEFORE snapshotting, if you"
echo "          have not already snapshotted a pagefile-on-C: state."

echo "==> Creating Gen2/NVMe OS disk from snapshot $OS_SNAPSHOT"
SNAP_ID=$(az snapshot show -g "$RG" -n "$OS_SNAPSHOT" --query id -o tsv)
az disk create -g "$RG" -l "$LOCATION" -n "${SRC_VM}-osdisk-v6" \
    --source "$SNAP_ID" --hyper-v-generation V2 --sku Premium_LRS -o none

# Tag the copied OS disk as NVMe-capable (a disk from an old SCSI snapshot does not advertise NVMe).
az disk update -g "$RG" -n "${SRC_VM}-osdisk-v6" \
    --set supportedCapabilities.diskControllerTypes='SCSI, NVMe' -o none

echo "==> Creating staging $TARGET VM '$STAGE_VM' from the copied OS disk (Windows, NVMe)"
az vm create -g "$RG" -n "$STAGE_VM" --size "$TARGET" --location "$LOCATION" \
    ${ZONE:+--zone "$ZONE"} \
    --attach-os-disk "${SRC_VM}-osdisk-v6" --os-type Windows \
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true \
    --disk-controller-type NVMe -o none

echo "==> Staging VM up. VALIDATE the MID server on '$STAGE_VM' before cutover."

if [[ "$PRESERVE_NAME" != "true" ]]; then
  cat <<NOTE
  Cutover (keep NEW name '$STAGE_VM'):
    1. Stop the MID service on the OLD VM '$SRC_VM'.
    2. Move the private IP (reassign NIC ipconfig) OR repoint DNS / MID registration to '$STAGE_VM'.
    3. Verify, then deallocate the OLD VM (keep it for a few days as rollback).
NOTE
  exit 0
fi

# ----- PRESERVE ORIGINAL NAME: delete old VM, recreate with same name on the migrated disk -----
echo "==> PRESERVE_NAME=true: cutting over while keeping the original name '$SRC_VM'"
read -r -p "    Validation passed on '$STAGE_VM'? Type YES to proceed with name-preserving cutover: " OK
[[ "$OK" == "YES" ]] || { echo "    Aborted."; exit 1; }

echo "    Deleting staging VM resource '$STAGE_VM' (its OS disk is retained)..."
az vm delete -g "$RG" -n "$STAGE_VM" --yes -o none

echo "    Deleting OLD VM resource '$SRC_VM' to release the name (disks/NIC retained)..."
OLD_NIC=$(az vm show -g "$RG" -n "$SRC_VM" --query "networkProfile.networkInterfaces[0].id" -o tsv)
az vm delete -g "$RG" -n "$SRC_VM" --yes -o none

echo "    Recreating '$SRC_VM' on the migrated disk + original NIC..."
az vm create -g "$RG" -n "$SRC_VM" --size "$TARGET" --location "$LOCATION" \
    ${ZONE:+--zone "$ZONE"} \
    --attach-os-disk "${SRC_VM}-osdisk-v6" --os-type Windows \
    --nics "$OLD_NIC" \
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true \
    --disk-controller-type NVMe -o none

echo "==> Done. '$SRC_VM' now runs $TARGET (no temp disk) with its original name and private IP."
cat <<'NOTE'
  Post-cutover:
    1. Re-apply VM extensions, boot diagnostics, tags, and identities not carried by the disk/NIC.
    2. Verify the MID server registers in ServiceNow, then clean up the OLD OS disk and snapshots
       after a safe rollback window.
  Rollback: recreate the VM from the retained OLD OS disk (see 99-rollback.sh).
NOTE
