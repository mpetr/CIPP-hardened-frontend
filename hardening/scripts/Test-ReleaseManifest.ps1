[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),

    [switch]$RequireApproval
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-JsonPropertyValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-RepoPath {
    param([string]$RelativePath)
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($RelativePath)) 'A manifest path reference is empty.'
    return Join-Path $RepositoryRoot ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
}

function Assert-ReferencedFile {
    param([string]$RelativePath, [string]$Description)
    $full = Resolve-RepoPath $RelativePath
    Assert-Condition (Test-Path -LiteralPath $full -PathType Leaf) "$Description does not exist: $RelativePath"
    return $full
}

Assert-Condition ($manifest.schemaVersion -eq 1) 'Unsupported release manifest schemaVersion.'
Assert-Condition ($manifest.bundleId -match '^ch-ui\d+\.\d+\.\d+-api\d+\.\d+\.\d+-r\d+$') 'Invalid bundleId.'
Assert-Condition ($manifest.status -in @('review-in-progress', 'ready-for-maintainer-approval', 'approved', 'approved-for-test-deployment', 'deployed', 'failed', 'rolled-back', 'deferred')) 'Invalid release status.'

if ($manifest.PSObject.Properties.Name -contains 'releaseAgePolicy') {
    Assert-Condition ($manifest.releaseAgePolicy.minimumAgeDays -ge 30) 'releaseAgePolicy.minimumAgeDays must be at least 30.'
    Assert-Condition ($manifest.releaseAgePolicy.latestAllowedWhenAged -eq $true) 'releaseAgePolicy.latestAllowedWhenAged must be true for the approved PRD policy.'
    Assert-Condition ($manifest.releaseAgePolicy.criticalFreshExceptionsOnly -eq $true) 'releaseAgePolicy.criticalFreshExceptionsOnly must be true.'
} elseif ($RequireApproval) {
    throw 'releaseAgePolicy is required before approval.'
}

foreach ($componentName in @('frontend', 'api')) {
    $component = $manifest.$componentName
    Assert-Condition ($component.upstreamCommit -match '^[a-f0-9]{40}$') "$componentName upstreamCommit must be a 40-character lowercase SHA."
    Assert-Condition ($component.lockfileSha256 -match '^[a-f0-9]{64}$') "$componentName lockfileSha256 must be a SHA-256 value."
    if ($component.hardenedCommit) {
        Assert-Condition ($component.hardenedCommit -match '^[a-f0-9]{40}$') "$componentName hardenedCommit must be a 40-character lowercase SHA."
    }
}

foreach ($property in @('codexReview', 'findings', 'decision')) {
    $relative = $manifest.documentation.$property
    $null = Assert-ReferencedFile $relative "Referenced documentation $property"
}

foreach ($risk in @($manifest.documentation.risks)) {
    $null = Assert-ReferencedFile $risk 'Referenced risk record'
}

foreach ($exception in @($manifest.documentation.versionExceptions)) {
    $exceptionPath = Assert-ReferencedFile $exception 'Referenced version-exception record'
    if ($RequireApproval) {
        $exceptionText = Get-Content -Raw -LiteralPath $exceptionPath
        Assert-Condition ($exceptionText -match '(?im)^Status:\s*Approved\s*$') "Version-exception record is not approved: $exception"
    }
}

$releaseAgeEvidence = $null
if (($manifest.documentation.PSObject.Properties.Name -contains 'releaseAgeEvidence') -and $manifest.documentation.releaseAgeEvidence) {
    $agePath = Assert-ReferencedFile $manifest.documentation.releaseAgeEvidence 'Release-age evidence'
    $releaseAgeEvidence = Get-Content -Raw -LiteralPath $agePath | ConvertFrom-Json
} elseif ($RequireApproval) {
    throw 'Release-age evidence is required before approval.'
}

foreach ($artifact in @($manifest.artifacts)) {
    $artifactName = Get-JsonPropertyValue $artifact 'name'
    $artifactPathReference = Get-JsonPropertyValue $artifact 'path'
    $localEvidencePath = Get-JsonPropertyValue $artifact 'localEvidencePath'
    $artifactReference = if (-not [string]::IsNullOrWhiteSpace($artifactPathReference)) { $artifactPathReference } else { $localEvidencePath }

    Assert-Condition ((Get-JsonPropertyValue $artifact 'sha256') -match '^[a-f0-9]{64}$') "Artifact hash is invalid: $artifactName"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($artifactReference)) "Artifact reference is missing for: $artifactName"

    if (-not [string]::IsNullOrWhiteSpace($artifactPathReference)) {
        $artifactPath = if ([IO.Path]::IsPathRooted($artifactPathReference)) { $artifactPathReference } else { Resolve-RepoPath $artifactPathReference }
        Assert-Condition (Test-Path -LiteralPath $artifactPath -PathType Leaf) "Artifact does not exist: $artifactPath"
        $actual = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Condition ($actual -eq (Get-JsonPropertyValue $artifact 'sha256')) "Artifact hash mismatch: $artifactPath"
    } else {
        Assert-Condition ((Get-JsonPropertyValue $artifact 'source') -eq 'github-actions-artifact') "Artifact without repository-local path must be a GitHub Actions artifact: $artifactName"
        Assert-Condition (-not [string]::IsNullOrWhiteSpace((Get-JsonPropertyValue $artifact 'runId'))) "GitHub Actions artifact lacks runId: $artifactName"
        $sizeBytes = Get-JsonPropertyValue $artifact 'sizeBytes'
        if ($null -ne $sizeBytes) {
            Assert-Condition ($sizeBytes -gt 0) "Artifact sizeBytes must be positive: $artifactName"
        }
    }
}

