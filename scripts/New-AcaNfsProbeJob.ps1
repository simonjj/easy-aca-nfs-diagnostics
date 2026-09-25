[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [string] $SourceJobResourceId,

    [ValidatePattern('^[a-z][a-z0-9-]{0,30}$')]
    [string] $ProbeJobName,

    [string] $VolumeName,

    [string] $ContainerName,

    [ValidateNotNullOrEmpty()]
    [string] $Image = 'mcr.microsoft.com/azurelinux/base/core:3.0',

    [ValidateRange(10, 3600)]
    [int] $DurationSeconds = 180,

    [ValidateRange(1, 100)]
    [int] $Parallelism = 1,

    [ValidateRange(1, 100)]
    [int] $ReplicaCompletionCount = 1,

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AcaNfsDiagnostics.psm1') -Force

$sourceParts = Get-AcaJobResourceParts -ResourceId $SourceJobResourceId
$sourceJob = Get-AcaResource -ResourceId $sourceParts.ResourceId

if ([string]::IsNullOrWhiteSpace($ProbeJobName)) {
    $ProbeJobName = Get-DefaultProbeJobName -SourceJobName $sourceParts.Name
}

$document = New-AcaNfsProbeDocument `
    -SourceJob $sourceJob `
    -ProbeJobName $ProbeJobName `
    -VolumeName $VolumeName `
    -ContainerName $ContainerName `
    -Image $Image `
    -DurationSeconds $DurationSeconds `
    -Parallelism $Parallelism `
    -ReplicaCompletionCount $ReplicaCompletionCount

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) "$ProbeJobName.request.json"
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$document | ConvertTo-Json -Depth 100 | Set-Content -Path $resolvedOutputPath -Encoding utf8NoBOM

$probeResourceId = "/subscriptions/$($sourceParts.SubscriptionId)/resourceGroups/$($sourceParts.ResourceGroup)/providers/Microsoft.App/jobs/$ProbeJobName"
$url = "https://management.azure.com${probeResourceId}?api-version=2025-07-01"

Write-Host "Generated request: $resolvedOutputPath"
Write-Host "Review the request before creating the probe."

if ($PSCmdlet.ShouldProcess($probeResourceId, 'Create or update ACA NFS probe job')) {
    $result = Invoke-AzJson -Arguments @(
        'rest',
        '--method', 'put',
        '--url', $url,
        '--body', "@$resolvedOutputPath"
    )
    $result = Wait-AcaResourceProvisioning -ResourceId $probeResourceId

    [pscustomobject]@{
        ProbeJobResourceId = $probeResourceId
        ProvisioningState  = $result.properties.provisioningState
        RequestPath        = $resolvedOutputPath
        NextCommand        = "pwsh `"$PSScriptRoot\Invoke-AcaNfsProbe.ps1`" -ProbeJobResourceId `"$probeResourceId`""
    }
}
