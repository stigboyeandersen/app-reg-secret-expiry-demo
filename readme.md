# App registration secret expiry demo

This repository demonstrates a **secret-value-free** way to inventory Microsoft Entra
app registrations, calculate the expiry window for their client secrets, and publish
the results to Azure Monitor Logs. It is intended for a lab, proof of concept, or
starting point for an operational runbook—not as a complete certificate or alerting
solution.

The demo records metadata such as application ID, display name, secret key ID,
creation/expiry timestamps, and days remaining. It **never writes or logs a client
secret value**.

## Architecture

```text
Azure Automation Account
  └─ scheduled PowerShell runbook
       ├─ managed identity
       ├─ Microsoft Graph (app registrations + password credentials metadata)
       └─ Azure Monitor Logs ingestion API
             └─ Data Collection Rule (DCR)
                  └─ Log Analytics custom table
```

Terraform creates the Azure resources, identity permissions, DCR, custom table,
and runbook schedule. The runbook uses its Automation managed identity, obtains a
token for Microsoft Graph and Azure Monitor Logs, queries password-credential
metadata, and sends normalized records to the custom table.

The Automation Account is configured with a **user-assigned managed identity**.
Terraform creates that identity, attaches it to the account, grants it the
required Microsoft Graph application permission, and assigns it
**Monitoring Metrics Publisher** on the DCR. The runbook explicitly requests
tokens for that identity.

The exact resource names and input variable names are deployment-specific.
Inspect `terraform/variables.tf` and `terraform/outputs.tf` for the complete list.

## Prerequisites

* An Azure subscription and permission to create resources in
  `<SUBSCRIPTION_ID>` / `<RESOURCE_GROUP>`.
* Terraform `>= <REQUIRED_VERSION>` installed locally.
* Azure CLI installed and authenticated:

  ```bash
  az login
  az account set --subscription <SUBSCRIPTION_ID>
  ```

* A Microsoft Entra tenant where you can obtain tenant-admin consent (see below).
* PowerShell 7 if you want to run or debug the runbook locally. The production
  execution is hosted by Azure Automation.
* The Terraform CLI identity must be able to register/configure the resource
  providers used by the configuration, create role assignments, and create the
  Azure Monitor resources in scope.

Do not place real secrets in `*.tfvars`, shell history, runbook parameters, source
files, or issue/PR descriptions. Use placeholders and a secret manager for any
unrelated credentials.

## Azure permissions and administrator consent

There are two distinct permission sets:

1. **Deployment permissions.** The identity running Terraform needs resource
   permissions such as resource-group resource creation, role-assignment creation,
   and Microsoft.Authorization permissions appropriate to your organization.
   A constrained service principal or deployment identity is preferable to
   `Owner` in production; grant only the actions required by the Terraform plan.
