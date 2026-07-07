##############################################################################
# GROUP A - B-series (v1) -> Bsv2  |  IN-PLACE RESIZE (Terraform-native)
#
# `size` is an in-place update in azurerm_linux_virtual_machine, so changing
# the SKU and running `terraform apply` resizes the VM (brief reboot). No
# destroy/recreate, no state drift - the OS/data disks and config are kept.
#
# HOW TO USE
#   1. This is the shape your EXISTING VM resource should already have in state.
#      If the VM is already managed by Terraform, you only change ONE line:
#      set `size` from the old SKU to the new Bsv2 SKU, then `terraform apply`.
#   2. Mapping (see VM_Replacement_Recommendations.xlsx):
#        Standard_B4ms  -> Standard_B4s_v2
#        Standard_B8ms  -> Standard_B8s_v2
#        Standard_B16ms -> Standard_B16s_v2
#        Standard_B1ms  -> Standard_B2ls_v2
#        Standard_B1s   -> Standard_B2ts_v2
#   3. Bsv2 keeps the SCSI controller and supports Gen1/Gen2, so NO Gen2/NVMe
#      change is needed - a plain resize is enough.
##############################################################################

variable "resource_group_name" {
  type    = string
  default = "myResourceGroup"
}

variable "location" {
  type    = string
  default = "westeurope"
}

# The B-series VM being resized. Adjust to match the resource already in state.
resource "azurerm_linux_virtual_machine" "b_series" {
  name                = "vm-b4ms"
  resource_group_name = var.resource_group_name
  location            = var.location

  # <<< THE ONLY MIGRATION CHANGE: old "Standard_B4ms" -> new Bsv2 SKU >>>
  size = "Standard_B4s_v2"

  admin_username                  = "azureuser"
  disable_password_authentication = true

  network_interface_ids = [azurerm_network_interface.b_series.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  # Present only for the initial build; ignored on an existing (in-state) VM.
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Bsv2 supports Accelerated Networking (B-series v1 often did not). Enable it
  # on the NIC (see azurerm_network_interface below), not here.

  lifecycle {
    # The image is only used at create time; don't let a plan try to rebuild
    # the OS disk if the published image version moves.
    ignore_changes = [source_image_reference]
  }
}

# Existing swap/tmp data disk carried over to the resized VM (persistent).
# For B-series there is no local-disk SKU variant, so keep a managed data disk.
resource "azurerm_managed_disk" "b_series_swap" {
  name                 = "vm-b4ms-swap"
  resource_group_name  = var.resource_group_name
  location             = var.location
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 16 # sized to your swap/tmp needs; see disk-billing note
}

resource "azurerm_virtual_machine_data_disk_attachment" "b_series_swap" {
  managed_disk_id    = azurerm_managed_disk.b_series_swap.id
  virtual_machine_id = azurerm_linux_virtual_machine.b_series.id
  lun                = 0
  caching            = "ReadWrite"
}

resource "azurerm_network_interface" "b_series" {
  name                           = "vm-b4ms-nic"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  accelerated_networking_enabled = true # Bsv2 supports it

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

variable "subnet_id" {
  type    = string
  default = "" # set to your existing subnet resource ID
}
