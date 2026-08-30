# Builds a release APK that CAN NAME ITSELF, and puts it in Downloads under
# that name.
#
#   powershell -ExecutionPolicy Bypass -File tool\build_apk.ps1
#   powershell -ExecutionPolicy Bypass -File tool\build_apk.ps1 -Abi armeabi-v7a
#   powershell -ExecutionPolicy Bypass -File tool\build_apk.ps1 -Aab
#
# The ExecutionPolicy flag is not optional on this machine: unsigned local
# scripts are blocked by default (same as tool\docs.ps1).
#
# WHY THIS SCRIPT EXISTS. Two builds have already been mis-identified by hand.
# On 13 Aug 2026 an IPA built from the PREVIOUS commit shipped under the new
# commit's name, because CI builds from ORIGIN and nothing had been pushed. On
# 21 Aug the Settings screen reported `(1)` on a phone running versionCode
# 2002. A volunteer's bug report is worth nothing if it cannot say which binary
# produced it, so ONE source of truth now feeds BOTH the file name and the line
# inside the app: the sha below.
#
# A DIRTY TREE IS NAMED `-dirty`, not silently rounded to the last commit. A
# sha that names a commit the build does not match is worse than no sha: it
# invites reading a diff that was never in the binary.
#
# ONE ABI PER BUILD, AND NEVER --split-per-abi. Splitting makes Flutter rewrite
# the versionCode as `abiVersionCode * 1000 + versionCode` (arm64 is 2), so a
# pubspec saying 2003 installs as 4003 and the version line inside the app is
# wrong again in a new way. This is where the 3T's mysterious "2002" came from:
# `+2`, split, arm64. Building one ABI leaves the number alone.
#
# APP BUNDLES: PASS -Aab. Play takes a bundle, not an APK, and this mode exists
# so a bundle gets the same sha stamping, the same secrets.json and the same md5
# report an APK gets. A bundle built by hand gets none of that, and hand-built
# Android artifacts are how every APK before 22 Aug 2026 shipped DARK: Sentry
# and Aptabase compiled out, and not one event from a real ride.
#
# -Abi IS IGNORED WITH -Aab, and the versionCode trap above does not apply to a
# bundle. The rewrite comes from --split-per-abi, which a bundle never uses:
# Play splits per device at delivery instead, so a pubspec saying 4004 reaches
# Play as 4004.
#
# SIGNING CHANGED ON 27 AUG 2026. This script builds the RELEASE type, and the
# release type now signs with the Play UPLOAD KEY when android/key.properties
# is present (it is, on this machine). Before that date it signed with the
# debug key.
#
# WHAT THAT COSTS THE FOUR RIDERS WHO ALREADY HOLD A BUILD: a debug-signed app
# cannot be replaced in place by an upload-signed one. Android refuses the
# install on a signature mismatch. So the NEXT APK this script sends them
# forces an uninstall, and uninstalling WIPES THEIR RIDE HISTORY. Say so in the
# mail, or they lose their first week without warning.
#
# Builds still come from THIS machine only: the keystore is not in the repo and
# is not in CI.

param(
  [switch]$Aab,
  [ValidateSet("arm64-v8a", "armeabi-v7a")]
  [string]$Abi = "arm64-v8a",
  [string]$OutDir = "$env:USERPROFILE\Downloads"
)

# What --target-platform calls the same two things.
$targets = @{ "arm64-v8a" = "android-arm64"; "armeabi-v7a" = "android-arm" }

$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

$sha = (git rev-parse --short HEAD).Trim()
$dirty = git status --porcelain
if ($dirty) {
  $sha = "$sha-dirty"
  Write-Host "The tree is dirty. This build is named $sha." -ForegroundColor Yellow
}

# `version: 1.0.0+1`. The app reads these back through --dart-define, so the
# version line and the file name can never disagree with each other again.
$versionLine = Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)\+(\S+)\s*$'
if (-not $versionLine) { throw "pubspec.yaml has no `version: x.y.z+n` line." }
$version = $versionLine.Matches[0].Groups[1].Value
$buildNumber = $versionLine.Matches[0].Groups[2].Value

$defines = @(
  "--dart-define=BUILD_SHA=$sha",
  "--dart-define=BUILD_VERSION=$version",
  "--dart-define=BUILD_NUMBER=$buildNumber"
)

# Sentry and Aptabase. Absent is a valid state (a clone gets it), and the app
# runs with both switched off, so this is a warning and not an error.
if (Test-Path secrets.json) {
  $defines += "--dart-define-from-file=secrets.json"
} else {
  Write-Host "No secrets.json. Crash reporting and analytics will be OFF." -ForegroundColor Yellow
}

if ($Aab -and $PSBoundParameters.ContainsKey("Abi")) {
  Write-Host "-Abi is ignored with -Aab: a bundle carries every ABI." -ForegroundColor Yellow
}

if ($Aab) {
  Write-Host "Building $version+$buildNumber ($sha) as an app bundle ..." -ForegroundColor Cyan
  & flutter build appbundle --release @defines
  if ($LASTEXITCODE -ne 0) { throw "flutter build appbundle failed with $LASTEXITCODE." }

  $built = "build\app\outputs\bundle\release\app-release.aab"
  if (-not (Test-Path $built)) { throw "No AAB at $built." }

  $out = Join-Path $OutDir "commute_guardian-$sha.aab"
} else {
  Write-Host "Building $version+$buildNumber ($sha) for $Abi ..." -ForegroundColor Cyan
  $target = $targets[$Abi]
  & flutter build apk --release --target-platform $target @defines
  if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed with $LASTEXITCODE." }

  $built = "build\app\outputs\flutter-apk\app-release.apk"
  if (-not (Test-Path $built)) { throw "No APK at $built." }

  $out = Join-Path $OutDir "commute_guardian-$Abi-$sha.apk"
}
Copy-Item $built $out -Force

# The hash is how the last two mis-shipped builds were caught. Compare it with
# the previous one before sending: two different shas with the same hash means
# the build did not rebuild.
$hash = (Get-FileHash $out -Algorithm MD5).Hash.ToLower()
$size = [math]::Round((Get-Item $out).Length / 1MB, 1)

Write-Host ""
Write-Host "  $out" -ForegroundColor Green
Write-Host "  md5 $hash"
Write-Host "  $size MB"
Write-Host "  Settings will read: Commute Guardian $version ($buildNumber) $sha"
if ($Aab) {
  # Play refuses a second upload carrying a versionCode it has already seen,
  # and the message it gives says nothing about pubspec.yaml.
  Write-Host "  Play will read versionCode $buildNumber, and REFUSES a second"
  Write-Host "  upload with that number. Bump pubspec.yaml before the next one."
} else {
  Write-Host "  Android will install versionCode $buildNumber. If those two ever"
  Write-Host "  differ, something split the APK per ABI. See pubspec.yaml."
}
