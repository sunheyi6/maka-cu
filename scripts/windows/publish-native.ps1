param(
  [ValidateSet('win-x64')]
  [string]$RuntimeIdentifier = 'win-x64',
  [ValidateSet('Release')]
  [string]$Configuration = 'Release',
  [switch]$IncludeFixture,
  [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$helperProject = Join-Path $repoRoot 'apps/OpenComputerUseWindows/native/MakaCuWindows.csproj'
$fixtureProject = Join-Path $repoRoot 'apps/OpenComputerUseWindows/fixture/HangWindowFixture/HangWindowFixture.csproj'
$outputRoot = if ($OutputDirectory) {
  [IO.Path]::GetFullPath($OutputDirectory)
} else {
  Join-Path $repoRoot "dist/windows-native/$RuntimeIdentifier"
}
$helperOutput = Join-Path $outputRoot 'helper'
$fixtureOutput = Join-Path $outputRoot 'fixture'

if (Test-Path $outputRoot) { Remove-Item -LiteralPath $outputRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $helperOutput | Out-Null

dotnet publish $helperProject -c $Configuration -r $RuntimeIdentifier --self-contained true `
  -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=false -p:PublishTrimmed=false `
  -p:DebugType=embedded -o $helperOutput

if ($IncludeFixture) {
  New-Item -ItemType Directory -Force -Path $fixtureOutput | Out-Null
  dotnet publish $fixtureProject -c $Configuration -r $RuntimeIdentifier --self-contained true `
    -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=false -p:PublishTrimmed=false `
    -p:DebugType=embedded -o $fixtureOutput
}

$sdk = (& dotnet --version).Trim()
$files = @()
foreach ($path in Get-ChildItem -LiteralPath $outputRoot -Recurse -File | Where-Object { $_.FullName -ne (Join-Path $outputRoot 'manifest.json') }) {
  $hash = (Get-FileHash -LiteralPath $path.FullName -Algorithm SHA256).Hash
  $files += [ordered]@{
    path = $path.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
    bytes = $path.Length
    sha256 = $hash
  }
}
$manifest = [ordered]@{
  schema = 'maka-cu-windows-native-publish/1'
  runtimeIdentifier = $RuntimeIdentifier
  configuration = $Configuration
  targetFramework = 'net8.0-windows10.0.22621.0'
  sdk = $sdk
  selfContained = $true
  singleFile = $true
  managedSingleFile = $true
  nativeCompanionsRequired = $true
  compression = $false
  trimmed = $false
  distributionReady = $false
  files = $files
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot 'manifest.json') -Encoding UTF8
Write-Host "Published Windows native helper to $outputRoot"
