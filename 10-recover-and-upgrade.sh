#!/usr/bin/env bash
###############################################################################
# 10-recover-and-upgrade.sh
#
# One-shot, fully-instrumented workflow to (1) ROLL BACK a VM that was broken by
# a failed NVMe/v6 conversion to a known-good SCSI-bootable state, (2) VERIFY the
# rollback actually boots, then (3) run the HARDENED in-place upgrade to a v6
# (NVMe) size with a guest verify-or-abort gate and a proof reboot on SCSI first.
#
# Every phase prints a banner (==> PHASE) and every check prints [  OK  ] / [FAIL]
# with the value it observed, so you can see exactly where you are at all times.
#
# WHY THIS EXISTS (root cause of the field failure):
#   * v6 sizes (D2s_v6 / E2s_v6 ...) are NVMe-ONLY. If the OS initramfs that boots
#     lacks the nvme driver, the root disk never appears -> dracut emergency shell
#     ("system-lv_root does not exist").
#   * On Azure Boost the NVMe controller is exposed on a synthetic Hyper-V vPCI bus.
#     If the initramfs lacks pci_hyperv, the guest sees an EMPTY PCI bus, /dev/nvme0n1
#     never appears (even though nvme is loaded) -> same dracut emergency shell. RHEL's
#     hostonly initramfs drops pci_hyperv when rebuilt on a SCSI VM (no vPCI present at
#     build time), so it MUST be force-added.
#   * The rollback ALSO failed because its snapshot was taken AFTER the guest was
#     edited, so the broken initramfs (missing LVM auto-activation) was baked in.
#   -> Fix: roll back from a CLEAN pre-edit snapshot, PROVE it boots on SCSI, then
#      prep + VERIFY the guest, PROVE it still boots on SCSI, and only THEN convert
#      to NVMe in a single atomic size+controller update.
#
# ---------------------------------------------------------------------------
# ONE-LINE USAGE (env vars):
#   RG=RG-RNDDEV-CFI01 VM=azurl41015 SNAPSHOT=azurl41015-os-PRE \
#   TARGET_SIZE=Standard_D2s_v6 ROLLBACK_SIZE=Standard_DS1_v2 \
#   bash 10-recover-and-upgrade.sh
#
# MODES (optional):  MODE=full          (default: rollback + verify + upgrade)
#                    MODE=rollback-only (just restore & verify the SCSI VM)
#                    MODE=upgrade-only  (skip rollback; prep+verify+convert current VM)
#   DRYRUN=1  -> print every az command instead of running the state-changing ones.
#
# Required: RG, VM, TARGET_SIZE (unless rollback-only), SNAPSHOT (unless upgrade-only)
###############################################################################
set -uo pipefail

# ----------------------------- parameters ----------------------------------
RG="${RG:-}"; VM="${VM:-}"
SNAPSHOT="${SNAPSHOT:-}"
TARGET_SIZE="${TARGET_SIZE:-}"
ROLLBACK_SIZE="${ROLLBACK_SIZE:-Standard_DS1_v2}"
MODE="${MODE:-full}"
DRYRUN="${DRYRUN:-0}"
BOOT_TRIES="${BOOT_TRIES:-40}"     # boot-health polls (x ~15s)

