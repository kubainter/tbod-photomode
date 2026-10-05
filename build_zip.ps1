param(
    [string]$Version = "1.6.2"
)

$ErrorActionPreference = 'Stop'
$projectDir = $PSScriptRoot
$modFolder = Join-Path $projectDir 'TBOD_PhotoMode'
$releaseDir = Join-Path $projectDir 'release'
$zipName = "TBOD_PhotoMode_v$Version.zip"
$zipPath = Join-Path $releaseDir $zipName

if (-not (Test-Path $releaseDir)) {
    New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
}

if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

Write-Host "Packaging $modFolder -> $zipPath..."
$7zExe = "C:\Program Files\7-Zip\7z.exe"
if (Test-Path $7zExe) {
    Write-Host "Using 7-Zip for robust compression..." -ForegroundColor Green
    $7zArgs = @("a", "-tzip", "-mx=9", "-xr!smoke_test.lua", "-xr!engine_e2e.lua", "-xr!Tests", "-xr!*.ps1", "-xr!*.bat", $zipPath, "$modFolder")
    $process = Start-Process -FilePath $7zExe -ArgumentList $7zArgs -Wait -NoNewWindow -PassThru
    if ($process.ExitCode -ne 0) {
        Write-Host "ERROR: 7-Zip failed with exit code $($process.ExitCode). Aborting." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "WARNING: 7-Zip not found. Falling back to native Windows tar.exe..." -ForegroundColor Yellow
    # Windows native tar.exe guarantees spec-compliant ZIP files with forward slashes (/)
    Push-Location -Path $projectDir
    $folderName = Split-Path $modFolder -Leaf
    $tarArgs = @("-a", "-c", "--exclude=smoke_test.lua", "--exclude=engine_e2e.lua", "--exclude=Tests", "--exclude=*.ps1", "--exclude=*.bat", "-f", "`"$zipPath`"", $folderName)
    $process = Start-Process -FilePath "tar.exe" -ArgumentList $tarArgs -Wait -NoNewWindow -PassThru
    Pop-Location
    if ($process.ExitCode -ne 0) {
        Write-Host "ERROR: tar.exe failed with exit code $($process.ExitCode). Aborting." -ForegroundColor Red
        exit 1
    }
}
Write-Host "Successfully built release: $zipPath"
Get-FileHash $zipPath -Algorithm SHA256
