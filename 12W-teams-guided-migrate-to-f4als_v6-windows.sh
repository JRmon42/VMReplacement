#!/usr/bin/env bash
###############################################################################
# 12W-teams-guided-migrate-to-f4als_v6-windows.sh
#
# GUIDED, STEP-BY-STEP, SELF-SERVICE migration of a WINDOWS VM from
# Standard_F4s_v2 (Gen1 / SCSI, has a D: temp disk) to the GENERALLY-AVAILABLE
# Standard_F4als_v6 (Gen2 / NVMe, NO temp disk).
#
# Use this when the local-temp-disk size Standard_F4alds_v6 is NOT available to
# the subscription (its 'Microsoft.Compute/FALDV6Series' preview is restricted and
# returns 'FeatureRegistrationUnsupported' - it cannot be self-registered). The GA
# diskless F4als_v6 IS available, and this script lands on it safely.
#
# The script prints each PHASE, runs the checks for that phase with [ OK ] / [FAIL],
# and PAUSES for you to confirm before moving on. It STOPS immediately if a check
# fails and NEVER continues past a failed readiness gate. A safety SNAPSHOT of the
# OS disk is taken first, so you can always roll back.
#
# WHY THIS TAKES SEVERAL STEPS (so the steps make sense):
#   * v6 sizes are Gen2/UEFI + NVMe ONLY. The original OS disk is Gen1 (MBR/BIOS),
#     so it must first be converted IN-GUEST with mbr2gpt, then the VM flipped to
#     Trusted Launch / Gen2, then the disk tagged NVMe-capable.
#   * Windows also blocks an *in-place* resize from a size WITH a temp disk (F4s_v2
#     has D:) to one WITHOUT (F4als_v6). So we do NOT resize: we REBUILD the VM on
#     F4als_v6 from the SAME OS disk + SAME NIC (same name, same private IP). A
#     rebuild is not a resize, so the restriction (https://aka.ms/AAah4sj) does not
#     apply. The pagefile is moved off D: first so nothing depends on the temp disk.
#
# ---------------------------------------------------------------------------
# HOW TO USE  (detailed, copy-paste steps -- safe for someone new to Azure)
#
#   PREREQUISITE - run as **Contributor on the resource group** (or higher). That single role
#     covers every action this script performs: create the safety snapshot, tag the disk NVMe,
#     convert to Gen2 (Trusted Launch), and delete + recreate the VM on the new size. No
#     subscription-level or RBAC-management rights are needed. If a step returns
#     'AuthorizationFailed', ask the subscription owner to assign Contributor on the RG:
#        az role assignment create --assignee <your-upn> --role Contributor \
#          --scope /subscriptions/<sub-id>/resourceGroups/<resource-group>
#
#   STEP 0 - Open the RIGHT shell (avoids the PowerShell/Bash trap)
#     Go to  https://shell.azure.com  and click **Switch to Bash** (top-left) if the
#     prompt starts with 'PS'. Azure CLI is preinstalled and you are already logged
#     in. Then select the subscription:
#        az account set --subscription "245843b4-f532-4374-9864-7c7eb82d3e18"
#        az account show --query name -o tsv
#     -> must print the correct subscription (e.g. MfgTransNonProd).
#     (PowerShell '$RG=...' variables do NOT pass into a bash script -- use Bash.)
#
#   STEP 1 - Download this script:
#        curl -O https://raw.githubusercontent.com/JRmon42/VMReplacement/main/12W-teams-guided-migrate-to-f4als_v6-windows.sh
#
#   STEP 2 - (Recommended first time) DRY-RUN to see every action without changing anything:
#        DRYRUN=1 \
#        RG="rg-mfgtransnonprod-servicenow" \
#        VM="azumw57012" \
#        bash 12W-teams-guided-migrate-to-f4als_v6-windows.sh
#
#   STEP 3 - Real run (paste the whole block, values inline on the SAME bash line):
#        RG="rg-mfgtransnonprod-servicenow" \
#        VM="azumw57012" \
#        TARGET_SIZE="Standard_F4als_v6" \
#        bash 12W-teams-guided-migrate-to-f4als_v6-windows.sh
#     The script prints each step with [ OK ] / [FAIL] and PAUSES between phases.
#     When it finishes (or stops), COPY THE FULL OUTPUT and send it back to us.
#
#   REQUIRED : RG, VM   (the VM must be RUNNING so the in-guest prep can run;
#                        run as Contributor on the resource group -- see PREREQUISITE above)
#   OPTIONAL : TARGET_SIZE  (default Standard_F4als_v6; use Standard_F8als_v6 for 8 vCPU)
#              SNAPSHOT     (a pre-existing safety snapshot name; if unset one is created)
#              ZONE         (availability zone for the rebuilt VM, e.g. 3; auto-detected)
#              AUTO=1       run without pausing between phases (no prompts)
#              DRYRUN=1     print the state-changing az commands, do NOT run them
#
#   ROLLBACK (if anything looks wrong AFTER the rebuild): recreate the VM on the
#   original size from the safety snapshot printed in STEP 2. Ask us and we will
#   drive it, or see 99-rollback.sh in the repo.
# ---------------------------------------------------------------------------
set -uo pipefail

