# Simple OLRX Database Creator
# Clean script with minimal syntax

param(
    [string]$DatabasePath = "C:\Omnicell\OmniLinkRx\olrx_scan.db",
    [string]$Sqlite3Path = "C:\sqlite3\sqlite3.exe"
)

Write-Host "Creating OLRX Database" -ForegroundColor Green
Write-Host "Database: $DatabasePath"
Write-Host "SQLite: $Sqlite3Path"

# Check SQLite
if (-not (Test-Path $Sqlite3Path)) {
    Write-Host "ERROR: SQLite not found" -ForegroundColor Red
    exit 1
}

# Remove old database
if (Test-Path $DatabasePath) {
    Remove-Item $DatabasePath -Force
    Write-Host "Removed old database" -ForegroundColor Yellow
}

# Create directory
$dbDir = Split-Path $DatabasePath -Parent
if (-not (Test-Path $dbDir)) {
    New-Item -ItemType Directory -Path $dbDir -Force
    Write-Host "Created directory" -ForegroundColor Green
}

# Create main table
Write-Host "Creating main table..."
$sql1 = "CREATE TABLE OLRXScans (id INTEGER PRIMARY KEY, pdf_path TEXT UNIQUE, file_name TEXT, file_size INTEGER, last_modified TEXT, last_name TEXT, first_name TEXT, mrn TEXT, account TEXT, admission_date TEXT, discharge_date TEXT, extraction_success INTEGER DEFAULT 0, date_indexed TEXT DEFAULT (datetime('now')), file_hash TEXT);"

try {
    & $Sqlite3Path $DatabasePath $sql1
    Write-Host "Main table created" -ForegroundColor Green
}
catch {
    Write-Host "Failed to create main table" -ForegroundColor Red
    exit 1
}

# Create log table  
Write-Host "Creating log table..."
$sql2 = "CREATE TABLE processing_log (id INTEGER PRIMARY KEY, operation_type TEXT, files_processed INTEGER DEFAULT 0, files_successful INTEGER DEFAULT 0, files_failed INTEGER DEFAULT 0, start_time TEXT, end_time TEXT, notes TEXT);"

try {
    & $Sqlite3Path $DatabasePath $sql2
    Write-Host "Log table created" -ForegroundColor Green
}
catch {
    Write-Host "Log table failed (not critical)" -ForegroundColor Yellow
}

# Create indexes
Write-Host "Creating indexes..."
$indexes = @(
    "CREATE INDEX idx_mrn ON OLRXScans(mrn);",
    "CREATE INDEX idx_account ON OLRXScans(account);",
    "CREATE INDEX idx_last_name ON OLRXScans(last_name);"
)

$indexCount = 0
foreach ($idx in $indexes) {
    try {
        & $Sqlite3Path $DatabasePath $idx
        $indexCount++
    }
    catch {
        Write-Host "Index failed (not critical)" -ForegroundColor DarkYellow
    }
}
Write-Host "Created $indexCount indexes" -ForegroundColor Green

# Test database
Write-Host "Testing database..."
try {
    & $Sqlite3Path $DatabasePath "INSERT INTO OLRXScans (pdf_path, file_name) VALUES ('test.pdf', 'test.pdf');"
    $count = & $Sqlite3Path $DatabasePath "SELECT COUNT(*) FROM OLRXScans;"
    & $Sqlite3Path $DatabasePath "DELETE FROM OLRXScans WHERE pdf_path = 'test.pdf';"
    Write-Host "Database test passed" -ForegroundColor Green
}
catch {
    Write-Host "Database test failed" -ForegroundColor Red
    exit 1
}

# Show results
Write-Host ""
Write-Host "DATABASE CREATED SUCCESSFULLY" -ForegroundColor Green
Write-Host "Location: $DatabasePath"

if (Test-Path $DatabasePath) {
    $size = [math]::Round((Get-Item $DatabasePath).Length / 1KB, 2)
    Write-Host "Size: $size KB"
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "1. Run indexing: .\olrx_index_to_database.ps1 -FolderPath 'YourPDFFolder'" -ForegroundColor Gray
    Write-Host "2. Search files: .\olrx_search_and_copy_enhanced.ps1" -ForegroundColor Gray
}
else {
    Write-Host "ERROR: Database not created" -ForegroundColor Red
    exit 1
}
