[CmdletBinding()]
param(
    [string]$DcrEndpoint = $env:APP_REG_SECRET_EXPIRY_DCR_ENDPOINT,
    [string]$DcrImmutableId = $env:APP_REG_SECRET_EXPIRY_DCR_IMMUTABLE_ID,
    [string]$DcrStreamName = $(if ($env:APP_REG_SECRET_EXPIRY_DCR_STREAM_NAME) { $env:APP_REG_SECRET_EXPIRY_DCR_STREAM_NAME } else { 'Custom-AppRegistrationSecretExpiry_CL' }),
    [string]$DcrTableName = $(if ($env:APP_REG_SECRET_EXPIRY_DCR_TABLE_NAME) { $env:APP_REG_SECRET_EXPIRY_DCR_TABLE_NAME } else { 'AppRegistrationSecretExpiry_CL' }),
    [int]$WarningThresholdDays = $(if ($env:APP_REG_SECRET_EXPIRY_WARNING_THRESHOLD_DAYS) { [int]$env:APP_REG_SECRET_EXPIRY_WARNING_THRESHOLD_DAYS } else { 30 }),
    [string]$TenantId = $env:APP_REG_SECRET_EXPIRY_TENANT_ID,
    [string]$ManagedIdentityClientId = $env:APP_REG_SECRET_EXPIRY_MANAGED_IDENTITY_CLIENT_ID,
    [int]$MaxRetries = $(if ($env:APP_REG_SECRET_EXPIRY_MAX_RETRIES) { [int]$env:APP_REG_SECRET_EXPIRY_MAX_RETRIES } else { 3 }),
    [int]$RetryDelaySeconds = $(if ($env:APP_REG_SECRET_EXPIRY_RETRY_DELAY_SECONDS) { [int]$env:APP_REG_SECRET_EXPIRY_RETRY_DELAY_SECONDS } else { 2 })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredValue {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Required runbook setting '$Name' was not supplied."
    }
    $Value
}

function Get-ManagedIdentityToken {
    param([string]$Resource, [string]$ClientId)
    $identityEndpoint = $env:IDENTITY_ENDPOINT
    $identityHeader = $env:IDENTITY_HEADER
    $query = @{
        'api-version' = if ($identityEndpoint) { '2019-08-01' } else { '2018-02-01' }
        resource = $Resource
    }
    if (-not [string]::IsNullOrWhiteSpace($ClientId)) { $query.client_id = $ClientId }
    $uri = if ($identityEndpoint) { $identityEndpoint } else { 'http://169.254.169.254/metadata/identity/oauth2/token' }
    $uri += '?' +
        (($query.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
        }) -join '&')
    $headers = if ($identityEndpoint) {
        @{ 'X-IDENTITY-HEADER' = $identityHeader }
    } else {
        @{ Metadata = 'true' }
    }
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ContentType 'application/json'
    if ([string]::IsNullOrWhiteSpace($response.access_token)) { throw "Managed identity returned no token for $Resource." }
    [string]$response.access_token
}

function Invoke-WithRetry {
    param([scriptblock]$Operation, [string]$Description)
    $attempt = 0
    while ($true) {
        try { return & $Operation }
        catch {
            $attempt++
            if ($attempt -gt $MaxRetries) { throw "$Description failed after $MaxRetries retries: $($_.Exception.Message)" }
            $delay = [Math]::Min(60, [Math]::Max(1, $RetryDelaySeconds) * [Math]::Pow(2, $attempt - 1))
            Write-Warning "$Description failed; retrying in $delay seconds: $($_.Exception.Message)"
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-GraphApplications {
    param([string]$Token)
    $headers = @{ Authorization = 'Bearer ' + $Token }
    $uri = 'https://graph.microsoft.com/v1.0/applications?$select=id,appId,displayName,passwordCredentials&$top=999'
    $applications = @()
    while (-not [string]::IsNullOrWhiteSpace($uri)) {
        $page = Invoke-WithRetry -Description 'Microsoft Graph applications request' -Operation {
            Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ContentType 'application/json'
        }
        if ($null -ne $page.value) { $applications += @($page.value) }
        $uri = [string]$page.'@odata.nextLink'
    }
    $applications
}

if ($WarningThresholdDays -lt 0 -or $MaxRetries -lt 0 -or $RetryDelaySeconds -lt 0) {
    throw 'WarningThresholdDays, MaxRetries, and RetryDelaySeconds must be zero or greater.'
}
$DcrEndpoint = Get-RequiredValue 'DcrEndpoint' $DcrEndpoint
$DcrImmutableId = Get-RequiredValue 'DcrImmutableId' $DcrImmutableId
$TenantId = Get-RequiredValue 'TenantId' $TenantId

try {
    $graphToken = Get-ManagedIdentityToken 'https://graph.microsoft.com/' $ManagedIdentityClientId
    $applications = Get-GraphApplications $graphToken
    $nowUtc = [DateTime]::UtcNow
    $records = foreach ($application in $applications) {
        foreach ($credential in @($application.passwordCredentials)) {
            if ($null -eq $credential.endDateTime) { continue }
            $expiryUtc = ([DateTime]$credential.endDateTime).ToUniversalTime()
            $daysUntilExpiry = [int][Math]::Floor(($expiryUtc - $nowUtc).TotalDays)
            $status = if ($expiryUtc -le $nowUtc) { 'Expired' } elseif ($daysUntilExpiry -le $WarningThresholdDays) { 'ExpiringSoon' } else { 'Valid' }
            [ordered]@{
                TimeGenerated = $nowUtc.ToString('o')
                AppId = [string]$application.appId
                DisplayName = [string]$application.displayName
                CredentialType = 'Password'
                CredentialKeyId = [string]$credential.keyId
                EndDateTime = $expiryUtc.ToString('o')
                DaysUntilExpiry = $daysUntilExpiry
                Owner = [string]$application.id
                Status = $status
                Error = ''
            }
        }
    }

    $ingestionUri = if ($DcrEndpoint -match '/dataCollectionRules/') {
        $DcrEndpoint
    } else {
        '{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01' -f $DcrEndpoint.TrimEnd('/'), [uri]::EscapeDataString($DcrImmutableId), [uri]::EscapeDataString($DcrStreamName)
    }
    $ingestionToken = Get-ManagedIdentityToken 'https://monitor.azure.com/' $ManagedIdentityClientId
    $body = ConvertTo-Json -InputObject @($records) -Depth 8 -Compress
    $ingestionHeaders = @{ Authorization = 'Bearer ' + $ingestionToken }
    Invoke-WithRetry -Description 'Logs Ingestion API request' -Operation {
        Invoke-RestMethod -Method Post -Uri $ingestionUri -Headers $ingestionHeaders -ContentType 'application/json' -Body $body
    } | Out-Null
    Write-Output ("Processed {0} password credential records for tenant {1}; sent to {2}." -f @($records).Count, $TenantId, $DcrTableName)
}
catch {
    Write-Error ("App registration secret expiry runbook failed: {0}" -f $_.Exception.Message)
    throw
}
