# Create New OLRX Database - Simple Version
# Creates a fresh database with minimal complexity

param(
    [string]$DatabasePath = "F:\olrx_scan_new.db",
    [string]$Sqlite3Path = "C:\sqlite3\sqlite3.exe"
)

Write-Host "CREATING NEW OLRX DATABASE" -ForegroundColor Green
Write-Host "=========================" -ForegroundColor Green

# Check SQLite3
if (-not (Test-Path $Sqlite3Path)) {
    Write-Host "ERROR: SQLite3 not found at $Sqlite3Path" -ForegroundColor Red
    Write-Host "Download from: https://www.sqlite.org/download.html" -ForegroundColor Yellow
    exit 1
}

Write-Host "SQLite3 found: $Sqlite3Path" -ForegroundColor Green

# Delete existing database if it exists
if (Test-Path $DatabasePath) {
    Write-Host "Removing existing database: $DatabasePath" -ForegroundColor Yellow
    Remove-Item $DatabasePath -Force
}

# Create directory if needed
$dbDir = Split-Path $DatabasePath -Parent
if (-not (Test-Path $dbDir)) {
    Write-Host "Creating directory: $dbDir" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $dbDir -Force | Out-Null
}

Write-Host "Creating new database: $DatabasePath" -ForegroundColor Cyan

# Step 1: Create main table
Write-Host "Step 1: Creating main table..." -ForegroundColor Yellow
$mainTable = @"
CREATE TABLE OLRXScans (
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
);
"@

try {
    & $Sqlite3Path $DatabasePath $mainTable
    Write-Host "✓ Main table created successfully" -ForegroundColor Green
}
catch {
    Write-Host "✗ Failed to create main table: $_" -ForegroundColor Red
    exit 1
}

# Step 2: Create log table
Write-Host "Step 2: Creating log table..." -ForegroundColor Yellow
$logTable = @"
CREATE TABLE processing_log (
    id INTEGER PRIMARY KEY,
    operation_type TEXT,
    files_processed INTEGER DEFAULT 0,
    files_successful INTEGER DEFAULT 0,
    files_failed INTEGER DEFAULT 0,
    start_time TEXT,
    end_time TEXT,
    notes TEXT
);
"@

try {
    & $Sqlite3Path $DatabasePath $logTable
    Write-Host "✓ Log table created successfully" -ForegroundColor Green
}
catch {
    Write-Host "✗ Failed to create log table: $_" -ForegroundColor Red
    Write-Host "But main table exists, so database is partially usable" -ForegroundColor Yellow
}

# Step 3: Create essential indexes
Write-Host "Step 3: Creating indexes..." -ForegroundColor Yellow

$indexes = @(
    "CREATE INDEX idx_mrn ON OLRXScans(mrn);",
    "CREATE INDEX idx_account ON OLRXScans(account);",
    "CREATE INDEX idx_last_name ON OLRXScans(last_name);",
    "CREATE INDEX idx_file_hash ON OLRXScans(file_hash);"
)

$indexCount = 0
foreach ($index in $indexes) {
    try {
        & $Sqlite3Path $DatabasePath $index
        $indexCount++
    }
    catch {
        Write-Host "Index creation failed (not critical): $index" -ForegroundColor DarkYellow
    }
}
Write-Host "✓ Created $indexCount of $($indexes.Count) indexes" -ForegroundColor Green

# Step 4: Test the database
Write-Host "Step 4: Testing database..." -ForegroundColor Yellow

try {
    # Test insert
    & $Sqlite3Path $DatabasePath "INSERT INTO OLRXScans (pdf_path, file_name) VALUES ('test.pdf', 'test.pdf');"
    
    # Test select
    $count = & $Sqlite3Path $DatabasePath "SELECT COUNT(*) FROM OLRXScans;"
    
    # Test delete
    & $Sqlite3Path $DatabasePath "DELETE FROM OLRXScans WHERE pdf_path = 'test.pdf';"
    
    Write-Host "✓ Database operations work correctly" -ForegroundColor Green
}
catch {
    Write-Host "✗ Database test failed: $_" -ForegroundColor Red
    exit 1
}

# Step 5: Final verification
Write-Host "Step 5: Final verification..." -ForegroundColor Yellow

try {
    $integrity = & $Sqlite3Path $DatabasePath "PRAGMA integrity_check;"
    if ($integrity -eq "ok") {
        Write-Host "✓ Database integrity check passed" -ForegroundColor Green
    } else {
        Write-Host "⚠ Database integrity issues: $integrity" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "⚠ Could not run integrity check" -ForegroundColor Yellow
}

# Show final status
Write-Host "`n" + "="*50 -ForegroundColor Green
Write-Host "NEW DATABASE CREATION COMPLETE!" -ForegroundColor Green  
Write-Host "="*50 -ForegroundColor Green

if (Test-Path $DatabasePath) {
    $dbFile = Get-Item $DatabasePath
    $dbSizeKB = [math]::Round($dbFile.Length / 1KB, 2)
    
    Write-Host "Database location: $DatabasePath" -ForegroundColor White
    Write-Host "Database size: $dbSizeKB KB" -ForegroundColor White
    Write-Host "Created: $($dbFile.CreationTime)" -ForegroundColor White
    
    Write-Host "`nYour database is ready!" -ForegroundColor Green
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Run: .\olrx_index_to_database.ps1 -DatabasePath '$DatabasePath' -FolderPath 'YourPDFFolder'" -ForegroundColor Gray
    Write-Host "  2. Search: .\olrx_search_and_copy_enhanced.ps1 -DatabasePath '$DatabasePath'" -ForegroundColor Gray
} else {
    Write-Host "ERROR: Database file was not created" -ForegroundColor Red
    exit 1
}
