# RunTests.ps1
# Automated unit test runner for TBOD_PhotoMode

$ErrorActionPreference = "Stop"
$env:Path = "$env:LOCALAPPDATA\Programs\Lua\bin;$env:ProgramFiles\Lua;$env:Path"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host "Running TBOD_PhotoMode Unit Test Suite..." -ForegroundColor Cyan
& lua Tests\run_all.lua

if ($LASTEXITCODE -ne 0) {
    Write-Host "`nTest execution FAILED with exit code $LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
} else {
    Write-Host "`nAll tests executed cleanly!" -ForegroundColor Green
}
