#!/usr/bin/env bash
###############################################################################
# 11W-teams-guided-recover-and-migrate-windows.sh
#
# GUIDED, STEP-BY-STEP recovery + migration for a WINDOWS VM going from
# Standard_F4s_v2 (Gen1 / SCSI) to an F-series v6 size (Gen2 / NVMe).
# Designed to be run TOGETHER on a Teams screen-share: it prints each PHASE, runs
# the checks for that phase with [ OK ] / [FAIL], and PAUSES for you to confirm
# before moving on. It refuses to continue if a readiness check fails.
#
# It does two things in order:
#   PART A - ROLLBACK: bring the VM back to the original, known-good Gen1/SCSI state
#            from a clean pre-migration snapshot, and VERIFY it boots.
#   PART B - MIGRATE : run every step to reach the v6 (Gen2 + NVMe) size, verifying
#            readiness BEFORE and AFTER each step.
#
# WHY THE EARLIER ATTEMPTS FAILED (so the steps make sense):
#   * v6 sizes are Gen2/UEFI + NVMe ONLY. The original OS disk is Gen1 (MBR/BIOS),
#     so the portal "Swap OS Disk" greys it out ("Disk generation is not compatible
#     with VM generation") and a v6 VM will not boot from it.
#   * The fix is, IN ORDER: (1) convert the guest MBR->GPT with in-box mbr2gpt while
#     still on Gen1, (2) flip the VM to Trusted Launch / Gen2, (3) tag the OS disk
#     as NVMe-capable, (4) change size + controller to NVMe in ONE update.
#   * Windows also blocks resizing between a size WITH a local temp disk (F4s_v2 has
#     D:) and one WITHOUT (F4als_v6). So we target F4alds_v6 (the temp-disk twin) by
#     default. (https://aka.ms/AAah4sj)
#
# ---------------------------------------------------------------------------
# HOW TO USE
#   1. Open Azure Cloud Shell (Bash) at https://shell.azure.com  -- az is preinstalled
#      and you are already logged in. (Or a local Bash with Azure CLI + 'az login'.)
#   2. Select the right subscription:
#        az account set --subscription "245843b4-f532-4374-9864-7c7eb82d3e18"
#   3. Download this script, then run it with the VM values, e.g.:
#
#        RG="rg-mfgtransnonprod-servicenow" \
#        VM="azumw57012" \
#        SNAPSHOT="azumw57012-os-YYYYMMDD-HHMMSS" \
#        TARGET_SIZE="Standard_F4alds_v6" \
#        ROLLBACK_SIZE="Standard_F4s_v2" \
#        bash 11W-teams-guided-recover-and-migrate-windows.sh
#
#   REQUIRED : RG, VM, SNAPSHOT (a CLEAN pre-migration snapshot of the OS disk)
#   OPTIONAL : TARGET_SIZE   (default Standard_F4alds_v6)
#              ROLLBACK_SIZE (default Standard_F4s_v2 - the original size)
#              MODE=full | rollback-only | migrate-only   (default full)
#              AUTO=1        run without pausing between phases (no prompts)
#              DRYRUN=1      print the state-changing az commands, do NOT run them
#
#   If you do not know the snapshot name, list candidates:
#        az snapshot list -g "$RG" --query "[?contains(name,'azumw57012')].{name:name,created:timeCreated,gen:hyperVGeneration}" -o table
#   If no clean snapshot exists, tell us on the call BEFORE running PART A.
# ---------------------------------------------------------------------------
set -uo pipefail

# ------------------------------ parameters ---------------------------------
RG="${RG:-}"; VM="${VM:-}"
SNAPSHOT="${SNAPSHOT:-}"
TARGET_SIZE="${TARGET_SIZE:-Standard_F4alds_v6}"
ROLLBACK_SIZE="${ROLLBACK_SIZE:-Standard_F4s_v2}"
MODE="${MODE:-full}"
AUTO="${AUTO:-0}"
DRYRUN="${DRYRUN:-0}"
BOOT_TRIES="${BOOT_TRIES:-40}"     # boot-health polls (x ~15s => ~10 min)

