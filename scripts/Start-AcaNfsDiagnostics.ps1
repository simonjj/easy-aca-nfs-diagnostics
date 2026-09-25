[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [string[]] $JobResourceId,

    [string] $ProbeSourceJobResourceId,

    [ValidatePattern('^[a-z][a-z0-9-]{0,30}$')]
    [string] $ProbeJobName,

    [string] $VolumeName,

    [string] $ContainerName,

    [ValidateNotNullOrEmpty()]
    [string] $Image = 'mcr.microsoft.com/azurelinux/base/core:3.0',

    [ValidateRange(10, 3600)]
    [int] $ProbeDurationSeconds = 180,

    [ValidateRange(0, 100)]
    [int] $ProbeExecutions = 3,

    [ValidateRange(1, 100)]
    [int] $Parallelism = 1,

    [ValidateRange(1, 100)]
    [int] $ReplicaCompletionCount = 1,

    [ValidateRange(0, 3600)]
    [int] $WaitSeconds = 240,

    [ValidateRange(1, 100)]
    [int] $RecentExecutionCount = 20,

    [switch] $SkipProbe,

    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AcaNfsDiagnostics.psm1') -Force

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [int] $Number,

        [Parameter(Mandatory)]
        [int] $Total,

        [Parameter(Mandatory)]
        [string] $Message
    )

    Write-Host ""
    Write-Host "[$Number/$Total] $Message" -ForegroundColor Cyan
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required but was not found in PATH.'
}

if ($JobResourceId.Count -eq 0) {
    throw 'Provide at least one ACA Job resource ID.'
}

if ([string]::IsNullOrWhiteSpace($ProbeSourceJobResourceId)) {
    $ProbeSourceJobResourceId = $JobResourceId[0]
}

$jobIds = @($JobResourceId | ForEach-Object {
    (Get-AcaJobResourceParts -ResourceId $_).ResourceId
})
$probeSourceParts = Get-AcaJobResourceParts -ResourceId $ProbeSourceJobResourceId

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss')
    $OutputDirectory = Join-Path (Get-Location) "aca-nfs-diagnostics-$timestamp"
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$totalSteps = if ($SkipProbe) { 3 } else { 6 }
$step = 1

Write-Step -Number $step -Total $totalSteps -Message 'Validating Azure CLI authentication and Container Apps tooling'
$account = Invoke-AzJson -Arguments @('account', 'show')
Write-Host "Signed in as: $($account.user.name)"
Write-Host "Default subscription: $($account.name) ($($account.id))"

$extensionOutput = & az extension show --name containerapp --only-show-errors --output json 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Installing the Azure Container Apps CLI extension...'
    & az extension add --name containerapp --upgrade --yes --only-show-errors --output none | Out-Null
}
else {
    Write-Host 'Updating the Azure Container Apps CLI extension...'
    & az extension update --name containerapp --only-show-errors --output none | Out-Null
}
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to install or update the Azure Container Apps CLI extension.'
}