# ----------------------------- pretty output -------------------------------
c_reset=$'\033[0m'; c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_hd=$'\033[36m'; c_wn=$'\033[33m'
PHASE_N=0
phase(){ PHASE_N=$((PHASE_N+1)); printf '\n%s========================================================================%s\n' "$c_hd" "$c_reset"; printf '%s==> PHASE %s: %s%s\n' "$c_hd" "$PHASE_N" "$1" "$c_reset"; printf '%s========================================================================%s\n' "$c_hd" "$c_reset"; }
step(){ printf '   %s-> %s%s\n' "$c_hd" "$1" "$c_reset"; }
ok(){   printf '   [  %sOK%s  ] %s\n' "$c_ok" "$c_reset" "$1"; }
bad(){  printf '   [ %sFAIL%s ] %s\n' "$c_bad" "$c_reset" "$1"; }
warn(){ printf '   [ %sWARN%s ] %s\n' "$c_wn" "$c_reset" "$1"; }
die(){  bad "$1"; printf '\n%sABORTED.%s %s\n' "$c_bad" "$c_reset" "${2:-No changes left the VM in a worse state than described above.}"; exit 1; }
# run a state-changing az command (honours DRYRUN)
run(){ if [ "$DRYRUN" = 1 ]; then printf '   %s[dry-run]%s %s\n' "$c_wn" "$c_reset" "$*"; else "$@"; fi; }

# ----------------------------- preflight -----------------------------------
phase "Preflight & context"
[ -n "$RG" ] && [ -n "$VM" ] || die "RG and VM are required." "Set them: RG=... VM=... bash $0"
command -v az >/dev/null 2>&1 || die "azure-cli (az) not found on PATH."
az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"
step "Subscription: $(az account show --query name -o tsv 2>/dev/null)"

az vm show -g "$RG" -n "$VM" >/dev/null 2>&1 || die "VM '$VM' not found in RG '$RG'."
CUR_SIZE=$(az vm show -g "$RG" -n "$VM" --query "hardwareProfile.vmSize" -o tsv 2>/dev/null)
CUR_CTRL=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.diskControllerType" -o tsv 2>/dev/null)
CUR_SEC=$(az vm show  -g "$RG" -n "$VM" --query "securityProfile.securityType" -o tsv 2>/dev/null)
LOCATION=$(az vm show -g "$RG" -n "$VM" --query "location" -o tsv 2>/dev/null)
POWER=$(az vm get-instance-view -g "$RG" -n "$VM" --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" -o tsv 2>/dev/null)
ok "Current: size=${CUR_SIZE:-?}  controller=${CUR_CTRL:-SCSI}  security=${CUR_SEC:-Standard}  power='${POWER:-?}'  loc=$LOCATION"

case "$MODE" in full|rollback-only|upgrade-only) ok "Mode: $MODE" ;; *) die "Unknown MODE='$MODE' (use full|rollback-only|upgrade-only)";; esac
if [ "$MODE" != upgrade-only ]; then
  if [ -z "$SNAPSHOT" ]; then
    warn "No SNAPSHOT set. Candidate snapshots for this VM:"
    az snapshot list -g "$RG" --query "[?contains(name,'$VM')].{name:name,created:timeCreated,gen:hyperVGeneration}" -o table 2>/dev/null || true
    die "SNAPSHOT is required for rollback." "Pick a CLEAN pre-edit snapshot and set SNAPSHOT=<name>."
  fi
  az snapshot show -g "$RG" -n "$SNAPSHOT" >/dev/null 2>&1 || die "Snapshot '$SNAPSHOT' not found in RG '$RG'."
  SNAP_GEN=$(az snapshot show -g "$RG" -n "$SNAPSHOT" --query "hyperVGeneration" -o tsv 2>/dev/null)
  SNAP_CREATED=$(az snapshot show -g "$RG" -n "$SNAPSHOT" --query "timeCreated" -o tsv 2>/dev/null)
  ok "Rollback snapshot: $SNAPSHOT  (gen=${SNAP_GEN:-?}  created=$SNAP_CREATED)"
fi
if [ "$MODE" != rollback-only ]; then
  [ -n "$TARGET_SIZE" ] || die "TARGET_SIZE is required for the upgrade (e.g. Standard_D2s_v6)."
  ok "Upgrade target size: $TARGET_SIZE"
fi

