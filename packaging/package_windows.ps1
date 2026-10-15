<#
.SYNOPSIS
  Zips the Windows release build (flutter build windows --release) into
  <OutDir>\DatabaseManager-<version>-windows-<arch>.zip.

.DESCRIPTION
  The architecture comes from the machine this runs on (x64 or arm64), because
  Flutter builds for the host; pass -Arch to override it. The version comes from
  pubspec.yaml.
#>
param(
    [string]$OutDir = 'dist',
    [ValidateSet('x64', 'arm64')]
    [string]$Arch
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

if (-not $Arch) {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { $Arch = 'x64' }
        'ARM64' { $Arch = 'arm64' }
        default { throw "unsupported PROCESSOR_ARCHITECTURE '$env:PROCESSOR_ARCHITECTURE' (AMD64 or ARM64)" }
    }
}

$release = "build\windows\$Arch\runner\Release"
if (-not (Test-Path "$release\database_manager.exe")) {
    throw "$release\database_manager.exe not found; run 'flutter build windows --release' first"
}

$versionLine = Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)' | Select-Object -First 1
$version = ($versionLine.Matches[0].Groups[1].Value -split '\+')[0]

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = (Resolve-Path $OutDir).Path

$name = "DatabaseManager-$version-windows-$Arch"
$stage = Join-Path ([IO.Path]::GetTempPath()) "databasemanager-zip-$([guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -Recurse -Path $release -Destination (Join-Path $stage $name)
    $zip = Join-Path $out "$name.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # includeBaseDirectory: the zip holds a single top-level folder.
    [IO.Compression.ZipFile]::CreateFromDirectory(
        (Join-Path $stage $name), $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
    Write-Host "Built: $zip"
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}
