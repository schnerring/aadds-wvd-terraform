
# Resource Group

resource "azurerm_resource_group" "avd" {
  name     = "avd-rg"
  location = var.location
}

# Network Resources

resource "azurerm_virtual_network" "avd" {
  name                = "avd-vnet"
  location            = azurerm_resource_group.avd.location
  resource_group_name = azurerm_resource_group.avd.name
  address_space       = ["10.10.0.0/16"]

  # Use AADDS DCs as DNS servers
  dns_servers = azurerm_active_directory_domain_service.aadds.initial_replica_set.0.domain_controller_ip_addresses
}

resource "azurerm_subnet" "avd" {
  name                 = "avd-snet"
  resource_group_name  = azurerm_resource_group.avd.name
  virtual_network_name = azurerm_virtual_network.avd.name
  address_prefixes     = ["10.10.0.0/24"]
}

resource "azurerm_virtual_network_peering" "aadds_to_avd" {
  name                      = "hub-to-avd-peer"
  resource_group_name       = azurerm_resource_group.aadds.name
  virtual_network_name      = azurerm_virtual_network.aadds.name
  remote_virtual_network_id = azurerm_virtual_network.avd.id
}

resource "azurerm_virtual_network_peering" "avd_to_aadds" {
  name                      = "avd-to-aadds-peer"
  resource_group_name       = azurerm_resource_group.avd.name
  virtual_network_name      = azurerm_virtual_network.avd.name
  remote_virtual_network_id = azurerm_virtual_network.aadds.id
}

# Host Pool

locals {
  # Switzerland North is not supported
  avd_location = "West Europe"
}

resource "azurerm_virtual_desktop_host_pool" "avd" {
  name                = "avd-hp"
  location            = local.avd_location
  resource_group_name = azurerm_resource_group.avd.name

  type                = "Pooled"
  load_balancer_type  = "BreadthFirst"
  friendly_name       = "AVD Host Pool using AADDS"
  start_vm_on_connect = true
}

resource "time_rotating" "avd_registration_expiration" {
  # Must be between 1 hour and 30 days
  rotation_days = 29
}

resource "azurerm_virtual_desktop_host_pool_registration_info" "avd" {
  hostpool_id     = azurerm_virtual_desktop_host_pool.avd.id
  expiration_date = time_rotating.avd_registration_expiration.rotation_rfc3339
}

# Workspace and App Group

resource "azurerm_virtual_desktop_workspace" "avd" {
  name                = "avd-ws"
  location            = local.avd_location
  resource_group_name = azurerm_resource_group.avd.name
}

resource "azurerm_virtual_desktop_application_group" "avd" {
  name                = "desktop-ag"
  location            = local.avd_location
  resource_group_name = azurerm_resource_group.avd.name

  type          = "Desktop"
  host_pool_id  = azurerm_virtual_desktop_host_pool.avd.id
  friendly_name = "Full Desktop"
}

resource "azurerm_virtual_desktop_workspace_application_group_association" "avd" {
  workspace_id         = azurerm_virtual_desktop_workspace.avd.id
  application_group_id = azurerm_virtual_desktop_application_group.avd.id
}

# Session Host VMs

resource "azurerm_network_interface" "avd" {
  count               = var.avd_host_pool_size
  name                = "avd-nic-${count.index}"
  location            = azurerm_resource_group.avd.location
  resource_group_name = azurerm_resource_group.avd.name

  ip_configuration {
    name                          = "avd-ipconf-${count.index}"
    subnet_id                     = azurerm_subnet.avd.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "random_password" "avd_local_admin" {
  length = 64
}

resource "azurerm_windows_virtual_machine" "avd" {
  count               = length(azurerm_network_interface.avd)
  name                = "avd-vm-${count.index}"
  location            = azurerm_resource_group.avd.location
  resource_group_name = azurerm_resource_group.avd.name

  size                  = "Standard_D4s_v5"
  license_type          = "Windows_Client" # https://docs.microsoft.com/en-us/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment#verify-your-vm-is-utilizing-the-licensing-benefit
  admin_username        = "avd-local-admin"
  admin_password        = random_password.avd_local_admin.result
  network_interface_ids = [azurerm_network_interface.avd[count.index].id]

  os_disk {
    name                 = "avd-osdisk-${count.index}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-21h2-avd"
    version   = "latest"
  }
}

# AADDS Domain-join

resource "azurerm_virtual_machine_extension" "avd_aadds_domain_join" {
  count                      = length(azurerm_windows_virtual_machine.avd)
  name                       = "aadds-domain-join-vmext"
  virtual_machine_id         = azurerm_windows_virtual_machine.avd[count.index].id
  publisher                  = "Microsoft.Compute"
  type                       = "JsonADDomainExtension"
  type_handler_version       = "1.3"
  auto_upgrade_minor_version = true

  settings = <<-SETTINGS
    {
      "Name": "${azurerm_active_directory_domain_service.aadds.domain_name}",
      "OUPath": "${join(",", formatlist("DC=%s", split(".", azurerm_active_directory_domain_service.aadds.domain_name)))}",
      "User": "${azuread_user.dc_admin.user_principal_name}",
      "Restart": "true",
      "Options": "3"
    }
    SETTINGS

  protected_settings = <<-PROTECTED_SETTINGS
    {
      "Password": "${random_password.dc_admin.result}"
    }
    PROTECTED_SETTINGS

  lifecycle {
    ignore_changes = [settings, protected_settings]
  }

  depends_on = [
    azurerm_virtual_network_peering.aadds_to_avd,
    azurerm_virtual_network_peering.avd_to_aadds
  ]
}

# Register to Host Pool

resource "azurerm_virtual_machine_extension" "avd_add_session_host" {
  count                = length(azurerm_windows_virtual_machine.avd)
  name                 = "add-session-host-vmext"
  virtual_machine_id   = azurerm_windows_virtual_machine.avd[count.index].id
  publisher            = "Microsoft.Powershell"
  type                 = "DSC"
  type_handler_version = "2.73"

  settings = <<-SETTINGS
    {
      "modulesUrl": "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_3-10-2021.zip",
      "configurationFunction": "Configuration.ps1\\AddSessionHost",
      "properties": {
        "hostPoolName": "${azurerm_virtual_desktop_host_pool.avd.name}",
        "aadJoin": false
      }
    }
    SETTINGS

  protected_settings = <<-PROTECTED_SETTINGS
    {
      "properties": {
        "registrationInfoToken": "${azurerm_virtual_desktop_host_pool_registration_info.avd.token}"
      }
    }
    PROTECTED_SETTINGS

  lifecycle {
    ignore_changes = [settings, protected_settings]
  }

  depends_on = [azurerm_virtual_machine_extension.avd_aadds_domain_join]
}

# FSLogix Profile Storage

resource "random_id" "random" {
  byte_length = 2
}

resource "azurerm_storage_account" "avd_fslogix" {
  name                = "fslogix${random_id.random.dec}"
  location            = azurerm_resource_group.avd.location
  resource_group_name = azurerm_resource_group.avd.name

  account_kind             = "FileStorage"
  account_tier             = "Premium"
  account_replication_type = "LRS"

  azure_files_authentication {
    directory_type = "AADDS"
  }
}

resource "azurerm_storage_share" "avd_fslogix" {
  name                 = "profiles"
  storage_account_name = azurerm_storage_account.avd_fslogix.name
}
