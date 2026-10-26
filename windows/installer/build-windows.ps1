# Builds MeshCore Open for Windows and packages it as an installer,
# build\windows\installer\MeshCore-Open-SOS-Setup.exe.
#
# Needs Flutter, Visual Studio 2022 with "Desktop development with C++",
# Inno Setup 6 and Windows Developer Mode. From the project folder:
#
#   powershell -ExecutionPolicy Bypass -File windows\installer\build-windows.ps1

$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path "$PSScriptRoot\..\..")

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

function Fail($text) {
  Write-Host "`n$text" -ForegroundColor Red
  exit 1
}

Step 'Checking the tools'
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Fail 'Flutter was not found. Add its bin folder (e.g. C:\src\flutter\bin) to your PATH, then open a new PowerShell window.'
}
$devMode = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
  -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
if (-not $devMode -or $devMode.AllowDevelopmentWithoutDevLicense -ne 1) {
  Fail 'Developer Mode is off. Turn it on in Settings > System > For developers, then run this again.'
}
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path $vswhere) {
  & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vs) {
  Fail 'Visual Studio with "Desktop development with C++" was not found.'
}
$iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
  foreach ($candidate in @(
      "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
      "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
      "$env:ProgramFiles\Inno Setup 6\ISCC.exe")) {
    if (Test-Path $candidate) { $iscc = $candidate; break }
  }
}
if (-not $iscc) { Fail 'Inno Setup 6 was not found.' }

# pubspec.yaml "version: 9.5.0+19" -> 9.5.0
$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
Write-Host "MeshCore Open SOS $version"

Step 'Fetching packages'
flutter pub get
if ($LASTEXITCODE) { Fail 'flutter pub get failed (see above).' }

Step 'Building the app (this takes several minutes the first time)'
flutter build windows --release
if ($LASTEXITCODE) { Fail 'The Windows build failed (see above).' }
$release = 'build\windows\x64\runner\Release'

Step 'Adding the Visual C++ runtime'
# Shipped next to the app, so it runs without the separate redistributable.
$crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT" -Directory -ErrorAction SilentlyContinue |
  Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { Fail 'The Visual C++ runtime files were not found in Visual Studio.' }
Copy-Item "$($crt.FullName)\*.dll" $release -Force

Step 'Packaging the installer'
& $iscc "/DAppVersion=$version" 'windows\installer\meshcore-open.iss'
if ($LASTEXITCODE) { Fail 'Inno Setup failed (see above).' }

$setup = Resolve-Path 'build\windows\installer\MeshCore-Open-SOS-Setup.exe'
Write-Host "`nDone: $setup" -ForegroundColor Green
