[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$ApiRepositoryRoot,
    [string]$ManifestPath,
    [datetime]$DecisionTimestampUtc = (Get-Date).ToUniversalTime(),
    [ValidateRange(1, 3650)]
    [int]$MinimumAgeDays = 30,
    [string]$OutputPath,
    [string]$AdditionalEvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if (-not $ApiRepositoryRoot) { $ApiRepositoryRoot = Join-Path $RepositoryRoot '.local/api' }
if (Test-Path -LiteralPath $ApiRepositoryRoot) { $ApiRepositoryRoot = (Resolve-Path -LiteralPath $ApiRepositoryRoot).Path }
if ($ManifestPath) { $ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path }
if (-not $AdditionalEvidencePath) { $AdditionalEvidencePath = Join-Path $RepositoryRoot 'hardening/release-age-overrides.json' }

$DecisionTimestampUtc = $DecisionTimestampUtc.ToUniversalTime()
$cutoff = $DecisionTimestampUtc.AddDays(-1 * $MinimumAgeDays)
$entries = [System.Collections.Generic.List[object]]::new()
$warnings = [System.Collections.Generic.List[object]]::new()
$npmCache = @{}
$githubHeaders = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'CIPP-hardened-release-age-evidence'
    'X-GitHub-Api-Version' = '2022-11-28'
}

function Get-EntryKey {
    param([string]$Component, [string]$Type, [string]$Name, [string]$Version)
    return "$Component|$Type|$Name|$Version"
}

$overrides = @{}
if (Test-Path -LiteralPath $AdditionalEvidencePath -PathType Leaf) {
    $overrideDocument = Get-Content -Raw -LiteralPath $AdditionalEvidencePath | ConvertFrom-Json
    foreach ($entry in @($overrideDocument.entries)) {
        $key = Get-EntryKey $entry.component $entry.type $entry.name $entry.version
        $overrides[$key] = $entry
    }
}

function Get-AgeDays {
    param([AllowNull()][object]$Timestamp)
    if (-not $Timestamp) { return $null }
    $released = ([datetime]$Timestamp).ToUniversalTime()
    return [math]::Round(($DecisionTimestampUtc - $released).TotalDays, 4)
}

function Add-ReleaseAgeEntry {
    param(
        [string]$Component,
        [string]$Type,
        [string]$Name,
        [string]$Version,
        [string]$Source,
        [string]$SourceUrl,
        [AllowNull()][object]$ReleaseTimestamp,
        [AllowNull()][object]$IsLatest,
        [string]$Notes
    )

    $key = Get-EntryKey $Component $Type $Name $Version
    $override = if ($overrides.ContainsKey($key)) { $overrides[$key] } else { $null }
    if ($override) {
        if ($override.PSObject.Properties.Name -contains 'releaseTimestamp') { $ReleaseTimestamp = $override.releaseTimestamp }
        if ($override.PSObject.Properties.Name -contains 'source') { $Source = $override.source }
        if ($override.PSObject.Properties.Name -contains 'sourceUrl') { $SourceUrl = $override.sourceUrl }
        if ($override.PSObject.Properties.Name -contains 'notes') { $Notes = @($Notes, $override.notes) -ne '' -join ' ' }
    }

    $ageDays = Get-AgeDays $ReleaseTimestamp
    $status = 'eligible'
    $warningCategory = $null
    if ($override -and ($override.PSObject.Properties.Name -contains 'status')) {
        $status = [string]$override.status
    } elseif (-not $ReleaseTimestamp) {
        $status = 'blocked-missing-release-age-evidence'
        $warningCategory = 'missing-release-age-evidence'
    } elseif ($ageDays -lt $MinimumAgeDays) {
        $status = 'blocked-too-fresh'
        $warningCategory = 'too-fresh-version'
    }

    $exceptionRecord = if ($override -and ($override.PSObject.Properties.Name -contains 'exceptionRecord')) { $override.exceptionRecord } else { $null }
    $riskRecord = if ($override -and ($override.PSObject.Properties.Name -contains 'riskRecord')) { $override.riskRecord } else { $null }
    if ($status -eq 'critical-exception') { $warningCategory = 'critical-fresh-exception' }
    if ($status -eq 'bootstrap-exception') { $warningCategory = 'bootstrap-fresh-exception' }

    $record = [pscustomobject][ordered]@{
        component = $Component
        type = $Type
        name = $Name
        version = $Version
        source = $Source
        sourceUrl = $SourceUrl
        releaseTimestamp = if ($ReleaseTimestamp) { ([datetime]$ReleaseTimestamp).ToUniversalTime().ToString('o') } else { $null }
        decisionTimestamp = $DecisionTimestampUtc.ToString('o')
        minimumAgeDays = $MinimumAgeDays
        ageDays = $ageDays
        isLatest = $IsLatest
        status = $status
        warningCategory = $warningCategory
        exceptionRecord = $exceptionRecord
        riskRecord = $riskRecord
        notes = $Notes
    }
    $entries.Add($record)
    if ($warningCategory) {
        $requiredAction = if ($status -eq 'blocked-too-fresh') { 'Wait until the version is 30 full UTC days old or approve a critical version-exception record.' } elseif ($status -eq 'critical-exception') { 'Confirm the linked version-exception record is approved and critical-only.' } else { 'Provide authoritative release-age evidence or approve a documented exception.' }
        $warnings.Add([pscustomobject][ordered]@{
            category = $warningCategory
            component = $Component
            type = $Type
            name = $Name
            version = $Version
            status = $status
            requiredAction = $requiredAction
        })
    }
}