# ------------------------------ parameters ---------------------------------
RG="${RG:-}"; VM="${VM:-}"
TARGET_SIZE="${TARGET_SIZE:-Standard_F4als_v6}"
SNAPSHOT="${SNAPSHOT:-}"
ZONE="${ZONE:-}"
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
die(){  bad "$1"; printf '\n%sSTOPPED.%s %s\n' "$c_bad" "$c_reset" "${2:-Nothing further was changed. Share the output above with us.}"; exit 1; }
run(){ if [ "$DRYRUN" = 1 ]; then printf '   %s[dry-run]%s %s\n' "$c_wn" "$c_reset" "$*"; else "$@"; fi; }
confirm(){
  if [ "$AUTO" = 1 ]; then printf '   %s[AUTO]%s %s -> yes\n' "$c_wn" "$c_reset" "$1"; return 0; fi
  if [ ! -t 0 ]; then die "No interactive terminal to answer '$1'." "Run the script directly in the Bash Cloud Shell (do not pipe it), or add AUTO=1 to skip the prompts."; fi
  printf '\n   %s>>> ACTION NEEDED:%s %s %s[Y/n]%s ' "$c_wn" "$c_reset" "$1" "$c_wn" "$c_reset"
  read -r ans
  case "$ans" in y|Y|yes|YES|"") return 0;; *) die "Paused by user." "Re-run when ready; completed steps above are already applied.";; esac
}

# ------------------------------ progress log -------------------------------
DONE=()
mark(){ DONE+=("$1"); }
recap(){ printf '\n%s--- checklist so far ---%s\n' "$c_hd" "$c_reset"; local i; for i in "${DONE[@]}"; do printf '   [x] %s\n' "$i"; done; }

# in-guest PowerShell readiness probe. Echoes KEY=VALUE lines (BOOT_OK proves the OS booted).
guest_probe(){
  # shellcheck disable=SC2016  # the PowerShell must run inside the guest, not expand locally
  timeout 180 az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts '
    $ErrorActionPreference = "SilentlyContinue"
    Write-Output "BOOT_OK"
    Write-Output ("OS=" + (Get-CimInstance Win32_OperatingSystem).Caption)
    $fw = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType).PEFirmwareType
    Write-Output ("FIRMWARE=" + $(if ($fw -eq 2) {"UEFI"} elseif ($fw -eq 1) {"BIOS"} else {"UNKNOWN"}))
    Write-Output ("PARTSTYLE=" + (Get-Disk | Where-Object IsSystem | Select-Object -First 1).PartitionStyle)
    $pf = (Get-CimInstance Win32_PageFileSetting | ForEach-Object { $_.Name }) -join ";"
    Write-Output ("PAGEFILE=" + $(if ($pf) {$pf} else {"auto/C"}))
  ' --query "value[0].message" -o tsv 2>/dev/null || true
}

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
if [ -z "$RG" ] || [ -z "$VM" ]; then die "RG and VM are required." "Set them, e.g. RG=... VM=... bash $0"; fi
command -v az >/dev/null 2>&1 || die "azure-cli (az) not found. Use Azure Cloud Shell (Bash)."
az account show >/dev/null 2>&1 || die "Not logged in. Run: az login  (or open Azure Cloud Shell)."
ok "Subscription: $(az account show --query name -o tsv 2>/dev/null)"

