#!/usr/bin/env bash
# MID-SERVER (MFG) - WINDOWS - OPTION 1: In-place upgrade F4s_v2 (SCSI) -> F-series v6 (NVMe),
# targeting the LOCAL-TEMP-DISK variant Standard_F4alds_v6 / Standard_F8alds_v6.
#
# WHY A DIFFERENT TARGET FOR WINDOWS ------------------------------------------------------------
# F4s_v2 HAS a local temp disk (the D: drive). F4als_v6 / F8als_v6 have NO local temp disk.
# Azure does NOT allow a *Windows* VM to resize between a "with temp disk" size and a
# "without temp disk" size (either direction). The attempt fails with:
#   (OperationNotAllowed) Unable to resize the VM '<name>' since changing from resource disk to
#   non-resource disk VM size and vice-versa is not allowed.  ->  https://aka.ms/AAah4sj
# (This restriction is Windows-only; Linux VMs may cross the boundary, which is why the RHEL MID
#  servers accepted F4als_v6 with scripts 02F/03F.)
#
# FIX: target the temp-disk twin -- Standard_F4alds_v6 (4 vCPU / 8 GiB) or Standard_F8alds_v6
# (8 vCPU / 16 GiB). Same CPU/RAM as F4als_v6/F8als_v6, on Gen2 + NVMe, but WITH a local NVMe
# temp disk, so the transition is "with temp disk -> with temp disk" (allowed) and the D: drive
# (pagefile/scratch) is preserved. Same OS disk, name and private IP are kept.
#
# The snapshot taken in step 0 is your rollback.
set -euo pipefail
RG="${RG:-myResourceGroup}"

# VM name -> target size (use the *alds* local-temp-disk variants for Windows).
#   Standard machines (4 vCPU / 8 GiB)  -> Standard_F4alds_v6
#   Enhanced machines (8 vCPU / 16 GiB) -> Standard_F8alds_v6
declare -A MAP=(
  [azumw57012]=Standard_F4alds_v6
  # [azumw57013]=Standard_F8alds_v6
)

for VM in "${!MAP[@]}"; do
  TARGET="${MAP[$VM]}"
  echo "==> $VM -> $TARGET (Windows, Gen2 + NVMe, local-temp-disk variant)"

  OSDISK=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.name" -o tsv)
  OSDISK_ID=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.managedDisk.id" -o tsv)

  # 0) Snapshot the OS disk (instant rollback, no downtime):
  az snapshot create -g "$RG" -n "${VM}-os-$(date +%Y%m%d-%H%M%S)" \
      --source "$OSDISK_ID" --incremental true -o none

  # 1) Prepare + VERIFY the Windows guest for NVMe BEFORE touching the VM. Unlike Linux there is
  #    no initramfs to rebuild: Windows Server 2016+ ships the in-box StorNVMe driver. The only
  #    requirement is that StorNVMe is a BOOT-START driver (Start=0) so Windows can boot from the
  #    NVMe controller. We set it if needed and abort if the driver is absent (older OS). Because
  #    the target KEEPS a local temp disk, the pagefile on D: does NOT need to be moved.
  # shellcheck disable=SC2016  # the PowerShell must run inside the guest, not expand locally
  PREP_MSG=$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts '
    $ErrorActionPreference = "Stop"
    $svc = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
    if (Test-Path $svc) {
      $start = (Get-ItemProperty -Path $svc -Name Start -ErrorAction SilentlyContinue).Start
      if ($start -ne 0) {
        Set-ItemProperty -Path $svc -Name Start -Value 0
        Write-Output "STORNVME=SET_BOOT"
      } else {
        Write-Output "STORNVME=OK"
      }
    } else {
      Write-Output "STORNVME=MISSING"
    }
    $fw = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
    Write-Output ("FIRMWARE=" + $(if ($fw -eq 2) {"UEFI"} elseif ($fw -eq 1) {"BIOS"} else {"UNKNOWN"}))
    Write-Output ("OS=" + (Get-CimInstance Win32_OperatingSystem).Caption)
    if ((Test-Path $svc) -and ((Get-ItemProperty -Path $svc -Name Start).Start -eq 0)) { Write-Output "NVME_READY=YES" } else { Write-Output "NVME_READY=NO" }
  ' --query "value[0].message" -o tsv 2>/dev/null || true)
  echo "$PREP_MSG"
  if ! grep -q "NVME_READY=YES" <<<"$PREP_MSG"; then
    echo "    !! ABORT $VM: StorNVMe driver missing/not boot-start. Use a WS2016+ image or install"
    echo "       the in-box NVMe driver, then re-run. The VM was NOT deallocated (stays on SCSI)."
    continue
  fi

  # 2) Deallocate (the disk-controller type cannot change on a running VM):
  az vm deallocate -g "$RG" -n "$VM" -o none

  # 3) Convert Gen1 -> Trusted Launch / Gen2 IN PLACE if not already Gen2 (no disk rebuild).
  #    If the VM/disk is already Gen2 this is a no-op; failures here are non-fatal (already Gen2).
  GEN=$(az disk show -g "$RG" -n "$OSDISK" --query hyperVGeneration -o tsv 2>/dev/null || echo "")
  if [[ "$GEN" != "V2" ]]; then
    az vm update -g "$RG" -n "$VM" --security-type TrustedLaunch \
        --enable-secure-boot true --enable-vtpm true -o none || {
        echo "    NOTE: Gen1->Gen2/Trusted Launch conversion not applied; ensure the disk is Gen2 (V2)."; }
  fi

  # 4) Tag the OS disk as NVMe-capable (a disk that only advertises SCSI blocks the NVMe switch):
  az disk update -g "$RG" -n "$OSDISK" \
      --set supportedCapabilities.diskControllerTypes='SCSI, NVMe' -o none

  # 5) Resize to the F-series v6 SKU AND switch the disk controller to NVMe in a SINGLE update.
  #    NVMe cannot be set while the VM is still on a SCSI-only size (F4s_v2), so both properties
  #    must change together in the same 'az vm update' call.
  az vm update -g "$RG" -n "$VM" \
      --set hardwareProfile.vmSize="$TARGET" storageProfile.diskControllerType=NVMe -o none

  # 6) Start and validate:
  az vm start -g "$RG" -n "$VM" -o none
  az vm show  -g "$RG" -n "$VM" -d \
      --query "{size:hardwareProfile.vmSize,ctrl:storageProfile.diskControllerType,power:powerState}" -o table
  echo "    upgraded & started. Confirm the D: temp drive is present and the MID service registers in ServiceNow."
done
echo "MID-server (Windows in-place) complete. If boot fails, restore from snapshot (see 99-rollback)."