if ($RequireApproval) {
    Assert-Condition ($manifest.status -in @('approved', 'approved-for-test-deployment', 'deployed')) 'Manifest is not approved for deployment.'
    Assert-Condition ($null -ne $manifest.approval) 'Approval record is missing.'
    Assert-Condition ((-not [string]::IsNullOrWhiteSpace((Get-JsonPropertyValue $manifest.approval 'maintainer'))) -or (-not [string]::IsNullOrWhiteSpace((Get-JsonPropertyValue $manifest.approval 'approvedBy')))) 'Approval maintainer is missing.'
    Assert-Condition (@($manifest.artifacts).Count -ge 2) 'Approved release must contain frontend and API artifacts.'
    Assert-Condition ($manifest.frontend.hardenedCommit -match '^[a-f0-9]{40}$') 'Approved release is missing frontend hardenedCommit.'
    Assert-Condition ($manifest.api.hardenedCommit -match '^[a-f0-9]{40}$') 'Approved release is missing API hardenedCommit.'

    $codexPath = Resolve-RepoPath $manifest.documentation.codexReview
    $decisionPath = Resolve-RepoPath $manifest.documentation.decision
    $codexText = Get-Content -Raw -LiteralPath $codexPath
    $decisionText = Get-Content -Raw -LiteralPath $decisionPath
    Assert-Condition ($codexText -notmatch '(?im)^Status:\s*Pending') 'Codex review is still pending.'
    Assert-Condition ($decisionText -match '(?im)^Status:\s*Approved( for test deployment)?\s*$') 'Release decision is not Approved.'

    Assert-Condition ($null -ne $releaseAgeEvidence) 'Release-age evidence is missing.'
    Assert-Condition ($releaseAgeEvidence.minimumAgeDays -ge $manifest.releaseAgePolicy.minimumAgeDays) 'Release-age evidence was generated with a weaker minimum age policy.'
    Assert-Condition ($releaseAgeEvidence.status -in @('passed', 'passed-with-exceptions')) "Release-age evidence status blocks approval: $($releaseAgeEvidence.status)"

    $versionExceptionSet = @{}
    foreach ($exception in @($manifest.documentation.versionExceptions)) { $versionExceptionSet[$exception] = $true }
    $riskSet = @{}
    foreach ($risk in @($manifest.documentation.risks)) { $riskSet[$risk] = $true }

    foreach ($entry in @($releaseAgeEvidence.entries)) {
        switch ($entry.status) {
            'eligible' { continue }
            'not-controllable' { continue }
            'critical-exception' {
                Assert-Condition (-not [string]::IsNullOrWhiteSpace($entry.exceptionRecord)) "Critical version exception lacks exceptionRecord: $($entry.name) $($entry.version)"
                Assert-Condition ($versionExceptionSet.ContainsKey([string]$entry.exceptionRecord)) "Critical version exception is not listed in manifest.documentation.versionExceptions: $($entry.exceptionRecord)"
                continue
            }
            'bootstrap-exception' {
                Assert-Condition (-not [string]::IsNullOrWhiteSpace($entry.exceptionRecord)) "Bootstrap version exception lacks exceptionRecord: $($entry.name) $($entry.version)"
                Assert-Condition ($versionExceptionSet.ContainsKey([string]$entry.exceptionRecord)) "Bootstrap version exception is not listed in manifest.documentation.versionExceptions: $($entry.exceptionRecord)"
                continue
            }
            'risk-accepted' {
                Assert-Condition (-not [string]::IsNullOrWhiteSpace($entry.riskRecord)) "Release-age entry lacks riskRecord: $($entry.name) $($entry.version)"
                Assert-Condition ($riskSet.ContainsKey([string]$entry.riskRecord)) "Release-age risk record is not listed in manifest.documentation.risks: $($entry.riskRecord)"
                continue
            }
            default { throw "Release-age entry blocks approval: $($entry.component) $($entry.type) $($entry.name) $($entry.version) status=$($entry.status)" }
        }
    }
}

[pscustomobject]@{
    valid = $true
    bundleId = $manifest.bundleId
    status = $manifest.status
    artifactCount = @($manifest.artifacts).Count
    approvalRequired = [bool]$RequireApproval
    releaseAgeStatus = if ($releaseAgeEvidence) { $releaseAgeEvidence.status } else { $null }
}