# ----------------------------- helpers -------------------------------------
# Poll the guest until the Azure agent responds (== the OS actually booted).
# Prints the guest report and returns 0 on success, 1 on timeout.
wait_boot(){
  local tries="$1" i out
  step "Waiting for guest to boot & report health (up to $((tries*15/60)) min)..."
  for ((i=1;i<=tries;i++)); do
    # shellcheck disable=SC2016
    # NOTE: wrap in `timeout` - when the guest agent is down (e.g. dracut emergency
    # shell) `az vm run-command invoke` blocks for the extension timeout (~90 min).
    # Bounding each poll makes boot-failure detection actually fire within BOOT_TRIES.
    out=$(timeout 120 az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts '
      echo BOOT_OK
      echo "KERNEL=$(uname -r)"
      echo "ROOT=$(findmnt -no SOURCE / 2>/dev/null)"
      if ls /dev/nvme0n1 >/dev/null 2>&1; then echo GUEST_CTRL=NVMe; else echo GUEST_CTRL=SCSI; fi
      if command -v lvs >/dev/null 2>&1; then
        A=$(lvs --noheadings -o lv_attr "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null | tr -d " ")
        case "$A" in *a*) echo ROOTLV=active;; *) echo ROOTLV=inactive-or-notlvm;; esac
      fi' \
      --query "value[0].message" -o tsv 2>/dev/null || true)
    if grep -q BOOT_OK <<<"$out"; then printf '%s\n' "$out" | sed 's/^/        /'; return 0; fi
    printf '        ...poll %s/%s (guest not responding yet)\n' "$i" "$tries"
    sleep 15
  done
  return 1
}

# Guest NVMe prep + VERIFY (identical logic to 02-*.sh). Echoes NVME_READY=YES/NO.
guest_prep_and_verify(){
  # shellcheck disable=SC2016  # $(...) / $VARs must run inside the guest, not expand locally
  # `timeout 600` bounds the dracut rebuild; if it overruns, NVME_READY is absent and
  # the caller aborts WITHOUT deallocating, so the VM stays bootable on SCSI.
  timeout 600 az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts '
    set -e
    if command -v dracut >/dev/null 2>&1; then
      echo "add_drivers+=\" nvme nvme_core pci_hyperv hv_vmbus hv_storvsc hv_netvsc hv_utils \"" > /etc/dracut.conf.d/nvme.conf
      dracut -f --regenerate-all --add-drivers "nvme nvme_core pci_hyperv hv_vmbus hv_storvsc hv_netvsc hv_utils"
    elif command -v update-initramfs >/dev/null 2>&1; then
      for m in nvme nvme_core pci_hyperv hv_vmbus hv_storvsc hv_netvsc hv_utils; do
        grep -q "^$m\$" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules
      done
      update-initramfs -u -k all
    fi
    ROOT_SRC=$(findmnt -no SOURCE / || true)
    RDLVM=""
    if command -v lvs >/dev/null 2>&1 && lvs "$ROOT_SRC" >/dev/null 2>&1; then
      VG=$(lvs --noheadings -o vg_name "$ROOT_SRC" | tr -d " ")
      LV=$(lvs --noheadings -o lv_name "$ROOT_SRC" | tr -d " ")
      RDLVM="rd.lvm.vg=${VG}"
    fi
    ARGS="rd.auto nvme_core.io_timeout=240 ${RDLVM}"
    if command -v grubby >/dev/null 2>&1; then
      grubby --update-kernel=ALL --args="$ARGS" || true
    else
      for a in $ARGS; do
        grep -q "$a" /etc/default/grub || sed -i "s#\(GRUB_CMDLINE_LINUX=\"\)#\1$a #" /etc/default/grub
      done
      if command -v update-grub >/dev/null 2>&1; then update-grub
      elif [ -d /boot/grub2 ]; then grub2-mkconfig -o /boot/grub2/grub.cfg; fi
    fi
    if command -v lsinitramfs >/dev/null 2>&1; then
      IMG=$(ls -1v /boot/initrd.img-* 2>/dev/null | grep -v -- -rescue | tail -n1); LISTER=lsinitramfs
    else
      IMG=$(ls -1v /boot/initramfs-*.img 2>/dev/null | grep -v kdump | tail -n1); LISTER=lsinitrd
    fi
    NVME_INITRAMFS=MISSING
    [ -n "$IMG" ] && "$LISTER" "$IMG" 2>/dev/null | grep -q nvme && NVME_INITRAMFS=OK
    # pci_hyperv must be in the initramfs (module) OR built into the kernel; on Azure Boost the
    # NVMe controller lives on a synthetic Hyper-V vPCI bus that only comes up with pci_hyperv.
    PCI_HYPERV=MISSING
    if [ -n "$IMG" ] && "$LISTER" "$IMG" 2>/dev/null | grep -q "pci-hyperv"; then PCI_HYPERV=OK
    elif modinfo pci_hyperv 2>/dev/null | grep -qi "builtin"; then PCI_HYPERV=OK; fi
    LVM_OK=OK
    if [ -n "$RDLVM" ]; then
      if grep -rq "rd.lvm.vg" /boot/loader/entries/ 2>/dev/null \
         || grep -q "rd.lvm.vg" /boot/grub2/grub.cfg 2>/dev/null \
         || grep -q "rd.lvm.vg" /boot/grub/grub.cfg 2>/dev/null; then LVM_OK=OK; else LVM_OK=MISSING; fi
    fi
    FSTAB_OK=OK
    grep -Eq "^[[:space:]]*/dev/sd" /etc/fstab && FSTAB_OK=BAD
    echo "KERNEL_IMG=$IMG"
    echo "NVME_INITRAMFS=$NVME_INITRAMFS"
    echo "PCI_HYPERV=$PCI_HYPERV"
    echo "RDLVM=${RDLVM:-none} LVM_OK=$LVM_OK"
    echo "FSTAB_OK=$FSTAB_OK"
    if [ "$NVME_INITRAMFS" = OK ] && [ "$PCI_HYPERV" = OK ] && [ "$LVM_OK" = OK ] && [ "$FSTAB_OK" = OK ]; then echo NVME_READY=YES; else echo NVME_READY=NO; fi
    ' --query "value[0].message" -o tsv 2>/dev/null || true
}