# ------------------------------ pretty output ------------------------------
c_reset=$'\033[0m'; c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_hd=$'\033[36m'; c_wn=$'\033[33m'
PHASE_N=0
phase(){ PHASE_N=$((PHASE_N+1)); printf '\n%s========================================================================%s\n' "$c_hd" "$c_reset"; printf '%s==> STEP %s: %s%s\n' "$c_hd" "$PHASE_N" "$1" "$c_reset"; printf '%s========================================================================%s\n' "$c_hd" "$c_reset"; }
step(){ printf '   %s-> %s%s\n' "$c_hd" "$1" "$c_reset"; }
ok(){   printf '   [  %sOK%s  ] %s\n' "$c_ok" "$c_reset" "$1"; }
bad(){  printf '   [ %sFAIL%s ] %s\n' "$c_bad" "$c_reset" "$1"; }
warn(){ printf '   [ %sWARN%s ] %s\n' "$c_wn" "$c_reset" "$1"; }
die(){  bad "$1"; printf '\n%sSTOPPED.%s %s\n' "$c_bad" "$c_reset" "${2:-Nothing further was changed. Share the output above on the call.}"; exit 1; }
run(){ if [ "$DRYRUN" = 1 ]; then printf '   %s[dry-run]%s %s\n' "$c_wn" "$c_reset" "$*"; else "$@"; fi; }
# Pause between phases so we can watch each step land in the portal on Teams.
confirm(){ if [ "$AUTO" = 1 ]; then return 0; fi; printf '   %s? %s%s ' "$c_wn" "$1" "$c_reset"; read -r ans; case "$ans" in y|Y|yes|YES|"") return 0;; *) die "Paused by user." "Re-run when ready; completed steps above are already applied.";; esac; }

# ------------------------------ progress log -------------------------------
DONE=()
mark(){ DONE+=("$1"); }
recap(){ printf '\n%s--- checklist so far ---%s\n' "$c_hd" "$c_reset"; local i; for i in "${DONE[@]}"; do printf '   [x] %s\n' "$i"; done; }

# in-guest PowerShell readiness probe. Echoes KEY=VALUE lines + VERDICT.
guest_probe(){
  # shellcheck disable=SC2016  # the PowerShell must run inside the guest, not expand locally
  timeout 180 az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts '
    $ErrorActionPreference = "SilentlyContinue"
    Write-Output "BOOT_OK"
    Write-Output ("OS=" + (Get-CimInstance Win32_OperatingSystem).Caption)
    $fw = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType).PEFirmwareType
    Write-Output ("FIRMWARE=" + $(if ($fw -eq 2) {"UEFI"} elseif ($fw -eq 1) {"BIOS"} else {"UNKNOWN"}))
    Write-Output ("PARTSTYLE=" + (Get-Disk | Where-Object IsSystem | Select-Object -First 1).PartitionStyle)
    Write-Output ("BITLOCKER_C=" + (Get-BitLockerVolume -MountPoint "C:").ProtectionStatus)
    $svc = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
    Write-Output ("STORNVME_START=" + $(if (Test-Path $svc) { (Get-ItemProperty -Path $svc -Name Start).Start } else { "MISSING" }))
  ' --query "value[0].message" -o tsv 2>/dev/null || true
}

# poll until the guest reports BOOT_OK (== the OS actually booted). Prints the report.
wait_boot(){
  local tries="$1" i out
  step "Waiting for the guest to boot & report (up to ~$((tries*15/60)) min)..."
  for ((i=1;i<=tries;i++)); do
    out=$(guest_probe)
    if grep -q BOOT_OK <<<"$out"; then printf '%s\n' "$out" | sed 's/^/        /'; GUEST_REPORT="$out"; return 0; fi
    printf '        ...poll %s/%s (guest not responding yet)\n' "$i" "$tries"; sleep 15
  done
  GUEST_REPORT=""; return 1
}

