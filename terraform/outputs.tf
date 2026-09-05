output "resource_group_name" {
  description = "Resource group containing the demo."
  value       = azurerm_resource_group.this.name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID."
  value       = azurerm_log_analytics_workspace.this.id
}

output "custom_table_name" {
  description = "Custom Log Analytics table receiving expiry records."
  value       = local.table_name
}

output "logs_ingestion_endpoint" {
  description = "DCE endpoint to use as the base URL for the Logs Ingestion API."
  value       = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint
}

output "logs_ingestion_api_path" {
  description = "Relative Logs Ingestion API path for the custom stream."
  value       = "/dataCollectionRules/${azurerm_monitor_data_collection_rule.this.immutable_id}/streams/${local.stream_name}?api-version=2023-01-01"
}

output "logs_ingestion_url" {
  description = "Complete Logs Ingestion API URL used by the runbook."
  value       = "${azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint}/dataCollectionRules/${azurerm_monitor_data_collection_rule.this.immutable_id}/streams/${local.stream_name}?api-version=2023-01-01"
}

output "automation_account_name" {
  description = "Automation Account hosting the runbook."
  value       = azurerm_automation_account.this.name
}

output "automation_account_principal_id" {
  description = "System-assigned managed identity principal ID."
  value       = azurerm_automation_account.this.identity[0].principal_id
}

output "runbook_name" {
  description = "Imported Automation runbook name."
  value       = azurerm_automation_runbook.this.name
}
