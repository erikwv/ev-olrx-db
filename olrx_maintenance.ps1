# OLRX Database Maintenance Script
# Performs routine maintenance tasks on the OLRX database

param(
    [string]$DatabasePath = "C:\Omnicell\OmniLinkRx\olrx_scan.db",
    [string]$Sqlite3Path = "C:\sqlite3\sqlite3.exe",
    [switch]$FullMaintenance = $false,
    [switch]$ShowStats = $false,
    [switch]$CleanupOrphans = $false,
    [switch]$Vacuum = $false,
    [switch]$ReindexAll = $false
)

# Load Windows Forms Assembly
Add-Type -AssemblyName System.Windows.Forms

# Check if sqlite3 is available
if (-not (Test-Path $Sqlite3Path)) {
    Write-Error "sqlite3 not found at $Sqlite3Path. Please install SQLite or update the path."
    exit 1
}

# Check if database exists
if (-not (Test-Path $DatabasePath)) {
    Write-Error "Database not found at $DatabasePath. Please run init_database.ps1 first."
    exit 1
}

# Function to execute database query safely
function Execute-MaintenanceQuery {
    param(
        [string]$Query,
        [string]$Description = "Database query"
    )
    
    try {
        Write-Host "Executing: $Description" -ForegroundColor Cyan
        $result = & $Sqlite3Path $DatabasePath $Query
        return $result
    }
    catch {
        Write-Warning "Failed to execute $Description`: $_"
        return $null
    }
}

# Function to show database statistics
function Show-DatabaseStats {
    Write-Host "`n" + "="*60 -ForegroundColor Green
    Write-Host "DATABASE STATISTICS" -ForegroundColor Green
    Write-Host "="*60 -ForegroundColor Green
    
    # Basic record counts
    $totalRecords = Execute-MaintenanceQuery "SELECT COUNT(*) FROM OLRXScans" "Total records count"
    $successfulExtractions = Execute-MaintenanceQuery "SELECT COUNT(*) FROM OLRXScans WHERE extraction_success = 1" "Successful extractions count"
    $failedExtractions = Execute-MaintenanceQuery "SELECT COUNT(*) FROM OLRXScans WHERE extraction_success = 0" "Failed extractions count"
    
    Write-Host "Total records in database: $totalRecords" -ForegroundColor White
    Write-Host "Successful data extractions: $successfulExtractions" -ForegroundColor Green
    Write-Host "Failed extractions: $failedExtractions" -ForegroundColor Red
    
    if ($totalRecords -gt 0) {
        $successRate = [math]::Round(($successfulExtractions / $totalRecords) * 100, 2)
        Write-Host "Success rate: $successRate%" -ForegroundColor $(if ($successRate -gt 80) { 'Green' } elseif ($successRate -gt 60) { 'Yellow' } else { 'Red' })
    }
    
    # Recent activity
    Write-Host "`nRecent Activity:" -ForegroundColor Cyan
    $last24h = Execute-MaintenanceQuery "SELECT COUNT(*) FROM OLRXScans WHERE date_indexed > datetime('now', '-1 day')" "Records added in last 24 hours"
    $last7days = Execute-MaintenanceQuery "SELECT COUNT(*) FROM OLRXScans WHERE date_indexed > datetime('now', '-7 days')" "Records added in last 7 days"
    $last30days = Execute-MaintenanceQuery "SELECT COUNT(*) FROM OLRXScans WHERE date_indexed > datetime('now', '-30 days')" "Records added in last 30 days"
    
    Write-Host "  Last 24 hours: $last24h records" -ForegroundColor White
    Write-Host "  Last 7 days: $last7days records" -ForegroundColor White
    Write-Host "  Last 30 days: $last30days records" -ForegroundColor White
    
    # Database file info
    if (Test-Path $DatabasePath) {
        $dbFile = Get-Item $DatabasePath
        $dbSizeMB = [math]::Round($dbFile.Length / 1MB, 2)
        Write-Host "`nDatabase file size: $dbSizeMB MB" -ForegroundColor White
        Write-Host "Last modified: $($dbFile.LastWriteTime)" -ForegroundColor White
    }
    
    # Processing log summary
    Write-Host "`nProcessing History (Last 10 operations):" -ForegroundColor Cyan
    $logQuery = @"
SELECT 
    operation_type,
    files_processed,
    files_successful,
    files_failed,
    substr(start_time, 1, 16) as start_time,
    substr(notes, 1, 50) as notes
FROM processing_log 
ORDER BY id DESC 
LIMIT 10
"@
    
    $logResults = Execute-MaintenanceQuery $logQuery "Processing log history"
    if ($logResults) {
        Write-Host "Operation | Files | Success | Failed | Time | Notes" -ForegroundColor Gray
        Write-Host "-" * 60 -ForegroundColor Gray
        foreach ($line in $logResults) {
            Write-Host $line -ForegroundColor Gray
        }
    }
}