###############################################################################
# PHASE: ROLLBACK  (restore a known-good SCSI-bootable VM from a clean snapshot)
###############################################################################
if [ "$MODE" != upgrade-only ]; then
  phase "Rollback to known-good SCSI state from snapshot '$SNAPSHOT'"

  step "Capturing config to preserve (NIC / data disks / tags / security type)"
  NIC=$(az vm show -g "$RG" -n "$VM" --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null)
  DATA_DISKS=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.dataDisks[].managedDisk.id" -o tsv 2>/dev/null)
  [ -n "$NIC" ] && ok "NIC: ${NIC##*/}" || die "Could not read the VM NIC."
  [ -n "$DATA_DISKS" ] && ok "Data disks to re-attach: $(wc -w <<<"$DATA_DISKS")" || step "No data disks attached."

  SNAP_ID=$(az snapshot show -g "$RG" -n "$SNAPSHOT" --query id -o tsv)
  ROLLBACK_DISK="${VM}-rollback-osdisk"
  step "Creating rollback OS disk '$ROLLBACK_DISK' from the snapshot (inherits gen=${SNAP_GEN:-?})"
  if az disk show -g "$RG" -n "$ROLLBACK_DISK" >/dev/null 2>&1; then
    warn "Disk '$ROLLBACK_DISK' already exists - reusing it."
  else
    run az disk create -g "$RG" -l "$LOCATION" -n "$ROLLBACK_DISK" --source "$SNAP_ID" -o none \
      && ok "Rollback disk created." || die "Failed to create rollback disk."
  fi
  # Tag it SCSI-capable so a SCSI VM can boot it (a v6-tagged disk still lists SCSI too; harmless).
  run az disk update -g "$RG" -n "$ROLLBACK_DISK" --set supportedCapabilities.diskControllerTypes='SCSI, NVMe' -o none >/dev/null 2>&1 || true

  step "Deallocating '$VM' before swap/recreate"
  run az vm deallocate -g "$RG" -n "$VM" -o none && ok "Deallocated." || warn "Deallocate returned non-zero (may already be stopped)."

  step "Attempting in-place OS-disk swap to the rollback disk (works if VM is still SCSI)"
  if [ "$DRYRUN" = 1 ]; then
    warn "[dry-run] would try: az vm update --os-disk $ROLLBACK_DISK  (fallback: delete+recreate)"
  elif az vm update -g "$RG" -n "$VM" --os-disk "$ROLLBACK_DISK" -o none 2>/tmp/rb_err.$$; then
    ok "OS-disk swap succeeded."
    # ensure it is on the SCSI rollback size
    az vm update -g "$RG" -n "$VM" --set hardwareProfile.vmSize="$ROLLBACK_SIZE" storageProfile.diskControllerType=SCSI -o none 2>/dev/null || true
  else
    warn "Swap rejected (VM is on an NVMe-only size). Falling back to DELETE + RECREATE:"
    sed 's/^/        /' "/tmp/rb_err.$$" 2>/dev/null; rm -f "/tmp/rb_err.$$"
    step "Deleting the converted VM '$VM' (NIC + disks are retained)"
    az vm delete -g "$RG" -n "$VM" --yes -o none && ok "VM resource deleted (NIC/disks kept)." || die "Failed to delete VM for recreate."
    step "Recreating original SCSI VM '$VM' ($ROLLBACK_SIZE) from the rollback disk"
    SEC_ARGS=()
    if [ "${CUR_SEC:-Standard}" = "TrustedLaunch" ]; then SEC_ARGS=(--security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true); fi
    az vm create -g "$RG" -n "$VM" --attach-os-disk "$ROLLBACK_DISK" --os-type Linux \
        --size "$ROLLBACK_SIZE" --nics "$NIC" "${SEC_ARGS[@]}" -o none \
      && ok "VM recreated on SCSI." || die "Failed to recreate VM."
    if [ -n "$DATA_DISKS" ]; then
      step "Re-attaching data disks"
      for d in $DATA_DISKS; do
        az vm disk attach -g "$RG" --vm-name "$VM" --name "$d" -o none 2>/dev/null \
          && ok "attached ${d##*/}" || warn "could not attach ${d##*/} (attach manually)"
      done
    fi
  fi
  rm -f "/tmp/rb_err.$$" 2>/dev/null || true

  step "Enabling boot diagnostics (so serial log is available if boot fails)"
  run az vm boot-diagnostics enable -g "$RG" -n "$VM" -o none >/dev/null 2>&1 && ok "Boot diagnostics enabled." || warn "Could not enable boot diagnostics."

  step "Starting '$VM'"
  run az vm start -g "$RG" -n "$VM" -o none && ok "Start issued." || die "Failed to start VM."

  # ---- VERIFY the rollback actually booted on SCSI ----
  phase "VERIFY rollback booted correctly (must pass before upgrading)"
  if [ "$DRYRUN" = 1 ]; then warn "[dry-run] skipping live boot verification."; else
    if REPORT=$(wait_boot "$BOOT_TRIES"); then
      ok "Guest agent responded -> the OS booted."
      grep -q "GUEST_CTRL=SCSI" <<<"$REPORT" && ok "Disk controller in guest: SCSI (expected)." || warn "Guest not on SCSI: $(grep GUEST_CTRL <<<"$REPORT")"
      if grep -q "ROOTLV=" <<<"$REPORT"; then grep -q "ROOTLV=active" <<<"$REPORT" && ok "LVM root is active." || warn "Root LV not reported active."; fi
      RB_SIZE=$(az vm show -g "$RG" -n "$VM" --query "hardwareProfile.vmSize" -o tsv)
      RB_CTRL=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.diskControllerType" -o tsv)
      ok "Azure view: size=$RB_SIZE controller=${RB_CTRL:-SCSI}"
      grep -q "$(printf '%s' "$REPORT" | grep KERNEL)" <<<"$REPORT" && ok "$(grep KERNEL <<<"$REPORT" | head -1)"
    else
      die "Rollback VM did NOT boot within the timeout." \
          "Open Serial Console (Boot diagnostics). If it drops to dracut, in the shell run: lvm vgchange -ay; exit. If '/dev/sd*' is empty -> offline-repair on a helper VM. Do NOT proceed to upgrade."
    fi
  fi
  if [ "$MODE" = rollback-only ]; then
    phase "DONE (rollback-only)"; ok "VM '$VM' restored and booting on SCSI ($ROLLBACK_SIZE)."
    echo "  Re-apply extensions / managed identities / tags if the VM was recreated."; exit 0
  fi
