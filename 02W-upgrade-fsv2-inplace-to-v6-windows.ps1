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

  $v      = Get-AzVM -ResourceGroupName $RG -Name $vm
  $osName = $v.StorageProfile.OsDisk.Name
  $osDisk = Get-AzDisk -ResourceGroupName $RG -DiskName $osName

  # 0) Snapshot the OS disk (rollback):
  $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
  $cfg    = New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $v.Location -CreateOption Copy -Incremental
  New-AzSnapshot -ResourceGroupName $RG -SnapshotName "$vm-os-$stamp" -Snapshot $cfg | Out-Null

  # 1) Prepare + VERIFY the Windows guest for NVMe (StorNVMe must be boot-start). The target keeps
  #    a local temp disk, so the pagefile on D: does NOT need to be moved.
  $ps = @'
$ErrorActionPreference = "Stop"
$svc = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
if (Test-Path $svc) {
  if ((Get-ItemProperty -Path $svc -Name Start).Start -ne 0) { Set-ItemProperty -Path $svc -Name Start -Value 0 }
  Write-Output "NVME_READY=YES"
} else { Write-Output "NVME_READY=NO" }
'@
  $res = Invoke-AzVMRunCommand -ResourceGroupName $RG -Name $vm -CommandId RunPowerShellScript -ScriptString $ps
  $msg = $res.Value[0].Message
  Write-Host $msg
  if ($msg -notmatch "NVME_READY=YES") {
    Write-Warning "    ABORT $vm: StorNVMe missing/not boot-start (need WS2016+). VM NOT deallocated; stays on SCSI."
    continue
  }

  # 2) Deallocate:
  Stop-AzVM -ResourceGroupName $RG -Name $vm -Force | Out-Null

  # 3) Gen1 -> Gen2 / Trusted Launch in place if not already Gen2:
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