function Get-GitHubOwnerRepo {
    param([string]$Repository)
    if ($Repository -match 'github\.com[:/]([^/]+)/([^/.]+)') { return "$($Matches[1])/$($Matches[2])" }
    throw "Cannot parse GitHub repository URL: $Repository"
}

function Get-GitHubReleaseTimestamp {
    param([string]$OwnerRepo, [string]$Tag)
    $encodedTag = [uri]::EscapeDataString($Tag)
    $uri = "https://api.github.com/repos/$OwnerRepo/releases/tags/$encodedTag"
    try {
        $release = Invoke-RestMethod -Uri $uri -Headers $githubHeaders -Method Get
        return [pscustomobject]@{ timestamp = $release.published_at; url = $release.html_url; note = $null }
    } catch {
        return [pscustomobject]@{ timestamp = $null; url = "https://github.com/$OwnerRepo/releases/tag/$Tag"; note = "GitHub release metadata unavailable: $($_.Exception.Message)" }
    }
}

function Get-GitHubCommitTimestamp {
    param([string]$OwnerRepo, [string]$Commit)
    $uri = "https://api.github.com/repos/$OwnerRepo/commits/$Commit"
    try {
        $commit = Invoke-RestMethod -Uri $uri -Headers $githubHeaders -Method Get
        return [pscustomobject]@{ timestamp = $commit.commit.committer.date; url = $commit.html_url; note = $null }
    } catch {
        return [pscustomobject]@{ timestamp = $null; url = "https://github.com/$OwnerRepo/commit/$Commit"; note = "GitHub commit metadata unavailable: $($_.Exception.Message)" }
    }
}

function Get-NpmMetadata {
    param([string]$Name)
    if ($npmCache.ContainsKey($Name)) { return $npmCache[$Name] }
    $encoded = [uri]::EscapeDataString($Name)
    $uri = "https://registry.npmjs.org/$encoded"
    try {
        $metadata = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Accept = 'application/json'; 'User-Agent' = 'CIPP-hardened-release-age-evidence' }
        $npmCache[$Name] = $metadata
        return $metadata
    } catch {
        return $null
    }
}

function Get-YarnLockPackages {
    param([string]$YarnLockPath)
    if (-not (Test-Path -LiteralPath $YarnLockPath -PathType Leaf)) { return @() }
    $lines = Get-Content -LiteralPath $YarnLockPath
    $packages = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\S.*:$') {
            $header = $line.TrimEnd(':')
            $block = [System.Collections.Generic.List[string]]::new()
            $j = $i + 1
            while ($j -lt $lines.Count -and ($lines[$j] -eq '' -or $lines[$j] -match '^\s')) {
                $block.Add($lines[$j])
                $j++
            }
            $blockText = $block -join [Environment]::NewLine
            if ($blockText -match '(?m)^\s+version "([^"]+)"') {
                $version = $Matches[1]
                $descriptor = (($header -split ',\s*') | Select-Object -First 1).Trim().Trim([char]34).Trim([char]39)
                $lastAt = $descriptor.LastIndexOf('@')
                if ($lastAt -gt 0) {
                    $name = $descriptor.Substring(0, $lastAt)
                    $key = "$name@$version"
                    if (-not $packages.ContainsKey($key)) {
                        $packages[$key] = [pscustomobject][ordered]@{ name = $name; version = $version }
                    }
                }
            }
            $i = $j - 1
        }
    }
    return @($packages.Values | Sort-Object name, version)
}

function Add-NpmPackageEvidence {
    param([string]$Component, [string]$Name, [string]$Version)
    $metadata = Get-NpmMetadata $Name
    if ($metadata) {
        $timeProperty = $metadata.time.PSObject.Properties[$Version]
        $timestamp = if ($timeProperty) { $timeProperty.Value } else { $null }
        $latest = $metadata.'dist-tags'.latest
        Add-ReleaseAgeEntry -Component $Component -Type 'npm-package' -Name $Name -Version $Version -Source 'npm-registry-time' -SourceUrl "https://registry.npmjs.org/$([uri]::EscapeDataString($Name))" -ReleaseTimestamp $timestamp -IsLatest ($latest -eq $Version) -Notes $null
    } else {
        Add-ReleaseAgeEntry -Component $Component -Type 'npm-package' -Name $Name -Version $Version -Source 'npm-registry-time' -SourceUrl "https://registry.npmjs.org/$([uri]::EscapeDataString($Name))" -ReleaseTimestamp $null -IsLatest $null -Notes 'npm metadata could not be collected.'
    }
}

