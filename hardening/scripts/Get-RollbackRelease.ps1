[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CurrentManifestPath,

    [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),

    [Parameter(Mandatory)]
    [switch]$HealthCheckFailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $HealthCheckFailed) {
    throw 'Rollback selection requires explicit -HealthCheckFailed confirmation.'
}

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$CurrentManifestPath = (Resolve-Path -LiteralPath $CurrentManifestPath).Path
$current = Get-Content -Raw -LiteralPath $CurrentManifestPath | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($current.previousRelease)) {
    throw "Release $($current.bundleId) does not declare a previous release."
}

$previousManifestPath = Join-Path $RepositoryRoot "docs/releases/$($current.previousRelease)/manifest.json"
if (-not (Test-Path -LiteralPath $previousManifestPath -PathType Leaf)) {
    throw "Previous release manifest was not found: $previousManifestPath"
}

$validation = & (Join-Path $PSScriptRoot 'Test-ReleaseManifest.ps1') -ManifestPath $previousManifestPath -RepositoryRoot $RepositoryRoot -RequireApproval
$previous = Get-Content -Raw -LiteralPath $previousManifestPath | ConvertFrom-Json

[pscustomobject][ordered]@{
    rollbackRequired = $true
    failedRelease = $current.bundleId
    selectedRelease = $previous.bundleId
    manifestPath = $previousManifestPath
    artifacts = $previous.artifacts
    validation = $validation
    azureExecutionConfigured = $false
}
