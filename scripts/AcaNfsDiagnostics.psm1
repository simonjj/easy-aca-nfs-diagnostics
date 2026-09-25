Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ApiVersion = '2025-07-01'

function Get-ObjectProperty {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name,

        [AllowNull()]
        [object] $Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Copy-DeepObject {
    param(
        [Parameter(Mandatory)]
        [object] $InputObject
    )

    return $InputObject | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
}

function Invoke-AzJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is required but was not found in PATH.'
    }

    $allArguments = @($Arguments)
    if ($allArguments -notcontains '--only-show-errors') {
        $allArguments += '--only-show-errors'
    }
    if ($allArguments -notcontains '--output' -and $allArguments -notcontains '-o') {
        $allArguments += @('--output', 'json')
    }

    $output = & az @allArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed:`n$($output -join "`n")"
    }

    $json = ($output -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    try {
        return $json | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Azure CLI returned non-JSON output:`n$json"
    }
}

function Get-AcaJobResourceParts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId
    )

    $pattern = '^/subscriptions/(?<subscription>[^/]+)/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.App/jobs/(?<name>[^/]+)$'
    $match = [regex]::Match($ResourceId.TrimEnd('/'), $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Invalid ACA Job resource ID: $ResourceId"
    }

    [pscustomobject]@{
        SubscriptionId = $match.Groups['subscription'].Value
        ResourceGroup  = $match.Groups['resourceGroup'].Value
        Name           = $match.Groups['name'].Value
        ResourceId     = $ResourceId.TrimEnd('/')
    }
}

function Get-AcaResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId
    )

    $url = "https://management.azure.com$($ResourceId.TrimEnd('/'))?api-version=$script:ApiVersion"
    Invoke-AzJson -Arguments @('rest', '--method', 'get', '--url', $url)
}

function Get-AcaEnvironmentStorages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $EnvironmentResourceId
    )

    $url = "https://management.azure.com$($EnvironmentResourceId.TrimEnd('/'))/storages?api-version=$script:ApiVersion"
    $response = Invoke-AzJson -Arguments @('rest', '--method', 'get', '--url', $url)
    $value = Get-ObjectProperty -InputObject $response -Name 'value' -Default @()
    return @($value)
}

function Get-DefaultProbeJobName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SourceJobName
    )

    $suffix = '-nfs-probe'
    $maxBaseLength = 31 - $suffix.Length
    $baseName = $SourceJobName.ToLowerInvariant() -replace '[^a-z0-9-]', '-'
    $baseName = $baseName.Trim('-')
    if ($baseName.Length -gt $maxBaseLength) {
        $baseName = $baseName.Substring(0, $maxBaseLength).TrimEnd('-')
    }

    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = 'aca'
    }

    return "$baseName$suffix"
}

function Get-NfsSelection {
    param(
        [Parameter(Mandatory)]
        [object] $SourceJob,

        [string] $VolumeName,

        [string] $ContainerName
    )

    $properties = Get-ObjectProperty -InputObject $SourceJob -Name 'properties'
    $template = Get-ObjectProperty -InputObject $properties -Name 'template'
    $volumeValue = Get-ObjectProperty -InputObject $template -Name 'volumes' -Default @()
    $containerValue = Get-ObjectProperty -InputObject $template -Name 'containers' -Default @()
    $volumes = @($volumeValue | Where-Object { $null -ne $_ })
    $containers = @($containerValue | Where-Object { $null -ne $_ })

    $nfsVolumes = @($volumes | Where-Object {
        (Get-ObjectProperty -InputObject $_ -Name 'storageType') -eq 'NfsAzureFile'
    })

    if (-not [string]::IsNullOrWhiteSpace($VolumeName)) {
        $nfsVolumes = @($nfsVolumes | Where-Object {
            (Get-ObjectProperty -InputObject $_ -Name 'name') -eq $VolumeName
        })
    }

    if ($nfsVolumes.Count -ne 1) {
        $available = @($volumes | ForEach-Object {
            "$(Get-ObjectProperty -InputObject $_ -Name 'name') ($(Get-ObjectProperty -InputObject $_ -Name 'storageType'))"
        }) -join ', '
        throw "Expected exactly one NfsAzureFile volume. Specify -VolumeName. Available volumes: $available"
    }

    $volume = $nfsVolumes[0]
    $selectedVolumeName = Get-ObjectProperty -InputObject $volume -Name 'name'
    $candidates = @()

    foreach ($container in $containers) {
        $name = Get-ObjectProperty -InputObject $container -Name 'name'
        if (-not [string]::IsNullOrWhiteSpace($ContainerName) -and $name -ne $ContainerName) {
            continue
        }

        $mounts = @((Get-ObjectProperty -InputObject $container -Name 'volumeMounts' -Default @()) | Where-Object {
            (Get-ObjectProperty -InputObject $_ -Name 'volumeName') -eq $selectedVolumeName
        })

        foreach ($mount in $mounts) {
            $candidates += [pscustomobject]@{
                Container = $container
                Mount     = $mount
            }
        }
    }

    if ($candidates.Count -eq 0) {
        throw "No container mount was found for NFS volume '$selectedVolumeName'."
    }

    if (-not [string]::IsNullOrWhiteSpace($ContainerName) -and $candidates.Count -ne 1) {
        throw "Container '$ContainerName' did not resolve to exactly one mount for '$selectedVolumeName'."
    }

    return [pscustomobject]@{
        Volume    = $volume
        Container = $candidates[0].Container
        Mount     = $candidates[0].Mount
    }
}

function New-AcaNfsProbeDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SourceJob,

        [Parameter(Mandatory)]
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
        [int] $ReplicaCompletionCount = 1
    )

    if ($ProbeJobName.Contains('--') -or $ProbeJobName.EndsWith('-')) {
        throw 'Probe job name must not contain consecutive hyphens or end with a hyphen.'
    }
    if ($ReplicaCompletionCount -gt $Parallelism) {
        throw 'ReplicaCompletionCount cannot be greater than Parallelism.'
    }

    $selection = Get-NfsSelection -SourceJob $SourceJob -VolumeName $VolumeName -ContainerName $ContainerName
    $sourceProperties = Get-ObjectProperty -InputObject $SourceJob -Name 'properties'
    $sourceContainerResources = Get-ObjectProperty -InputObject $selection.Container -Name 'resources'
    if ($null -eq $sourceContainerResources) {
        throw 'The selected source container does not define resources.'
    }

    $environmentId = Get-ObjectProperty -InputObject $sourceProperties -Name 'environmentId'
    if ([string]::IsNullOrWhiteSpace($environmentId)) {
        $environmentId = Get-ObjectProperty -InputObject $sourceProperties -Name 'managedEnvironmentId'
    }
    if ([string]::IsNullOrWhiteSpace($environmentId)) {
        throw 'The source job does not contain an environment resource ID.'
    }

    $mountPath = Get-ObjectProperty -InputObject $selection.Mount -Name 'mountPath'
    if ([string]::IsNullOrWhiteSpace($mountPath)) {
        throw 'The selected NFS volume mount does not define mountPath.'
    }

    $probeScript = @'
set -eu
mount_path="${ACA_NFS_MOUNT_PATH:?ACA_NFS_MOUNT_PATH is required}"
echo "ACA NFS probe started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Mount path: ${mount_path}"
test -d "${mount_path}"
ls -ld "${mount_path}"
df -T "${mount_path}" || true
ls -la "${mount_path}" 2>&1 | head -100 || true
elapsed=0
while [ "${elapsed}" -lt __DURATION_SECONDS__ ]; do
  echo "ACA NFS probe heartbeat at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  test -d "${mount_path}"
  ls -ld "${mount_path}"
  sleep 10
  elapsed=$((elapsed + 10))
done
echo "ACA NFS probe completed at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
'@.Replace('__DURATION_SECONDS__', [string]$DurationSeconds).Replace("`r`n", "`n")

    $probeContainer = [ordered]@{
        name         = 'nfs-probe'
        image        = $Image
        command      = @('/bin/sh', '-c')
        args         = @($probeScript)
        env          = @(
            [ordered]@{
                name  = 'ACA_NFS_MOUNT_PATH'
                value = $mountPath
            }
        )
        resources    = Copy-DeepObject -InputObject $sourceContainerResources
        volumeMounts = @(
            Copy-DeepObject -InputObject $selection.Mount
        )
    }

    $sourceName = Get-ObjectProperty -InputObject $SourceJob -Name 'name' -Default 'unknown'
    $document = [ordered]@{
        location   = Get-ObjectProperty -InputObject $SourceJob -Name 'location'
        tags       = [ordered]@{
            'aca-nfs-diagnostics' = 'probe'
            'source-job'          = $sourceName
        }
        properties = [ordered]@{
            environmentId = $environmentId
            configuration = [ordered]@{
                triggerType        = 'Manual'
                replicaTimeout     = $DurationSeconds + 300
                replicaRetryLimit  = 0
                manualTriggerConfig = [ordered]@{
                    parallelism           = $Parallelism
                    replicaCompletionCount = $ReplicaCompletionCount
                }
            }
            template      = [ordered]@{
                containers = @($probeContainer)
                volumes    = @(
                    Copy-DeepObject -InputObject $selection.Volume
                )
            }
        }
    }

    $workloadProfileName = Get-ObjectProperty -InputObject $sourceProperties -Name 'workloadProfileName'
    if (-not [string]::IsNullOrWhiteSpace($workloadProfileName)) {
        $document.properties['workloadProfileName'] = $workloadProfileName
    }

    return [pscustomobject]$document
}

function Get-NormalizedAcaJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Job
    )

    $properties = Get-ObjectProperty -InputObject $Job -Name 'properties'
    $configuration = Get-ObjectProperty -InputObject $properties -Name 'configuration'
    $template = Get-ObjectProperty -InputObject $properties -Name 'template'
    $containers = @((Get-ObjectProperty -InputObject $template -Name 'containers' -Default @()) | Where-Object { $null -ne $_ })
    $volumes = @((Get-ObjectProperty -InputObject $template -Name 'volumes' -Default @()) | Where-Object { $null -ne $_ })

    $normalizedContainers = foreach ($container in $containers) {
        $environmentVariables = foreach ($variable in @((Get-ObjectProperty -InputObject $container -Name 'env' -Default @()))) {
            $secretRef = Get-ObjectProperty -InputObject $variable -Name 'secretRef'
            [ordered]@{
                name   = Get-ObjectProperty -InputObject $variable -Name 'name'
                source = if ([string]::IsNullOrWhiteSpace($secretRef)) { 'value-redacted' } else { 'secretRef' }
            }
        }

        [ordered]@{
            name         = Get-ObjectProperty -InputObject $container -Name 'name'
            image        = Get-ObjectProperty -InputObject $container -Name 'image'
            resources    = Get-ObjectProperty -InputObject $container -Name 'resources'
            volumeMounts = @((Get-ObjectProperty -InputObject $container -Name 'volumeMounts' -Default @()))
            environment  = @($environmentVariables)
        }
    }

    $normalizedVolumes = foreach ($volume in $volumes) {
        [ordered]@{
            name         = Get-ObjectProperty -InputObject $volume -Name 'name'
            storageType  = Get-ObjectProperty -InputObject $volume -Name 'storageType'
            storageName  = Get-ObjectProperty -InputObject $volume -Name 'storageName'
            mountOptions = Get-ObjectProperty -InputObject $volume -Name 'mountOptions'
        }
    }

    $trigger = [ordered]@{
        type              = Get-ObjectProperty -InputObject $configuration -Name 'triggerType'
        replicaTimeout    = Get-ObjectProperty -InputObject $configuration -Name 'replicaTimeout'
        replicaRetryLimit = Get-ObjectProperty -InputObject $configuration -Name 'replicaRetryLimit'
    }

    $manual = Get-ObjectProperty -InputObject $configuration -Name 'manualTriggerConfig'
    if ($null -ne $manual) {
        $trigger['parallelism'] = Get-ObjectProperty -InputObject $manual -Name 'parallelism'
        $trigger['replicaCompletionCount'] = Get-ObjectProperty -InputObject $manual -Name 'replicaCompletionCount'
    }

    $schedule = Get-ObjectProperty -InputObject $configuration -Name 'scheduleTriggerConfig'
    if ($null -ne $schedule) {
        $trigger['cronExpression'] = Get-ObjectProperty -InputObject $schedule -Name 'cronExpression'
        $trigger['parallelism'] = Get-ObjectProperty -InputObject $schedule -Name 'parallelism'
        $trigger['replicaCompletionCount'] = Get-ObjectProperty -InputObject $schedule -Name 'replicaCompletionCount'
    }

    $event = Get-ObjectProperty -InputObject $configuration -Name 'eventTriggerConfig'
    if ($null -ne $event) {
        $scale = Get-ObjectProperty -InputObject $event -Name 'scale'
        $trigger['parallelism'] = Get-ObjectProperty -InputObject $event -Name 'parallelism'
        $trigger['replicaCompletionCount'] = Get-ObjectProperty -InputObject $event -Name 'replicaCompletionCount'
        $trigger['pollingInterval'] = Get-ObjectProperty -InputObject $scale -Name 'pollingInterval'
        $trigger['minExecutions'] = Get-ObjectProperty -InputObject $scale -Name 'minExecutions'
        $trigger['maxExecutions'] = Get-ObjectProperty -InputObject $scale -Name 'maxExecutions'
    }

    $environmentId = Get-ObjectProperty -InputObject $properties -Name 'environmentId'
    if ([string]::IsNullOrWhiteSpace($environmentId)) {
        $environmentId = Get-ObjectProperty -InputObject $properties -Name 'managedEnvironmentId'
    }

    [ordered]@{
        resourceId          = Get-ObjectProperty -InputObject $Job -Name 'id'
        name                = Get-ObjectProperty -InputObject $Job -Name 'name'
        location            = Get-ObjectProperty -InputObject $Job -Name 'location'
        environmentId       = $environmentId
        workloadProfileName = Get-ObjectProperty -InputObject $properties -Name 'workloadProfileName'
        trigger             = $trigger
        containers          = @($normalizedContainers)
        volumes             = @($normalizedVolumes)
    }
}

