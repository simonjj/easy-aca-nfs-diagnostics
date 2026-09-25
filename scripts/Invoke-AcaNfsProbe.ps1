[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProbeJobResourceId,

    [ValidateRange(1, 100)]
    [int] $Executions = 1,

    [ValidateRange(0, 3600)]
    [int] $WaitSeconds = 240,

    [ValidateRange(2, 120)]
    [int] $PollSeconds = 10,

    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AcaNfsDiagnostics.psm1') -Force

$parts = Get-AcaJobResourceParts -ResourceId $ProbeJobResourceId
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location) "aca-nfs-probe-$timestamp"
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$probeJob = Get-AcaResource -ResourceId $ProbeJobResourceId
$normalizedProbe = Get-NormalizedAcaJob -Job $probeJob
$normalizedProbe | ConvertTo-Json -Depth 100 | Set-Content `
    -Path (Join-Path $OutputDirectory 'probe-job.json') `
    -Encoding utf8NoBOM

$records = @()
$terminalStatuses = @('Succeeded', 'Failed', 'Stopped')

for ($index = 1; $index -le $Executions; $index++) {
    $startedAt = [DateTime]::UtcNow
    Write-Host "Starting probe execution $index of $Executions at $($startedAt.ToString('o'))"

    $startResult = Invoke-AzJson -Arguments @(
        'containerapp', 'job', 'start',
        '--name', $parts.Name,
        '--resource-group', $parts.ResourceGroup,
        '--subscription', $parts.SubscriptionId
    )

    $startResult | ConvertTo-Json -Depth 100 | Set-Content `
        -Path (Join-Path $OutputDirectory "start-$index.json") `
        -Encoding utf8NoBOM

    $executionName = $null
    if ($null -ne $startResult -and $null -ne $startResult.PSObject.Properties['name']) {
        $executionName = $startResult.name
    }

    $latestExecution = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $executionList = Invoke-AzJson -Arguments @(
            'containerapp', 'job', 'execution', 'list',
            '--name', $parts.Name,
            '--resource-group', $parts.ResourceGroup,
            '--subscription', $parts.SubscriptionId
        )

        if (-not [string]::IsNullOrWhiteSpace($executionName)) {
            $latestExecution = @($executionList | Where-Object { $_.name -eq $executionName }) | Select-Object -First 1
        }
        else {
            $discoveryThreshold = $startedAt.AddMinutes(-1)
            $latestExecution = @($executionList | Where-Object {
                $null -ne $_.properties.startTime -and [DateTime]$_.properties.startTime -ge $discoveryThreshold
            } | Sort-Object { $_.properties.startTime } -Descending) | Select-Object -First 1
            if ($null -ne $latestExecution) {
                $executionName = $latestExecution.name
            }
        }

        $status = if ($null -ne $latestExecution) { $latestExecution.properties.status } else { 'PendingDiscovery' }
        Write-Host "Execution: $executionName Status: $status"

        if ($WaitSeconds -eq 0 -or $terminalStatuses -contains $status -or [DateTime]::UtcNow -ge $deadline) {
            break
        }

        Start-Sleep -Seconds $PollSeconds
    } while ($true)

    if ($null -ne $latestExecution) {
        $latestExecution | ConvertTo-Json -Depth 100 | Set-Content `
            -Path (Join-Path $OutputDirectory "execution-$index.json") `
            -Encoding utf8NoBOM
    }

    $records += [ordered]@{
        requestedAtUtc = $startedAt.ToString('o')
        executionName  = $executionName
        status         = if ($null -ne $latestExecution) { $latestExecution.properties.status } else { 'Unknown' }
        startTime      = if ($null -ne $latestExecution) { $latestExecution.properties.startTime } else { $null }
        endTime        = if ($null -ne $latestExecution) { $latestExecution.properties.endTime } else { $null }
    }
}

$manifest = [ordered]@{
    collectedAtUtc    = [DateTime]::UtcNow.ToString('o')
    probeJobResourceId = $ProbeJobResourceId
    executions        = $records
    note              = 'If the NFS host mount fails, the probe container may never start. Preserve exact UTC timestamps for platform correlation.'
}

$manifest | ConvertTo-Json -Depth 100 | Set-Content `
    -Path (Join-Path $OutputDirectory 'manifest.json') `
    -Encoding utf8NoBOM

$zipPath = "$OutputDirectory.zip"
Compress-Archive -Path (Join-Path $OutputDirectory '*') -DestinationPath $zipPath -Force

[pscustomobject]@{
    ProbeJobResourceId = $ProbeJobResourceId
    OutputDirectory    = $OutputDirectory
    BundlePath         = $zipPath
    Executions         = $records
}