fi

###############################################################################
# PHASE: GUEST NVMe PREP + VERIFY (gate) — VM must be booting on SCSI now
###############################################################################
phase "Prepare guest for NVMe and VERIFY (abort if not ready)"
OSDISK=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.name" -o tsv)
step "OS disk in use: $OSDISK"
step "Rebuilding initramfs for ALL kernels (nvme + pci_hyperv + hv_*) and setting rd.lvm.vg / rd.auto"
if [ "$DRYRUN" = 1 ]; then warn "[dry-run] skipping guest prep."; PREP_MSG="NVME_READY=YES"; else PREP_MSG=$(guest_prep_and_verify); fi
printf '%s\n' "$PREP_MSG" | sed 's/^/        /'
if grep -q "NVME_INITRAMFS=OK"  <<<"$PREP_MSG"; then ok "nvme present in NEWEST-kernel initramfs."; else bad "nvme MISSING from newest-kernel initramfs."; fi
if grep -q "PCI_HYPERV=OK"      <<<"$PREP_MSG"; then ok "pci_hyperv present (Azure Boost NVMe vPCI bus will enumerate)."; else bad "pci_hyperv MISSING -> NVMe controller will NOT appear on the vPCI bus (empty PCI bus / dracut hang)."; fi
if grep -q "LVM_OK=OK"          <<<"$PREP_MSG"; then ok "rd.lvm.vg present (whole VG activates: root + separate /usr,/var)."; else bad "rd.lvm.vg MISSING for LVM root."; fi
if grep -q "FSTAB_OK=OK"        <<<"$PREP_MSG"; then ok "/etc/fstab uses UUIDs (no /dev/sdX)."; else bad "/etc/fstab references /dev/sdX - convert to UUID."; fi
grep -q "NVME_READY=YES" <<<"$PREP_MSG" \
  && ok "GATE PASSED: guest is NVMe-ready." \
  || die "GATE FAILED: guest is NOT NVMe-ready." "The VM was NOT deallocated and stays bootable on SCSI. Fix the item(s) marked FAIL above, then re-run with MODE=upgrade-only."