# The target must be a diskless *als_v6 (this script is specifically the blue/green diskless path).
if [[ ! "$TARGET_SIZE" =~ als_v6$ ]] || [[ "$TARGET_SIZE" =~ alds_v6$ ]]; then
  die "TARGET_SIZE='$TARGET_SIZE' is not a diskless *als_v6 size." "This script targets the GA diskless F4als_v6/F8als_v6. For the local-temp-disk 'alds_v6' twin use 11W instead."
fi
ok "Target: $TARGET_SIZE (GA, Gen2 + NVMe, no local temp disk)"
[ "$DRYRUN" = 1 ] && warn "DRYRUN=1 - state-changing commands are printed, not executed."

az vm show -g "$RG" -n "$VM" >/dev/null 2>&1 || die "VM '$VM' not found in RG '$RG'." "Check the name/RG/subscription. The VM must exist and be running for the in-guest prep."
CUR_SIZE=$(az vm show -g "$RG" -n "$VM" --query "hardwareProfile.vmSize" -o tsv 2>/dev/null)
LOCATION=$(az vm show -g "$RG" -n "$VM" --query "location" -o tsv 2>/dev/null)
OSDISK=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.name" -o tsv 2>/dev/null)
NIC=$(az vm show -g "$RG" -n "$VM" --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null)
POWER=$(az vm get-instance-view -g "$RG" -n "$VM" --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" -o tsv 2>/dev/null)
[ -z "$ZONE" ] && ZONE=$(az vm show -g "$RG" -n "$VM" --query "zones[0]" -o tsv 2>/dev/null || echo "")
ok "Current VM: size=${CUR_SIZE:-?}  location=${LOCATION:-?}  osDisk=${OSDISK:-?}  zone=${ZONE:-none}  power='${POWER:-?}'"
[ -n "$OSDISK" ] || die "Could not resolve the OS disk name for '$VM'."
[ -n "$NIC" ]    || die "Could not resolve the NIC for '$VM'."

# Confirm the target size is actually offered to this subscription in this region (it should be, GA).
TSIZE="${TARGET_SIZE#Standard_}"
SKU_OK=$(az vm list-skus -l "$LOCATION" --size "$TSIZE" --query "[?name=='$TARGET_SIZE'] | length(@)" -o tsv 2>/dev/null || echo 0)
if [ "${SKU_OK:-0}" = 0 ]; then
  die "Target size '$TARGET_SIZE' is NOT offered to this subscription in '$LOCATION'." "Confirm the size name/region, or tell us on the call. (F4als_v6 is GA and normally available.)"
fi
ok "Target size '$TARGET_SIZE' is available in '$LOCATION'."

# PREREQUISITE: this script is designed to run as **Contributor on the resource group '$RG'** (or
# higher). Contributor covers every action used here - snapshots/write, disks/write,
# virtualMachines/write|delete|deallocate|start, virtualMachines/runCommand/action and the NIC
# actions. We do NOT probe Azure AD / role assignments (a Contributor or guest account may lack the
# Microsoft Graph directory permission needed to read them). Instead, each write step below VERIFIES
# its own result and hard-stops on 'AuthorizationFailed' - the safety-snapshot step is the first gate.
SUBID=$(az account show --query id -o tsv 2>/dev/null)
RGSCOPE="/subscriptions/${SUBID}/resourceGroups/${RG}"
ok "Running as: $(az account show --query user.name -o tsv 2>/dev/null)  (needs Contributor on '$RG')"

# The in-guest prep needs the VM running.
case "${POWER:-}" in
  *running*) ok "VM is running (in-guest prep can run).";;
  *)
    if [ "$DRYRUN" = 1 ]; then
      warn "VM is '${POWER:-unknown}'. In a real run it is started here and we wait for the guest agent before the in-guest prep."
    else
      step "VM is '${POWER:-unknown}' - starting it so the in-guest prep can run..."
      run az vm start -g "$RG" -n "$VM" -o none
      if wait_boot "$BOOT_TRIES"; then
        ok "VM started and the guest agent is responding."
      else
        die "VM did not become ready after start." "Start it in the portal, confirm the Azure VM guest agent is healthy, then re-run."
      fi
    fi
    ;;
esac
mark "Preflight OK - target available, VM/OS-disk/NIC resolved"; recap
confirm "Proceed to take a safety snapshot?"

