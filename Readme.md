As organizations grow, their CI/CD requirements become more demanding. While GitHub’s hosted runners are convenient, many enterprises need custom runners for specialized workloads, enhanced security, or cost optimization. In this article, I’ll Walk you through implementing scaling self-hosted GitHub Actions runners using Azure Virtual Machine Scale Sets (VMSS).

Why Self-Hosted Runners?
Before diving into the implementation, let’s understand why you might want self-hosted runners:

Cost Optimization: For high-volume CI/CD, self-hosted runners can be more cost-effective than paying per-minute for GitHub-hosted runners.
Custom Environment: You can configure runners with specific software, security patches, and configurations.
Network Access: Runners can access internal resources within your network securely.
Resource Control: You have full control over the compute resources allocated to your workflows.
The Architecture
Our solution uses several Azure and GitHub components:

Azure Virtual Machine Scale Set for runner hosting
Azure Key Vault for secure secret management
GitHub Actions Runner Groups for organization
Terraform for infrastructure as code
Custom initialization script for runner setup
Prerequisites:
A user managed identity (UMSI) with access to Azure subscription, and federated credentials setup for running github actions
UMSI should have a client id, the target subscription id, the azure cloud’s tenant id, those values should be added to the environment in github named as “Dev”. Values of those variables should be CLIENT_ID, SUBSCRIPTION_ID, TENANT_ID, as these are the exact names used in the github workflow YAML file below.
A github personal access token (PAT) with access for generating and creating GitHub runner registration token. The token needs to be stored in the GitHub repo’s environment secret named to: “github_token”.
Implementation Deep Dive
Creation of Azure Components
Create the below hierarchy in terraform, and copy the codes mentioned below. the YML file will take care of the deployment of the resources mentioned in terraform.

Get Roshan Patel’s stories in your inbox
Join Medium for free to get updates from this writer.

Enter your email
Subscribe

Remember me for faster sign in

version.tf:

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}
provider "github" {
  token = var.github_token
  owner = var.github_organization
}
vmss.tf


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
variables.tf

# Variables
variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "vmss_name" {
  type = string
}

variable "min_instances" {
  type    = number
  default = 0
}

variable "max_instances" {
  type    = number
  default = 10
}

variable "github_token" {
  type      = string
  sensitive = true
}

variable "github_organization" {
  type = string
}

variable "github_repository" {
  type = string
}
variable "shell_file" {
  type = string
}
variables.tfvars

resource_group_name = "github-runner-rg"
location            = "eastus"
vmss_name           = "github-runner-vmss"
min_instances       = 0
max_instances       = 10
github_token        = ""
github_organization = "your org name"
github_repository   = "your repo name"
shell_file          = "init.sh"
init.sh

#!/bin/bash

# Error handling and logging
set -e
exec 1> >(logger -s -t $(basename $0)) 2>&1

# Root operations
sudo apt-get update
sudo apt-get install -y curl jq pwgen unzip

# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Create runner user with password
RUNNER_USER="github-runner"
RUNNER_DIR="/actions-runner"
RUNNER_PASSWORD=$(pwgen -s 20 1)

# Create user and directories
sudo useradd -m -s /bin/bash $RUNNER_USER
echo "$RUNNER_USER:$RUNNER_PASSWORD" | sudo chpasswd
sudo usermod -aG sudo $RUNNER_USER
sudo mkdir -p $RUNNER_DIR
sudo chown -R $RUNNER_USER:$RUNNER_USER $RUNNER_DIR

# Switch to runner user for setup - note the EOF is not quoted now
sudo -u $RUNNER_USER bash << EOF
RUNNER_DIR="/actions-runner"
cd \$RUNNER_DIR

# Get GitHub token and configure
az login --identity
GITHUB_TOKEN=\$(az keyvault secret show --name "github-pat" --vault-name "${keyvault_name}" --query "value" -o tsv)

# Get registration token
TOKEN=\$(curl -L -X POST \\
  -H "Accept: application/vnd.github+json" \\
  -H "Authorization: Bearer \$GITHUB_TOKEN" \\
  -H "X-GitHub-Api-Version: 2022-11-28" \\
  "https://api.github.com/orgs/${github_organization}/actions/runners/registration-token" | jq -r '.token')

# Download and extract runner
curl -o actions-runner-linux-x64-2.321.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-linux-x64-2.321.0.tar.gz
tar xzf ./actions-runner-linux-x64-2.321.0.tar.gz

# Configure runner
./config.sh --unattended \\
    --url "https://github.com/${github_organization}" \\
    --token "\$TOKEN" \\
    --name "\$HOSTNAME" \\
    --runnergroup "${runner_group_name}" \\
    --labels "azure-vmss" \\
    --work "_work" \\
    --ephemeral \\
    --replace