###############################################################################
# PHASE: PROVE the new initramfs still boots on SCSI (zero NVMe risk)
###############################################################################
phase "Proof reboot on SCSI with the new initramfs"
step "Restarting the guest (still on SCSI)"
if [ "$DRYRUN" = 1 ]; then warn "[dry-run] skipping proof reboot."; else
  az vm restart -g "$RG" -n "$VM" -o none && ok "Restart issued." || die "Restart failed."
  if REPORT=$(wait_boot "$BOOT_TRIES"); then
    ok "Guest rebooted cleanly with the rebuilt initramfs (still SCSI)."
    grep -q "ROOTLV=active" <<<"$REPORT" && ok "LVM root active after reboot." || warn "Root LV state: $(grep ROOTLV <<<"$REPORT" || echo n/a)"
  else
    die "The rebuilt initramfs did NOT boot on SCSI." "Do NOT convert to NVMe. Recover via Serial Console (lvm vgchange -ay; exit) or offline repair, then re-run MODE=upgrade-only."
  fi
fi

###############################################################################
# PHASE: CONVERT TO NVMe (single atomic size + controller update)
###############################################################################
phase "Convert to $TARGET_SIZE on NVMe"
OSDISK=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.name" -o tsv)

step "Deallocating for the conversion"
run az vm deallocate -g "$RG" -n "$VM" -o none && ok "Deallocated." || die "Deallocate failed."