gval(){ grep -E "^$1=" <<<"${GUEST_REPORT:-}" | head -1 | cut -d= -f2-; }

# ============================== PREFLIGHT ===================================
phase "Preflight & context (no changes made)"
if [ -z "$RG" ] || [ -z "$VM" ]; then die "RG and VM are required." "Set them, e.g. RG=... VM=... SNAPSHOT=... bash $0"; fi
command -v az >/dev/null 2>&1 || die "azure-cli (az) not found. Use Azure Cloud Shell (Bash)."
az account show >/dev/null 2>&1 || die "Not logged in. Run: az login  (or open Azure Cloud Shell)."
ok "Subscription: $(az account show --query name -o tsv 2>/dev/null)"
case "$MODE" in full|rollback-only|migrate-only) ok "Mode: $MODE   Target size: $TARGET_SIZE   Rollback size: $ROLLBACK_SIZE";; *) die "Unknown MODE='$MODE' (use full|rollback-only|migrate-only)";; esac
[ "$DRYRUN" = 1 ] && warn "DRYRUN=1 - state-changing commands are printed, not executed."

az vm show -g "$RG" -n "$VM" >/dev/null 2>&1 && VM_EXISTS=1 || VM_EXISTS=0
if [ "$VM_EXISTS" = 1 ]; then
  CUR_SIZE=$(az vm show -g "$RG" -n "$VM" --query "hardwareProfile.vmSize" -o tsv 2>/dev/null)
  CUR_CTRL=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.diskControllerType" -o tsv 2>/dev/null)
  CUR_SEC=$(az vm show  -g "$RG" -n "$VM" --query "securityProfile.securityType" -o tsv 2>/dev/null)
  LOCATION=$(az vm show -g "$RG" -n "$VM" --query "location" -o tsv 2>/dev/null)
  POWER=$(az vm get-instance-view -g "$RG" -n "$VM" --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" -o tsv 2>/dev/null)
  ok "Current VM: size=${CUR_SIZE:-?}  controller=${CUR_CTRL:-SCSI}  security=${CUR_SEC:-Standard}  power='${POWER:-?}'"
else
  LOCATION="${LOCATION:-westeurope}"
  warn "VM '$VM' does not currently exist (it may have been deleted). PART A will recreate it."
fi

if [ "$MODE" != migrate-only ]; then
  [ -n "$SNAPSHOT" ] || { az snapshot list -g "$RG" --query "[?contains(name,'$VM')].{name:name,created:timeCreated,gen:hyperVGeneration}" -o table 2>/dev/null; die "SNAPSHOT is required for rollback." "Pick a CLEAN pre-migration snapshot from the list above and set SNAPSHOT=<name>."; }
  az snapshot show -g "$RG" -n "$SNAPSHOT" >/dev/null 2>&1 || die "Snapshot '$SNAPSHOT' not found in RG '$RG'."
  SNAP_GEN=$(az snapshot show -g "$RG" -n "$SNAPSHOT" --query hyperVGeneration -o tsv 2>/dev/null)
  ok "Rollback snapshot: $SNAPSHOT (gen=${SNAP_GEN:-?}, created $(az snapshot show -g "$RG" -n "$SNAPSHOT" --query timeCreated -o tsv 2>/dev/null))"
fi
mark "Preflight OK"; recap
confirm "Proceed?"

# ============================== PART A: ROLLBACK ============================
if [ "$MODE" != migrate-only ]; then
  phase "PART A - Roll back to the original Gen1/SCSI VM from snapshot"
  SNAP_ID=$(az snapshot show -g "$RG" -n "$SNAPSHOT" --query id -o tsv)
  ROLLBACK_DISK="${VM}-rollback-osdisk"
  step "Recreating rollback OS disk '$ROLLBACK_DISK' from the snapshot (inherits Gen1)..."
  if az disk show -g "$RG" -n "$ROLLBACK_DISK" >/dev/null 2>&1; then
    ok "Rollback disk already exists - reusing it."
  else
    run az disk create -g "$RG" -l "$LOCATION" -n "$ROLLBACK_DISK" --source "$SNAP_ID" -o none && ok "Rollback disk created."
  fi

  SWAPPED=0
  if [ "$VM_EXISTS" = 1 ]; then
    step "Deallocating '$VM' and trying an in-place OS-disk swap first (least disruptive)..."
    run az vm deallocate -g "$RG" -n "$VM" -o none
    if [ "$DRYRUN" = 1 ]; then warn "[dry-run] would attempt: az vm update --os-disk $ROLLBACK_DISK"; SWAPPED=1; fi
    if [ "$DRYRUN" != 1 ] && az vm update -g "$RG" -n "$VM" --os-disk "$ROLLBACK_DISK" -o none 2>/tmp/rb_err.$$; then
      ok "OS-disk swap succeeded."; SWAPPED=1
    elif [ "$DRYRUN" != 1 ]; then
      warn "Swap rejected (VM is on an NVMe/Gen2 size - expected). Will delete + recreate the original VM."
      sed 's/^/        /' "/tmp/rb_err.$$" 2>/dev/null || true; rm -f "/tmp/rb_err.$$"
    fi
  fi

  if [ "$SWAPPED" != 1 ]; then
    NIC=""
    if [ "$VM_EXISTS" = 1 ]; then
      NIC=$(az vm show -g "$RG" -n "$VM" --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null)
      step "Deleting the current VM '$VM' (its NIC + disks are retained, keeping the private IP)..."
      run az vm delete -g "$RG" -n "$VM" --yes -o none
    else
      NIC=$(az network nic list -g "$RG" --query "[?contains(name,'$VM')].id | [0]" -o tsv 2>/dev/null)
    fi
    [ -n "$NIC" ] || die "Could not find the original NIC to reattach." "Locate the NIC for '$VM' and pass it, or recreate the VM in the portal on disk '$ROLLBACK_DISK'."
    step "Recreating original VM '$VM' ($ROLLBACK_SIZE, Gen1/SCSI) on the rollback disk + original NIC..."
    run az vm create -g "$RG" -n "$VM" --attach-os-disk "$ROLLBACK_DISK" --os-type Windows \
        --size "$ROLLBACK_SIZE" --nics "$NIC" -o none && ok "Original VM recreated."
  fi

  step "Starting the VM..."
  run az vm start -g "$RG" -n "$VM" -o none

  # GATE: prove the rollback VM actually boots before we touch anything else.
  if [ "$DRYRUN" = 1 ]; then
    warn "[dry-run] skipping boot verification."
  else
    if wait_boot "$BOOT_TRIES"; then
      ok "VM booted and the guest agent responded (rollback confirmed healthy)."
      GEN_NOW=$(az disk show -g "$RG" -n "$ROLLBACK_DISK" --query hyperVGeneration -o tsv 2>/dev/null)
      ok "OS disk generation: ${GEN_NOW:-?}   guest firmware: $(gval FIRMWARE)   OS: $(gval OS)"
    else
      die "VM did not report healthy after rollback." "Check boot diagnostics/serial console in the portal. Do NOT proceed to migration."
    fi
  fi
  mark "PART A rollback complete - VM back on original Gen1/SCSI and booting"; recap
  warn "ACTION: confirm the ServiceNow MID service is running on '$VM' before continuing."
  confirm "Is the VM healthy and the MID service OK? Continue to migration?"
fi

[ "$MODE" = rollback-only ] && { printf '\n%sDone (rollback-only). The VM is back on its original size.%s\n' "$c_ok" "$c_reset"; exit 0; }

# ============================== PART B: MIGRATE ============================
OSDISK=$(az vm show -g "$RG" -n "$VM" --query storageProfile.osDisk.name -o tsv 2>/dev/null) || true
[ -n "${OSDISK:-}" ] || { [ "$DRYRUN" = 1 ] && OSDISK="${VM}-rollback-osdisk"; }
[ -n "${OSDISK:-}" ] || die "Could not resolve the OS disk name for '$VM'."

phase "PART B.1 - Prepare the Windows guest (MBR->GPT + NVMe driver), then VERIFY"
step "Running in-guest prep: mbr2gpt convert (if BIOS/MBR) + set StorNVMe boot-start..."
# shellcheck disable=SC2016  # the PowerShell must run inside the guest, not expand locally
PREP=$(run az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts '
  $ErrorActionPreference = "Stop"
  Write-Output ("OS=" + (Get-CimInstance Win32_OperatingSystem).Caption)
  $fw = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
  if ($fw -eq 2) { Write-Output "MBR2GPT=ALREADY_GPT" }
  else {
    $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    if ($bl -and $bl.ProtectionStatus -eq "On") { Write-Output "MBR2GPT=BITLOCKER_ON" }
    elseif (-not (Test-Path "$env:SystemRoot\System32\mbr2gpt.exe")) { Write-Output "MBR2GPT=NO_TOOL_WS2016" }
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
    Write-Output "STORNVME=OK"
  } else { Write-Output "STORNVME=MISSING" }
' --query "value[0].message" -o tsv 2>/dev/null || true)
[ "$DRYRUN" != 1 ] && printf '%s\n' "$PREP" | sed 's/^/        /'

if [ "$DRYRUN" != 1 ]; then
  case "$PREP" in
    *BITLOCKER_ON*)  die "BitLocker is ON on C:." "Suspend/disable BitLocker on C:, then re-run with MODE=migrate-only.";;
    *NO_TOOL_WS2016*)die "This guest is Windows Server 2016 (no mbr2gpt)." "Upgrade the guest OS to 2019/2022 first, then re-run MODE=migrate-only.";;
    *VALIDATE_FAIL*) die "mbr2gpt /validate failed." "Usually no free space at the end of C:. Run 'Defrag C: /U /V' / free space, then re-run MODE=migrate-only.";;
    *CONVERT_FAIL*)  die "mbr2gpt /convert failed." "Review C:\\Windows\\setupact.log for MBR2GPT lines, then re-run MODE=migrate-only.";;
    *STORNVME=MISSING*) die "StorNVMe driver missing (very old image)." "Install the in-box NVMe driver / update the guest, then re-run.";;
  esac
  ok "Guest prep applied (MBR->GPT done or already GPT; StorNVMe boot-start set)."
