locals {
  table_name  = "AppRegistrationSecretExpiry_CL"
  stream_name = "Custom-AppRegistrationSecretExpiry_CL"

  schedule_start_time = coalesce(
    var.schedule_start_time,
    timeadd(timestamp(), "10m")
  )
}

data "azurerm_client_config" "current" {}

data "azuread_service_principal" "microsoft_graph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name_prefix}-law"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_in_days
  tags                = var.tags
}

# azurerm_log_analytics_custom_table is not currently exposed consistently by
# AzureRM 4.x. AzAPI keeps the table schema usable across provider minor versions.
resource "azapi_resource" "custom_table" {
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  parent_id = azurerm_log_analytics_workspace.this.id
  name      = local.table_name

  body = {
    properties = {
      retentionInDays = var.retention_in_days
      schema = {
        name = local.table_name
        columns = [
          { name = "TimeGenerated", type = "datetime" },
          { name = "AppId", type = "string" },
          { name = "DisplayName", type = "string" },
          { name = "CredentialType", type = "string" },
          { name = "CredentialKeyId", type = "string" },
          { name = "EndDateTime", type = "datetime" },
          { name = "DaysUntilExpiry", type = "int" },
          { name = "Owner", type = "string" },
          { name = "Status", type = "string" },
          { name = "Error", type = "string" }
        ]
      }
    }
  }

  schema_validation_enabled = false
  response_export_values    = ["*"]
}

resource "azurerm_monitor_data_collection_endpoint" "this" {
  name                          = "${var.name_prefix}-dce"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  public_network_access_enabled = true
  description                   = "Logs Ingestion API endpoint for app registration secret expiry results."
  tags                          = var.tags
}

resource "azurerm_monitor_data_collection_rule" "this" {
  name                        = "${var.name_prefix}-dcr"
  resource_group_name         = azurerm_resource_group.this.name
  location                    = azurerm_resource_group.this.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.this.id
  description                 = "Routes app registration secret expiry records to Log Analytics."
  tags                        = var.tags

  stream_declaration {
    stream_name = local.stream_name

    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "AppId"
      type = "string"
    }
    column {
      name = "DisplayName"
      type = "string"
    }
    column {
      name = "CredentialType"
      type = "string"
    }
    column {
      name = "CredentialKeyId"
      type = "string"
    }
    column {
      name = "EndDateTime"
      type = "datetime"
    }
    column {
      name = "DaysUntilExpiry"
      type = "int"
    }
    column {
      name = "Owner"
      type = "string"
    }
    column {
      name = "Status"
      type = "string"
    }
    column {
      name = "Error"
      type = "string"
    }
  }

  destinations {
    log_analytics {
      name                  = "log-analytics"
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
    }
  }

  data_flow {
    streams       = [local.stream_name]
    destinations  = ["log-analytics"]
    output_stream = local.stream_name
  }

  depends_on = [azapi_resource.custom_table]
}

resource "azurerm_role_assignment" "automation_dcr_ingestion" {
  scope                = azurerm_monitor_data_collection_rule.this.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_automation_account.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azuread_app_role_assignment" "automation_graph_application_read" {
  app_role_id         = "9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30"
  principal_object_id = azurerm_automation_account.this.identity[0].principal_id
  resource_object_id  = data.azuread_service_principal.microsoft_graph.object_id
}

resource "azurerm_automation_account" "this" {
  name                          = "${var.name_prefix}-aa"
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  sku_name                      = "Basic"
  local_authentication_enabled  = false
  public_network_access_enabled = true
  identity {
    type = "SystemAssigned"
  }
  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "automation_account" {
  name                       = "${var.name_prefix}-automation-diagnostics"
  target_resource_id         = azurerm_automation_account.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "JobLogs"
  }

  enabled_log {
    category = "JobStreams"
  }

  enabled_log {
    category = "AuditEvent"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_automation_runbook" "this" {
  name                    = "AppRegistrationSecretExpiry"
  location                = azurerm_resource_group.this.location
  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  runbook_type            = "PowerShell"
  log_progress            = true
  log_verbose             = true
  description             = "Collects Entra app registration credential expiry data and sends it through the Logs Ingestion API."
  content = replace(
    replace(
      replace(
        replace(
          file("${path.module}/${var.runbook_path}"),
          "__DCR_ENDPOINT__",
          azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint
        ),
        "__DCR_IMMUTABLE_ID__",
        azurerm_monitor_data_collection_rule.this.immutable_id
      ),
      "__TENANT_ID__",
      data.azurerm_client_config.current.tenant_id
    ),
    "__WARNING_THRESHOLD_DAYS__",
    tostring(var.warning_threshold_days)
  )

  publish_content_link {
    uri = var.runbook_publish_uri
  }
}

resource "azurerm_automation_schedule" "daily" {
  name                    = "${var.name_prefix}-daily"
  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  frequency               = "Day"
  interval                = 1
  timezone                = "Etc/UTC"
  start_time              = local.schedule_start_time
  description             = "Runs the app registration secret expiry check once per day."

  lifecycle {
    # The default start time is intentionally generated at apply time; do not
    # recreate or move the schedule on every subsequent plan.
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_job_schedule" "daily_runbook" {
  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  runbook_name            = azurerm_automation_runbook.this.name
  schedule_name           = azurerm_automation_schedule.daily.name
}