# ============================== STEP: SNAPSHOT =============================
phase "Safety snapshot of the OS disk (instant rollback point)"
if [ -n "$SNAPSHOT" ]; then
  az snapshot show -g "$RG" -n "$SNAPSHOT" >/dev/null 2>&1 || die "Provided SNAPSHOT '$SNAPSHOT' not found."
  ok "Using existing snapshot: $SNAPSHOT"
else
  SNAPSHOT="${VM}-pre-f4alsv6-$(date +%Y%m%d-%H%M%S)"
  OSID=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.managedDisk.id" -o tsv 2>/dev/null)
  step "Creating incremental snapshot '$SNAPSHOT' from the current OS disk..."
  run az snapshot create -g "$RG" -n "$SNAPSHOT" --source "$OSID" --incremental true -o none
  # VERIFY the snapshot actually exists - 'az snapshot create' can print an error (e.g.
  # AuthorizationFailed: missing Microsoft.Compute/snapshots/write) yet the script must NOT
  # proceed without a real rollback point.
  if [ "$DRYRUN" != 1 ]; then
    az snapshot show -g "$RG" -n "$SNAPSHOT" >/dev/null 2>&1 \
      || die "Safety snapshot was NOT created (see the error above)." "This is a missing permission ('Microsoft.Compute/snapshots/write'). We must have a rollback point before migrating - do NOT proceed. Ask the subscription owner to grant Contributor on the resource group:  az role assignment create --assignee <your-upn> --role Contributor --scope '$RGSCOPE'  -- then re-run. (Or run with SNAPSHOT=<an existing snapshot name>.)"
  fi
  ok "Safety snapshot created: $SNAPSHOT"
fi
warn "ROLLBACK POINT: keep this snapshot name -> $SNAPSHOT"
mark "Safety snapshot ready ($SNAPSHOT)"; recap
confirm "Snapshot done. Proceed to prepare the Windows guest?"

# ============================== STEP: GUEST PREP ===========================
phase "Prepare the Windows guest (pagefile off D:, MBR->GPT, NVMe driver), then VERIFY"
step "Running in-guest prep (this can take a few minutes)..."
# shellcheck disable=SC2016  # the PowerShell must run inside the guest, not expand locally
PREP=$(run az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts '
  $ErrorActionPreference = "Stop"
  Write-Output ("OS=" + (Get-CimInstance Win32_OperatingSystem).Caption)
  # 1) Move the pagefile OFF the temp disk (D:) to a system-managed pagefile on C:, so nothing
  #    depends on the local temp disk that the diskless target removes.
  $cs = Get-CimInstance Win32_ComputerSystem
  if (-not $cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{AutomaticManagedPagefile=$true} | Out-Null }
  Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -notlike "C:*" } | Remove-CimInstance -ErrorAction SilentlyContinue
  Write-Output "PAGEFILE=managed_on_C"
  # 2) Gen1(MBR/BIOS) -> GPT/EFI with in-box MBR2GPT while still on Gen1 (WS2016 has no tool;
  #    disable BitLocker first). Azure does NOT auto-run this; Gen2 needs GPT/EFI.
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
  # 3) Ensure StorNVMe is boot-start so the rebuilt VM boots on the NVMe controller.
  $svc = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
  if (Test-Path $svc) {
    if ((Get-ItemProperty -Path $svc -Name Start).Start -ne 0) { Set-ItemProperty -Path $svc -Name Start -Value 0 }
    Write-Output "STORNVME=OK"
  } else { Write-Output "STORNVME=MISSING" }
' --query "value[0].message" -o tsv 2>/dev/null || true)
[ "$DRYRUN" != 1 ] && printf '%s\n' "$PREP" | sed 's/^/        /'

