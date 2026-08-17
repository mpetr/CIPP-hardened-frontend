[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string]$FrontendRepository = 'https://github.com/KelvinTegelaar/CIPP',
    [Parameter(Mandatory = $true)]
    [string]$FrontendTag,
    [string]$FrontendExpectedCommit,
    [string]$ApiRepository = 'https://github.com/KelvinTegelaar/CIPP-API',
    [string]$ApiTag,
    [string]$ApiExpectedCommit,
    [switch]$ReuseExistingArchives,
    [switch]$ForceDownload,
    [switch]$NoExtract
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
$repositoryRoot = (Resolve-Path -LiteralPath $repositoryRoot).Path
if (-not $OutputRoot) {
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $OutputRoot = Join-Path $repositoryRoot ".artifacts/upstream-tag-archive-$timestamp"
}

$gitCommand = if ($env:CIPP_HARDENED_GIT) {
    $env:CIPP_HARDENED_GIT
} else {
    (Get-Command git -ErrorAction Stop).Source
}

function ConvertTo-GitHubOwnerRepo {
    param([string]$Repository)

    if ($Repository -match 'github\.com[:/]([^/]+)/([^/.]+)(?:\.git)?/?$') {
        return "$($Matches[1])/$($Matches[2])"
    }

    if ($Repository -match '^([^/]+)/([^/]+)$') {
        return $Repository
    }

    throw "Repository is not a supported GitHub repository reference: $Repository"
}

function ConvertTo-SafeFileNamePart {
    param([string]$Value)
    return ($Value -replace '[^A-Za-z0-9_.-]', '-')
}

function Resolve-TagCommit {
    param(
        [string]$Repository,
        [string]$Tag
    )

    $exactRef = "refs/tags/$Tag"
    $dereferenceRef = "refs/tags/$Tag^{}"
    $refs = @(& $gitCommand ls-remote --tags $Repository $exactRef $dereferenceRef)
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-remote failed for $Repository tag $Tag."
    }

    $exactPattern = [regex]::Escape($exactRef)
    $dereferencePattern = [regex]::Escape($dereferenceRef)
    $selected = @($refs | Where-Object { $_ -match "\s$dereferencePattern$" } | Select-Object -First 1)
    if (-not $selected) {
        $selected = @($refs | Where-Object { $_ -match "\s$exactPattern$" } | Select-Object -First 1)
    }
    if (-not $selected) {
        throw "Tag was not found: $Repository $Tag"
    }

    $commit = (($selected[0] -split '\s+') | Select-Object -First 1).Trim()
    if ($commit -notmatch '^[a-f0-9]{40}$') {
        throw "Resolved tag commit is not a full SHA-1: $Repository $Tag -> $commit"
    }
    return $commit
}

function New-ComponentSnapshot {
    param(
        [string]$Name,
        [string]$Repository,
        [string]$Tag,
        [string]$ExpectedCommit,
        [string]$Root
    )

    $ownerRepo = ConvertTo-GitHubOwnerRepo $Repository
    $repoName = ($ownerRepo -split '/')[-1]
    $commit = Resolve-TagCommit -Repository $Repository -Tag $Tag

    if ($ExpectedCommit -and $commit -ne $ExpectedCommit) {
        throw "$Name tag $Tag resolved to $commit, expected $ExpectedCommit."
    }

    $tagPath = [uri]::EscapeDataString($Tag)
    $archiveUrl = "https://github.com/$ownerRepo/archive/refs/tags/$tagPath.zip"
    $safeTag = ConvertTo-SafeFileNamePart $Tag
    $archivePath = Join-Path $Root "$repoName-$safeTag.zip"
    $extractRoot = Join-Path $Root $Name

    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        if (-not $ReuseExistingArchives -and -not $ForceDownload) {
            throw "Archive already exists: $archivePath. Use -ReuseExistingArchives or -ForceDownload."
        }
    }

    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or $ForceDownload) {
        Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $archivePath
    }

    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $extractedFiles = $null
    if (-not $NoExtract) {
        if (Test-Path -LiteralPath $extractRoot -PathType Container) {
            $existingChildren = @(Get-ChildItem -LiteralPath $extractRoot -Force)
            if ($existingChildren.Count -gt 0) {
                throw "Extraction directory is not empty: $extractRoot. Use a fresh output directory."
            }
        } else {
            $null = New-Item -ItemType Directory -Path $extractRoot
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
        $extractedFiles = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File).Count
    }

    return [pscustomobject][ordered]@{
        component = $Name
        repository = $Repository
        ownerRepo = $ownerRepo
        tag = $Tag
        resolvedCommit = $commit
        archiveUrl = $archiveUrl
        archivePath = $archivePath
        archiveSha256 = $archiveHash
        extractRoot = if ($NoExtract) { $null } else { $extractRoot }
        extractedFiles = $extractedFiles
    }
}

if ($ApiExpectedCommit -and -not $ApiTag) {
    throw '-ApiExpectedCommit requires -ApiTag.'
}

$OutputRoot = Join-Path $repositoryRoot $OutputRoot
$null = New-Item -ItemType Directory -Force -Path $OutputRoot
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

$components = [System.Collections.Generic.List[object]]::new()
$components.Add((New-ComponentSnapshot -Name 'frontend' -Repository $FrontendRepository -Tag $FrontendTag -ExpectedCommit $FrontendExpectedCommit -Root $OutputRoot))
if ($ApiTag) {
    $components.Add((New-ComponentSnapshot -Name 'api' -Repository $ApiRepository -Tag $ApiTag -ExpectedCommit $ApiExpectedCommit -Root $OutputRoot))
}

$snapshot = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    outputRoot = $OutputRoot
    components = $components
}

$snapshotPath = Join-Path $OutputRoot 'snapshot.json'
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $snapshotPath -Encoding utf8NoBOM
$snapshot
