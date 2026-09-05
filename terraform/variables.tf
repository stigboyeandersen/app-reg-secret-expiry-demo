variable "location" {
  description = "Azure region for the demo resources."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Name of the resource group to create."
  type        = string
  default     = "rg-app-registration-secret-expiry"
}

variable "name_prefix" {
  description = "Short, globally unique prefix used in resource names."
  type        = string
  default     = "appregexpiry"
  validation {
    condition     = can(regex("^[a-z0-9-]{3,18}$", var.name_prefix))
    error_message = "name_prefix must contain only lowercase letters, numbers, and hyphens and be 3-18 characters."
  }
}

variable "retention_in_days" {
  description = "Retention period for the workspace and custom table."
  type        = number
  default     = 30
  validation {
    condition     = var.retention_in_days >= 30 && var.retention_in_days <= 730
    error_message = "retention_in_days must be between 30 and 730."
  }
}

variable "warning_threshold_days" {
  description = "Number of days before expiry that marks a password credential as expiring soon."
  type        = number
  default     = 30
  validation {
    condition     = var.warning_threshold_days >= 0
    error_message = "warning_threshold_days must be zero or greater."
  }
}

variable "runbook_path" {
  description = "Path to the PowerShell runbook, relative to this Terraform module."
  type        = string
  default     = "scripts/app-registration-secret-expiry.ps1"
}

variable "runbook_publish_uri" {
  description = "A publicly reachable URI accepted by the Automation API as the runbook publish content link."
  type        = string
  default     = "https://raw.githubusercontent.com/stigboyeandersen/app-reg-secret-expiry-demo/main/terraform/scripts/app-registration-secret-expiry.ps1"
}

variable "schedule_start_time" {
  description = "RFC3339 start time for the daily schedule; it must be at least five minutes in the future."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to created resources."
  type        = map(string)
  default = {
    purpose = "app-registration-secret-expiry-demo"
  }
}
