# Terraform migration examples

Illustrative, **validated** (`terraform validate`, azurerm ~> 4.0) examples for the two
migration groups. They accompany `VM_Replacement_Terraform_Migration_Reply.docx`.
Treat them as templates: wire in your existing resource group, subnet, NIC, SSH key
and (for Group B) the OS-disk snapshot ID, and reconcile with your current state.

| Module | Group | Method |
|--------|-------|--------|
| `groupA-bsv2-resize/` | B-series → Bsv2 | **In-place resize** — change `size`, `terraform apply` (no recreate) |
| `groupB-v6-bluegreen/` | DSv2 → v6 (Gen2/NVMe) | **Blue/green** — new v6 VM from the migrated Gen2 OS disk, then cut over |

## Why two different methods
- `size` is an **in-place** update on `azurerm_linux_virtual_machine`, so the Bsv2 resize
  is a one-line change with no state drift.
- `secure_boot_enabled`, `vtpm_enabled` and `disk_controller_type` are **ForceNew**, so
  enabling Gen2/NVMe/Trusted Launch on the live VM would destroy + recreate it. The
  blue/green module sidesteps that by declaring a **new** VM built from the migrated
  Gen2 OS disk (`os_managed_disk_id`), then retiring the old one.

## Swap / tmp disk
- Modeled as a standalone `azurerm_managed_disk` + `azurerm_virtual_machine_data_disk_attachment`
  so it survives VM recreation and detaches/reattaches cleanly.
- Alternatively, use the **`D2ds_v6` / `E2ds_v6`** sizes (Group B): they include a ~110 GiB
  **local NVMe** disk for swap/tmp with no separate managed disk to bill.

## Usage
```bash
cd groupA-bsv2-resize          # or groupB-v6-bluegreen
terraform init
terraform plan   -var 'resource_group_name=...' -var 'subnet_id=...'
terraform apply  -var 'resource_group_name=...' -var 'subnet_id=...'
```
Group B also needs `-var 'os_snapshot_id=<snapshot resource ID>'`.

> Validate in a non-production subscription first, and always run
> `00-snapshot-all.sh` before any destructive step.
