data "azurerm_client_config" "current" {}

# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.vmss_name}-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "subnet" {
  name                 = "${var.vmss_name}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

##KeyVault for GitHub Secret Dynamic Fetch
resource "azurerm_key_vault" "vmss" {
  name                      = "kvl-use-vmsspoc-rk"
  location                  = azurerm_resource_group.rg.location
  resource_group_name       = azurerm_resource_group.rg.name
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  sku_name                  = "standard"
  purge_protection_enabled  = false
  enable_rbac_authorization = true
}



#VMSS password

resource "random_password" "vmss_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}
#Runner Group in GitHub


# VMSS
resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                = var.vmss_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard_D2s_v3"
  instances           = var.min_instances

  admin_username                  = "adminuser"
  admin_password                  = random_password.vmss_password.result
  disable_password_authentication = false

  identity {
    type = "SystemAssigned"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  network_interface {
    name    = "vmss-nic"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.subnet.id
    }
  }

  lifecycle {
    ignore_changes = [instances]
  }
}

resource "azurerm_virtual_machine_scale_set_extension" "vmss" {
  name                         = "CustomScriptExtension"
  virtual_machine_scale_set_id = azurerm_linux_virtual_machine_scale_set.vmss.id
  publisher                    = "Microsoft.Azure.Extensions"
  type                         = "CustomScript"
  type_handler_version         = "2.1"
  protected_settings = <<PROTECTED_SETTINGS
    {
      "script": "${base64encode(templatefile(var.shell_file, {
  github_organization = var.github_organization,
  keyvault_name       = azurerm_key_vault.vmss.name,
  runner_group_name   = github_actions_runner_group.vmss.name
}))}"
    }
    PROTECTED_SETTINGS

}

resource "azurerm_role_assignment" "vmss_admin" {
  scope                = azurerm_key_vault.vmss.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = azurerm_linux_virtual_machine_scale_set.vmss.identity[0].principal_id
}
resource "azurerm_role_assignment" "kv_admin" {
  scope                = azurerm_key_vault.vmss.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}
resource "azurerm_key_vault_secret" "github_pat" {
  name         = "github-pat"
  value        = var.github_token
  key_vault_id = azurerm_key_vault.vmss.id
  depends_on   = [azurerm_role_assignment.kv_admin, azurerm_linux_virtual_machine_scale_set.vmss]
}
resource "azurerm_key_vault_secret" "vm_password" {
  name         = "vm-password"
  value        = random_password.vmss_password.result
  key_vault_id = azurerm_key_vault.vmss.id
  depends_on   = [azurerm_role_assignment.kv_admin, azurerm_linux_virtual_machine_scale_set.vmss]
}
