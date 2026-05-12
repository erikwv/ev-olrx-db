param(
    [string]$PythonExe = "python",
    [string]$AppName = "OLRXSearchAndCopy"
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "Installing build dependencies..." -ForegroundColor Cyan
& $PythonExe -m pip install -r (Join-Path $ScriptRoot "requirements-build.txt")

Write-Host "Building standalone executable..." -ForegroundColor Cyan
& $PythonExe -m PyInstaller `
    --noconfirm `
    --clean `
    --onefile `
    --windowed `
    --name $AppName `
    (Join-Path $ScriptRoot "olrx_search_and_copy.py")

Write-Host "Build complete. Output: $(Join-Path $ScriptRoot "dist\$AppName.exe")" -ForegroundColor Green
