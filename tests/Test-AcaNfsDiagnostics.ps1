Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'scripts/AcaNfsDiagnostics.psm1') -Force

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [object] $Expected,

        [Parameter(Mandatory)]
        [object] $Actual,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if ("$Expected" -ne "$Actual") {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$fixturePath = Join-Path $PSScriptRoot 'fixtures/source-job.json'
$sourceJob = Get-Content -Raw -Path $fixturePath | ConvertFrom-Json -Depth 100

$probe = New-AcaNfsProbeDocument `
    -SourceJob $sourceJob `
    -ProbeJobName 'example-nfs-probe' `
    -DurationSeconds 120

Assert-Equal $sourceJob.properties.environmentId $probe.properties.environmentId 'Environment ID was not preserved.'
Assert-Equal 'D8' $probe.properties.workloadProfileName 'Workload profile was not preserved.'
Assert-Equal 'Manual' $probe.properties.configuration.triggerType 'Probe must use a manual trigger.'
Assert-Equal 2 $probe.properties.template.containers[0].resources.cpu 'CPU was not preserved.'
Assert-Equal '4Gi' $probe.properties.template.containers[0].resources.memory 'Memory was not preserved.'
Assert-Equal '/data-vol' $probe.properties.template.containers[0].volumeMounts[0].mountPath 'Mount path was not preserved.'
Assert-Equal 'example-nfs' $probe.properties.template.volumes[0].storageName 'Storage reference was not preserved.'
Assert-Equal 'vers=4.1,sec=sys' $probe.properties.template.volumes[0].mountOptions 'Mount options were not preserved.'
Assert-Equal 'mcr.microsoft.com/azurelinux/base/core:3.0' $probe.properties.template.containers[0].image 'Unexpected probe image.'

$normalized = Get-NormalizedAcaJob -Job $sourceJob
$normalizedJson = $normalized | ConvertTo-Json -Depth 100

Assert-True (-not $normalizedJson.Contains('do-not-export')) 'Normalized support data leaked an application value.'
Assert-Equal 'value-redacted' $normalized.containers[0].environment[0].source 'Plain values must be redacted.'
Assert-Equal 'secretRef' $normalized.containers[0].environment[1].source 'Secret references must be identified without exporting values.'

$defaultName = Get-DefaultProbeJobName -SourceJobName 'this-is-an-extremely-long-container-apps-job-name'
Assert-True ($defaultName.Length -le 31) 'Generated probe name exceeds the ACA Job name limit.'
Assert-True ($defaultName.EndsWith('-nfs-probe')) 'Generated probe name is missing the expected suffix.'

Write-Host 'All ACA NFS diagnostics tests passed.'