fi
mark "PART B.1 guest prepared"; recap
confirm "Guest prep looks good. Proceed to deallocate + Gen2 conversion?"

phase "PART B.2 - Deallocate + convert Gen1 -> Gen2 (Trusted Launch), then VERIFY gen=V2"
step "Deallocating..."
run az vm deallocate -g "$RG" -n "$VM" -o none
GEN=$(az disk show -g "$RG" -n "$OSDISK" --query hyperVGeneration -o tsv 2>/dev/null || echo "")
if [ "$GEN" = "V2" ]; then
  ok "OS disk is already Gen2 (V2) - skipping the Trusted Launch flip."
else
  step "Flipping the VM to Trusted Launch / Gen2 (Secure Boot + vTPM)..."
  run az vm update -g "$RG" -n "$VM" --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true -o none \
    || die "Trusted Launch conversion failed." "Check the guest is GPT/EFI (PART B.1) and the OS is 2019/2022. Roll back with MODE=rollback-only if needed."
fi
# GATE: the disk must now report V2, or the v6 resize cannot work.
if [ "$DRYRUN" != 1 ]; then
  GEN=$(az disk show -g "$RG" -n "$OSDISK" --query hyperVGeneration -o tsv 2>/dev/null || echo "")
  if [ "$GEN" = "V2" ]; then ok "OS disk generation is now V2 (Gen2)."; else die "OS disk is still '$GEN' (expected V2)." "Do not proceed. Roll back with MODE=rollback-only and review PART B.1 on the call."; fi
