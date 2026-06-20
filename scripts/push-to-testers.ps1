# scripts/push-to-testers.ps1
#
# Build a signed release APK and push it to the "internal" Firebase App
# Distribution group in one shot. Run from PowerShell (not Git Bash — the
# sandboxed Bash environment can't open the loopback socket Gradle needs).
#
# Pre-reqs:
#   * firebase login        (run once)
#   * android/key.properties + android/release-key.jks (already configured)
#   * Eclipse Adoptium JDK 17 at C:\Program Files\Eclipse Adoptium\jdk-17.0.19.10-hotspot
#
# Usage:
#   ./scripts/push-to-testers.ps1
#   ./scripts/push-to-testers.ps1 -ReleaseNotes "Custom note here"

param(
    [string]$ReleaseNotes = @"
* Community Hub badges no longer re-light after opening a category
* Community Hub badges now appear for the first message after app launch
* Fixed crash opening recipe details before saved-state load completes
* Fixed crash when double-tapping Scan in My Pantry
* Fixed chat reconnect crashes after network drops
"@,
    [string]$Group = "internal"
)

$ErrorActionPreference = "Stop"

# Pin the JDK that matches build_chowsa.bat — Flutter sometimes picks a
# newer Android Studio bundled JDK that breaks the AGP/Gradle versions
# we're locked to.
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-17.0.19.10-hotspot"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

# The agent in gradle.properties only loads in the build daemon's JVM. The
# Gradle LAUNCHER JVM (which is what fails first with the loopback error)
# reads GRADLE_OPTS, not gradle.properties. Mirror the same flags here so
# the launcher gets patched too. Without this, the build dies before the
# daemon is ever spawned.
$agentJar = (Resolve-Path "android/unix-fix-agent.jar").Path
$env:GRADLE_OPTS = "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED -javaagent:$agentJar"

$appId = "1:703850334339:android:e6daef272096f8ad3ef3b6"
$apk   = "build/app/outputs/flutter-apk/app-release.apk"

Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    Write-Host "==> Java version" -ForegroundColor Cyan
    java -version

    Write-Host "==> flutter build apk --release (production)" -ForegroundColor Cyan
    flutter build apk `
        --release `
        --dart-define=IS_PRODUCTION=true `
        -PIS_PRODUCTION=true
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed" }

    if (-not (Test-Path $apk)) {
        throw "Build reported success but $apk not found"
    }
    $sizeMb = [math]::Round((Get-Item $apk).Length / 1MB, 2)
    Write-Host "APK ready: $apk ($sizeMb MB)" -ForegroundColor Green

    Write-Host "==> firebase appdistribution:distribute" -ForegroundColor Cyan
    firebase appdistribution:distribute $apk `
        --app $appId `
        --groups $Group `
        --release-notes $ReleaseNotes
    if ($LASTEXITCODE -ne 0) { throw "firebase appdistribution:distribute failed" }

    Write-Host ""
    Write-Host "Pushed to '$Group' group on Firebase App Distribution." -ForegroundColor Green
    Write-Host "Testers receive an email + Firebase App Tester notification within a few minutes."
} finally {
    Pop-Location
}
