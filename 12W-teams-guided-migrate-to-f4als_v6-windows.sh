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
#              SNAPSHOT_SKU (storage SKU for the safety snapshot; auto-matched to the disk's
#                            existing incremental snapshots -- set Standard_ZRS if it complains)
#              REUSE_SNAPSHOT=0  force a brand-new snapshot instead of reusing the newest existing one
#              ZONE         (availability zone for the rebuilt VM, e.g. 3; auto-detected)
#              AUTO=1       run without pausing between phases (no prompts)
#              PREP_TIMEOUT seconds to allow for the in-guest prep (default 4800 = 80 min).
#                           STEP 3 runs mbr2gpt (and a defrag if needed) inside Windows and can
#                           legitimately take 20-60 min on a busy production disk - it is NOT hung.
#                           A progress line is printed every 20s; leave the window open.
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
SNAPSHOT_SKU="${SNAPSHOT_SKU:-}"   # storage SKU for the safety snapshot; auto-matched to existing ones
ZONE="${ZONE:-}"
AUTO="${AUTO:-0}"
DRYRUN="${DRYRUN:-0}"
BOOT_TRIES="${BOOT_TRIES:-40}"     # boot-health polls (x ~15s => ~10 min)
PREP_TIMEOUT="${PREP_TIMEOUT:-4800}" # max seconds to wait for the in-guest prep (80 min; Azure caps run-command at 90)

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

# Ctrl-C does NOT stop the work happening inside Windows: run-command scripts are executed by the
# Azure guest agent, so they keep going. Explain that rather than leaving a bare shell prompt.
on_interrupt(){
  printf '\n\n%s!!! INTERRUPTED (Ctrl-C) !!!%s\n' "$c_bad" "$c_reset"
  printf '   This stopped only the command on YOUR side. If the in-guest preparation was running,\n'
  printf '   it is STILL RUNNING inside Windows and will finish on its own.\n'
  printf '   * Do NOT reboot, stop, resize or delete the VM now.\n'
  printf '   * Wait a few minutes, then simply re-run this script - it is safe to re-run and will\n'
  printf '     wait for the in-guest script to finish, then skip whatever is already done.\n'
  printf '   * Nothing destructive has been performed by this script.\n'
  printf '   * TIP: in Cloud Shell, Ctrl-C SENDS AN INTERRUPT - it does not copy. To copy text,\n'
  printf '     select it and use Ctrl-Insert, or right-click -> Copy.\n'
  printf '   * The in-guest output is also written to C:\\Windows\\Temp\\mig-prep-last.log inside the\n'
  printf '     VM, so nothing is lost. Once the guest run has finished you can read it with:\n'
  printf '       az vm run-command invoke -g %s -n %s --command-id RunPowerShellScript \\\n' "${RG:-<rg>}" "${VM:-<vm>}"
  printf '         --scripts "Get-Content C:\\Windows\\Temp\\mig-prep-last.log -Tail 60" \\\n'
  printf '         --query "value[0].message" -o tsv\n\n'
  exit 130
}
trap on_interrupt INT