fi
mark "PART B.2 VM is Gen2 (V2)"; recap
confirm "Gen2 confirmed. Proceed to tag the disk NVMe-capable?"

phase "PART B.3 - Tag the OS disk as NVMe-capable, then VERIFY"
step "Setting supportedCapabilities.diskControllerTypes='SCSI, NVMe' on '$OSDISK'..."
run az disk update -g "$RG" -n "$OSDISK" --set supportedCapabilities.diskControllerTypes='SCSI, NVMe' -o none
if [ "$DRYRUN" != 1 ]; then
  CTRLS=$(az disk show -g "$RG" -n "$OSDISK" --query "supportedCapabilities.diskControllerTypes" -o tsv 2>/dev/null || echo "")
  if grep -qi nvme <<<"$CTRLS"; then ok "Disk now advertises: $CTRLS"; else die "Disk still does not advertise NVMe ('$CTRLS')." "Re-run this step; do not proceed."; fi
fi
mark "PART B.3 disk is NVMe-capable"; recap
confirm "Disk NVMe-capable confirmed. Proceed to the final size + controller change?"

phase "PART B.4 - Change size + controller to NVMe in ONE update (the key step)"
step "Updating size=$TARGET_SIZE AND diskControllerType=NVMe together..."
run az vm update -g "$RG" -n "$VM" \
    --set hardwareProfile.vmSize="$TARGET_SIZE" storageProfile.diskControllerType=NVMe -o none \
  || die "Combined size+NVMe update was rejected." "Confirm the target size supports NVMe and that PART B.2/B.3 passed. Roll back with MODE=rollback-only if the VM will not start."
