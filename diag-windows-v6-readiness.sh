#!/usr/bin/env bash
# READ-ONLY diagnostics for a WINDOWS F4s_v2 -> F-series v6 (Gen2 + NVMe) migration.
# Makes NO changes. Run this and paste the output so we can see exactly what is blocking the
# resize / OS-disk swap. Covers the four things that stop a Windows Gen1->v6 upgrade:
#   1. VM/disk generation (Gen1 MBR vs Gen2 GPT)  -> greys out "Swap OS Disk" / blocks v6 boot
#   2. guest firmware = BIOS vs UEFI              -> is MBR2GPT actually done?
#   3. BitLocker on C:                            -> blocks MBR2GPT
#   4. StorNVMe boot-start + OS version (WS2016?) -> blocks NVMe boot / MBR2GPT unsupported
#
# Usage:  RG=RG-MFGTRANSNONPROD-SERVICENOW VM=azumw57012 ./diag-windows-v6-readiness.sh
set -euo pipefail
RG="${RG:-myResourceGroup}"
VM="${VM:-azumw57012}"

echo "==================================================================="
echo " Windows v6 readiness diagnostics for VM '$VM' (RG '$RG') - READ ONLY"
echo "==================================================================="

echo "--- [1] VM control-plane state (size / controller / security type) ---"
az vm show -g "$RG" -n "$VM" \
  --query "{size:hardwareProfile.vmSize,ctrl:storageProfile.diskControllerType,secType:securityProfile.securityType,osDisk:storageProfile.osDisk.name}" \
  -o table || echo "    (could not read VM - check name/RG/subscription)"

OSDISK=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.name" -o tsv 2>/dev/null || echo "")
echo
echo "--- [2] OS disk generation + advertised controllers (expect gen=V2, ctrl includes NVMe) ---"
if [[ -n "$OSDISK" ]]; then
  az disk show -g "$RG" -n "$OSDISK" \
    --query "{disk:name,gen:hyperVGeneration,ctrl:supportedCapabilities.diskControllerTypes,state:diskState}" \
    -o table || true
else
  echo "    (OS disk name not resolved)"
fi

echo
echo "--- [2b] Target v6 SKU availability + preview feature flags (control-plane) ---"
# The local-temp-disk 'alds_v6' sizes (Fadsv6 / FALDV6Series) may be behind a PREVIEW feature flag
# in some subscriptions: 'not available to the current subscription ... feature flags registered:
# Microsoft.Compute/FALDV6Series'. That is NOT a quota error. Check availability + registration.
LOC=$(az vm show -g "$RG" -n "$VM" --query location -o tsv 2>/dev/null || echo "")
TARGET="${TARGET:-Standard_F4alds_v6}"
if [[ -n "$LOC" ]]; then
  echo "    location = $LOC   target = $TARGET"
  AVAIL=$(az vm list-skus -l "$LOC" --size "${TARGET#Standard_}" --query "[?name=='$TARGET'] | length(@)" -o tsv 2>/dev/null || echo "0")
  if [[ "${AVAIL:-0}" != "0" ]]; then
    echo "    SKU_AVAILABLE     = yes ('$TARGET' is offered to this subscription in $LOC)"
  else
    echo "    SKU_AVAILABLE     = NO  ('$TARGET' NOT offered here -> preview flag and/or region issue, NOT quota)"
  fi
fi
for F in FALDV6Series FADSV6Series; do
  ST=$(az feature show --namespace Microsoft.Compute --name "$F" --query properties.state -o tsv 2>/dev/null || echo "n/a")
  echo "    FEATURE $F = $ST   (want 'Registered'; register with: az feature register --namespace Microsoft.Compute --name $F)"
done