function Get-NormalizedAcaEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Environment,

        [object[]] $Storages = @()
    )

    $properties = Get-ObjectProperty -InputObject $Environment -Name 'properties'
    $vnet = Get-ObjectProperty -InputObject $properties -Name 'vnetConfiguration'
    $profiles = foreach ($profile in @((Get-ObjectProperty -InputObject $properties -Name 'workloadProfiles' -Default @()))) {
        [ordered]@{
            name                = Get-ObjectProperty -InputObject $profile -Name 'name'
            workloadProfileType = Get-ObjectProperty -InputObject $profile -Name 'workloadProfileType'
            minimumCount        = Get-ObjectProperty -InputObject $profile -Name 'minimumCount'
            maximumCount        = Get-ObjectProperty -InputObject $profile -Name 'maximumCount'
        }
    }

    $nfsStorages = foreach ($storage in @($Storages)) {
        $storageProperties = Get-ObjectProperty -InputObject $storage -Name 'properties'
        $nfs = Get-ObjectProperty -InputObject $storageProperties -Name 'nfsAzureFile'
        if ($null -eq $nfs) {
            continue
        }

        [ordered]@{
            resourceId = Get-ObjectProperty -InputObject $storage -Name 'id'
            name       = Get-ObjectProperty -InputObject $storage -Name 'name'
            server     = Get-ObjectProperty -InputObject $nfs -Name 'server'
            shareName  = Get-ObjectProperty -InputObject $nfs -Name 'shareName'
            accessMode = Get-ObjectProperty -InputObject $nfs -Name 'accessMode'
        }
    }

    [ordered]@{
        resourceId             = Get-ObjectProperty -InputObject $Environment -Name 'id'
        name                   = Get-ObjectProperty -InputObject $Environment -Name 'name'
        location               = Get-ObjectProperty -InputObject $Environment -Name 'location'
        infrastructureSubnetId = Get-ObjectProperty -InputObject $vnet -Name 'infrastructureSubnetId'
        workloadProfiles       = @($profiles)
        nfsStorages            = @($nfsStorages)
    }
}

