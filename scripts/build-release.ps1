# scripts/build-release.ps1
#
# One-shot Play-Store release build for ChowSA.
#
# Wraps `flutter build appbundle` with the two flags that production builds
# MUST carry, so they can't be forgotten on the command line:
#
#   --dart-define=IS_PRODUCTION=true   → flips EnvConfig to prod AdMob IDs,
#                                        Supabase prod project, etc.
#   -PIS_PRODUCTION=true               → flips android/app/build.gradle.kts's
#                                        admobAppId placeholder to the real
#                                        AdMob App ID instead of the test ID.
#
# Pre-requisites (one-time):
#   • android/key.properties exists (see android/app/build.gradle.kts header).
#   • android/keystores/chowsa-release.jks exists.
#   • You've bumped `version:` in pubspec.yaml since the last upload.
#
# Output:
#   build/app/outputs/bundle/release/app-release.aab
#
# Usage:
#   pwsh ./scripts/build-release.ps1

$ErrorActionPreference = "Stop"

Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    if (-not (Test-Path "android/key.properties")) {
        Write-Error "android/key.properties is missing — release builds will fall back to the debug signature and Play will reject the AAB. Create it before running this script."
    }
    if (-not (Test-Path "android/keystores")) {
        Write-Warning "android/keystores/ not found. If your storeFile path in key.properties points elsewhere this is fine; otherwise the build will fail."
    }

    Write-Host "==> flutter clean" -ForegroundColor Cyan
    flutter clean
    if ($LASTEXITCODE -ne 0) { throw "flutter clean failed" }

    Write-Host "==> flutter pub get" -ForegroundColor Cyan
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }

    Write-Host "==> flutter analyze" -ForegroundColor Cyan
    flutter analyze
    if ($LASTEXITCODE -ne 0) { throw "flutter analyze found issues — fix before building a release" }

    Write-Host "==> flutter build appbundle (production)" -ForegroundColor Cyan
    flutter build appbundle `
        --release `
        --dart-define=IS_PRODUCTION=true `
        -PIS_PRODUCTION=true
    if ($LASTEXITCODE -ne 0) { throw "flutter build appbundle failed" }

    $aab = "build/app/outputs/bundle/release/app-release.aab"
    if (Test-Path $aab) {
        $size = [math]::Round((Get-Item $aab).Length / 1MB, 2)
        Write-Host ""
        Write-Host "Release bundle ready: $aab ($size MB)" -ForegroundColor Green
        Write-Host "Upload to Play Console → Internal testing track first."
    } else {
        Write-Error "Build reported success but $aab was not found."
    }
} finally {
    Pop-Location
}
