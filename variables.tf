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