step "Starting the VM..."
run az vm start -g "$RG" -n "$VM" -o none
mark "PART B.4 resize + NVMe applied"; recap

phase "PART B.5 - Final validation"
if [ "$DRYRUN" = 1 ]; then
  warn "[dry-run] skipping final validation."
else
  FSIZE=$(az vm show -g "$RG" -n "$VM" --query hardwareProfile.vmSize -o tsv 2>/dev/null)
  FCTRL=$(az vm show -g "$RG" -n "$VM" --query storageProfile.diskControllerType -o tsv 2>/dev/null)
  if [ "$FSIZE" = "$TARGET_SIZE" ]; then ok "Size = $FSIZE"; else bad "Size = ${FSIZE:-?} (expected $TARGET_SIZE)"; fi
  if [ "$FCTRL" = "NVMe" ]; then ok "Controller = NVMe"; else bad "Controller = ${FCTRL:-?} (expected NVMe)"; fi
  if wait_boot "$BOOT_TRIES"; then
    ok "VM booted on the v6/NVMe size and the guest responded."
    ok "Guest: firmware=$(gval FIRMWARE)  partition=$(gval PARTSTYLE)  OS=$(gval OS)"
  else
    die "VM did NOT boot after the v6/NVMe switch." "Roll back immediately:  MODE=rollback-only SNAPSHOT=$SNAPSHOT ROLLBACK_SIZE=$ROLLBACK_SIZE bash $0"
  fi
fi
mark "PART B.5 validated on v6 + NVMe"; recap
printf '\n%s========================================================================%s\n' "$c_ok" "$c_reset"
printf '%sMIGRATION COMPLETE:%s %s is now %s on the NVMe controller.\n' "$c_ok" "$c_reset" "$VM" "$TARGET_SIZE"
printf 'Next: confirm the D: temp drive is present and the ServiceNow MID service registers.\n'
printf 'Rollback if anything looks wrong:  MODE=rollback-only SNAPSHOT=%s ROLLBACK_SIZE=%s bash %s\n' "$SNAPSHOT" "$ROLLBACK_SIZE" "$0"
printf '%s========================================================================%s\n' "$c_ok" "$c_reset"
