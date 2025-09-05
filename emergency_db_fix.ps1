# Emergency OLRX Database Fix
# Handles immediate corruption issues and creates a working database

param(
    [string]$DatabasePath = "F:\olrx_scan.db",
    [string]$Sqlite3Path = "C:\sqlite3\sqlite3.exe"
)

Write-Host "EMERGENCY DATABASE FIX UTILITY" -ForegroundColor Red
Write-Host "===============================" -ForegroundColor Red

# Check sqlite3
if (-not (Test-Path $Sqlite3Path)) {
    Write-Error "SQLite3 not found at $Sqlite3Path"
    Write-Host "Download from: https://www.sqlite.org/download.html" -ForegroundColor Yellow
    exit 1
}

# Show SQLite version
Write-Host "SQLite version:" -ForegroundColor Cyan
& $Sqlite3Path -version

# Step 1: Remove any existing corrupted database
if (Test-Path $DatabasePath) {
    $backupPath = $DatabasePath + ".emergency_backup." + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")
    Write-Host "Backing up existing database to: $backupPath" -ForegroundColor Yellow
    Move-Item $DatabasePath $backupPath -Force
}

# Step 2: Ensure directory exists
$dbDir = Split-Path $DatabasePath -Parent
if (-not (Test-Path $dbDir)) {
    New-Item -ItemType Directory -Path $dbDir -Force
    Write-Host "Created directory: $dbDir" -ForegroundColor Green
}

# Step 3: Test basic SQLite functionality
Write-Host "`nTesting SQLite functionality..." -ForegroundColor Cyan
try {
    $testDb = "$env:TEMP\olrx_test.db"
    $testResult = & $Sqlite3Path $testDb "CREATE TABLE test(id INTEGER); INSERT INTO test VALUES(1); SELECT * FROM test; DROP TABLE test;"
    Remove-Item $testDb -Force -ErrorAction SilentlyContinue
    Write-Host "✓ SQLite basic functionality works" -ForegroundColor Green
}
catch {
    Write-Error "SQLite basic functionality test failed: $_"
    exit 1
}

# Step 4: Create database with minimal approach
Write-Host "`nCreating database with minimal approach..." -ForegroundColor Cyan

# Create each table separately with error checking
$commands = @(
    @{
        Name = "Main table"
        SQL = "CREATE TABLE OLRXScans (
            id INTEGER PRIMARY KEY,
            pdf_path TEXT UNIQUE,
            file_name TEXT,
            file_size INTEGER,
            last_modified TEXT,
            last_name TEXT,
            first_name TEXT,
            mrn TEXT,
            account TEXT,
            admission_date TEXT,
            discharge_date TEXT,
            extraction_success INTEGER DEFAULT 0,
            date_indexed TEXT DEFAULT (datetime('now')),
            file_hash TEXT
        );"
    },
    @{
        Name = "Log table"
        SQL = "CREATE TABLE processing_log (
            id INTEGER PRIMARY KEY,
            operation_type TEXT,
            files_processed INTEGER DEFAULT 0,
            files_successful INTEGER DEFAULT 0,
            files_failed INTEGER DEFAULT 0,
            start_time TEXT,
            end_time TEXT,
            notes TEXT
        );"
    },
    @{
        Name = "MRN index"
        SQL = "CREATE INDEX idx_mrn ON OLRXScans(mrn);"
    },
    @{
        Name = "Account index"
        SQL = "CREATE INDEX idx_account ON OLRXScans(account);"
    },
    @{
        Name = "Name index"
        SQL = "CREATE INDEX idx_last_name ON OLRXScans(last_name);"
    },
    @{
        Name = "Hash index"
        SQL = "CREATE INDEX idx_file_hash ON OLRXScans(file_hash);"
    }
)

$successCount = 0
foreach ($cmd in $commands) {
    try {
        Write-Host "Creating: $($cmd.Name)" -ForegroundColor Yellow
        $result = & $Sqlite3Path $DatabasePath $cmd.SQL 2>&1
        
        if ($result -match "Error:|error:|malformed") {
            Write-Host "✗ Failed: $($cmd.Name) - $result" -ForegroundColor Red
        } else {
            Write-Host "✓ Success: $($cmd.Name)" -ForegroundColor Green
            $successCount++
        }
    }
    catch {
        Write-Host "✗ Exception: $($cmd.Name) - $_" -ForegroundColor Red
    }
}

# Step 5: Test the database
Write-Host "`nTesting created database..." -ForegroundColor Cyan
try {
    # Test basic operations
    $testInsert = & $Sqlite3Path $DatabasePath "INSERT INTO OLRXScans (pdf_path, file_name) VALUES ('test', 'test.pdf');" 2>&1
    $testSelect = & $Sqlite3Path $DatabasePath "SELECT COUNT(*) FROM OLRXScans;" 2>&1
    $testDelete = & $Sqlite3Path $DatabasePath "DELETE FROM OLRXScans WHERE pdf_path = 'test';" 2>&1
    
    if ($testSelect -eq "1") {
        Write-Host "✓ Database operations work correctly" -ForegroundColor Green
    } else {
        Write-Host "✗ Database operations failed" -ForegroundColor Red
    }
    
    # Test integrity
    $integrity = & $Sqlite3Path $DatabasePath "PRAGMA integrity_check;" 2>&1
    if ($integrity -eq "ok") {
        Write-Host "✓ Database integrity is good" -ForegroundColor Green
    } else {
        Write-Host "✗ Database integrity issues: $integrity" -ForegroundColor Red
    }
}
catch {
    Write-Host "✗ Database testing failed: $_" -ForegroundColor Red
}

# Step 6: Show final status
Write-Host "`n" + "="*50 -ForegroundColor Green
Write-Host "EMERGENCY FIX COMPLETE" -ForegroundColor Green
Write-Host "="*50 -ForegroundColor Green

if (Test-Path $DatabasePath) {
    $dbFile = Get-Item $DatabasePath
    $dbSizeKB = [math]::Round($dbFile.Length / 1KB, 2)
    Write-Host "Database created: $DatabasePath" -ForegroundColor White
    Write-Host "Database size: $dbSizeKB KB" -ForegroundColor White
    Write-Host "Components created: $successCount of $($commands.Count)" -ForegroundColor White
    
    if ($successCount -ge 2) {  # At least main table and log table
        Write-Host "`n✓ Database is ready for use!" -ForegroundColor Green
        Write-Host "Next step: .\olrx_index_to_database.ps1 -FolderPath 'YourPDFFolder'" -ForegroundColor Cyan
    } else {
        Write-Host "`n⚠ Database has issues - may need manual intervention" -ForegroundColor Yellow
    }
} else {
    Write-Host "✗ Database file was not created" -ForegroundColor Red
}

# Diagnostic information
Write-Host "`nDiagnostic Information:" -ForegroundColor Yellow
Write-Host "SQLite Path: $Sqlite3Path" -ForegroundColor Gray
Write-Host "Database Path: $DatabasePath" -ForegroundColor Gray
Write-Host "Directory writable: $(Test-Path $dbDir -PathType Container)" -ForegroundColor Gray

$freeSpace = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq (Split-Path $DatabasePath -Qualifier) } | Select-Object -ExpandProperty FreeSpace
if ($freeSpace) {
    $freeSpaceMB = [math]::Round($freeSpace / 1MB, 2)
    Write-Host "Free space on drive: $freeSpaceMB MB" -ForegroundColor Gray
}