function Get-RecentAcaJobExecutions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $JobResourceId,

        [ValidateRange(1, 100)]
        [int] $Count = 20
    )

    $parts = Get-AcaJobResourceParts -ResourceId $JobResourceId
    $executions = Invoke-AzJson -Arguments @(
        'containerapp', 'job', 'execution', 'list',
        '--name', $parts.Name,
        '--resource-group', $parts.ResourceGroup,
        '--subscription', $parts.SubscriptionId
    )

    $normalized = foreach ($execution in @($executions) | Sort-Object { $_.properties.startTime } -Descending | Select-Object -First $Count) {
        $properties = Get-ObjectProperty -InputObject $execution -Name 'properties'
        [ordered]@{
            name      = Get-ObjectProperty -InputObject $execution -Name 'name'
            status    = Get-ObjectProperty -InputObject $properties -Name 'status'
            startTime = Get-ObjectProperty -InputObject $properties -Name 'startTime'
            endTime   = Get-ObjectProperty -InputObject $properties -Name 'endTime'
        }
    }

    return @($normalized)
}

Export-ModuleMember -Function @(
    'Get-AcaJobResourceParts',
    'Get-AcaResource',
    'Get-AcaEnvironmentStorages',
    'Get-DefaultProbeJobName',
    'New-AcaNfsProbeDocument',
    'Get-NormalizedAcaJob',
    'Get-NormalizedAcaEnvironment',
    'Get-RecentAcaJobExecutions',
    'Invoke-AzJson'
)
