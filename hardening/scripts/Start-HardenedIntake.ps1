[CmdletBinding()]
param(
    [string]$FrontendRepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$ApiRepositoryRoot,
    [string]$FrontendTag,
    [string]$ApiTag,
    [ValidateRange(1, 999)]
    [int]$Revision = 1,
    [ValidateRange(1, 3650)]
    [int]$MinimumReleaseAgeDays = 30,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$FrontendRepositoryRoot = (Resolve-Path -LiteralPath $FrontendRepositoryRoot).Path
if (-not $ApiRepositoryRoot) {
    $ApiRepositoryRoot = Join-Path $FrontendRepositoryRoot '.local/api'
}
$ApiRepositoryRoot = (Resolve-Path -LiteralPath $ApiRepositoryRoot).Path

$gitCommand = if ($env:CIPP_HARDENED_GIT) {
    $env:CIPP_HARDENED_GIT
} else {
    (Get-Command git -ErrorAction Stop).Source
}

function Invoke-RepoGit {
    param(
        [string]$Repository,
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )

    $output = & $gitCommand -C $Repository @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git failed in $($Repository): git $($Arguments -join ' ')"
    }
    return $output
}

function Convert-ToVersion {
    param([string]$Tag)

    $normalized = $Tag.TrimStart('v').Split('-')[0]
    try {
        return [version]$normalized
    } catch {
        throw "Release tag is not a supported semantic version: $Tag"
    }
}

function Test-ReleaseIsAged {
    param([object]$Release, [datetime]$CutoffTimestampUtc)

    if (-not $Release.published_at) { return $false }
    return ([datetime]$Release.published_at).ToUniversalTime() -le $CutoffTimestampUtc
}

function Get-StableReleases {
    param([string]$Repository)

    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'CIPP-hardened-manual-intake'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $uri = "https://api.github.com/repos/$Repository/releases?per_page=50"
    return @(Invoke-RestMethod -Uri $uri -Headers $headers -Method Get | Where-Object {
        -not $_.draft -and -not $_.prerelease
    })
}

$baselinePath = Join-Path $FrontendRepositoryRoot 'hardening/baseline.json'
$baseline = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json

$frontendReleases = Get-StableReleases 'KelvinTegelaar/CIPP'
$apiReleases = Get-StableReleases 'KelvinTegelaar/CIPP-API'
$decisionTimestampUtc = (Get-Date).ToUniversalTime()
$releaseAgeCutoffUtc = $decisionTimestampUtc.AddDays(-1 * $MinimumReleaseAgeDays)
$agedFrontendReleases = @($frontendReleases | Where-Object { Test-ReleaseIsAged $_ $releaseAgeCutoffUtc })
$agedApiReleases = @($apiReleases | Where-Object { Test-ReleaseIsAged $_ $releaseAgeCutoffUtc })

if (-not $FrontendTag) {
    $selectedFrontend = $agedFrontendReleases |
        Sort-Object { Convert-ToVersion $_.tag_name } -Descending |
        Select-Object -First 1
    if (-not $selectedFrontend) {
        throw "No stable frontend release is at least $MinimumReleaseAgeDays full UTC days old. Cutoff: $($releaseAgeCutoffUtc.ToString('o'))."
    }
    $FrontendTag = $selectedFrontend.tag_name
} else {
    $selectedFrontend = $frontendReleases | Where-Object tag_name -eq $FrontendTag | Select-Object -First 1
    if (-not $selectedFrontend) {
        throw "Stable frontend release was not found: $FrontendTag"
    }
    if (-not (Test-ReleaseIsAged $selectedFrontend $releaseAgeCutoffUtc)) {
        throw "Frontend release $FrontendTag is not at least $MinimumReleaseAgeDays full UTC days old. Published: $($selectedFrontend.published_at)."
    }
}