# Function to clean up orphaned records (files that no longer exist)
function Remove-OrphanedRecords {
    Write-Host "`nCleaning up orphaned records..." -ForegroundColor Yellow
    
    # Get all file paths from database
    $allPaths = Execute-MaintenanceQuery "SELECT pdf_path FROM OLRXScans" "All PDF paths"
    
    if (-not $allPaths) {
        Write-Host "No records found to check" -ForegroundColor Gray
        return
    }
    
    $orphanedCount = 0
    $checkedCount = 0
    
    foreach ($path in $allPaths) {
        $checkedCount++
        if (-not (Test-Path $path)) {
            $orphanedCount++
            Write-Host "Removing orphaned record: $path" -ForegroundColor Red
            
            $escapedPath = $path.Replace("'", "''")"
            $deleteQuery = "DELETE FROM OLRXScans WHERE pdf_path = '$escapedPath'"
            Execute-MaintenanceQuery $deleteQuery "Delete orphaned record" | Out-Null
        }
        
        # Progress indicator
        if ($checkedCount % 100 -eq 0) {
            Write-Host "Checked $checkedCount files..." -ForegroundColor Gray
        }
    }
    
    Write-Host "Cleanup complete: Removed $orphanedCount orphaned records from $checkedCount total records" -ForegroundColor Green
    
    # Log the cleanup operation
    $logSQL = @"
INSERT INTO processing_log (operation_type, files_processed, files_successful, start_time, end_time, notes)
VALUES ('CLEANUP', $checkedCount, $($checkedCount - $orphanedCount), datetime('now'), datetime('now'), 'Removed $orphanedCount orphaned records')
"@
    Execute-MaintenanceQuery $logSQL "Log cleanup operation" | Out-Null
}

# Function to vacuum and optimize database
function Optimize-Database {
    Write-Host "`nOptimizing database..." -ForegroundColor Yellow
    
    # Get database size before optimization
    $sizeBefore = if (Test-Path $DatabasePath) { 
        [math]::Round((Get-Item $DatabasePath).Length / 1MB, 2) 
    } else { 0 }
    
    Write-Host "Database size before optimization: $sizeBefore MB" -ForegroundColor Gray
    
    # Run VACUUM to reclaim space
    Execute-MaintenanceQuery "VACUUM" "Database vacuum" | Out-Null
    
    # Run ANALYZE to update query planner statistics
    Execute-MaintenanceQuery "ANALYZE" "Database analyze" | Out-Null
    
    # Reindex all indexes
    Execute-MaintenanceQuery "REINDEX" "Database reindex" | Out-Null
    
    # Get database size after optimization
    $sizeAfter = if (Test-Path $DatabasePath) { 
        [math]::Round((Get-Item $DatabasePath).Length / 1MB, 2) 
    } else { 0 }
    
    $spaceSaved = $sizeBefore - $sizeAfter
    
    Write-Host "Database size after optimization: $sizeAfter MB" -ForegroundColor Gray
    Write-Host "Space saved: $spaceSaved MB" -ForegroundColor $(if ($spaceSaved -gt 0) { 'Green' } else { 'Yellow' })
    Write-Host "Database optimization complete" -ForegroundColor Green
    
    # Log the optimization
    $logSQL = @"
INSERT INTO processing_log (operation_type, start_time, end_time, notes)
VALUES ('OPTIMIZE', datetime('now'), datetime('now'), 'Vacuum, analyze, reindex complete. Size: $sizeBefore -> $sizeAfter MB')
"@
    Execute-MaintenanceQuery $logSQL "Log optimization" | Out-Null
}

