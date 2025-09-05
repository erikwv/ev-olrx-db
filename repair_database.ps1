# OLRX Database Repair Utility
# Attempts to recover data from corrupted SQLite databases

param(
    [string]$DatabasePath = "F:\olrx_scan.db",
    [string]$Sqlite3Path = "C:\sqlite3\sqlite3.exe",
    [switch]$Force = $false
)

# Check if sqlite3 is available
if (-not (Test-Path $Sqlite3Path)) {
    Write-Error "sqlite3 not found at $Sqlite3Path. Please install SQLite or update the path."
    exit 1
}

# Check if database exists
if (-not (Test-Path $DatabasePath)) {
    Write-Error "Database not found at $DatabasePath"
    exit 1
}

Write-Host "OLRX Database Repair Utility" -ForegroundColor Cyan
Write-Host "Database: $DatabasePath" -ForegroundColor Gray

# Check current database status
Write-Host "`nChecking database status..." -ForegroundColor Yellow
try {
    $integrityCheck = & $Sqlite3Path $DatabasePath "PRAGMA integrity_check;" 2>&1
    Write-Host "Integrity check result: $integrityCheck" -ForegroundColor $(if ($integrityCheck -eq "ok") { 'Green' } else { 'Red' })
    
    if ($integrityCheck -eq "ok" -and -not $Force) {
        Write-Host "Database appears to be healthy. Use -Force to proceed anyway." -ForegroundColor Green
        exit 0
    }
}
catch {
    Write-Host "Cannot perform integrity check - database may be severely corrupted" -ForegroundColor Red
}

# Attempt to recover data
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$backupPath = $DatabasePath + ".backup.$timestamp"
$recoveredPath = $DatabasePath + ".recovered.$timestamp"

Write-Host "`nAttempting data recovery..." -ForegroundColor Yellow

try {
    # Create backup of original (even if corrupted)
    Copy-Item $DatabasePath $backupPath -Force
    Write-Host "✓ Created backup: $backupPath" -ForegroundColor Green
    
    # Try to dump data to SQL format
    Write-Host "Attempting to export data..." -ForegroundColor Yellow
    $dumpFile = $DatabasePath + ".dump.$timestamp.sql"
    
    # Try different recovery approaches
    $recoveryMethods = @(
        ".dump",
        ".mode insert`n.output $dumpFile`nSELECT * FROM OLRXScans;",
        ".mode csv`n.output $dumpFile`nSELECT * FROM OLRXScans;"
    )
    
    $recoverySuccessful = $false
    foreach ($method in $recoveryMethods) {
        try {
            Write-Host "Trying recovery method: $($method.Split('`n')[0])" -ForegroundColor Gray
            $result = & $Sqlite3Path $DatabasePath $method 2>&1
            
            if (-not ($result -match "Error:|error:|malformed")) {
                Write-Host "✓ Recovery method successful" -ForegroundColor Green
                $recoverySuccessful = $true
                break
            }
        }
        catch {
            Write-Host "Recovery method failed: $_" -ForegroundColor Red
        }
    }
    
    if ($recoverySuccessful) {
        # Create new database
        Write-Host "Creating new database..." -ForegroundColor Yellow
        
        # Initialize new database
        & "$PSScriptRoot\init_database.ps1" -DatabasePath $recoveredPath -ForceRecreate
        
        if (Test-Path $dumpFile) {
            # Try to import recovered data
            Write-Host "Importing recovered data..." -ForegroundColor Yellow
            & $Sqlite3Path $recoveredPath ".read $dumpFile"
            
            # Verify recovery
            $recoveredCount = & $Sqlite3Path $recoveredPath "SELECT COUNT(*) FROM OLRXScans;"
            Write-Host "✓ Recovered $recoveredCount records" -ForegroundColor Green
            
            # Ask user if they want to replace original
            if (-not $Force) {
                $choice = Read-Host "Replace original database with recovered version? (y/n)"
                if ($choice -eq 'y' -or $choice -eq 'Y') {
                    Move-Item $recoveredPath $DatabasePath -Force
                    Write-Host "✓ Original database replaced with recovered version" -ForegroundColor Green
                }
                else {
                    Write-Host "Recovered database saved as: $recoveredPath" -ForegroundColor Yellow
                }
            }
            else {
                Move-Item $recoveredPath $DatabasePath -Force
                Write-Host "✓ Original database replaced with recovered version" -ForegroundColor Green
            }
        }
    }
    else {
        Write-Host "✗ Could not recover data from database" -ForegroundColor Red
        Write-Host "Recommendations:" -ForegroundColor Yellow
        Write-Host "  1. Use backup files if available" -ForegroundColor Gray
        Write-Host "  2. Re-run indexing process on original PDF files" -ForegroundColor Gray
        Write-Host "  3. Check disk for hardware issues" -ForegroundColor Gray
    }
}
catch {
    Write-Error "Recovery process failed: $_"
}

# Clean up temporary files
if (Test-Path $dumpFile) {
    $keepDump = Read-Host "Keep SQL dump file for manual recovery? (y/n)"
    if ($keepDump -ne 'y' -and $keepDump -ne 'Y') {
        Remove-Item $dumpFile -Force
    }
    else {
        Write-Host "SQL dump saved as: $dumpFile" -ForegroundColor Cyan
    }
}

Write-Host "`nRepair process complete." -ForegroundColor Cyan