$frontendVersion = Convert-ToVersion $FrontendTag
if (-not $ApiTag) {
    $selectedApi = $agedApiReleases |
        Where-Object {
            $version = Convert-ToVersion $_.tag_name
            $version.Major -eq $frontendVersion.Major -and $version.Minor -eq $frontendVersion.Minor
        } |
        Sort-Object { Convert-ToVersion $_.tag_name } -Descending |
        Select-Object -First 1

    if (-not $selectedApi) {
        throw "No stable API release matches frontend major/minor $($frontendVersion.Major).$($frontendVersion.Minor)."
    }
    $ApiTag = $selectedApi.tag_name
} else {
    $selectedApi = $apiReleases | Where-Object tag_name -eq $ApiTag | Select-Object -First 1
    if (-not $selectedApi) {
        throw "Stable API release was not found: $ApiTag"
    }
    if (-not (Test-ReleaseIsAged $selectedApi $releaseAgeCutoffUtc)) {
        throw "API release $ApiTag is not at least $MinimumReleaseAgeDays full UTC days old. Published: $($selectedApi.published_at)."
    }
    $apiVersionCheck = Convert-ToVersion $ApiTag
    if ($apiVersionCheck.Major -ne $frontendVersion.Major -or $apiVersionCheck.Minor -ne $frontendVersion.Minor) {
        throw "API $ApiTag is not compatible by the CIPP-hardened major/minor pairing rule with frontend $FrontendTag."
    }
}

$null = Invoke-RepoGit $FrontendRepositoryRoot fetch upstream tag $FrontendTag '--no-write-fetch-head'
$null = Invoke-RepoGit $ApiRepositoryRoot fetch upstream tag $ApiTag '--no-write-fetch-head'

$frontendCommit = (Invoke-RepoGit $FrontendRepositoryRoot rev-parse "$FrontendTag^{commit}" | Select-Object -Last 1).Trim()
$apiCommit = (Invoke-RepoGit $ApiRepositoryRoot rev-parse "$ApiTag^{commit}" | Select-Object -Last 1).Trim()

$frontendVersionText = (Convert-ToVersion $FrontendTag).ToString(3)
$apiVersionText = (Convert-ToVersion $ApiTag).ToString(3)
$bundleId = "ch-ui$frontendVersionText-api$apiVersionText-r$Revision"
$releaseRelative = "docs/releases/$bundleId"
$releaseDirectory = Join-Path $FrontendRepositoryRoot $releaseRelative

if (Test-Path -LiteralPath $releaseDirectory) {
    if (-not $Force) {
        throw "Release directory already exists: $releaseDirectory. Use -Force only to regenerate an unapproved candidate."
    }
} else {
    $null = New-Item -ItemType Directory -Path $releaseDirectory
}

$warningScript = Join-Path $PSScriptRoot 'Get-ChangeWarnings.ps1'
$frontendWarnings = & $warningScript -RepositoryRoot $FrontendRepositoryRoot -BaseCommit $baseline.frontend.upstreamCommit -TargetCommit $frontendCommit -Component frontend
$apiWarnings = & $warningScript -RepositoryRoot $ApiRepositoryRoot -BaseCommit $baseline.api.upstreamCommit -TargetCommit $apiCommit -Component api

$warningRecord = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    bundleId = $bundleId
    warningCount = $frontendWarnings.warningCount + $apiWarnings.warningCount
    components = @($frontendWarnings, $apiWarnings)
}
$warningRecord | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $releaseDirectory 'warnings.json') -Encoding utf8NoBOM

$frontendChanged = @(Invoke-RepoGit $FrontendRepositoryRoot diff '--name-status' $baseline.frontend.upstreamCommit $frontendCommit)
$apiChanged = @(Invoke-RepoGit $ApiRepositoryRoot diff '--name-status' $baseline.api.upstreamCommit $apiCommit)
$newLine = [Environment]::NewLine

$diffDocument = @"
# Upstream changes — $bundleId

## Exact ranges

- Frontend: $($baseline.frontend.upstreamCommit)..$frontendCommit
- API: $($baseline.api.upstreamCommit)..$apiCommit

## Frontend files

$($frontendChanged -join $newLine)

## API files

$($apiChanged -join $newLine)

Use the exact ranges above for local Codex review. This document is a file summary, not a substitute for reviewing the diff.
"@
$diffDocument | Set-Content -LiteralPath (Join-Path $releaseDirectory 'upstream-diff.md') -Encoding utf8NoBOM