# Function to find and report duplicate files
function Find-DuplicateFiles {
    Write-Host "`nChecking for duplicate files..." -ForegroundColor Yellow
    
    $duplicateQuery = @"
SELECT 
    file_hash,
    COUNT(*) as duplicate_count,
    GROUP_CONCAT(file_name, '; ') as file_names
FROM OLRXScans 
WHERE file_hash IS NOT NULL 
GROUP BY file_hash 
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC
"@
    
    $duplicates = Execute-MaintenanceQuery $duplicateQuery "Find duplicate files"
    
    if ($duplicates -and $duplicates.Count -gt 0) {
        Write-Host "Found duplicate files:" -ForegroundColor Red
        foreach ($duplicate in $duplicates) {
            Write-Host "  $duplicate" -ForegroundColor Gray
        }
        
        $duplicateCount = $duplicates.Count
        Write-Host "`nTotal duplicate file groups: $duplicateCount" -ForegroundColor Red
    }
    else {
        Write-Host "No duplicate files found" -ForegroundColor Green
    }
}

# Function to check database integrity
function Test-DatabaseIntegrity {
    Write-Host "`nChecking database integrity..." -ForegroundColor Yellow
    
    $integrityResult = Execute-MaintenanceQuery "PRAGMA integrity_check" "Database integrity check"
    
    if ($integrityResult -eq "ok") {
        Write-Host "Database integrity check: PASSED" -ForegroundColor Green
    }
    else {
        Write-Host "Database integrity check: FAILED" -ForegroundColor Red
        Write-Host "Issues found:" -ForegroundColor Red
        foreach ($issue in $integrityResult) {
            Write-Host "  $issue" -ForegroundColor Red
        }
    }
}

# Main execution logic
Write-Host "OLRX Database Maintenance Utility" -ForegroundColor Cyan
Write-Host "Database: $DatabasePath" -ForegroundColor Gray
Write-Host "Started: $(Get-Date)" -ForegroundColor Gray

# If no specific options are provided, show help
if (-not ($ShowStats -or $CleanupOrphans -or $Vacuum -or $ReindexAll -or $FullMaintenance)) {
    Write-Host "`nUsage:" -ForegroundColor White
    Write-Host "  -ShowStats        : Display database statistics" -ForegroundColor Gray
    Write-Host "  -CleanupOrphans   : Remove records for files that no longer exist" -ForegroundColor Gray
    Write-Host "  -Vacuum           : Optimize and vacuum the database" -ForegroundColor Gray
    Write-Host "  -ReindexAll       : Rebuild all database indexes" -ForegroundColor Gray
    Write-Host "  -FullMaintenance  : Run all maintenance tasks" -ForegroundColor Gray
    Write-Host "`nExample: .\olrx_maintenance.ps1 -ShowStats -CleanupOrphans" -ForegroundColor Yellow
    exit 0
}

# Execute requested operations
if ($ShowStats -or $FullMaintenance) {
    Show-DatabaseStats
}

if ($CleanupOrphans -or $FullMaintenance) {
    Remove-OrphanedRecords
}

if ($Vacuum -or $FullMaintenance) {
    Optimize-Database
}

if ($ReindexAll -or $FullMaintenance) {
    Write-Host "`nRebuilding database indexes..." -ForegroundColor Yellow
    Execute-MaintenanceQuery "REINDEX" "Rebuild all indexes" | Out-Null
    Write-Host "Index rebuild complete" -ForegroundColor Green
}

# Additional checks for full maintenance
if ($FullMaintenance) {
    Test-DatabaseIntegrity
    Find-DuplicateFiles
    
    # Show updated stats after maintenance
    Write-Host "`n" + "="*60 -ForegroundColor Blue
    Write-Host "POST-MAINTENANCE STATISTICS" -ForegroundColor Blue
    Write-Host "="*60 -ForegroundColor Blue
    Show-DatabaseStats
}

Write-Host "`nMaintenance completed at: $(Get-Date)" -ForegroundColor Cyan

# If running interactively, pause for user to see results
if ($Host.Name -eq "ConsoleHost") {
    Write-Host "`nPress any key to continue..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
