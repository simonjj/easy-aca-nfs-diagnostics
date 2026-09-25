[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string] $ProbeJobResourceId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AcaNfsDiagnostics.psm1') -Force

$parts = Get-AcaJobResourceParts -ResourceId $ProbeJobResourceId

if ($PSCmdlet.ShouldProcess($ProbeJobResourceId, 'Permanently delete ACA NFS probe job')) {
    & az containerapp job delete `
        --name $parts.Name `
        --resource-group $parts.ResourceGroup `
        --subscription $parts.SubscriptionId `
        --yes `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete probe job: $ProbeJobResourceId"
    }

    Write-Host "Deleted probe job: $ProbeJobResourceId"
}