2. **Runbook Microsoft Graph permissions.** The Automation Account's
   user-assigned managed identity needs an **application permission** that allows
   reading app
   registration credential metadata. In the Microsoft Graph API this is commonly
   `Application.Read.All` (confirm the exact permission in the implementation and
   your tenant's policy).

Granting Graph application permissions requires **tenant-admin consent**.
Terraform assigns `Application.Read.All` to the Automation managed identity when
the deploying identity is allowed to manage Graph app-role assignments. A tenant
administrator may still need to review/grant consent in the Entra admin center
(or use an approved equivalent administrative process) before the schedule can
collect data.

The user-assigned identity that sends data must also have permission to send data through the
DCR. Assign **Monitoring Metrics Publisher** to every managed identity or
service principal that will call the Logs Ingestion API, normally at the DCR
scope. The demo assigns this role to the Automation Account's user-assigned
managed identity. Any additional producer identity needs its own assignment;
having access to the DCE URL alone is not sufficient.

For example, assign the role to another producer with Azure CLI:

```bash
az role assignment create \
  --assignee-object-id <PRODUCER_OBJECT_ID> \
  --assignee-principal-type ServicePrincipal \
  --role "Monitoring Metrics Publisher" \
  --scope <DCR_RESOURCE_ID>
```

This ingestion permission is separate from query permission. Users who only
need to view the collected records should receive an appropriate Log Analytics
workspace role, such as **Log Analytics Reader**, rather than the ingestion
role. Do not grant write access to unrelated workspaces or subscriptions.

After deployment, verify that:

* the Automation Account has the expected user-assigned identity attached;
* the required Microsoft Graph application permission has admin consent;
* the identity has the DCR ingestion role; and
* the runbook can obtain tokens without a client secret.

The scheduled job receives its DCR endpoint, DCR immutable ID, tenant ID, and
warning threshold through Terraform-rendered runbook defaults. This avoids an
Azure Automation API limitation where scheduled job parameter maps can be
dropped. You can still override these values when starting a one-off job.

## Deploy with Terraform

1. Clone the repository and change into its root.
2. Authenticate to the intended subscription.
3. Copy the example variables file if one exists:

   ```bash
   cp <EXAMPLE_TFVARS_FILE> terraform.tfvars
   ```

4. Set only non-secret values, such as resource group, location, retention, and
   schedule start time. The provider uses the subscription and tenant selected
   by your Azure CLI/Terraform authentication.
   Keep `terraform.tfvars` local.
5. Initialize, review, and apply:

   ```bash
   terraform -chdir=terraform init
   terraform -chdir=terraform fmt -check
   terraform -chdir=terraform validate
   terraform -chdir=terraform plan -out tfplan
   terraform -chdir=terraform apply tfplan
   ```

6. Complete the manual tenant-admin consent step above.
7. Start a one-off runbook job (or wait for the schedule) and record the job ID
   and output for verification.

Use the actual variable names and required values shown by the repository's
Terraform configuration. Do not invent values for resource IDs: use the workspace
and DCR IDs output by Terraform or the Azure portal.

Terraform state contains resource identifiers and may contain sensitive provider
data. Store state in a protected remote backend for shared use, enable locking,
restrict access, and never commit state or plan files.

## Runbook and schedule behavior

The schedule invokes the runbook at the configured UTC time and interval. Each run:

1. Gets an access token using the Automation Account managed identity.
2. Reads app registrations and password-credential metadata from Microsoft Graph.
3. Calculates `DaysUntilExpiry` relative to UTC.
4. Emits one record per credential, including expired and soon-to-expire entries.
5. Posts the records to the DCR ingestion endpoint.

The runbook is designed to be repeatable: a later run writes a fresh observation
for the same credential rather than changing the credential. Configure the expiry
threshold to match your operating policy. Schedule timing is UTC; allow for
eventual consistency in Graph and Log Analytics ingestion. A failed job should be
retried after checking the job output and permissions; it does not rotate or
disable credentials.

The Automation Account diagnostic setting sends `JobLogs`, `JobStreams`,
`AuditEvent`, and `AllMetrics` to the same Log Analytics Workspace. This provides
the execution evidence needed to confirm that scheduled jobs start, finish, and
report errors. Graph application-role assignments can take a short time to
propagate after deployment; if the first run returns `403 Forbidden`, wait and
retry after confirming that the managed identity has `Application.Read.All`.

Certificates are **out of scope**. This demo does not inventory certificate
credentials, validate certificate chains, or alert on certificate expiration.
Alert rules, action groups, notifications, ticketing, and remediation are also
out of scope and must be added separately.

## DCR and custom table schema

The DCR maps the JSON payload sent by the runbook to the Log Analytics custom
table. The implementation is the source of truth for the deployed table name and
column types; the logical fields are:

| Field | Meaning |
| --- | --- |
| `TimeGenerated` | UTC time at which the observation was created |
| `AppId` | App registration/client application ID |
| `DisplayName` | App registration display name |
| `CredentialType` | Credential type; this demo emits `Password` |
| `CredentialKeyId` | Key ID of the password credential |
| `EndDateTime` | Credential expiry time |
| `DaysUntilExpiry` | Whole days between observation time and expiry |
| `Owner` | Application object ID used to identify the owning app |
| `Status` | `Expired`, `ExpiringSoon`, or `Valid` |
| `Error` | Reserved for collection errors; normally empty |

Do not add `SecretText`, `ClientSecret`, or equivalent fields. If a source API
returns a secret value unexpectedly, discard it and do not include it in logs.

## Sample KQL

Replace `<CUSTOM_TABLE>` with the deployed custom table name (including its
workspace-specific suffix if required).

Latest observations for credentials:

```kusto
<CUSTOM_TABLE>
| summarize arg_max(TimeGenerated, *) by AppId, CredentialKeyId
| project TimeGenerated, DisplayName, AppId, CredentialKeyId,
          EndDateTime, DaysUntilExpiry, Status
| order by DaysUntilExpiry asc
```

Expired or soon-to-expire credentials:

```kusto
<CUSTOM_TABLE>
| summarize arg_max(TimeGenerated, *) by AppId, CredentialKeyId
| where DaysUntilExpiry <= 30
| project DisplayName, AppId, CredentialKeyId,
          EndDateTime, DaysUntilExpiry, Status
| order by EndDateTime asc
```

Collection health by run:

```kusto
<CUSTOM_TABLE>
| summarize Records=count(), Applications=dcount(AppId)
    by bin(TimeGenerated, 1d)
| order by TimeGenerated desc
```

KQL queries do not reveal secret values because the runbook never sends them.

Automation job errors and streams:

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Resource has "appregexpiry-aa"
| where Category in ("JobLogs", "JobStreams")
| where TimeGenerated > ago(7d)
| project TimeGenerated, Category, RunbookName_s, JobId_g,
          ResultType, ResultDescription, StreamType_s, _ResourceId
| order by TimeGenerated desc
```

Confirm that the scheduled runbook is executing:

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Resource has "appregexpiry-aa"
| where Category == "JobLogs"
| where TimeGenerated > ago(7d)
| summarize Jobs=dcount(JobId_g), LastJob=max(TimeGenerated)
    by RunbookName_s
```

## Verification

Verify in this order:

1. `terraform output` shows the expected resource IDs and schedule.
2. The Automation Account job completes successfully.
3. The job output shows records prepared and ingested, without credential values.
4. In the workspace, run the KQL query above. Allow several minutes for ingestion.
5. Confirm records contain expected metadata and that `DaysUntilExpiry` agrees with
   the credential's expiry date.
6. Confirm a second run produces a newer `TimeGenerated` observation.
7. Test an intentionally unauthorized identity only in a non-production tenant
   if you need to validate failure handling; do not weaken production permissions.

The deployed demo was verified with a successful run that submitted two
password-credential records to `AppRegistrationSecretExpiry_CL`.

## Cleanup

Before deletion, disable the schedule if you want to prevent a final run. Then
destroy only the resources managed by this demo:

```bash
terraform destroy
```

Review the plan carefully. A shared Log Analytics workspace, resource group, or
identity may be used by other workloads; remove only demo-created resources.
Remove the tenant-admin Graph consent and any manually created role assignments
if they are no longer needed. Retain or delete historical log data according to
your organization's retention policy.

## Costs

This demo can incur charges for Azure Automation, Log Analytics ingestion and
retention, and related Azure Monitor/DCR usage. Costs depend on schedule
frequency, number of app registrations/credentials, workspace pricing tier, and
retention. Use a small non-production tenant, a low-frequency schedule, and an
existing workspace when appropriate. Check current regional prices and your
subscription's pricing tier before deployment; this README is not a quote.

## Security and privacy

* The runbook uses managed identity; no client secret is required for the demo.
* Only credential metadata is collected. Secret values are never requested,
  persisted, or emitted.
* Restrict Graph application permissions and DCR ingestion scope.
* Protect Terraform state, backend storage, job output, workspace access, and
  diagnostic logs.
* Review display names and IDs for sensitive business information before sharing
  query results.
* Use separate non-production resources while evaluating the demo.

## Limitations

* Certificates are not collected or evaluated.
* No alert rules, action groups, email, ticketing, dashboards, or automatic
  rotation/remediation are included.
* Graph and Log Analytics are eventually consistent; observations can be delayed.
* Results reflect the permissions and tenant visible to the managed identity.
* The demo does not prove that a secret is used, valid, or safe to rotate.
* Schema names/types and Terraform variable names can change with implementation
  revisions; inspect the deployed outputs and source before automation.

## Troubleshooting

**The runbook returns `403` from Graph.** Confirm the Automation Account managed
identity is the caller, the required application permission is present, and a
tenant administrator has granted consent. Re-run only after directory replication
has completed.

**The runbook returns `401` or ingestion fails.** Check token audience/resource,
DCR endpoint and immutable ID, DCR stream mapping, and the managed identity's
Azure Monitor ingestion role. Verify that the workspace and DCR are in the
expected tenant/subscription.

**The runbook returns `Unable to connect to the remote server` while obtaining a
token.** The runbook supports the Azure Automation managed-identity endpoint
(`IDENTITY_ENDPOINT`/`IDENTITY_HEADER`) and the IMDS fallback. Confirm the
Automation Account identity is enabled and retry after the identity has
propagated.

**The custom table is empty.** Confirm the job completed, inspect job output for
the record count, wait for ingestion, and query the exact deployed table name.
Check that the DCR transform and JSON property names match the runbook payload.

**Terraform cannot create role assignments.** Use a deployment identity with
permission to create role assignments, or have an administrator apply that
specific change. Do not broaden permissions permanently just to make the demo
apply.

**No credentials are returned.** Confirm the tenant has password credentials,
the Graph permission grants directory-wide read access, and the runbook is using
the intended tenant. This is expected if there are no visible credentials.