$step++
Write-Step -Number $step -Total $totalSteps -Message 'Exporting the baseline support bundle'
$baselineDirectory = Join-Path $OutputDirectory 'baseline'
$baselineResult = & (Join-Path $PSScriptRoot 'Export-AcaNfsSupportBundle.ps1') `
    -JobResourceId $jobIds `
    -RecentExecutionCount $RecentExecutionCount `
    -OutputDirectory $baselineDirectory

if ($SkipProbe) {
    $step++
    Write-Step -Number $step -Total $totalSteps -Message 'Writing the run summary'

    $summaryPath = Join-Path $OutputDirectory 'RUN-SUMMARY.txt'
    @"
ACA NFS diagnostics run
Completed at (UTC): $([DateTime]::UtcNow.ToString('o'))
Mode: configuration export only
Jobs: $($jobIds -join ', ')
Baseline bundle: $($baselineResult.BundlePath)

No probe resource was created because -SkipProbe was specified.
"@ | Set-Content -Path $summaryPath -Encoding utf8NoBOM

    [pscustomobject]@{
        OutputDirectory = $OutputDirectory
        BaselineBundle  = $baselineResult.BundlePath
        ProbeJobResourceId = $null
        ProbeBundle     = $null
        FinalBundle     = $null
        SummaryPath     = $summaryPath
    }
    return
}

$step++
Write-Step -Number $step -Total $totalSteps -Message 'Generating a source-aligned manual probe job'
$sourceJob = Get-AcaResource -ResourceId $probeSourceParts.ResourceId
if ([string]::IsNullOrWhiteSpace($ProbeJobName)) {
    $ProbeJobName = Get-DefaultProbeJobName -SourceJobName $probeSourceParts.Name
}

$probeDocument = New-AcaNfsProbeDocument `
    -SourceJob $sourceJob `
    -ProbeJobName $ProbeJobName `
    -VolumeName $VolumeName `
    -ContainerName $ContainerName `
    -Image $Image `
    -DurationSeconds $ProbeDurationSeconds `
    -Parallelism $Parallelism `
    -ReplicaCompletionCount $ReplicaCompletionCount

$probeRequestPath = Join-Path $OutputDirectory "$ProbeJobName.request.json"
$probeDocument | ConvertTo-Json -Depth 100 | Set-Content -Path $probeRequestPath -Encoding utf8NoBOM

$probeResourceId = "/subscriptions/$($probeSourceParts.SubscriptionId)/resourceGroups/$($probeSourceParts.ResourceGroup)/providers/Microsoft.App/jobs/$ProbeJobName"
$probeUrl = "https://management.azure.com${probeResourceId}?api-version=2025-07-01"
$probeBundle = $null
$finalResult = $null

Write-Host "Probe request: $probeRequestPath"
Write-Host "Probe resource: $probeResourceId"

$createdProbe = $false
if ($PSCmdlet.ShouldProcess($probeResourceId, 'Create or update and run ACA NFS probe job')) {
    $step++
    Write-Step -Number $step -Total $totalSteps -Message 'Deploying the manual probe job'
    $probeResult = Invoke-AzJson -Arguments @(
        'rest',
        '--method', 'put',
        '--url', $probeUrl,
        '--body', "@$probeRequestPath"
    )
    $createdProbe = $true
    Write-Host "Provisioning state: $($probeResult.properties.provisioningState)"

    $step++
    Write-Step -Number $step -Total $totalSteps -Message "Running and recording $ProbeExecutions probe execution(s)"
    $probeBundle = $null
    if ($ProbeExecutions -gt 0) {
        $probeBundle = & (Join-Path $PSScriptRoot 'Invoke-AcaNfsProbe.ps1') `
            -ProbeJobResourceId $probeResourceId `
            -Executions $ProbeExecutions `
            -WaitSeconds $WaitSeconds `
            -OutputDirectory (Join-Path $OutputDirectory 'probe-executions')
    }
    else {
        Write-Host 'Probe was deployed but not started because -ProbeExecutions 0 was specified.'
    }

    $step++
    Write-Step -Number $step -Total $totalSteps -Message 'Exporting the final source-and-probe support bundle'
    $finalJobIds = @($jobIds)
    if ($finalJobIds -notcontains $probeResourceId) {
        $finalJobIds += $probeResourceId
    }

    $finalResult = & (Join-Path $PSScriptRoot 'Export-AcaNfsSupportBundle.ps1') `
        -JobResourceId $finalJobIds `
        -RecentExecutionCount $RecentExecutionCount `
        -OutputDirectory (Join-Path $OutputDirectory 'final')
}

$summaryPath = Join-Path $OutputDirectory 'RUN-SUMMARY.txt'
$probeBundlePath = if ($null -ne $probeBundle) { $probeBundle.BundlePath } else { 'Not run' }
$finalBundlePath = if ($null -ne $finalResult) { $finalResult.BundlePath } else { 'Not generated' }
$cleanupInstruction = if ($createdProbe) {
    "pwsh `"$PSScriptRoot\Remove-AcaNfsProbeJob.ps1`" -ProbeJobResourceId `"$probeResourceId`""
}
else {
    'Not applicable because the probe was not deployed.'
}

@"
ACA NFS diagnostics run
Completed at (UTC): $([DateTime]::UtcNow.ToString('o'))
Source jobs: $($jobIds -join ', ')
Probe source job: $ProbeSourceJobResourceId
Probe job: $probeResourceId
Probe deployed: $createdProbe
Baseline bundle: $($baselineResult.BundlePath)
Probe execution bundle: $probeBundlePath
Final support bundle: $finalBundlePath

$(
    if ($createdProbe) {
        'The probe job was intentionally preserved for additional reproduction attempts.'
    }
    else {
        'The probe job was not deployed.'
    }
)

Explicit cleanup command:
$cleanupInstruction

Optional host-level capture:
Run scripts/Run-NfsClientCapture.sh on a fresh customer-controlled Linux VM or AKS node.
"@ | Set-Content -Path $summaryPath -Encoding utf8NoBOM

Write-Host ""
Write-Host 'Diagnostics workflow complete.' -ForegroundColor Green
Write-Host "Run summary: $summaryPath"
if ($createdProbe) {
    Write-Host 'The probe job was not deleted.'
}

[pscustomobject]@{
    OutputDirectory   = $OutputDirectory
    BaselineBundle    = $baselineResult.BundlePath
    ProbeJobResourceId = $probeResourceId
    ProbeBundle       = if ($null -ne $probeBundle) { $probeBundle.BundlePath } else { $null }
    FinalBundle       = if ($null -ne $finalResult) { $finalResult.BundlePath } else { $null }
    SummaryPath       = $summaryPath
}
