# Azure VM Migration Scripts

Replacement of Reserved-Instance VMs with latest-generation PAYGO equivalents,
preserving all configuration stored on the system (OS) disk. Region: West Europe.

> Edit `RG`, the VM names, and (for blue/green) the snapshot names before running.
> Test in a non-production subscription first.

| # | Script | Scope | Method |
|---|--------|-------|--------|
| 00 | `00-snapshot-all.sh` | All VMs | Pre-step: incremental rollback snapshots (no downtime) |
| 01 | `01-resize-bseries-to-bsv2.sh` / `.ps1` | B4ms,B8ms,B1ms,B1s,B16ms | **In-place resize** to Bsv2 |
| 02 | `02-upgrade-dsv2-inplace-to-v6.sh` | DS1_v2, DS11_v2 | In-place **Gen1->Gen2 + NVMe** then resize to v6 |
| 03 | `03-dsv2-bluegreen-to-v6.sh` | DS1_v2, DS11_v2 | **Blue/green** from snapshot (lowest service interruption) |
| 99 | `99-rollback.sh` | Any | Restore OS disk from a snapshot |

## Recommended path per VM
- **B-series -> Bsv2:** Script 01. Same SCSI controller + Gen1/Gen2 support, so a plain
  resize keeps the system disk untouched. Lowest risk.
- **DS1_v2 / DS11_v2 -> v6:** v6 requires **Gen2 + NVMe**, so a plain resize is blocked.
  Use Script 02 (keep same disk) or, for near-zero downtime + instant rollback, Script 03.

Always run **00** first.
