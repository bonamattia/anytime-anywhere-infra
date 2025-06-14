terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  required_version = ">= 1.4.0"
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

#############################
#         VARIABLES         #
#############################

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "location" {
  default = "westeurope"
}

variable "amadeus_api_key" {
  description = "Amadeus API key"
  type        = string
}

variable "amadeus_api_secret" {
  description = "Amadeus API secret"
  type        = string
}

#############################
#           LOCALS          #
#############################

locals {
  tags = {
    env     = "dev"
    owner   = "mattia-bonandini"
    project = "anytime-anywhere"
  }
}

#############################
#      RESOURCE GROUP       #
#############################

resource "azurerm_resource_group" "main" {
  name     = "aa-dev-rg"
  location = var.location
  tags     = local.tags
}

#############################
#     STORAGE ACCOUNT       #
#############################

resource "azurerm_storage_account" "main" {
  name                     = "atimeawheredevstorage"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = local.tags
}

resource "azurerm_storage_table" "aa-dev" {
  name                 = "atimeawheredevtable"
  storage_account_name = azurerm_storage_account.main.name
}

# ================================
# Log Analytics Workspace
# ================================
resource "azurerm_log_analytics_workspace" "main" {
  name                = "aa-dev-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

#############################
#   APPLICATION INSIGHTS    #
#############################

resource "azurerm_application_insights" "main" {
  name                = "aa-dev-ai"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.main.id
  tags                = local.tags
}

#############################
#    APP SERVICE PLAN       #
#############################

resource "azurerm_service_plan" "main" {
  name                = "aa-dev-func-plan"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = local.tags
}

#############################
#        KEY VAULT          #
#############################

resource "azurerm_key_vault" "main" {
  name                        = "aa-dev-kv-01"
  location                    = var.location
  resource_group_name         = azurerm_resource_group.main.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  soft_delete_retention_days  = 7
  purge_protection_enabled    = true
  tags                        = local.tags
}

resource "azurerm_key_vault_secret" "amadeus_api_key" {
  name         = "amadeus-api-key"
  value        = var.amadeus_api_key
  key_vault_id = azurerm_key_vault.main.id
}

resource "azurerm_key_vault_secret" "amadeus_api_secret" {
  name         = "amadeus-api-secret"
  value        = var.amadeus_api_secret
  key_vault_id = azurerm_key_vault.main.id
}

resource "azurerm_key_vault_secret" "storage_conn" {
  name         = "azure-storage-connection-string"
  value        = azurerm_storage_account.main.primary_connection_string
  key_vault_id = azurerm_key_vault.main.id
}

#############################
#      FUNCTION APP         #
#############################

resource "azurerm_linux_function_app" "main" {
  name                       = "aa-dev-scheduler-func"
  location                   = var.location
  resource_group_name        = azurerm_resource_group.main.name
  service_plan_id            = azurerm_service_plan.main.id
  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME          = "python"
    AzureWebJobsStorage              = azurerm_storage_account.main.primary_connection_string
    AZURE_TABLE_NAME                 = azurerm_storage_table.aa-dev.name
    AMADEUS_API_KEY                  = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.amadeus_api_key.id})"
    AMADEUS_API_SECRET               = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.amadeus_api_secret.id})"
    AZURE_STORAGE_CONNECTION_STRING  = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.storage_conn.id})"
    WEBSITE_RUN_FROM_PACKAGE         = "1"
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.main.connection_string
  }

  tags = local.tags

  depends_on = [
    azurerm_key_vault_secret.amadeus_api_key,
    azurerm_key_vault_secret.amadeus_api_secret,
    azurerm_key_vault_secret.storage_conn
  ]
}

#############################
#          OUTPUTS          #
#############################

output "function_app_url" {
  value = "https://${azurerm_linux_function_app.main.default_hostname}"
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "table_url" {
  value = "https://${azurerm_storage_account.main.name}.table.core.windows.net/FlightDeals"
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}