EOF

# Install and start service
cd $RUNNER_DIR
sudo ./svc.sh install $RUNNER_USER
sudo ./svc.sh start
github_components.tf

data "github_repository" "myRepo" {
  full_name = "${var.github_organization}/${var.github_repository}"
}

resource "github_actions_runner_group" "vmss" {
  name                       = "azure-vmss-runners"
  visibility                 = "all"
  selected_repository_ids    = [] #data.github_repository.myRepo.repo_id
  allows_public_repositories = false
}
github-agents.yml

name: GH Runners Scale

on:
  workflow_dispatch:
  push:
    branches: [ main ]
    paths:
      - ‘gh-runners/**’
      - ‘.github/workflows/github-agents.yml’
  pull_request:
    branches: [ main ]
    paths:
      - ‘gh-runners/**’
      - ‘.github/workflows/github-agents.yml’

permissions:
  id-token: write
  contents: read

jobs:
  terraform:
    runs-on: ubuntu-latest
      #group: 'azure-vmss-runners'
    environment: Dev

    steps:
    - uses: actions/checkout@v3

    - name: Azure Login
      uses: azure/login@v1
      with:
        client-id: ${{ vars.CLIENT_ID }}
        tenant-id: ${{ vars.TENANT_ID }}
        subscription-id: ${{ vars.SUBSCRIPTION_ID }}

    - name: Setup Node
      uses: actions/setup-node@v1
      with:
          node-version: '20' 

    - name: Setup Terraform
      uses: hashicorp/setup-terraform@v3
      with:
        terraform_version: "1.5.0"

    - name: Terraform Init
      working-directory: ./gh-runners
      run: terraform init

    # - name: Terraform Format
    #   working-directory: ./terraform
    #   run: terraform fmt -check

    - name: Terraform Plan
      working-directory: ./gh-runners
      run: terraform plan -var-file="variables.tfvars" -var="github_token=${{ secrets.GH_PAT_TOKEN }}"

    - name: Terraform Apply
      if: github.ref == 'refs/heads/main' && github.event_name == 'push'
      working-directory: ./gh-runners
      run: terraform apply -var-file="variables.tfvars" -var="github_token=${{ secrets.GH_PAT_TOKEN }}" -auto-approve
Runner Installation and Configuration
One of the key security features of this solution is its token management system. The implementation uses a GitHub Personal Access Token (PAT) stored securely in Azure Key Vault. When a new runner instance starts, it first authenticates to Azure using its managed identity. It then retrieves the PAT from Key Vault using az keyvault secret show. This PAT isn't used directly for runner registration; instead, it's used to generate a short-lived runner registration token by calling GitHub's API (/actions/runners/registration-token). This two-step token process enhances security by ensuring that even if a registration token is compromised, it has a limited lifetime and can only be used for runner registration, not other GitHub operations. The PAT itself never leaves the runner instance, and the registration token is used only once during the initial setup.

Press enter or click to view image in full size

The magic happens in our initialization script (init.sh). Here's what it does for every VMSS - instance that gets freshly created.

Sets up the required dependencies
Creates a dedicated runner user
Retrieves secrets from Azure Key Vault
Downloads and configures the GitHub Actions runner
Registers the runner with GitHub
Installs and starts the runner service
Security Considerations
Our implementation includes several security best practices:

RBAC Implementation: We use Azure RBAC for Key Vault access
Managed Identities: The VMSS uses a system-assigned managed identity
Isolated Network: Runners operate in their own virtual network
Ephemeral Runners: Each runner instance is ephemeral, reducing security risks
Conclusion
This setup provides a robust, scalable, and secure solution for running GitHub Actions workflows. The combination of Azure VMSS and GitHub Actions offers:

Automatic scaling based on demand
Cost optimization through scale-to-zero capability
Secure secret management
Custom runtime environments
Network isolation
The complete solution is available in the provided Terraform configurations and can be adapted to meet specific organizational needs.

Remember to consider your organization’s security requirements and compliance standards when implementing this solution. You might need to adjust network configurations, add additional security controls, or modify the runner setup based on your specific needs.

This solution focuses on only showcasing a possibility of scaling GitHub action runners, but you could always utilize an existing ubuntu image to configure the runner agents and modify the below terraform block.

source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

source_image_id = "link to compute gallery image"
Ideas on auto-scaling
This solution will help deploy a solution, where a VMSS is manually scaled to meet your demand of runner agents / jobs. However, you can create automation that adds a new self-hosted runner each time you receive a workflow_job webhook event with the queued activity, which notifies you that a new job is ready for processing. The webhook payload includes label data, so you can identify the type of runner the job is requesting. Once the job has finished, you can then create automation that removes the runner in response to the workflow_job completed activity, by increasing / decresing the total number of instances available in the VMSS.
