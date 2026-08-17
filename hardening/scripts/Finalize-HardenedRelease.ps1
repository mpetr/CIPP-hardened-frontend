[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BundleId,

    [Parameter(Mandatory)]
    [string]$FrontendArtifact,

    [Parameter(Mandatory)]
    [string]$ApiArtifact,

    [Parameter(Mandatory)]
    [string]$Maintainer,

    [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),

    [string]$ApiRepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if (-not $ApiRepositoryRoot) {
    $ApiRepositoryRoot = Join-Path $RepositoryRoot '.local/api'
}
$ApiRepositoryRoot = (Resolve-Path -LiteralPath $ApiRepositoryRoot).Path
$FrontendArtifact = (Resolve-Path -LiteralPath $FrontendArtifact).Path
$ApiArtifact = (Resolve-Path -LiteralPath $ApiArtifact).Path

$releaseRelative = "docs/releases/$BundleId"
$releaseDirectory = Join-Path $RepositoryRoot $releaseRelative
$manifestPath = Join-Path $releaseDirectory 'manifest.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

$null = & (Join-Path $PSScriptRoot 'Test-ReleaseManifest.ps1') -ManifestPath $manifestPath -RepositoryRoot $RepositoryRoot

$codexText = Get-Content -Raw -LiteralPath (Join-Path $releaseDirectory 'codex-review.md')
$findingsText = Get-Content -Raw -LiteralPath (Join-Path $releaseDirectory 'findings.md')
$decisionText = Get-Content -Raw -LiteralPath (Join-Path $releaseDirectory 'decision.md')

if ($codexText -match '(?im)^Status:\s*Pending') {
    throw 'Codex review is still pending.'
}
if ($findingsText -match '(?im)^Status:\s*Pending') {
    throw 'Finding decisions are still pending.'
}
if ($decisionText -notmatch '(?im)^Status:\s*Approved\s*$') {
    throw 'Release decision must contain Status: Approved.'
}

$gitCommand = if ($env:CIPP_HARDENED_GIT) {
    $env:CIPP_HARDENED_GIT
} else {
    (Get-Command git -ErrorAction Stop).Source
}

$frontendCommit = (& $gitCommand -C $RepositoryRoot rev-parse HEAD | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to read frontend HEAD.' }
$apiCommit = (& $gitCommand -C $ApiRepositoryRoot rev-parse HEAD | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to read API HEAD.' }

$inventoryPath = Join-Path $releaseDirectory 'module-inventory.json'
$inventoryResult = & (Join-Path $PSScriptRoot 'New-ModuleInventory.ps1') -ApiRepositoryRoot $ApiRepositoryRoot -OutputPath $inventoryPath

$artifactDirectory = Join-Path $RepositoryRoot ".artifacts/$BundleId"
$null = New-Item -ItemType Directory -Force -Path $artifactDirectory
$frontendStored = Join-Path $artifactDirectory ("frontend-" + (Split-Path $FrontendArtifact -Leaf))
$apiStored = Join-Path $artifactDirectory ("api-" + (Split-Path $ApiArtifact -Leaf))
Copy-Item -LiteralPath $FrontendArtifact -Destination $frontendStored -Force
Copy-Item -LiteralPath $ApiArtifact -Destination $apiStored -Force

$frontendHash = (Get-FileHash -LiteralPath $frontendStored -Algorithm SHA256).Hash.ToLowerInvariant()
$apiHash = (Get-FileHash -LiteralPath $apiStored -Algorithm SHA256).Hash.ToLowerInvariant()
$frontendRelative = [IO.Path]::GetRelativePath($RepositoryRoot, $frontendStored).Replace('\', '/')
$apiRelative = [IO.Path]::GetRelativePath($RepositoryRoot, $apiStored).Replace('\', '/')

$manifest.frontend.hardenedCommit = $frontendCommit
$manifest.api.hardenedCommit = $apiCommit
$manifest.api.moduleInventorySha256 = $inventoryResult.sha256
$manifest.artifacts = @(
    [pscustomobject][ordered]@{ component = 'frontend'; path = $frontendRelative; sha256 = $frontendHash },
    [pscustomobject][ordered]@{ component = 'api'; path = $apiRelative; sha256 = $apiHash }
)
$manifest.status = 'approved'
$manifest.approval = [pscustomobject][ordered]@{
    maintainer = $Maintainer
    approvedAt = (Get-Date).ToUniversalTime().ToString('o')
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
& (Join-Path $PSScriptRoot 'Test-ReleaseManifest.ps1') -ManifestPath $manifestPath -RepositoryRoot $RepositoryRoot -RequireApproval