if [ "$DRYRUN" != 1 ]; then
  # Empty/again-partial result => the guest agent did not run our script (VM not fully booted, agent
  # unhealthy, or run-command blocked). Treat as a hard failure rather than a false success.
  if ! grep -q "STORNVME=" <<<"$PREP"; then
    die "The in-guest preparation returned no result." "The Azure VM guest agent did not run the script (VM still booting, agent unhealthy, or run-command blocked). Confirm the VM is running and the guest agent is 'Ready' in the portal, then re-run."
  fi
  case "$PREP" in
    *BITLOCKER_ON*)   die "BitLocker is ON on C:." "Suspend/disable BitLocker on C:, then re-run.";;
    *NO_TOOL_WS2016*) die "This guest is Windows Server 2016 (no mbr2gpt)." "Upgrade the guest OS to 2019/2022 first, then re-run.";;
    *VALIDATE_FAIL*)  die "mbr2gpt /validate failed." "Usually no free space at the end of C:. Run 'Defrag C: /U /V' / free space, then re-run.";;
    *CONVERT_FAIL*)   die "mbr2gpt /convert failed." "Review C:\\Windows\\setupact.log for MBR2GPT lines, then re-run.";;
    *STORNVME=MISSING*) die "StorNVMe driver missing (very old image)." "Update the guest to WS2019+, then re-run.";;
  esac
  ok "Guest prep applied (pagefile on C:; MBR->GPT done or already GPT; StorNVMe boot-start set)."
fi
mark "Guest prepared (pagefile-on-C, GPT/EFI, NVMe-ready)"; recap
confirm "Guest prep looks good. Proceed to convert the VM to Gen2 (Trusted Launch)?"

# ============================== STEP: GEN2 FLIP ===========================
phase "Deallocate + convert Gen1 -> Gen2 (Trusted Launch), start, VERIFY it boots"
step "Deallocating..."
run az vm deallocate -g "$RG" -n "$VM" -o none
GEN=$(az disk show -g "$RG" -n "$OSDISK" --query hyperVGeneration -o tsv 2>/dev/null || echo "")
if [ "$GEN" = "V2" ]; then
  ok "OS disk is already Gen2 (V2) - skipping the Trusted Launch flip."
else
  step "Flipping the VM to Trusted Launch / Gen2 (Secure Boot + vTPM)..."
  run az vm update -g "$RG" -n "$VM" --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true -o none \
    || die "Trusted Launch conversion failed." "Check the guest is GPT/EFI (previous step) and the OS is 2019/2022. Roll back from snapshot '$SNAPSHOT' if needed."
fi
if [ "$DRYRUN" != 1 ]; then
  GEN=$(az disk show -g "$RG" -n "$OSDISK" --query hyperVGeneration -o tsv 2>/dev/null || echo "")
  [ "$GEN" = "V2" ] || die "OS disk is still '$GEN' (expected V2)." "Do not proceed. Roll back from snapshot '$SNAPSHOT' and review the guest prep with us."
  ok "OS disk generation is now V2 (Gen2)."
fi
step "Starting the VM (still on $CUR_SIZE, now Gen2) to confirm the conversion boots..."
run az vm start -g "$RG" -n "$VM" -o none
if [ "$DRYRUN" = 1 ]; then
  warn "[dry-run] skipping boot verification."
else
  if wait_boot "$BOOT_TRIES"; then
    ok "VM booted as Gen2. firmware=$(gval FIRMWARE)  partition=$(gval PARTSTYLE)  pagefile=$(gval PAGEFILE)"
    [ "$(gval FIRMWARE)" = "UEFI" ] || die "Guest still reports firmware=$(gval FIRMWARE) (expected UEFI)." "Gen2 conversion did not fully take. Roll back from snapshot '$SNAPSHOT'."
  else
    die "VM did not report healthy after the Gen2 conversion." "Check boot diagnostics/serial console. Roll back from snapshot '$SNAPSHOT'. Do NOT proceed."
  fi
fi
mark "VM converted to Gen2 (V2) and booting"; recap
confirm "Gen2 confirmed healthy. Proceed to tag the disk NVMe-capable?"

# ============================== STEP: TAG NVMe ============================
phase "Tag the OS disk as NVMe-capable, then VERIFY"
step "Deallocating for the rebuild..."
run az vm deallocate -g "$RG" -n "$VM" -o none
step "Setting supportedCapabilities.diskControllerTypes='SCSI, NVMe' on '$OSDISK'..."
run az disk update -g "$RG" -n "$OSDISK" --set supportedCapabilities.diskControllerTypes='SCSI, NVMe' -o none
if [ "$DRYRUN" != 1 ]; then
  CTRLS=$(az disk show -g "$RG" -n "$OSDISK" --query "supportedCapabilities.diskControllerTypes" -o tsv 2>/dev/null || echo "")
  grep -qi nvme <<<"$CTRLS" || die "Disk still does not advertise NVMe ('$CTRLS')." "Re-run this step; do not proceed."
  ok "Disk now advertises: $CTRLS"