echo
echo "--- [3] IN-GUEST checks (firmware, partition style, BitLocker, StorNVMe, OS, pagefile) ---"
echo "    Requires the VM to be RUNNING with the guest agent healthy."
# shellcheck disable=SC2016  # the PowerShell must run inside the guest, not expand locally
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts '
  $ErrorActionPreference = "SilentlyContinue"
  Write-Output ("OS                = " + (Get-CimInstance Win32_OperatingSystem).Caption)
  $fw = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType).PEFirmwareType
  Write-Output ("FIRMWARE          = " + $(if ($fw -eq 2) {"UEFI (GPT - Gen2 ready)"} elseif ($fw -eq 1) {"BIOS (MBR - STILL GEN1, run mbr2gpt)"} else {"UNKNOWN"}))
  $sys = (Get-CimInstance Win32_OperatingSystem).SystemDrive
  $pstyle = (Get-Disk | Where-Object { $_.IsSystem -eq $true } | Select-Object -First 1).PartitionStyle
  Write-Output ("PARTITION_STYLE   = " + $pstyle + "   (GPT = converted, MBR = not yet)")
  $bl = (Get-BitLockerVolume -MountPoint "C:").ProtectionStatus
  Write-Output ("BITLOCKER_C       = " + $(if ($bl -eq "On") {"ON  (must be OFF before mbr2gpt)"} else {"Off"}))
  $svc = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
  $st  = if (Test-Path $svc) { (Get-ItemProperty -Path $svc -Name Start).Start } else { "MISSING" }
  Write-Output ("STORNVME_START    = " + $st + "   (0 = boot-start / NVMe-ready)")
  $pf = (Get-CimInstance Win32_PageFileSetting | ForEach-Object { $_.Name }) -join ", "
  Write-Output ("PAGEFILE          = " + $(if ($pf) {$pf} else {"none/system-managed"}))
  $mlog = "C:\Windows\setupact.log"
  if (Test-Path $mlog) {
    $last = Select-String -Path $mlog -Pattern "MBR2GPT" -ErrorAction SilentlyContinue | Select-Object -Last 3
    if ($last) { Write-Output "MBR2GPT_LOG_TAIL  ="; $last | ForEach-Object { Write-Output ("    " + $_.Line) } }
  }
  # Overall verdict
  $ready = ($fw -eq 2) -and ($bl -ne "On") -and ((Test-Path $svc) -and ((Get-ItemProperty -Path $svc -Name Start).Start -eq 0))
  Write-Output ("VERDICT           = " + $(if ($ready) {"READY for Gen2+NVMe resize"} else {"NOT READY - see flags above"}))
' --query "value[0].message" -o tsv 2>/dev/null || echo "    (run-command failed - is the VM running with a healthy guest agent?)"

echo
echo "==================================================================="
echo " Interpretation:"
echo "  * gen=V1 / FIRMWARE=BIOS / PARTITION_STYLE=MBR  -> Gen1 not yet converted."
echo "    Fix: disable BitLocker, then in the guest run:"
echo "         mbr2gpt /validate /allowFullOS  &&  mbr2gpt /convert /allowFullOS"
echo "    (Windows Server 2016 has NO mbr2gpt -> upgrade guest to 2019/2022 first.)"
echo "  * ctrl without NVMe  -> tag the disk: az disk update ... diskControllerTypes='SCSI, NVMe'"
echo "  * SKU_AVAILABLE=NO / FEATURE ... != Registered  -> the target size is PREVIEW-gated (NOT quota)."
echo "    Fix: az feature register --namespace Microsoft.Compute --name FALDV6Series ; wait for 'Registered';"
echo "         then az provider register --namespace Microsoft.Compute.  Or use the diskless 'als_v6' via"
echo "         blue/green rebuild (03W) since 'als_v6' is already available to this subscription."
echo "  * STORNVME_START != 0 -> set it to 0 so Windows boots on the NVMe controller."
echo "  Once FIRMWARE=UEFI, BitLocker Off and STORNVME_START=0, run 02W to finish the upgrade."
echo "==================================================================="
