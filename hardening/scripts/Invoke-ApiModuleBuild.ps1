[CmdletBinding()]
param(
    [string]$ApiRepositoryRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.local/api')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ApiRepositoryRoot = (Resolve-Path -LiteralPath $ApiRepositoryRoot).Path
$upstreamBuild = Join-Path $ApiRepositoryRoot 'Tools/Build-DevApiModules.ps1'
if (-not (Test-Path -LiteralPath $upstreamBuild -PathType Leaf)) {
    throw "Upstream API build script not found: $upstreamBuild"
}

if (-not $IsWindows) {
    try {
        & $upstreamBuild
        if (-not $?) {
            throw 'Upstream API module build returned an unsuccessful PowerShell status.'
        }
    } catch {
        throw "Upstream API module build failed: $($_.Exception.Message)"
    }
    return
}

$toolsRoot = Join-Path $ApiRepositoryRoot 'Tools'
$modulesRoot = Join-Path $ApiRepositoryRoot 'Modules'
$outputRoot = Join-Path $ApiRepositoryRoot 'Output'
$scriptRoot = Join-Path $ApiRepositoryRoot '.artifacts'
$null = New-Item -ItemType Directory -Force -Path $scriptRoot
$childScript = Join-Path $scriptRoot ("module-build-child-" + [guid]::NewGuid().ToString('N') + '.ps1')

$childSource = @'
param([Parameter(Mandatory)][string]$ApiRepositoryRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolsRoot = Join-Path $ApiRepositoryRoot 'Tools'
$modulesRoot = Join-Path $ApiRepositoryRoot 'Modules'
Import-Module -Name (Join-Path $toolsRoot 'Metadata\1.5.7\Metadata.psd1') -Force
Import-Module -Name (Join-Path $toolsRoot 'Configuration\1.6.0\Configuration.psd1') -Force
Import-Module -Name (Join-Path $toolsRoot 'ModuleBuilder\3.1.8\ModuleBuilder.psd1') -Force
Set-Location -LiteralPath $ApiRepositoryRoot
& (Join-Path $toolsRoot 'Build-FunctionParameters.ps1')
& (Join-Path $toolsRoot 'Build-FunctionPermissions.ps1')
foreach ($moduleName in @(
    'CIPPCore',
    'CIPPDB',
    'CIPPTests',
    'CIPPStandards',
    'CIPPAlerts',
    'CippExtensions',
    'CIPPActivityTriggers',
    'CIPPHTTP'
)) {
    Build-Module -SourcePath (Join-Path $modulesRoot $moduleName)
}
'@

try {
    if (Test-Path -LiteralPath $outputRoot) {
        throw "Output already exists. Use a clean disposable API copy for the Windows module-build check: $outputRoot"
    }
    Set-Content -LiteralPath $childScript -Value $childSource -Encoding utf8NoBOM

    $configRoot = Join-Path $scriptRoot 'configuration'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $configRoot 'local'), (Join-Path $configRoot 'roaming'), (Join-Path $configRoot 'machine')
    $childEnvironment = @{
        LocalAppData = Join-Path $configRoot 'local'
        AppData = Join-Path $configRoot 'roaming'
        ProgramAppData = Join-Path $configRoot 'machine'
    }

    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $process = Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File',
        $childScript,
        '-ApiRepositoryRoot',
        $ApiRepositoryRoot
    ) -Wait -PassThru -NoNewWindow -Environment $childEnvironment

    if ($process.ExitCode -ne 0) {
        throw "API module compilation child process failed with exit code $($process.ExitCode)."
    }

    foreach ($moduleName in @(
        'CIPPCore',
        'CIPPDB',
        'CIPPTests',
        'CIPPStandards',
        'CIPPAlerts',
        'CippExtensions',
        'CIPPActivityTriggers',
        'CIPPHTTP'
    )) {
        $source = Join-Path $outputRoot $moduleName
        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            throw "Expected compiled module was not produced: $source"
        }
    }

    [pscustomobject][ordered]@{
        succeeded = $true
        platform = 'Windows'
        strategy = 'child-process-compile-check'
        moduleCount = 8
        staged = $false
        compiledOutput = $outputRoot
        apiRepositoryRoot = $ApiRepositoryRoot
    }
}
finally {
    if (Test-Path -LiteralPath $childScript) {
        Remove-Item -LiteralPath $childScript -Force -ErrorAction SilentlyContinue
    }
}
