param(
  [Parameter(Mandatory=$true)][string]$Project,
  [Parameter(Mandatory=$true)][string]$Stage,
  [Parameter(Mandatory=$true)][string]$FlutterRoot,
  [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$projectPath = (Resolve-Path -LiteralPath $Project).Path
$stagePath = [IO.Path]::GetFullPath($Stage)
if ($stagePath -eq $projectPath -or $projectPath.StartsWith($stagePath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Stage must be a dedicated copy, not the source or its parent' }
if ($stagePath.StartsWith($projectPath + '\', [StringComparison]::OrdinalIgnoreCase) -and
    -not $stagePath.StartsWith((Join-Path $projectPath 'build') + '\', [StringComparison]::OrdinalIgnoreCase) -and
    -not $stagePath.StartsWith((Join-Path $projectPath 'artifacts') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'In-project stages must stay under build/ or artifacts/' }
New-Item -ItemType Directory -Force -Path $stagePath | Out-Null
$marker = Join-Path $stagePath '.booruflow-mcp-stage.json'
if (-not (Test-Path -LiteralPath $marker) -and (Get-ChildItem -LiteralPath $stagePath -Force | Select-Object -First 1)) {
  $existingGradle = Join-Path $stagePath 'android/app/build.gradle.kts'
  if (-not (Test-Path -LiteralPath $existingGradle) -or -not ([IO.File]::ReadAllText($existingGradle)).Contains('applicationId = "io.github.normalllll.booruflow.automation"')) { throw 'Existing stage is not an isolated BooruFlow test copy' }
}
[IO.File]::WriteAllText($marker, (@{ source=$projectPath; purpose='isolated-android-mcp' } | ConvertTo-Json))
# Never mirror/delete the source; skip generated caches, credentials and junctions.
& robocopy $projectPath $stagePath /E /XJ /NFL /NDL /NJH /NJS /NP /XD (Join-Path $projectPath 'lib') .git .dart_tool build target artifacts .cache .codex .agents .aws /XF *.lock local.properties gradle.properties key.properties keystore.properties *.jks *.keystore .env .env.*
if ($LASTEXITCODE -gt 7) { throw "Staging copy failed: $LASTEXITCODE" }
$entry = Join-Path $stagePath 'tool/automation/android_mcp.dart'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'android_mcp.dart.template') -Destination $entry -Force
# Keep the compiler's application source live: editing the actual project lib/
# is immediately visible through this staging junction for hot reload.
$stageLib = Join-Path $stagePath 'lib'
$sourceLib = Join-Path $projectPath 'lib'
$libItem = Get-Item -LiteralPath $stageLib -ErrorAction SilentlyContinue
if (-not $libItem) {
  New-Item -ItemType Junction -Path $stageLib -Target $sourceLib | Out-Null
} elseif ($libItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
  if ($libItem.LinkType -ne 'Junction' -or [IO.Path]::GetFullPath($libItem.Target) -ne $sourceLib) { throw 'Unexpected lib reparse point' }
} else {
  $resolvedLib = (Resolve-Path -LiteralPath $stageLib).Path
  if ($resolvedLib -ne (Join-Path $stagePath 'lib') -or -not $resolvedLib.StartsWith($stagePath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected lib cleanup target' }
  Remove-Item -LiteralPath $resolvedLib -Recurse -Force
  New-Item -ItemType Junction -Path $stageLib -Target $sourceLib | Out-Null
}
$kotlinRoot = Join-Path $stagePath 'android/app/src/main/kotlin/io/github/normalllll/booruflow'
$main = Join-Path $kotlinRoot 'MainActivity.kt'
$mainText = [IO.File]::ReadAllText($main)
if (-not $mainText.Contains('class MainActivity :')) { throw 'Unexpected MainActivity declaration' }
[IO.File]::WriteAllText($main, $mainText.Replace('class MainActivity :', 'open class MainActivity :'))
New-Item -ItemType Directory -Force -Path (Join-Path $kotlinRoot 'automation') | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'AutomationActivity.kt') -Destination (Join-Path $kotlinRoot 'automation/AutomationActivity.kt') -Force
$gradle = Join-Path $stagePath 'android/app/build.gradle.kts'
$gradleText = [IO.File]::ReadAllText($gradle)
$gradleText = [regex]::Replace($gradleText, 'applicationId\s*=\s*"[^"]+"', 'applicationId = "io.github.normalllll.booruflow.automation"')
$gradleText = [regex]::Replace($gradleText, 'throw GradleException\("Missing required signing properties[^"\r\n]*"\)', 'logger.lifecycle("Automation Debug stage does not configure release signing")')
[IO.File]::WriteAllText($gradle, $gradleText)
$manifest = Join-Path $stagePath 'android/app/src/main/AndroidManifest.xml'
$manifestText = [IO.File]::ReadAllText($manifest)
$manifestText = [regex]::Replace($manifestText, 'android:name="(?:io\.github\.normalllll\.booruflow\.)?\.?MainActivity"', 'android:name="io.github.normalllll.booruflow.automation.AutomationActivity"')
$manifestText = $manifestText.Replace('android:label="BooruFlow"', 'android:label="BooruFlow Automation"')
if (-not $manifestText.Contains('automation.AutomationActivity')) { throw 'Unexpected launcher manifest' }
[IO.File]::WriteAllText($manifest, $manifestText)
[IO.File]::WriteAllText((Join-Path $stagePath 'android/gradle.properties'), "org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=1G -Dfile.encoding=UTF-8`nandroid.useAndroidX=true`n")
$dartPath = Join-Path $FlutterRoot 'bin/cache/dart-sdk/bin/dart.exe'
$snapshot = Join-Path $FlutterRoot 'bin/cache/flutter_tools.snapshot'
if (-not $PrepareOnly) {
  Push-Location $stagePath
  try {
    & $dartPath $snapshot pub get
    if ($LASTEXITCODE -ne 0) { throw 'Staging dependency resolution failed' }
    & $dartPath $snapshot build apk --debug --target-platform android-arm64 -t tool/automation/android_mcp.dart
    if ($LASTEXITCODE -ne 0) { throw 'Staging Android MCP build failed' }
  } finally { Pop-Location }
}
Write-Output $stagePath