# in-guest PowerShell readiness probe. Echoes KEY=VALUE lines (BOOT_OK proves the OS booted).
guest_probe(){
  # shellcheck disable=SC2016  # the PowerShell must run inside the guest, not expand locally
  timeout 180 az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts '
    $ErrorActionPreference = "SilentlyContinue"
    Write-Output "BOOT_OK"
    Write-Output ("OS=" + (Get-CimInstance Win32_OperatingSystem).Caption)
    $fw = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType).PEFirmwareType
    $fwStr = if ($fw -eq 2) {"UEFI"} elseif ($fw -eq 1) {"BIOS"} else {"UNKNOWN"}
    if ($fwStr -eq "UNKNOWN") {
      $bcd = (bcdedit /enum "{current}" 2>$null | Out-String)
      if ($bcd -match "winload\.efi") { $fwStr = "UEFI" } elseif ($bcd -match "winload\.exe") { $fwStr = "BIOS" }
    }
    if ($fwStr -eq "UNKNOWN") {
      $sb = $null; try { $sb = Confirm-SecureBootUEFI } catch { $sb = $null }
      if ($null -ne $sb) { $fwStr = "UEFI" }
    }
    Write-Output ("FIRMWARE=" + $fwStr)
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
  # Reuse the newest existing pre-migration snapshot of this VM if one is already there. This
  # avoids re-creating a snapshot on every re-run and sidesteps transient create failures
  # (auth token timeout, SKU races). Set REUSE_SNAPSHOT=0 to force a brand-new snapshot.
  REUSE_SNAPSHOT="${REUSE_SNAPSHOT:-1}"
  EXIST=""
  if [ "$REUSE_SNAPSHOT" = 1 ]; then
    EXIST=$(az snapshot list -g "$RG" --query "sort_by([?starts_with(name,'${VM}-pre-f4alsv6-')],&timeCreated)[-1].name" -o tsv 2>/dev/null)
  fi
  if [ -n "$EXIST" ] && [ "$EXIST" != "None" ]; then
    SNAPSHOT="$EXIST"
    ok "Reusing existing safety snapshot: $SNAPSHOT (set REUSE_SNAPSHOT=0 to force a new one)"
  else
    SNAPSHOT="${VM}-pre-f4alsv6-$(date +%Y%m%d-%H%M%S)"
    OSID=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.managedDisk.id" -o tsv 2>/dev/null)
    # Azure requires a new INCREMENTAL snapshot to use the SAME storage SKU as any existing
    # incremental snapshots of the same disk (else ConflictingUserInput LRS-vs-ZRS). Auto-match it.
    if [ -z "$SNAPSHOT_SKU" ]; then
      SNAPSHOT_SKU=$(az snapshot list -g "$RG" --query "[?creationData.sourceResourceId=='$OSID' && incremental].sku.name | [0]" -o tsv 2>/dev/null)
    fi
    [ -z "$SNAPSHOT_SKU" ] || [ "$SNAPSHOT_SKU" = "None" ] && SNAPSHOT_SKU="Standard_LRS"
    step "Creating incremental snapshot '$SNAPSHOT' (sku $SNAPSHOT_SKU) from the current OS disk..."
    run az snapshot create -g "$RG" -n "$SNAPSHOT" --source "$OSID" --incremental true --sku "$SNAPSHOT_SKU" -o none
    # VERIFY the snapshot actually exists - 'az snapshot create' can print an error (e.g.
    # AuthorizationFailed: missing Microsoft.Compute/snapshots/write, a SKU mismatch, or a
    # Cloud Shell token timeout) yet the script must NOT proceed without a real rollback point.
    if [ "$DRYRUN" != 1 ]; then
      az snapshot show -g "$RG" -n "$SNAPSHOT" >/dev/null 2>&1 \
        || die "Safety snapshot was NOT created (see the error above)." "We must have a rollback point before migrating - do NOT proceed. If it says 'Timeout waiting for token'/credential problem, your Cloud Shell session expired: run 'az login' (or restart Cloud Shell), then re-run. If it is a SKU mismatch (LRS vs ZRS), re-run with SNAPSHOT_SKU=Standard_ZRS. If it is AuthorizationFailed (missing Microsoft.Compute/snapshots/write), ask the subscription owner to grant Contributor on the resource group:  az role assignment create --assignee <your-upn> --role Contributor --scope '$RGSCOPE'  -- then re-run. (Or run with SNAPSHOT=<an existing snapshot name>.)"
    fi
    ok "Safety snapshot created: $SNAPSHOT"
  fi
fi
warn "ROLLBACK POINT: keep this snapshot name -> $SNAPSHOT"
mark "Safety snapshot ready ($SNAPSHOT)"; recap
confirm "Snapshot done. Proceed to prepare the Windows guest?"