if ($ManifestPath) {
    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    foreach ($componentName in @('frontend', 'api')) {
        $component = $manifest.$componentName
        $ownerRepo = Get-GitHubOwnerRepo $component.repository
        $release = Get-GitHubReleaseTimestamp -OwnerRepo $ownerRepo -Tag $component.upstreamTag
        Add-ReleaseAgeEntry -Component $componentName -Type 'upstream-release' -Name $ownerRepo -Version $component.upstreamTag -Source 'github-release-published_at' -SourceUrl $release.url -ReleaseTimestamp $release.timestamp -IsLatest $null -Notes $release.note
    }
}

foreach ($package in @(Get-YarnLockPackages -YarnLockPath (Join-Path $RepositoryRoot 'yarn.lock'))) {
    Add-NpmPackageEvidence -Component 'frontend' -Name $package.name -Version $package.version
}

$apiYarnLock = Join-Path $ApiRepositoryRoot 'yarn.lock'
foreach ($package in @(Get-YarnLockPackages -YarnLockPath $apiYarnLock)) {
    Add-NpmPackageEvidence -Component 'api' -Name $package.name -Version $package.version
}

$toolchainPath = Join-Path $RepositoryRoot 'hardening/toolchain.json'
if (Test-Path -LiteralPath $toolchainPath -PathType Leaf) {
    $toolchain = Get-Content -Raw -LiteralPath $toolchainPath | ConvertFrom-Json
    if ($toolchain.node.version) {
        Add-ReleaseAgeEntry -Component 'toolchain' -Type 'node-runtime' -Name 'node' -Version $toolchain.node.version -Source 'manual-required' -SourceUrl 'https://nodejs.org/' -ReleaseTimestamp $null -IsLatest $null -Notes 'Provide official Node release-date evidence through hardening/release-age-overrides.json.'
    }
    if ($toolchain.yarn.version) {
        Add-ReleaseAgeEntry -Component 'toolchain' -Type 'package-manager' -Name 'yarn' -Version $toolchain.yarn.version -Source 'manual-required' -SourceUrl 'https://classic.yarnpkg.com/' -ReleaseTimestamp $null -IsLatest $null -Notes 'Provide official Yarn release-date evidence through hardening/release-age-overrides.json.'
    }
}

$workflowRoots = @(
    [pscustomobject]@{ component = 'frontend'; path = Join-Path $RepositoryRoot '.github/workflows' },
    [pscustomobject]@{ component = 'api'; path = Join-Path $ApiRepositoryRoot '.github/workflows' }
)
foreach ($root in $workflowRoots) {
    if (-not (Test-Path -LiteralPath $root.path -PathType Container)) { continue }
    foreach ($workflow in @(Get-ChildItem -LiteralPath $root.path -Filter '*.yml' -File) + @(Get-ChildItem -LiteralPath $root.path -Filter '*.yaml' -File)) {
        $content = Get-Content -LiteralPath $workflow.FullName
        foreach ($line in $content) {
            if ($line -match '\buses:\s*([^\s#]+)') {
                $spec = $Matches[1].Trim().Trim([char]34).Trim([char]39)
                $at = $spec.LastIndexOf('@')
                if ($at -lt 1) { continue }
                $ownerRepo = $spec.Substring(0, $at)
                $ref = $spec.Substring($at + 1)
                if ($ownerRepo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { continue }
                if ($ref -match '^[a-f0-9]{40}$') {
                    $commit = Get-GitHubCommitTimestamp -OwnerRepo $ownerRepo -Commit $ref
                    Add-ReleaseAgeEntry -Component $root.component -Type 'github-action' -Name $ownerRepo -Version $ref -Source 'github-commit-committer-date' -SourceUrl $commit.url -ReleaseTimestamp $commit.timestamp -IsLatest $null -Notes $commit.note
                } else {
                    Add-ReleaseAgeEntry -Component $root.component -Type 'github-action' -Name $ownerRepo -Version $ref -Source 'mutable-action-ref' -SourceUrl "https://github.com/$ownerRepo" -ReleaseTimestamp $null -IsLatest $null -Notes "Workflow $($workflow.Name) uses a mutable action ref; pin to a full commit SHA or quarantine the workflow."
                }
            }
        }
    }
}

$blocked = @($entries | Where-Object { $_.status -like 'blocked-*' })
$exceptions = @($entries | Where-Object { $_.status -in @('critical-exception', 'bootstrap-exception', 'risk-accepted') })
$status = if ($blocked.Count -gt 0) { 'blocked' } elseif ($exceptions.Count -gt 0) { 'passed-with-exceptions' } else { 'passed' }

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    decisionTimestamp = $DecisionTimestampUtc.ToString('o')
    minimumAgeDays = $MinimumAgeDays
    cutoffTimestamp = $cutoff.ToString('o')
    status = $status
    entryCount = $entries.Count
    warningCount = $warnings.Count
    warningCategories = @($warnings.category | Sort-Object -Unique)
    entries = $entries
    warnings = $warnings
}

if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent) { $null = New-Item -ItemType Directory -Force -Path $parent }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
}

$result
