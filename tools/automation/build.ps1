param(
  [string]$FlutterRoot = $env:FLUTTER_ROOT,
  [ValidateSet('none','windows','android')][string]$Fixture = 'none'
)
$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $packageRoot '../..'))
if (-not $FlutterRoot) {
  $flutterCommand = Get-Command flutter -ErrorAction Stop
  $FlutterRoot = Split-Path (Split-Path $flutterCommand.Source -Parent) -Parent
}
$FlutterRoot = [IO.Path]::GetFullPath($FlutterRoot)
$dartPath = Join-Path $FlutterRoot 'bin/cache/dart-sdk/bin/dart.exe'
$flutterSnapshot = Join-Path $FlutterRoot 'bin/cache/flutter_tools.snapshot'
if (-not (Test-Path -LiteralPath $dartPath)) { throw "Dart not found under $FlutterRoot" }
Push-Location $packageRoot
try {
  & $dartPath pub get
  if ($LASTEXITCODE -ne 0) { throw 'Dart dependency resolution failed' }
  New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot 'build') | Out-Null
  & $dartPath compile exe bin/automation.dart -o build/automation.exe
  if ($LASTEXITCODE -ne 0) { throw 'MCP compilation failed' }
} finally { Pop-Location }
if ($Fixture -ne 'none') {
  Push-Location (Join-Path $repositoryRoot 'examples/capture_lab')
  try {
    $target = if ($Fixture -eq 'windows') { 'lib/driver_main.dart' } else { 'lib/android_driver_main.dart' }
    $buildTarget = if ($Fixture -eq 'windows') { 'windows' } else { 'apk' }
    & $dartPath $flutterSnapshot build $buildTarget --debug -t $target
    if ($LASTEXITCODE -ne 0) { throw 'Fixture build failed' }
  } finally { Pop-Location }
}
Write-Output (Join-Path $packageRoot 'build/automation.exe')