# ============================== STEP: GUEST PREP ===========================
phase "Prepare the Windows guest (pagefile off D:, MBR->GPT, NVMe driver), then VERIFY"
warn "This step runs INSIDE Windows and is the SLOWEST part of the migration."
warn "mbr2gpt (and a defrag, if one is needed) can take 20-60 minutes on a busy production C:."
warn "A progress line is printed every 20s. DO NOT press Ctrl-C and DO NOT close this window."
warn "If the OS disk is still MBR, the pagefile is removed and the script TESTS whether C: can be"
warn "shrunk (mbr2gpt always carves the EFI partition out of C:, and ignores free space elsewhere)."
warn "You may be asked for ONE Windows restart, after which it continues on its own."
warn "A system-managed pagefile on C: is restored automatically once the disk is GPT."
step "Running in-guest prep (expect 5-60 min; progress is printed below)..."
# shellcheck disable=SC2016  # the PowerShell must run inside the guest, not expand locally
GUEST_PREP_PS='
  $ErrorActionPreference = "Continue"
  # Mirror everything to a file inside the VM. If the operator side is interrupted (Ctrl-C in
  # Cloud Shell, session timeout, network drop) the run-command result is lost, but the guest
  # script keeps running - this log lets us recover its outcome afterwards instead of blindly
  # repeating a 30-60 minute defrag.
  try { Start-Transcript -Path ($env:SystemRoot + "\Temp\mig-prep-last.log") -Force | Out-Null } catch { }
  Write-Output "PREP_BEGIN"
  try { Write-Output ("OS=" + (Get-CimInstance Win32_OperatingSystem).Caption) } catch { Write-Output "OS=UNKNOWN" }
  # 0) Identify the OS disk and its REAL partition style first - the pagefile decision below
  #    depends on whether an MBR -> GPT conversion is still pending. The firmware registry value
  #    is unreliable on a Gen1 VM whose disk was already converted, so rely on the partition
  #    table + presence of an EFI System Partition (ESP) instead.
  $osNum = (Get-Partition -DriveLetter C -ErrorAction SilentlyContinue).DiskNumber
  if ($null -eq $osNum) { $osNum = 0 }
  $style = (Get-Disk -Number $osNum -ErrorAction SilentlyContinue).PartitionStyle
  $esp = @(Get-Partition -DiskNumber $osNum -ErrorAction SilentlyContinue | Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -or $_.Type -eq "System" })
  Write-Output ("OSDISK=num:" + $osNum + " style:" + $style + " esp:" + $esp.Count)
  $needConvert = ($style -ne "GPT")
  # 1) Pagefile. The target size has NO local temp disk, so the pagefile must not live on D:.
  #    While an MBR -> GPT conversion is still pending we remove the pagefile ENTIRELY instead of
  #    moving it to C:. pagefile.sys is an immovable file and, sitting at the end of C:, it is the
  #    usual reason mbr2gpt cannot shrink C: to carve the ~100MB EFI partition ("Partition final
  #    size is <n> (initial size was <n>), cannot rely on this space"). A system-managed pagefile
  #    on C: is put back automatically as soon as the disk is GPT.
  try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($needConvert) {
      if ($cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{AutomaticManagedPagefile=$false} | Out-Null }
      Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Remove-CimInstance -ErrorAction SilentlyContinue
      Write-Output "PAGEFILE=disabled_until_gpt"
    } else {
      if (-not $cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{AutomaticManagedPagefile=$true} | Out-Null }
      Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "C:*" } | Remove-CimInstance -ErrorAction SilentlyContinue
      Write-Output "PAGEFILE=managed_on_C"
    }
  } catch { Write-Output ("PAGEFILE=ERROR:" + $_.Exception.Message) }
  # 2) Gen1(MBR/BIOS) -> GPT/EFI with in-box MBR2GPT while still on Gen1 (WS2016 has no tool;
  #    disable BitLocker first). Azure does NOT auto-run this; Gen2 needs GPT/EFI.
  try {
    if ($style -eq "GPT" -and $esp.Count -ge 1) { Write-Output "MBR2GPT=ALREADY_GPT" }
    elseif ($style -eq "GPT") { Write-Output "MBR2GPT=GPT_NO_ESP" }
    else {
      $bl = $null
      if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        try { $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue } catch { $bl = $null }
      }
      if ($bl -and $bl.ProtectionStatus -eq "On") { Write-Output "MBR2GPT=BITLOCKER_ON" }
      elseif (-not (Test-Path "$env:SystemRoot\System32\mbr2gpt.exe")) { Write-Output "MBR2GPT=NO_TOOL_WS2016" }
      else {
        # Shared failure diagnostics: mbr2gpt output, the MBR2GPT lines it wrote to setupact.log,
        # and the real partition layout (including unallocated space, the usual culprit).
        function Emit-Mbr2GptDiag($out) {
          Write-Output ("MBR2GPT_OUT=" + (($out | Out-String).Trim() -replace "\s*\r?\n\s*"," | "))
          $lg = Get-Content "$env:SystemRoot\setupact.log" -ErrorAction SilentlyContinue | Select-String -Pattern "MBR2GPT" | Select-Object -Last 20
          foreach ($l in $lg) { Write-Output ("SETUPACT: " + $l.Line.Trim()) }
          try {
            $dd = Get-Disk -Number $osNum
            Write-Output ("DISK0=style:" + $dd.PartitionStyle + " parts:" + (Get-Partition -DiskNumber $osNum | Measure-Object).Count + " unallocMB:" + [math]::Round(($dd.Size - $dd.AllocatedSize)/1MB,0))
            foreach ($p in (Get-Partition -DiskNumber $osNum)) { Write-Output ("PART: n=" + $p.PartitionNumber + " type=" + $p.Type + " size=" + [math]::Round($p.Size/1GB,2) + "GB offset=" + [math]::Round($p.Offset/1GB,3) + "GB drive=" + $p.DriveLetter) }
            $cv = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
            if ($cv) { Write-Output ("CVOL: sizeGB=" + [math]::Round($cv.Size/1GB,2) + " freeGB=" + [math]::Round($cv.SizeRemaining/1GB,2)) }
          } catch {}
        }

        # mbr2gpt must carve an ~100MB EFI System Partition out of the disk. In full-OS mode it
        # cannot reuse the existing "System Reserved" partition, so it ALWAYS tries to shrink C:
        # itself - and it ignores any unallocated space that already exists on the disk (proven on
        # azumw17011: 1023MB free after C: and it still failed with "Cannot find room for the EFI
        # system partition"). So the ONLY thing that matters is: can Windows shrink C: right now?
        # A shrink stops at the last IMMOVABLE file, hence the cleanup below, and we then TEST the
        # shrink ourselves so we know the answer before mbr2gpt spends 30 minutes finding out.
        $needReboot = $false
        $blocked = $false
        try {
          $dsk = Get-Disk -Number $osNum
          Write-Output ("UNALLOC_MB=" + [math]::Round(($dsk.Size - $dsk.AllocatedSize)/1MB,0))
          try { & "$env:SystemRoot\System32\powercfg.exe" -h off 2>&1 | Out-Null; Write-Output "HIBER=off" } catch { Write-Output ("HIBER=ERROR:" + $_.Exception.Message) }
          try { & "$env:SystemRoot\System32\vssadmin.exe" delete shadows /all /quiet 2>&1 | Out-Null; Write-Output "SHADOWS=deleted" } catch { Write-Output ("SHADOWS=ERROR:" + $_.Exception.Message) }
          # The Azure guest agent writes ETL traces to C:\WindowsAzure\Logs and they are appended
          # continuously - on azumw17011 event 259 named one of them as the last unmovable file.
          # Delete the ones that are no longer open (never touch the current one: the agent is
          # what is executing this very script).
          try {
            $old = @(Get-ChildItem -Path "C:\WindowsAzure\Logs" -Recurse -Force -Filter "*.etl" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) })
            $n = 0
            foreach ($f in $old) { try { Remove-Item $f.FullName -Force -ErrorAction Stop; $n++ } catch {} }
            Write-Output ("AGENTLOGS=deleted:" + $n + " of:" + $old.Count)
          } catch { Write-Output ("AGENTLOGS=ERROR:" + $_.Exception.Message) }
          $pf = @(Get-ChildItem -Force -Path "C:\" -Filter "pagefile.sys" -ErrorAction SilentlyContinue).Count
          $hf = @(Get-ChildItem -Force -Path "C:\" -Filter "hiberfil.sys" -ErrorAction SilentlyContinue).Count
          Write-Output ("IMMOVABLE=pagefile:" + $pf + " hiberfil:" + $hf)
          $cpart = Get-Partition -DriveLetter C
          $sup = Get-PartitionSupportedSize -DiskNumber $osNum -PartitionNumber $cpart.PartitionNumber -ErrorAction SilentlyContinue
          if ($sup) { Write-Output ("CPART=disk:" + $osNum + " part:" + $cpart.PartitionNumber + " sizeMB:" + [math]::Round($cpart.Size/1MB,0) + " minMB:" + [math]::Round($sup.SizeMin/1MB,0) + " reclaimableMB:" + [math]::Round(($cpart.Size - $sup.SizeMin)/1MB,0)) }
          $cBefore = $cpart.Size
          # Select the volume by DISK + PARTITION number, never by drive letter: on azumw17011
          # "select volume C" reported "Volume 1 is the selected volume" and then refused a 512MB
          # shrink as "smaller than the minimum volume size" - it had picked the 500MB System
          # Reserved volume, not C:. list volume is included so the mapping is visible in the log.
          $dpf = Join-Path $env:TEMP "mig-shrink-c.txt"
          # Select by drive letter. An earlier build used "select disk N" + "select partition M",
          # but diskpart rejected it ("The arguments specified for this command are not valid"),
          # so the shrink never ran. "select volume C" is proven correct on this VM: the
          # "list volume" output shows Volume 1 = C: (Windows, Boot).
          $dpcmds = @("list volume","select volume C","shrink desired=512 minimum=128","exit")
          Set-Content -Path $dpf -Value $dpcmds -Encoding Ascii
          $dpo = & "$env:SystemRoot\System32\diskpart.exe" /s $dpf 2>&1
          Write-Output ("DISKPART=" + (($dpo | Out-String).Trim() -replace "\s*\r?\n\s*"," | "))
          $cAfter = (Get-Partition -DriveLetter C).Size
          $freed = $cBefore - $cAfter
          if ($freed -lt 100MB -and $sup) {
            # Fall back to the storage cmdlet with an explicit absolute target size, clamped to
            # the minimum the file system itself reports.
            $target = $cBefore - 512MB
            if ($target -lt $sup.SizeMin) { $target = $sup.SizeMin }
            if ($target -lt $cBefore) {
              try { Resize-Partition -DiskNumber $osNum -PartitionNumber $cpart.PartitionNumber -Size $target -ErrorAction Stop; Write-Output "RESIZE=OK" }
              catch { Write-Output ("RESIZE=FAIL:" + (($_.Exception.Message | Out-String).Trim() -replace "\s*\r?\n\s*"," | ")) }
              $cAfter = (Get-Partition -DriveLetter C).Size
              $freed = $cBefore - $cAfter
            }
          }
          if ($freed -lt 100MB) {
            # Last resort before giving up: consolidate free space (defrag /X is specifically the
            # remedy for "the shrink freed nothing"), then repeat the diskpart shrink once.
            try {
              & "$env:SystemRoot\System32\defrag.exe" C: /X /U 2>&1 | Out-Null
              Write-Output "DEFRAGX=done"
            } catch { Write-Output ("DEFRAGX=ERROR:" + $_.Exception.Message) }
            Set-Content -Path $dpf -Value $dpcmds -Encoding Ascii
            $dpo2 = & "$env:SystemRoot\System32\diskpart.exe" /s $dpf 2>&1
            Write-Output ("DISKPART2=" + (($dpo2 | Out-String).Trim() -replace "\s*\r?\n\s*"," | "))
            $cAfter = (Get-Partition -DriveLetter C).Size
            $freed = $cBefore - $cAfter
          }
          Remove-Item $dpf -Force -ErrorAction SilentlyContinue
          Write-Output ("SHRINK_FREED_MB=" + [math]::Round($freed/1MB,0))
          $dsk = Get-Disk -Number $osNum
          Write-Output ("UNALLOC_MB_AFTER=" + [math]::Round(($dsk.Size - $dsk.AllocatedSize)/1MB,0))
          # When a shrink is cut short, Windows logs event 259 naming the exact file that blocked
          # it. That single line tells us what to remove instead of guessing.
          try {
            $ev = Get-WinEvent -FilterHashtable @{LogName="Application"; Id=259} -MaxEvents 1 -ErrorAction SilentlyContinue
            if ($ev) { Write-Output ("LAST_UNMOVABLE=" + (($ev.Message | Out-String).Trim() -replace "\s*\r?\n\s*"," | ")) }
          } catch {}
          if ($freed -lt 100MB) {
            if ($pf -gt 0 -or $hf -gt 0) {
              # pagefile.sys / hiberfil.sys are still open; they are only released at the next
              # boot. One restart and a retry is all that is needed.
              Write-Output "SHRINK=NEED_REBOOT"
              $needReboot = $true
            } else {
              Write-Output "SHRINK=BLOCKED"
              $blocked = $true
            }
          } else { Write-Output "SHRINK=OK" }
        } catch { Write-Output ("SHRINK=ERROR:" + $_.Exception.Message) }

        if ($needReboot) { Write-Output "MBR2GPT=NEED_REBOOT" }
        elseif ($blocked) { Write-Output "MBR2GPT=SHRINK_BLOCKED" }
        else {
        # Run /validate FIRST. A defrag is only needed when validate complains, and a defrag of a
        # production C: can take 20-60 minutes - so we no longer pay that cost unconditionally.
        $mv = & "$env:SystemRoot\System32\mbr2gpt.exe" /validate /allowFullOS 2>&1
        if ($LASTEXITCODE -ne 0) {
          # Report WHY the first attempt failed before spending 20-60 min on a defrag, so the
          # reason is known even if the operator loses the session during the retry.
          Write-Output ("MBR2GPT_OUT1=" + (($mv | Out-String).Trim() -replace "\s*\r?\n\s*"," | "))
          Write-Output "MBR2GPT=DEFRAG_THEN_RETRY"
          Defrag C: /U 2>&1 | Out-Null
          $mv = & "$env:SystemRoot\System32\mbr2gpt.exe" /validate /allowFullOS 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
          Write-Output "MBR2GPT=VALIDATE_FAIL"
          Emit-Mbr2GptDiag $mv
        }
        else {
          $mc = & "$env:SystemRoot\System32\mbr2gpt.exe" /convert /allowFullOS 2>&1
          if ($LASTEXITCODE -ne 0) {
            Write-Output "MBR2GPT=CONVERT_FAIL"
            Emit-Mbr2GptDiag $mc
          } else {
            Write-Output "MBR2GPT=CONVERTED"
            # Disk is GPT now, so give the guest its pagefile back (system-managed on C:).
            try {
              $cs2 = Get-CimInstance Win32_ComputerSystem
              $cs2 | Set-CimInstance -Property @{AutomaticManagedPagefile=$true} | Out-Null
              Write-Output "PAGEFILE=restored_managed_on_C"
            } catch { Write-Output ("PAGEFILE=RESTORE_ERROR:" + $_.Exception.Message) }
          }
        }
        }
      }
    }
  } catch { Write-Output ("MBR2GPT=ERROR:" + $_.Exception.Message) }
  # 3) Ensure StorNVMe is boot-start so the rebuilt VM boots on the NVMe controller.
  try {
    $svc = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
    if (Test-Path $svc) {
      if ((Get-ItemProperty -Path $svc -Name Start).Start -ne 0) { Set-ItemProperty -Path $svc -Name Start -Value 0 }
      Write-Output "STORNVME=OK"
    } else { Write-Output "STORNVME=MISSING" }
  } catch { Write-Output ("STORNVME=ERROR:" + $_.Exception.Message) }
  try { Stop-Transcript | Out-Null } catch { }