# Gen2 is required by v6. Convert only if the disk is still Gen1.
DISK_GEN=$(az disk show -g "$RG" -n "$OSDISK" --query "hyperVGeneration" -o tsv 2>/dev/null)
if [ "${DISK_GEN:-V2}" = "V1" ]; then
  step "OS disk is Gen1 -> upgrading VM to Trusted Launch / Gen2 in place"
  run az vm update -g "$RG" -n "$VM" --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true -o none \
    && ok "Converted to Gen2/Trusted Launch." || warn "Gen2 conversion returned non-zero; verify OS Gen2 readiness."
else
  ok "OS disk already Gen2 (gen=$DISK_GEN) - no Gen1->Gen2 conversion needed."
fi

step "Tagging OS disk '$OSDISK' as NVMe-capable (SCSI, NVMe)"
run az disk update -g "$RG" -n "$OSDISK" --set supportedCapabilities.diskControllerTypes='SCSI, NVMe' -o none \
  && ok "Disk tagged NVMe-capable." || die "Failed to tag OS disk (this is what blocks the resize)."

step "Resizing to $TARGET_SIZE AND switching controller to NVMe in ONE update"
run az vm update -g "$RG" -n "$VM" \
    --set hardwareProfile.vmSize="$TARGET_SIZE" storageProfile.diskControllerType=NVMe -o none \
  && ok "Size + NVMe controller applied atomically." || die "Combined size/NVMe update failed."

step "Starting on NVMe"
run az vm start -g "$RG" -n "$VM" -o none && ok "Start issued." || die "Start failed."

###############################################################################
# PHASE: VERIFY the NVMe boot
###############################################################################
phase "VERIFY the upgraded VM boots on NVMe"
if [ "$DRYRUN" = 1 ]; then warn "[dry-run] skipping final verification."; else
  if REPORT=$(wait_boot "$BOOT_TRIES"); then
    ok "Guest agent responded -> the OS booted on the v6 size."
    grep -q "GUEST_CTRL=NVMe" <<<"$REPORT" && ok "Disk controller in guest: NVMe (expected)." || warn "Guest controller: $(grep GUEST_CTRL <<<"$REPORT")"
    grep -q "ROOTLV=active"   <<<"$REPORT" && ok "LVM root active on NVMe." || warn "Root LV state: $(grep ROOTLV <<<"$REPORT" || echo n/a)"
    FIN_SIZE=$(az vm show -g "$RG" -n "$VM" --query "hardwareProfile.vmSize" -o tsv)
    FIN_CTRL=$(az vm show -g "$RG" -n "$VM" --query "storageProfile.diskControllerType" -o tsv)
    ok "Azure view: size=$FIN_SIZE controller=$FIN_CTRL"
    phase "SUCCESS"
    echo "  '$VM' upgraded to $FIN_SIZE on NVMe and booting cleanly."
    echo "  Rollback snapshot '$SNAPSHOT' and disk '${VM}-rollback-osdisk' are retained - keep them a few days."
  else
    die "Upgraded VM did NOT boot on NVMe within the timeout." \
        "Roll back now:  MODE=rollback-only SNAPSHOT=$SNAPSHOT ROLLBACK_SIZE=$ROLLBACK_SIZE RG=$RG VM=$VM bash $0"
  fi
fi
