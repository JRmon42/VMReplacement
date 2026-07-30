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

  # 1) Prepare + VERIFY the Windows guest BEFORE touching the VM. Two things are required:
  #    (a) Gen1 -> Gen2 boot conversion: a Gen1 Windows OS disk is MBR/BIOS, but v6 sizes are
  #        Gen2/UEFI-only. The guest OS volume must be converted MBR->GPT (+ EFI system partition)
  #        with the in-box MBR2GPT.exe *while still running on the Gen1 VM*. Azure does NOT do this
  #        automatically -- the later 'az vm update --security-type TrustedLaunch' only flips the
  #        VM to Gen2/UEFI and REQUIRES the disk to already be GPT/EFI, otherwise it will not boot.
  #        (Windows Server 2016 has no MBR2GPT -> upgrade the guest to 2019/2022 first.)
  #        Disable BitLocker before conversion; you cannot extend the system volume afterwards.
  #    (b) NVMe boot: Windows Server 2019+ ships the in-box StorNVMe driver; it must be BOOT-START
  #        (Start=0) so Windows boots on the NVMe controller.
  #    IMPORTANT: once converted to Trusted Launch/Gen2 a VM cannot be rolled back to Gen1 except by
  #    restoring the step-0 snapshot -- so the snapshot above is mandatory.
  # shellcheck disable=SC2016  # the PowerShell must run inside the guest, not expand locally
  PREP_MSG=$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts '
    $ErrorActionPreference = "Stop"
    Write-Output ("OS=" + (Get-CimInstance Win32_OperatingSystem).Caption)
    # (a) Gen1(MBR/BIOS) -> GPT/EFI conversion, only if the guest is not already UEFI/GPT.
    $fw = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
    if ($fw -eq 2) {
      Write-Output "MBR2GPT=ALREADY_GPT"
    } else {
      $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
      if ($bl -and $bl.ProtectionStatus -eq "On") { Write-Output "MBR2GPT=BITLOCKER_ON" }
      else {
        Defrag C: /U 2>&1 | Out-Null
        & "$env:SystemRoot\System32\mbr2gpt.exe" /validate /allowFullOS 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Output "MBR2GPT=VALIDATE_FAIL" }
        else {
          & "$env:SystemRoot\System32\mbr2gpt.exe" /convert /allowFullOS 2>&1 | Out-Null
          if ($LASTEXITCODE -ne 0) { Write-Output "MBR2GPT=CONVERT_FAIL" } else { Write-Output "MBR2GPT=CONVERTED" }
        }
      }
    }
    # (b) StorNVMe must be boot-start.
    $svc = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
    if (Test-Path $svc) {
      if ((Get-ItemProperty -Path $svc -Name Start).Start -ne 0) { Set-ItemProperty -Path $svc -Name Start -Value 0 }
      Write-Output "STORNVME=OK"
    } else { Write-Output "STORNVME=MISSING" }
    $ok = ((Test-Path $svc) -and ((Get-ItemProperty -Path $svc -Name Start).Start -eq 0))
    Write-Output ("READY=" + $(if ($ok) {"YES"} else {"NO"}))
  ' --query "value[0].message" -o tsv 2>/dev/null || true)
  echo "$PREP_MSG"
  if grep -qE "MBR2GPT=(BITLOCKER_ON|VALIDATE_FAIL|CONVERT_FAIL)" <<<"$PREP_MSG"; then
    echo "    !! ABORT $VM: Gen1->Gen2 (MBR2GPT) prerequisite failed."
    echo "       - BITLOCKER_ON: disable BitLocker on C:, then re-run."
    echo "       - VALIDATE_FAIL: WS2016 has no MBR2GPT (upgrade guest to 2019/2022), or free space"
    echo "         at end of the system partition (run 'Defrag C: /U /V'), then re-run."
    echo "       The VM was NOT deallocated (stays bootable on Gen1/SCSI)."
    continue
  fi
  if ! grep -q "READY=YES" <<<"$PREP_MSG"; then
    echo "    !! ABORT $VM: StorNVMe driver missing/not boot-start. Use a WS2019+ image or install"
    echo "       the in-box NVMe driver, then re-run. The VM was NOT deallocated (stays on SCSI)."
    continue
  fi

  # 2) Deallocate (the disk-controller type / generation cannot change on a running VM):
  az vm deallocate -g "$RG" -n "$VM" -o none

  # 3) Convert Gen1 -> Trusted Launch / Gen2 IN PLACE if not already Gen2 (no disk rebuild). The
  #    guest was already made GPT/EFI in step 1, so this UEFI flip boots cleanly. Once done the VM
  #    CANNOT be rolled back to Gen1 except by restoring the step-0 snapshot.
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