'

# The in-guest prep may need exactly ONE restart: pagefile.sys and hiberfil.sys are only released
# at the next boot, and until they are gone Windows cannot shrink C: to make room for the EFI
# partition. When the guest asks for it we restart the VM and run the prep again - at most once.
PREP_ATTEMPT=0
while :; do
PREP_ATTEMPT=$((PREP_ATTEMPT+1))
if [ "$DRYRUN" = 1 ]; then
  printf '   %s[dry-run]%s az vm run-command invoke -g %s -n %s --command-id RunPowerShellScript --scripts <guest-prep>\n' "$c_wn" "$c_reset" "$RG" "$VM"
  PREP=""
else
  # Run the guest prep in the background so we can print a heartbeat. Three reasons this matters:
  #  * Azure Cloud Shell closes a session after ~20 min without activity - a silent 30-minute
  #    mbr2gpt would kill the shell mid-migration.
  #  * The operator can otherwise not tell "slow" from "hung".
  #  * If a PREVIOUS run of this script was interrupted (e.g. Ctrl-C), its script is STILL running
  #    inside the guest - Ctrl-C only kills the local CLI, not the guest agent. Azure allows one
  #    run-command at a time per VM, so we must wait for it instead of failing with a Conflict.
  PREP_T0=$SECONDS
  PREP=""
  while :; do
    PREP_FILE=$(mktemp 2>/dev/null || echo "/tmp/prep.$$")
    PREP_ERR=$(mktemp 2>/dev/null || echo "/tmp/preperr.$$")
    az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript \
        --scripts "$GUEST_PREP_PS" --query "value[0].message" -o tsv >"$PREP_FILE" 2>"$PREP_ERR" &
    PREP_PID=$!
    while kill -0 "$PREP_PID" 2>/dev/null; do
      sleep 20
      PREP_EL=$((SECONDS-PREP_T0))
      printf '        ...still working inside Windows (%02d:%02d elapsed, this is normal)\n' $((PREP_EL/60)) $((PREP_EL%60))
      if [ "$PREP_EL" -ge "$PREP_TIMEOUT" ]; then
        kill "$PREP_PID" 2>/dev/null
        die "The in-guest prep exceeded ${PREP_TIMEOUT}s without finishing." "Azure's run-command has a hard 90-minute limit. Check the VM's CPU/disk metrics in the portal - if it is still busy, re-run with a bigger PREP_TIMEOUT. NOTHING destructive has run: the VM and the OS disk are unchanged and snapshot '$SNAPSHOT' is your rollback point."
      fi
    done
    wait "$PREP_PID" 2>/dev/null
    PREP=$(tr -d '\000' <"$PREP_FILE" 2>/dev/null)
    PREP_ERRTXT=$(tr -d '\000' <"$PREP_ERR" 2>/dev/null)
    rm -f "$PREP_FILE" "$PREP_ERR" 2>/dev/null

    # A previous (interrupted) run is still executing in the guest -> wait for it, do not fail.
    if [ -z "${PREP//[[:space:]]/}" ] && grep -qiE 'in progress|conflict|already running' <<<"$PREP_ERRTXT"; then
      warn "Another run-command is STILL EXECUTING inside this VM."
      warn "This is normal if a previous run of this script was interrupted with Ctrl-C: that stops"
      warn "only the local command, not the script inside Windows, which keeps converting the disk."
      warn "Waiting 60s and retrying. Do NOT reboot, stop or resize the VM while this is in progress."
      sleep 60
      if [ $((SECONDS-PREP_T0)) -ge "$PREP_TIMEOUT" ]; then
        die "Still blocked by a previous in-guest run after ${PREP_TIMEOUT}s." "Wait for the earlier run to finish (watch CPU/disk metrics in the portal) and re-run this script. Do NOT reboot the VM. NOTHING destructive has run: snapshot '$SNAPSHOT' remains your rollback point."
      fi
      continue
    fi

    # Surface the az error instead of swallowing it - a silent empty result used to hide the cause.
    if [ -n "$PREP_ERRTXT" ]; then
      warn "Azure reported the following while running the in-guest prep:"
      printf '%s\n' "$PREP_ERRTXT" | sed 's/^/        /'
    fi
    break
  done
  step "In-guest prep call returned after $(( (SECONDS-PREP_T0)/60 ))m $(( (SECONDS-PREP_T0)%60 ))s."