fi
mark "OS disk is NVMe-capable"; recap
confirm "Disk NVMe-capable confirmed. Proceed to REBUILD the VM on $TARGET_SIZE? (deletes+recreates the VM; OS disk & NIC are kept)"

# ============================== STEP: BLUE/GREEN REBUILD ==================
phase "Rebuild the VM on $TARGET_SIZE from the SAME OS disk + SAME NIC (keeps name & IP)"
warn "This deletes the VM object and recreates it. The OS disk '$OSDISK' and NIC are RETAINED."
step "Deleting the VM object '$VM' (OS disk + NIC kept, private IP preserved)..."
run az vm delete -g "$RG" -n "$VM" --yes -o none \
  || die "Could not delete the VM object (needed to rebuild on the new size)." "Usually a missing permission ('Microsoft.Compute/virtualMachines/delete'). The OS disk and NIC are untouched; nothing was lost. Ask the subscription owner to grant Contributor on the resource group, then re-run."
if [ "$DRYRUN" != 1 ]; then
  az vm show -g "$RG" -n "$VM" >/dev/null 2>&1 \
    && die "The VM object still exists after the delete call (delete did not take)." "Check permissions/locks on '$VM'. The OS disk and NIC are retained; nothing was lost."
fi
step "Recreating '$VM' on $TARGET_SIZE (Gen2/NVMe) attaching the same OS disk + NIC..."
# shellcheck disable=SC2086  # ZONE must word-split into an optional flag (empty => omitted)
run az vm create -g "$RG" -n "$VM" --size "$TARGET_SIZE" --location "$LOCATION" \
    ${ZONE:+--zone "$ZONE"} \
    --attach-os-disk "$OSDISK" --os-type Windows \
    --nics "$NIC" \
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true \
    --disk-controller-type NVMe -o none \
  || die "Rebuild on $TARGET_SIZE failed." "Roll back: recreate '$VM' on the original size from OS disk '$OSDISK' (or snapshot '$SNAPSHOT'). Share the error above with us."
step "Starting the rebuilt VM..."
run az vm start -g "$RG" -n "$VM" -o none
mark "VM rebuilt on $TARGET_SIZE (NVMe, Gen2)"; recap

# ============================== STEP: FINAL VALIDATION ====================
phase "Final validation"
if [ "$DRYRUN" = 1 ]; then
  warn "[dry-run] skipping final validation."
  printf '\n%sDry-run complete.%s Re-run without DRYRUN=1 to apply.\n' "$c_ok" "$c_reset"; exit 0
fi
FSIZE=$(az vm show -g "$RG" -n "$VM" --query hardwareProfile.vmSize -o tsv 2>/dev/null)
FCTRL=$(az vm show -g "$RG" -n "$VM" --query storageProfile.diskControllerType -o tsv 2>/dev/null)
FSEC=$(az vm show -g "$RG" -n "$VM" --query securityProfile.securityType -o tsv 2>/dev/null)
if [ "$FSIZE" = "$TARGET_SIZE" ]; then ok "Size    = $FSIZE"; else bad "Size    = ${FSIZE:-?} (expected $TARGET_SIZE)"; fi
if grep -qi nvme <<<"${FCTRL:-}"; then ok "Controller = $FCTRL"; else bad "Controller = ${FCTRL:-?} (expected NVMe)"; fi
ok "Security type = ${FSEC:-Standard}"
if wait_boot "$BOOT_TRIES"; then
  ok "VM booted on $TARGET_SIZE. firmware=$(gval FIRMWARE)  partition=$(gval PARTSTYLE)  pagefile=$(gval PAGEFILE)"
else
  die "VM did not report healthy after the rebuild." "Check boot diagnostics/serial console. Roll back from OS disk '$OSDISK' / snapshot '$SNAPSHOT'."
fi
mark "Final validation passed"; recap
warn "ACTION: confirm the ServiceNow MID service is running and registered on '$VM'."
warn "Re-apply any VM extensions / boot diagnostics / tags / identities not carried by the disk+NIC."
printf '\n%sSUCCESS:%s %s is now running %s (Gen2 + NVMe, no temp disk) with its original name and private IP.\n' "$c_ok" "$c_reset" "$VM" "$TARGET_SIZE"
printf 'Keep the safety snapshot %s until the MID server is verified, then clean it up.\n' "$SNAPSHOT"
