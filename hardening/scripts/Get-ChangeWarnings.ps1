[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory)]
    [string]$BaseCommit,

    [Parameter(Mandatory)]
    [string]$TargetCommit,

    [Parameter(Mandatory)]
    [ValidateSet('frontend', 'api')]
    [string]$Component,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$gitCommand = if ($env:CIPP_HARDENED_GIT) {
    $env:CIPP_HARDENED_GIT
} else {
    (Get-Command git -ErrorAction Stop).Source
}

function Invoke-RepositoryGit {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    $output = & $gitCommand -C $RepositoryRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git failed in $($RepositoryRoot): git $($Arguments -join ' ')"
    }
    return $output
}

$null = Invoke-RepositoryGit cat-file '-e' "$BaseCommit^{commit}"
$null = Invoke-RepositoryGit cat-file '-e' "$TargetCommit^{commit}"

$changedFiles = @(Invoke-RepositoryGit diff '--name-only' $BaseCommit $TargetCommit)
$diffLines = @(Invoke-RepositoryGit diff '--no-ext-diff' '--unified=0' $BaseCommit $TargetCommit)
$warnings = [System.Collections.Generic.List[object]]::new()

function Add-Warning {
    param(
        [string]$Category,
        [string]$Severity,
        [string]$Path,
        [string]$Evidence,
        [string]$RequiredAction
    )

    $warnings.Add([pscustomobject][ordered]@{
        component = $Component
        category = $Category
        severity = $Severity
        path = $Path
        evidence = $Evidence
        requiredAction = $RequiredAction
    })
}

foreach ($path in $changedFiles) {
    if ($path -match '(^|/)(package\.json|yarn\.lock|package-lock\.json|requirements\.psd1)$') {
        Add-Warning 'dependency-change' 'review' $path 'Dependency manifest or lockfile changed.' 'Review versions, integrity data, source types, and install scripts.'
    }

    if ($path -match '^\.github/workflows/.+\.ya?ml$') {
        Add-Warning 'workflow-change' 'review' $path 'GitHub Actions workflow changed.' 'Review permissions, triggers, secrets, runner, and every action reference.'
    }

    if ($path -match '(^|/)(deployment|infra|infrastructure)/|\.(bicep|tf|tfvars)$') {
        Add-Warning 'infrastructure-change' 'review' $path 'Infrastructure or deployment file changed.' 'Review compatibility and add a hardening/risk record before changing behavior.'
    }

    if ($path -match '\.(exe|dll|so|dylib|nupkg|zip|jar|bin|pfx|cer)$') {
        Add-Warning 'binary-change' 'review' $path 'Bundled binary or archive changed.' 'Fingerprint, identify provenance, and review why it is required.'
    }
}

$currentPath = ''
foreach ($line in $diffLines) {
    if ($line -match '^\+\+\+ b/(.+)$') {
        $currentPath = $Matches[1]
        continue
    }

    if (-not $line.StartsWith('+') -or $line.StartsWith('+++')) {
        continue
    }

    $added = $line.Substring(1)
    $evidence = if ($added.Length -gt 240) { $added.Substring(0, 240) + '...' } else { $added }

    if ($added -match '(git\+|github:|file:|https?://[^\s"'']+\.(tgz|zip|nupkg|ps1|js))') {
        Add-Warning 'non-registry-source' 'review' $currentPath $evidence 'Confirm provenance and pin or fingerprint the exact content.'
    }
    if ($added -match '(?i)-(alpha|beta|preview|rc)(\.|-|[0-9])') {
        Add-Warning 'prerelease-input' 'review' $currentPath $evidence 'Confirm the prerelease is intentional and document its risk.'
    }
    if ($added -match '"(preinstall|install|postinstall|prepare)"\s*:') {
        Add-Warning 'install-script' 'review' $currentPath $evidence 'Review the script and all commands/network access before accepting it.'
    }
    if ($added -match '(?i)(Invoke-WebRequest|Invoke-RestMethod|DownloadString|Start-BitsTransfer|\bcurl\b|\bwget\b)') {
        Add-Warning 'runtime-download' 'review' $currentPath $evidence 'Identify the destination and content; pin or fingerprint when possible.'
    }
    if ($added -match '(?i)(Invoke-Expression|\biex\b|EncodedCommand|FromBase64String|\beval\s*\()') {
        Add-Warning 'dynamic-execution' 'review' $currentPath $evidence 'Review the complete data flow and prove untrusted input cannot reach execution.'
    }
    if ($added -match '(?i)(permissions\s*:|requiredResourceAccess|AppRole|RoleManagement|GraphPermission|application permission)') {
        Add-Warning 'permission-change' 'review' $currentPath $evidence 'Compare required privileges and update the permission/risk record.'
    }
    if ($added -match 'https?://[A-Za-z0-9._~:/?#\[\]@!$&''()*+,;=%-]+') {
        Add-Warning 'external-destination' 'info' $currentPath $evidence 'Confirm the destination is expected and not a new exfiltration path.'
    }
}

$result = [pscustomobject][ordered]@{
    component = $Component
    baseCommit = $BaseCommit
    targetCommit = $TargetCommit
    changedFileCount = $changedFiles.Count
    warningCount = $warnings.Count
    changedFiles = $changedFiles
    warnings = $warnings
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 8
} else {
    $result
}