fi
[ "$DRYRUN" != 1 ] && printf '%s\n' "$PREP" | sed 's/^/        /'

if [ "$DRYRUN" != 1 ]; then
  # Empty/again-partial result => the guest agent did not run our script (VM not fully booted, agent
  # unhealthy, or run-command blocked). Treat as a hard failure rather than a false success.
  # Distinguish "agent never ran our script" (empty) from "script ran but errored partway"
  # (has some markers but not the final STORNVME=). Either way we must not proceed.
  if ! grep -q "STORNVME=" <<<"$PREP"; then
    if [ -z "${PREP//[[:space:]]/}" ]; then
      die "The in-guest preparation returned no result." "The Azure VM guest agent did not run the script (VM still booting, agent unhealthy, run-command blocked, or the Cloud Shell session expired mid-run). Confirm the VM is running and the guest agent is 'Ready' in the portal, then simply re-run this script - it is safe to re-run and will skip anything already done."
    fi
    die "The in-guest preparation did not finish (see the partial output above)." "The guest script stopped before completing all steps. Copy the full output above and send it to us so we can pinpoint the failing step, then re-run."
  fi
  # C: could not be shrunk yet because pagefile.sys / hiberfil.sys are still open. They have
  # just been de-configured, and Windows only releases them at the next boot - so restart once
  # and run the prep again. NOTE: growing the disk does NOT help here; mbr2gpt in full-OS mode
  # ignores existing unallocated space and insists on shrinking C: itself.
  if grep -q "MBR2GPT=NEED_REBOOT" <<<"$PREP"; then
    if [ "$PREP_ATTEMPT" -ge 2 ]; then
      die "Even after a restart, Windows still cannot shrink C:." "Send us the SHRINK_FREED_MB / DISKPART / LAST_UNMOVABLE lines above - LAST_UNMOVABLE names the exact file that blocks the shrink. NOTHING destructive has run - the VM still boots and snapshot '$SNAPSHOT' remains your rollback point."
    fi
    warn "Windows cannot shrink C: yet: pagefile.sys and/or hiberfil.sys are still open."
    warn "They have just been DISABLED, and only a restart actually releases them."
    warn "This is a normal, reversible Windows reboot - no data is touched. A system-managed"
    warn "pagefile on C: is restored automatically once the disk is GPT."
    confirm "Restart Windows now to release those files, then continue automatically?"
    step "Restarting the VM..."
    run az vm restart -g "$RG" -n "$VM" -o none
    if ! wait_boot 40; then
      die "The VM did not report back after the restart." "Check it in the portal; once it is running and the guest agent is 'Ready', simply re-run this script - it is safe to re-run and resumes where it stopped. Snapshot '$SNAPSHOT' remains your rollback point."
    fi
    ok "VM restarted and responding - re-running the guest prep (attempt 2/2)."
    continue
  fi
  # The shrink was refused although the file system itself reports tens of GB as reclaimable
  # (see the CPART= line). Every removal we did - pagefile, hibernation file, shadow copies,
  # guest-agent traces - only takes effect for the shrink logic after a reboot: until then NTFS
  # still accounts for the old extents and the volume bitmap is not re-evaluated. So restart once
  # and retry before declaring this blocked.
  if grep -q "SHRINK=BLOCKED" <<<"$PREP" && [ "$PREP_ATTEMPT" -lt 2 ]; then
    warn "Windows refused to shrink C:, even though it reports tens of GB as reclaimable."
    warn "The pagefile, hibernation file, shadow copies and stale guest-agent logs have just been"
    warn "removed, but NTFS only re-evaluates the volume after a restart. Retrying once after a reboot."
    confirm "Restart Windows now and retry the shrink automatically?"
    step "Restarting the VM..."
    run az vm restart -g "$RG" -n "$VM" -o none
    if ! wait_boot 40; then
      die "The VM did not report back after the restart." "Check it in the portal; once it is running and the guest agent is 'Ready', simply re-run this script - it is safe to re-run and resumes where it stopped. Snapshot '$SNAPSHOT' remains your rollback point."
    fi
    ok "VM restarted and responding - re-running the guest prep (attempt 2/2)."
    continue
  fi
  # Shrink worked but mbr2gpt still refused: we have then hit the hard limitation of full-OS mode
  # (it will not reuse the System Reserved partition, and it does not use free space it did not
  # create itself). That cannot be solved from inside the running OS - say so explicitly instead
  # of sending the operator round the same loop again.
  if grep -q "CONVERT_FAIL" <<<"$PREP" && grep -q "SHRINK=OK" <<<"$PREP"; then
    die "C: was shrunk successfully, but mbr2gpt still cannot create the EFI partition." "This is the known dead end of running mbr2gpt inside a live Windows (/allowFullOS): it logs 'System partition cannot be removed in full OS mode, leaving it untouched', so it refuses to reuse the existing 500MB 'System Reserved' partition, and it will not use free space it did not create itself. The conversion has to be done with the disk OFFLINE, from WinRE on this VM (reagentc /boottore + restart, then 'mbr2gpt /convert /disk:0'), where that restriction does not apply and the System Reserved partition itself becomes the EFI partition. Note that attaching the OS disk to a helper VM does NOT work: mbr2gpt only accepts the system disk. Contact us and we will drive the WinRE procedure with you. NOTHING destructive has run - the VM still boots and snapshot '$SNAPSHOT' remains your rollback point."
  fi
  case "$PREP" in
    *BITLOCKER_ON*)   die "BitLocker is ON on C:." "Suspend/disable BitLocker on C:, then re-run.";;
    *NO_TOOL_WS2016*) die "This guest is Windows Server 2016 (no mbr2gpt)." "Upgrade the guest OS to 2019/2022 first, then re-run.";;
    *SHRINK_BLOCKED*) die "Windows cannot shrink C: at all, even after a restart and a free-space consolidation." "Every prerequisite has been cleared (pagefile, hibernation file, shadow copies, stale guest-agent traces) and the file system itself reports tens of GB as reclaimable on the CPART= line, yet diskpart, Resize-Partition and mbr2gpt all refuse the shrink. We have exhausted what can be done from inside the running OS. The remaining route is the OFFLINE conversion from WinRE on this VM, where mbr2gpt turns the existing 500MB 'System Reserved' partition into the EFI partition and no shrink of C: is needed at all. Send us the CPART / DISKPART / DISKPART2 / RESIZE / LAST_UNMOVABLE lines above and we will schedule that with you. NOTHING destructive has run - snapshot '$SNAPSHOT' remains your rollback point.";;
    *VALIDATE_FAIL*)  die "mbr2gpt /validate failed (details captured above: MBR2GPT_OUT / SETUPACT / DISK0 / PART lines)." "Send us those lines - they name the exact reason. Most common: >3 primary partitions, or no room for the ~100MB EFI system partition. Do NOT proceed; we'll advise the targeted fix.";;
    *CONVERT_FAIL*)   die "mbr2gpt /convert failed (diagnostics captured above)." "mbr2gpt validated the disk but could not create the ~100MB EFI partition. In full-OS mode it ALWAYS carves the ESP by shrinking C: - it ignores unallocated space that already exists on the disk, so growing the disk does not help. 'Partition final size is <n> (initial size was <n>)' means the shrink freed nothing because an immovable file sits at the end of C:. Send us the SHRINK_FREED_MB / DISKPART / LAST_UNMOVABLE lines above. NOTHING destructive has run - snapshot '$SNAPSHOT' remains your rollback point.";;
    *MBR2GPT=ERROR:*) die "The MBR->GPT step raised an error (see 'MBR2GPT=ERROR:' above)." "Send us that line; the OS disk was not converted, so nothing downstream ran.";;
    *GPT_NO_ESP*)     die "The OS disk is GPT but has no EFI System Partition." "Unusual layout - send us the OSDISK/PART lines above so we can add the ESP before the Gen2 flip.";;
    *STORNVME=MISSING*) die "StorNVMe driver missing (very old image)." "Update the guest to WS2019+, then re-run.";;
    *STORNVME=ERROR:*) die "Setting the StorNVMe boot-start raised an error (see 'STORNVME=ERROR:' above)." "Send us that line so we can adjust before the rebuild.";;
  esac
  ok "Guest prep applied (pagefile on C:; MBR->GPT done or already GPT; StorNVMe boot-start set)."
fi
break
done
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
    # The OS disk is already verified V2 (authoritative Azure signal) above. Gate on the guest's
    # partition style (must be GPT) and reject only an EXPLICIT BIOS reading. FIRMWARE=UNKNOWN is a
    # probe limitation on some images (this guest reports UNKNOWN even when UEFI), NOT a failure.
    FW=$(gval FIRMWARE); PS=$(gval PARTSTYLE)
    [ "$FW" = "BIOS" ] && die "Guest still reports firmware=BIOS after the Gen2 flip." "Gen2 conversion did not fully take. Roll back from snapshot '$SNAPSHOT'."
    [ "$PS" = "GPT" ] || die "Guest system disk is '$PS' (expected GPT) after the Gen2 flip." "Gen2 conversion did not fully take. Roll back from snapshot '$SNAPSHOT'."
    if [ "$FW" = "UEFI" ]; then ok "Firmware confirmed UEFI."; else warn "Firmware probe returned '$FW', but disk=V2 + partition=GPT confirm Gen2 - continuing."; fi
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
