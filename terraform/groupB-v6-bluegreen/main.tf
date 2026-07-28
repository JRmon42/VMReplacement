##############################################################################
# GROUP B - DSv2 (Gen1/SCSI) -> v6 (Gen2/NVMe)  |  BLUE/GREEN in Terraform
#
# Why blue/green: in the azurerm provider `secure_boot_enabled`, `vtpm_enabled`
# and `disk_controller_type` are ForceNew, so flipping them on the live VM would
# make Terraform DESTROY + RECREATE it (losing the OS disk). Instead we declare
# a NEW v6 VM built from the migrated Gen2 OS disk, validate, then retire the old
# one. State stays consistent because every resource is declared.
#
# PLAN
#   1. Snapshot the old OS disk first (script 00-snapshot-all.sh).
#   2. Create a Gen2 managed disk FROM that snapshot (hyper_v_generation = "V2").
#   3. Create the v6 VM from that disk (Trusted Launch + NVMe), attach the
#      swap/tmp data disk, validate the app.
#   4. Cut over the private IP / DNS / LB backend, then remove the old VM.
#
# RECOMMENDATION: use the "d" v6 sizes (D2ds_v6 / E2ds_v6). They ship a ~110 GiB
# LOCAL NVMe disk perfect for swap/tmp - no separate managed disk to bill.
# Mapping: DS1_v2 -> D2s_v6 (or D2ds_v6);  DS11_v2 -> E2s_v6 (or E2ds_v6).
##############################################################################

variable "resource_group_name" {
  type    = string
  default = "myResourceGroup"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "subnet_id" {
  type    = string
  default = "" # existing subnet resource ID
}

# Name of the OS-disk snapshot taken by 00-snapshot-all.sh, e.g.
# "vm-ds11v2-os-20260707-101500". Provide the full resource ID.
variable "os_snapshot_id" {
  type    = string
  default = ""
}

locals {
  src_vm = "vm-ds11v2"        # old Gen1 VM being replaced
  target = "Standard_E2ds_v6" # "d" size => local NVMe for swap/tmp
}

# 2) Gen2 OS disk created from the pre-migration snapshot.
#
# NVMe readiness (IMPORTANT):
#   (a) The SOURCE guest OS must be NVMe-ready BEFORE the snapshot (nvme in initramfs,
#       GRUB nvme_core.io_timeout=240, /etc/fstab on UUIDs) or the new VM will not boot.
#       Run migration script 02 step 1 on the source first if it has never booted on NVMe.
#   (b) A disk copied from an old SCSI snapshot does NOT advertise NVMe. azurerm has no
#       argument for supportedCapabilities.diskControllerTypes, so the null_resource below
#       tags it via CLI before the VM is created; otherwise disk_controller_type = "NVMe"
#       is rejected with "cannot boot with DiskControllerType 'NVMe'".
resource "azurerm_managed_disk" "v6_os" {
  name                 = "${local.src_vm}-osdisk-v6"
  resource_group_name  = var.resource_group_name
  location             = var.location
  storage_account_type = "Premium_LRS"
  create_option        = "Copy"
  source_resource_id   = var.os_snapshot_id
  hyper_v_generation   = "V2" # required for v6 / Trusted Launch
  os_type              = "Linux"
}

# 2b) Advertise NVMe on the copied OS disk (azurerm cannot set this natively).
# Requires the Azure CLI to be installed and authenticated in the Terraform runner.
resource "null_resource" "v6_os_nvme_capability" {
  triggers = {
    disk_id = azurerm_managed_disk.v6_os.id
  }
  provisioner "local-exec" {
    command = "az disk update --ids ${azurerm_managed_disk.v6_os.id} --set supportedCapabilities.diskControllerTypes='SCSI, NVMe' -o none"
  }
}

# NIC for the new VM. To preserve the ORIGINAL private IP, set a static address
# equal to the old VM's IP AFTER the old NIC is freed (or move the old NIC).
resource "azurerm_network_interface" "v6" {
  name                           = "${local.src_vm}-v6-nic"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic" # switch to "Static" + address at cutover
  }
}

# 3) New v6 VM attached to the migrated Gen2 OS disk (no reimage).
resource "azurerm_linux_virtual_machine" "v6" {
  name                = "${local.src_vm}-v6" # rename to ${local.src_vm} after decommissioning old
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = local.target

  network_interface_ids = [azurerm_network_interface.v6.id]

  # Trusted Launch (Gen2) + NVMe disk controller = the v6 requirement.
  secure_boot_enabled  = true
  vtpm_enabled         = true
  disk_controller_type = "NVMe"

  # Boot from the already-migrated Gen2 OS disk instead of a fresh image.
  # (azurerm >= 4.x: os_managed_disk_id attaches an existing managed OS disk;
  #  no admin_username / SSH key is needed when attaching an existing disk.)
  os_managed_disk_id = azurerm_managed_disk.v6_os.id

  # Ensure the OS disk advertises NVMe before this VM is created.
  depends_on = [null_resource.v6_os_nvme_capability]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }
}

# Swap/tmp: OPTION 1 - keep a persistent managed data disk (carry the old one
# over, or create a new one). OPTION 2 - drop this and rely on the D2ds/E2ds
# local NVMe disk (ephemeral, no billing). Shown here as Option 1.
resource "azurerm_managed_disk" "v6_swap" {
  name                 = "${local.src_vm}-v6-swap"
  resource_group_name  = var.resource_group_name
  location             = var.location
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 16
}

resource "azurerm_virtual_machine_data_disk_attachment" "v6_swap" {
  managed_disk_id    = azurerm_managed_disk.v6_swap.id
  virtual_machine_id = azurerm_linux_virtual_machine.v6.id
  lun                = 0
  caching            = "ReadWrite"
}

output "next_steps" {
  value = <<-EOT
    1. terraform apply  (builds ${local.src_vm}-v6 from the migrated Gen2 disk)
    2. Validate the app on the new VM.
    3. Cut over: repoint DNS / LB backend, or move the private IP to the v6 NIC.
    4. Remove the OLD VM from Terraform config and `terraform apply`; keep its
       OS disk + snapshot for a few days as rollback.
    5. (optional) Rename ${local.src_vm}-v6 back to ${local.src_vm}.
  EOT
}