$frontLockHash = (Get-FileHash -LiteralPath (Join-Path $FrontendRepositoryRoot 'yarn.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
$apiLockHash = (Get-FileHash -LiteralPath (Join-Path $ApiRepositoryRoot 'yarn.lock') -Algorithm SHA256).Hash.ToLowerInvariant()

$manifest = [ordered]@{
    schemaVersion = 1
    bundleId = $bundleId
    status = 'review-in-progress'
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
    releaseAgePolicy = [ordered]@{
        minimumAgeDays = $MinimumReleaseAgeDays
        decisionTimestampBasis = 'approval.approvedAt'
        latestAllowedWhenAged = $true
        criticalFreshExceptionsOnly = $true
    }
    frontend = [ordered]@{
        repository = 'https://github.com/KelvinTegelaar/CIPP'
        upstreamTag = $FrontendTag
        upstreamCommit = $frontendCommit
        hardenedCommit = $null
        lockfileSha256 = $frontLockHash
        moduleInventorySha256 = $null
    }
    api = [ordered]@{
        repository = 'https://github.com/KelvinTegelaar/CIPP-API'
        upstreamTag = $ApiTag
        upstreamCommit = $apiCommit
        hardenedCommit = $null
        lockfileSha256 = $apiLockHash
        moduleInventorySha256 = $null
    }
    documentation = [ordered]@{
        codexReview = "$releaseRelative/codex-review.md"
        findings = "$releaseRelative/findings.md"
        decision = "$releaseRelative/decision.md"
        releaseAgeEvidence = "$releaseRelative/release-age-evidence.json"
        risks = @()
        versionExceptions = @()
    }
    artifacts = @()
    previousRelease = if ($baseline.PSObject.Properties.Name -contains 'currentRelease') { $baseline.currentRelease } else { $null }
    approval = $null
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $releaseDirectory 'manifest.json') -Encoding utf8NoBOM

$releaseAgeScript = Join-Path $PSScriptRoot 'Get-ReleaseAgeEvidence.ps1'
$releaseAgeOutputPath = Join-Path $releaseDirectory 'release-age-evidence.json'
$releaseAgeEvidence = & $releaseAgeScript -RepositoryRoot $FrontendRepositoryRoot -ApiRepositoryRoot $ApiRepositoryRoot -ManifestPath (Join-Path $releaseDirectory 'manifest.json') -DecisionTimestampUtc $decisionTimestampUtc -MinimumAgeDays $MinimumReleaseAgeDays -OutputPath $releaseAgeOutputPath

Copy-Item -LiteralPath (Join-Path $FrontendRepositoryRoot 'docs/templates/codex-review.md') -Destination (Join-Path $releaseDirectory 'codex-review.md') -Force
Copy-Item -LiteralPath (Join-Path $FrontendRepositoryRoot 'docs/templates/release-decision.md') -Destination (Join-Path $releaseDirectory 'decision.md') -Force

@"
# Findings — $bundleId

Status: Pending review

See warnings.json and record every finding at the action threshold, suspicious input, false-positive decision, and accepted risk.
"@ | Set-Content -LiteralPath (Join-Path $releaseDirectory 'findings.md') -Encoding utf8NoBOM

$evidence = @"
# Evidence summary — $bundleId

Status: Review in progress

## Inputs

- Frontend: $FrontendTag at $frontendCommit
- API: $ApiTag at $apiCommit
- Compatibility rule: matching major/minor
- Candidate warnings: $($warningRecord.warningCount)
- Release-age status: $($releaseAgeEvidence.status)
- Release-age warnings: $($releaseAgeEvidence.warningCount)

## Maintainer actions

1. Review warnings.json and upstream-diff.md.
2. Apply upstream changes on hardened candidate branches.
3. Run normal functional builds/tests.
4. Run the exact-range Codex review.
5. Complete findings.md and decision.md.
6. Finalize artifacts and manifest.
"@
$evidence | Set-Content -LiteralPath (Join-Path $releaseDirectory 'evidence-summary.md') -Encoding utf8NoBOM

Write-Host "Prepared $bundleId without merging or deploying upstream code."
Write-Host "Review directory: $releaseDirectory"
Write-Host "Warnings: $($warningRecord.warningCount)"
Write-Host "Release-age status: $($releaseAgeEvidence.status)"
[pscustomobject]@{
    bundleId = $bundleId
    releaseDirectory = $releaseDirectory
    frontendTag = $FrontendTag
    frontendCommit = $frontendCommit
    apiTag = $ApiTag
    apiCommit = $apiCommit
    warningCount = $warningRecord.warningCount
    releaseAgeStatus = $releaseAgeEvidence.status
    releaseAgeWarningCount = $releaseAgeEvidence.warningCount
}
