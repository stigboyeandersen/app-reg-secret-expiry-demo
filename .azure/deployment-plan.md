# Deployment Plan

## Status
Deployed

## Project

`app-reg-secret-expiry-demo`

## Deployment method

Pure Terraform deployment from `terraform/`; no Azure Developer CLI application services are required.

## Azure context

- Subscription: Visual Studio Premium med MSDN
- Subscription ID: `b14e79d6-bf0b-4209-ac42-79406ad15a9d`
- Tenant ID: `756ddf46-dde6-481d-a9ae-cf501afcfa1e`
- Location: `westeurope`
- Resource group: `rg-app-registration-secret-expiry`

## Resources

- Azure Resource Group
- Log Analytics Workspace
- Dedicated custom Log Analytics table
- Data Collection Endpoint and Data Collection Rule
- Azure Automation Account with system-assigned managed identity
- PowerShell runbook and daily schedule
- DCR ingestion role assignment for the Automation identity

## Deployment prerequisites

- Azure CLI authentication is active for the target subscription.
- Terraform/OpenTofu configuration has passed formatting and validation.
- Microsoft Graph admin consent for the Automation identity's application permission remains a post-deployment tenant-administrator step.
- Deployment is authorized by the user and may incur Azure charges.

## Validation Proof

- `az account show` confirmed the selected subscription and authenticated user.
- `tofu init -input=false` completed successfully using the locked AzureRM and AzAPI providers.
- `tofu fmt -check -recursive` completed successfully.
- `tofu validate` completed successfully.
- `tofu plan -input=false -out=tfplan` completed successfully with the selected subscription and region.
- No `main.tfvars.json` file exists; no JSON template validation was required.
- No unresolved `{{ .Env.* }}` template variables were found under `terraform/`.
- The repository uses OpenTofu (`tofu`) because the Terraform binary is not installed; the configuration is standard Terraform and the README's Terraform commands remain applicable.

## All validation checks pass

- Terraform/OpenTofu installed and available
- Azure CLI installed
- Azure CLI authenticated to the selected subscription
- Terraform initialization succeeds
- Terraform formatting check succeeds
- Terraform configuration validation succeeds
- Terraform plan succeeds
- Terraform state inspection succeeds
- No unresolved Go-style template variables
- No invalid `main.tfvars.json` configuration

## Deployment confirmation

The user confirmed deployment to the selected subscription and `westeurope` on 2026-09-05.

## Deployment Proof

- OpenTofu apply completed successfully with 0 resources destroyed.
- Resource group, workspace, custom table, DCE, DCR, Automation Account, managed identity, runbook, schedule, and DCR ingestion role were created.
- The Automation runbook is `Published`; the schedule runs daily in UTC.
- The Automation identity has `Monitoring Metrics Publisher` on the DCR.
- Microsoft Graph admin consent for the Automation identity remains a required manual tenant-administrator step before the first successful collection run.

## Diagnostics Update

- Automation diagnostic setting: `appregexpiry-automation-diagnostics`
- Destination: `appregexpiry-law`
- Enabled categories: `JobLogs`, `JobStreams`, `AuditEvent`, and `AllMetrics`
- A test job reached `Running` and then failed with the expected `403 Forbidden`
  from Microsoft Graph because tenant-admin consent has not yet been granted.
- The managed identity token acquisition path is working; the remaining blocker
  is Graph application permission/admin consent.
