Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$fixturePath = Join-Path $PSScriptRoot 'fixtures/source-job.json'
$fixture = Get-Content -Raw -Path $fixturePath | ConvertFrom-Json -Depth 100
$testOutput = Join-Path ([System.IO.Path]::GetTempPath()) "aca-nfs-guided-test-$([guid]::NewGuid().ToString('N'))"
$sourceJobId = $fixture.id
$environmentId = $fixture.properties.environmentId
$probeJobId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.App/jobs/example-worker-nfs-probe'

$global:MockSourceJob = $fixture
$global:MockEnvironment = [pscustomobject]@{
    id = $environmentId
    name = 'example-env'
    location = 'eastus'
    properties = [pscustomobject]@{
        vnetConfiguration = [pscustomobject]@{
            infrastructureSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/virtualNetworks/example-vnet/subnets/aca'
        }
        workloadProfiles = @(
            [pscustomobject]@{
                name = 'D8'
                workloadProfileType = 'D8'
                minimumCount = 0
                maximumCount = 10
            }
        )
    }
}
$global:MockProbeJob = $null
$global:MockExecutionStart = [DateTime]::UtcNow.ToString('o')

function global:az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0

    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'show') {
        '{"id":"00000000-0000-0000-0000-000000000000","name":"Mock subscription","user":{"name":"customer@example.com"}}'
        return
    }

    if ($arguments[0] -eq 'extension') {
        if ($arguments[1] -eq 'show') {
            '{"name":"containerapp","version":"1.0.0"}'
        }
        return
    }

    if ($arguments[0] -eq 'rest') {
        $methodIndex = [Array]::IndexOf($arguments, '--method')
        $urlIndex = [Array]::IndexOf($arguments, '--url')
        $bodyIndex = [Array]::IndexOf($arguments, '--body')
        $method = $arguments[$methodIndex + 1]
        $url = $arguments[$urlIndex + 1]

        if ($method -eq 'put') {
            $bodyPath = $arguments[$bodyIndex + 1].TrimStart('@')
            $body = Get-Content -Raw -Path $bodyPath | ConvertFrom-Json -Depth 100
            $global:MockProbeJob = [pscustomobject]@{
                id = $probeJobId
                name = 'example-worker-nfs-probe'
                location = $body.location
                properties = $body.properties
            }
            @{
                id = $probeJobId
                properties = @{
                    provisioningState = 'Succeeded'
                }
            } | ConvertTo-Json -Depth 100
            return
        }

        if ($url -like '*/storages?*') {
            @{
                value = @(
                    @{
                        id = "$environmentId/storages/example-nfs"
                        name = 'example-nfs'
                        properties = @{
                            nfsAzureFile = @{
                                server = 'example.file.core.windows.net'
                                shareName = 'example-share'
                                accessMode = 'ReadWrite'
                            }
                        }
                    }
                )
            } | ConvertTo-Json -Depth 100
            return
        }

        if ($url -like "*$probeJobId*") {
            $global:MockProbeJob | ConvertTo-Json -Depth 100
            return
        }

        if ($url -like "*$sourceJobId*") {
            $global:MockSourceJob | ConvertTo-Json -Depth 100
            return
        }

        if ($url -like "*$environmentId*") {
            $global:MockEnvironment | ConvertTo-Json -Depth 100
            return
        }
    }

    if ($arguments[0] -eq 'containerapp' -and $arguments[1] -eq 'job') {
        if ($arguments[2] -eq 'start') {
            @{
                name = 'example-worker-nfs-probe-exec-1'
                properties = @{
                    status = 'Running'
                    startTime = $global:MockExecutionStart
                }
            } | ConvertTo-Json -Depth 100
            return
        }

        if ($arguments[2] -eq 'execution' -and $arguments[3] -eq 'list') {
            $nameIndex = [Array]::IndexOf($arguments, '--name')
            $jobName = $arguments[$nameIndex + 1]
            if ($jobName -eq 'example-worker-nfs-probe') {
                @(
                    @{
                        name = 'example-worker-nfs-probe-exec-1'
                        properties = @{
                            status = 'Succeeded'
                            startTime = $global:MockExecutionStart
                            endTime = [DateTime]::UtcNow.ToString('o')
                        }
                    }
                ) | ConvertTo-Json -Depth 100
            }
            else {
                '[]'
            }
            return
        }
    }

    $global:LASTEXITCODE = 1
    "Unexpected mock az invocation: $($arguments -join ' ')"
}

try {
    $result = & (Join-Path $repoRoot 'scripts/Start-AcaNfsDiagnostics.ps1') `
        -JobResourceId $sourceJobId `
        -ProbeExecutions 1 `
        -WaitSeconds 0 `
        -OutputDirectory $testOutput `
        -Confirm:$false

    if (-not (Test-Path $result.BaselineBundle)) {
        throw 'Guided workflow did not create the baseline bundle.'
    }
    if (-not (Test-Path $result.ProbeBundle)) {
        throw 'Guided workflow did not create the probe execution bundle.'
    }
    if (-not (Test-Path $result.FinalBundle)) {
        throw 'Guided workflow did not create the final support bundle.'
    }
    if (-not (Test-Path $result.SummaryPath)) {
        throw 'Guided workflow did not create RUN-SUMMARY.txt.'
    }

    $finalJson = Get-Content -Raw -Path (Join-Path $testOutput 'final/aca-nfs-support-bundle.json')
    if ($finalJson.Contains('do-not-export')) {
        throw 'Guided workflow leaked a fixture secret into the final support bundle.'
    }
    if (-not $finalJson.Contains('example-worker-nfs-probe')) {
        throw 'Final support bundle does not include the probe job.'
    }

    Write-Host 'Guided workflow test passed.'
}
finally {
    Remove-Item -LiteralPath $testOutput -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\global:az -ErrorAction SilentlyContinue
    Remove-Variable MockSourceJob,MockEnvironment,MockProbeJob,MockExecutionStart -Scope Global -ErrorAction SilentlyContinue
}
