[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $JobResourceId,

    [ValidateRange(1, 100)]
    [int] $RecentExecutionCount = 20,

    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AcaNfsDiagnostics.psm1') -Force

$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location) "aca-nfs-support-$timestamp"
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$jobs = @()
$environmentIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($resourceId in $JobResourceId) {
    $parts = Get-AcaJobResourceParts -ResourceId $resourceId
    Write-Host "Collecting job: $($parts.Name)"

    $job = Get-AcaResource -ResourceId $parts.ResourceId
    $normalized = Get-NormalizedAcaJob -Job $job
    $normalized['recentExecutions'] = @(Get-RecentAcaJobExecutions -JobResourceId $parts.ResourceId -Count $RecentExecutionCount)
    $jobs += $normalized

    if (-not [string]::IsNullOrWhiteSpace($normalized.environmentId)) {
        [void]$environmentIds.Add($normalized.environmentId)
    }
}

$environments = foreach ($environmentId in $environmentIds) {
    Write-Host "Collecting environment: $environmentId"
    $environment = Get-AcaResource -ResourceId $environmentId
    $storages = Get-AcaEnvironmentStorages -EnvironmentResourceId $environmentId
    Get-NormalizedAcaEnvironment -Environment $environment -Storages $storages
}

$bundle = [ordered]@{
    schemaVersion  = 1
    collectedAtUtc = [DateTime]::UtcNow.ToString('o')
    jobs           = @($jobs)
    environments   = @($environments)
    redaction      = [ordered]@{
        secretValues             = 'not collected'
        registryCredentials      = 'not collected'
        environmentVariableValues = 'redacted'
        applicationCommandAndArgs = 'not collected'
    }
}

$bundlePath = Join-Path $OutputDirectory 'aca-nfs-support-bundle.json'
$bundle | ConvertTo-Json -Depth 100 | Set-Content -Path $bundlePath -Encoding utf8NoBOM

$readme = @"
ACA NFS support bundle
Collected at (UTC): $($bundle.collectedAtUtc)

Included:
- Allowlisted ACA Job configuration
- Workload profile name and sizing limits
- NFS volume names, storage references, mount options, and mount paths
- NFS environment storage endpoint/share metadata
- Recent execution names, status, and UTC timestamps

Not included:
- Secret values
- Registry credentials
- Environment variable values
- Application commands and arguments

Review aca-nfs-support-bundle.json before sharing.
"@

$readme | Set-Content -Path (Join-Path $OutputDirectory 'README.txt') -Encoding utf8NoBOM

$zipPath = "$OutputDirectory.zip"
Compress-Archive -Path (Join-Path $OutputDirectory '*') -DestinationPath $zipPath -Force

[pscustomobject]@{
    OutputDirectory = $OutputDirectory
    BundlePath      = $zipPath
    JobCount        = $jobs.Count
    EnvironmentCount = @($environments).Count
}
