# MID-SERVER (MFG) - WINDOWS - OPTION 1 (PowerShell / Az module):
# In-place upgrade F4s_v2 (SCSI) -> Standard_F4alds_v6 / Standard_F8alds_v6 (Gen2 + NVMe).
#
# WHY THIS TARGET: F4s_v2 has a local temp disk (D:); F4als_v6/F8als_v6 have NONE. Azure blocks a
# *Windows* resize between a "with temp disk" and a "without temp disk" size (either direction) ->
#   (OperationNotAllowed) ... changing from resource disk to non-resource disk VM size and
#   vice-versa is not allowed.  ->  https://aka.ms/AAah4sj
# The *alds* variant is the temp-disk twin of *als* (same vCPU/RAM) but KEEPS a local NVMe disk,
# so the "with temp disk -> with temp disk" resize is allowed and the D: pagefile drive is kept.
#
# GEN1 NOTE: v6 is Gen2/UEFI + NVMe only. A Gen1 (MBR/BIOS) Windows disk must be converted in-guest
# with MBR2GPT (done automatically in step 1) BEFORE the Trusted Launch flip; otherwise it will not
# boot (and the portal "Swap OS Disk" greys it out as "Disk generation is not compatible"). WS2016
# is unsupported (no MBR2GPT); disable BitLocker first; conversion cannot be rolled back except via
# the step-0 snapshot.
#
# Run: Connect-AzAccount; Set-AzContext -Subscription <id>; then execute this script.

$RG = "myResourceGroup"

# VM name -> target size (use the *alds* local-temp-disk variants for Windows):
$Map = @{
  "azumw57012" = "Standard_F4alds_v6"   # standard (4 vCPU / 8 GiB)
  # "azumw57013" = "Standard_F8alds_v6" # enhanced (8 vCPU / 16 GiB)
}

foreach ($vm in $Map.Keys) {
  $target = $Map[$vm]
  Write-Host "==> $vm -> $target (Windows, Gen2 + NVMe, local-temp-disk variant)"

  # GUARD: a Windows resize from F4s_v2 (has D: temp disk) to a NO-temp-disk 'als_v6' size is
  # blocked by Azure (OperationNotAllowed, https://aka.ms/AAah4sj). Reject it and suggest the twin.
  if ($target -match 'als_v6$' -and $target -notmatch 'alds_v6$') {
    $suggest = $target -replace 'als_v6$', 'alds_v6'
    Write-Warning "    SKIP $vm: '$target' has NO local temp disk; a Windows resize from F4s_v2 is blocked. Use the temp-disk twin '$suggest' (or 03W blue/green for the diskless '$target')."
    continue
  }

  $v      = Get-AzVM -ResourceGroupName $RG -Name $vm
  $osName = $v.StorageProfile.OsDisk.Name
  $osDisk = Get-AzDisk -ResourceGroupName $RG -DiskName $osName

  # 0) Snapshot the OS disk (rollback):
  $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
  $cfg    = New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $v.Location -CreateOption Copy -Incremental
  New-AzSnapshot -ResourceGroupName $RG -SnapshotName "$vm-os-$stamp" -Snapshot $cfg | Out-Null

  # 1) Prepare + VERIFY the Windows guest for NVMe (StorNVMe must be boot-start). The target keeps
  #    a local temp disk, so the pagefile on D: does NOT need to be moved.
  # 1) Guest prep: (a) Gen1(MBR/BIOS)->GPT/EFI via in-box MBR2GPT while still running on Gen1
  #    (Azure does NOT auto-run this; the Trusted Launch flip in step 3 requires GPT/EFI first;
  #    WS2016 has no MBR2GPT -> upgrade guest to 2019/2022; disable BitLocker before converting),
  #    and (b) StorNVMe boot-start so the VM boots on the NVMe controller. The target keeps a local
  #    temp disk, so the pagefile on D: does NOT need to be moved.
  $ps = @'
$ErrorActionPreference = "Stop"
$fw = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
if ($fw -eq 2) { Write-Output "MBR2GPT=ALREADY_GPT" }
else {
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
$svc = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
if (Test-Path $svc) {
  if ((Get-ItemProperty -Path $svc -Name Start).Start -ne 0) { Set-ItemProperty -Path $svc -Name Start -Value 0 }
  Write-Output "NVME_READY=YES"
} else { Write-Output "NVME_READY=NO" }
'@
  $res = Invoke-AzVMRunCommand -ResourceGroupName $RG -Name $vm -CommandId RunPowerShellScript -ScriptString $ps
  $msg = $res.Value[0].Message
  Write-Host $msg
  if ($msg -match "MBR2GPT=(BITLOCKER_ON|VALIDATE_FAIL|CONVERT_FAIL)") {
    Write-Warning "    ABORT $vm: Gen1->Gen2 (MBR2GPT) prerequisite failed (disable BitLocker / WS2016 unsupported / defrag needed). VM NOT deallocated; stays on Gen1/SCSI."
    continue
  }
  if ($msg -notmatch "NVME_READY=YES") {
    Write-Warning "    ABORT $vm: StorNVMe missing/not boot-start (need WS2019+). VM NOT deallocated; stays on SCSI."
    continue
  }

  # 2) Deallocate:
  Stop-AzVM -ResourceGroupName $RG -Name $vm -Force | Out-Null

  # 3) Gen1 -> Gen2 / Trusted Launch in place if not already Gen2 (guest is already GPT/EFI from
  #    step 1). NOTE: irreversible to Gen1 except by restoring the step-0 snapshot.
  if ($osDisk.HyperVGeneration -ne "V2") {
    try {
      $v = Get-AzVM -ResourceGroupName $RG -Name $vm
      $v = Set-AzVMSecurityProfile -VM $v -SecurityType "TrustedLaunch"
      $v = Set-AzVMUefi -VM $v -EnableVtpm $true -EnableSecureBoot $true
      Update-AzVM -ResourceGroupName $RG -VM $v | Out-Null
    } catch { Write-Warning "    Gen1->Gen2/Trusted Launch not applied; ensure the disk is Gen2 (V2)." }
  }

  # 4) Tag the OS disk as NVMe-capable:
  $osDisk = Get-AzDisk -ResourceGroupName $RG -DiskName $osName
  $osDisk.SupportedCapabilities = @{ DiskControllerTypes = "SCSI, NVMe" }
  Update-AzDisk -ResourceGroupName $RG -DiskName $osName -Disk $osDisk | Out-Null

  # 5) Resize + switch to NVMe in a SINGLE update (both must change together):
  $v = Get-AzVM -ResourceGroupName $RG -Name $vm
  $v.HardwareProfile.VmSize = $target
  $v.StorageProfile.DiskControllerType = "NVMe"
  Update-AzVM -ResourceGroupName $RG -VM $v | Out-Null

  # 6) Start + validate:
  Start-AzVM -ResourceGroupName $RG -Name $vm | Out-Null
  $d = Get-AzVM -ResourceGroupName $RG -Name $vm -Status
  Write-Host ("    now: size=" + (Get-AzVM -ResourceGroupName $RG -Name $vm).HardwareProfile.VmSize +
              " ctrl=NVMe power=" + ($d.Statuses | Where-Object Code -like "PowerState/*").DisplayStatus)
  Write-Host "    Confirm the D: temp drive is present and the MID service registers in ServiceNow."
}
Write-Host "MID-server (Windows in-place) complete. If boot fails, restore from snapshot (see 99-rollback)."
