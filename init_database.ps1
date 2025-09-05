# OLRX Database Initialization Script
# Creates and initializes the SQLite database with proper schema

param(
    [string]$DatabasePath = "F:\olrx_scan.db",
    [string]$Sqlite3Path = "C:\sqlite3\sqlite3.exe"
)

# Check if sqlite3 is available
if (-not (Test-Path $Sqlite3Path)) {
    Write-Error "sqlite3 not found at $Sqlite3Path. Please install SQLite or update the path."
    exit 1
}

# Create database directory if it doesn't exist
$dbDir = Split-Path $DatabasePath -Parent
if (-not (Test-Path $dbDir)) {
    New-Item -ItemType Directory -Path $dbDir -Force | Out-Null
    Write-Host "Created database directory: $dbDir" -ForegroundColor Green
}

# SQL to create the main table
$createTableSQL = @"
CREATE TABLE IF NOT EXISTS OLRXScans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pdf_path TEXT NOT NULL UNIQUE,
    file_name TEXT NOT NULL,
    file_size INTEGER,
    last_modified DATETIME,
    last_name TEXT,
    first_name TEXT,
    mrn TEXT,
    account TEXT,
    admission_date TEXT,
    discharge_date TEXT,
    extraction_success INTEGER DEFAULT 0,
    date_indexed DATETIME DEFAULT CURRENT_TIMESTAMP,
    file_hash TEXT
);
"@

# SQL to create indexes for better query performance
$createIndexesSQL = @"
CREATE INDEX IF NOT EXISTS idx_mrn ON OLRXScans(mrn);
CREATE INDEX IF NOT EXISTS idx_account ON OLRXScans(account);
CREATE INDEX IF NOT EXISTS idx_last_name ON OLRXScans(last_name);
CREATE INDEX IF NOT EXISTS idx_admission_date ON OLRXScans(admission_date);
CREATE INDEX IF NOT EXISTS idx_discharge_date ON OLRXScans(discharge_date);
CREATE INDEX IF NOT EXISTS idx_file_hash ON OLRXScans(file_hash);
CREATE INDEX IF NOT EXISTS idx_date_indexed ON OLRXScans(date_indexed);
"@

# SQL to create a log table for tracking processing
$createLogTableSQL = @"
CREATE TABLE IF NOT EXISTS processing_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_type TEXT NOT NULL,
    files_processed INTEGER DEFAULT 0,
    files_successful INTEGER DEFAULT 0,
    files_failed INTEGER DEFAULT 0,
    start_time DATETIME,
    end_time DATETIME,
    notes TEXT
);
"@

try {
    Write-Host "Initializing OLRX database at: $DatabasePath" -ForegroundColor Cyan
    
    # Execute table creation
    & $Sqlite3Path $DatabasePath $createTableSQL
    Write-Host "Created OLRXScans table" -ForegroundColor Green
    
    # Execute index creation
    & $Sqlite3Path $DatabasePath $createIndexesSQL
    Write-Host "Created database indexes" -ForegroundColor Green
    
    # Execute log table creation
    & $Sqlite3Path $DatabasePath $createLogTableSQL
    Write-Host "Created processing_log table" -ForegroundColor Green
    
    # Verify database structure
    $tableInfo = & $Sqlite3Path $DatabasePath ".schema OLRXScans"
    Write-Host "`nDatabase schema created successfully:" -ForegroundColor Green
    Write-Host $tableInfo -ForegroundColor Gray
    
    Write-Host "`nDatabase initialization complete!" -ForegroundColor Green
    
} catch {
    Write-Error "Failed to initialize database: $_"
    exit 1
}
