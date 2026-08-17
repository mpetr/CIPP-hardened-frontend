[CmdletBinding()]
param(
    [string]$ApiRepositoryRoot = (Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) '.local/api'),

    [Parameter(Mandatory)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ApiRepositoryRoot = (Resolve-Path -LiteralPath $ApiRepositoryRoot).Path
$moduleRoot = Join-Path $ApiRepositoryRoot 'Modules'
if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
    throw "API Modules directory was not found: $moduleRoot"
}

$inventory = foreach ($file in Get-ChildItem -LiteralPath $moduleRoot -Recurse -File | Sort-Object FullName) {
    $relative = [IO.Path]::GetRelativePath($ApiRepositoryRoot, $file.FullName).Replace('\', '/')
    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
    [pscustomobject][ordered]@{
        path = $relative
        size = $file.Length
        sha256 = $hash.Hash.ToLowerInvariant()
    }
}

$record = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    apiRepositoryRoot = $ApiRepositoryRoot
    fileCount = @($inventory).Count
    files = @($inventory)
}

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path $outputFullPath -Parent
$null = New-Item -ItemType Directory -Force -Path $outputDirectory
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outputFullPath -Encoding utf8NoBOM
Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256 | ForEach-Object {
    [pscustomobject]@{
        path = $outputFullPath
        sha256 = $_.Hash.ToLowerInvariant()
        fileCount = @($inventory).Count
    }
}
