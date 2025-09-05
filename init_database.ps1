# OLRX Database Initialization Script
# Creates and initializes the SQLite database with proper schema

param(
    [string]$DatabasePath = "F:\olrx_scan.db",
    [string]$Sqlite3Path = "C:\sqlite3\sqlite3.exe",
    [switch]$ForceRecreate = $false
)

# Check if sqlite3 is available
if (-not (Test-Path $Sqlite3Path)) {
    Write-Error "sqlite3 not found at $Sqlite3Path. Please install SQLite or update the path."
    Write-Host "You can download SQLite from: https://www.sqlite.org/download.html" -ForegroundColor Yellow
    exit 1
}

# Create database directory if it doesn't exist
$dbDir = Split-Path $DatabasePath -Parent
if (-not (Test-Path $dbDir)) {
    New-Item -ItemType Directory -Path $dbDir -Force | Out-Null
    Write-Host "Created database directory: $dbDir" -ForegroundColor Green
}

# Function to execute SQLite commands safely
function Invoke-SqliteCommand {
    param(
        [string]$Command,
        [string]$Description
    )
    
    try {
        Write-Host "Executing: $Description" -ForegroundColor Cyan
        $result = & $Sqlite3Path $DatabasePath $Command 2>&1
        
        # Check for errors in output
        if ($result -match "Error:|error:|ERROR:") {
            throw "SQLite error: $result"
        }
        
        return $result
    }
    catch {
        Write-Error "Failed to execute $Description`: $_"
        throw
    }
}

# Check if database exists and handle corruption
if (Test-Path $DatabasePath) {
    if ($ForceRecreate) {
        Write-Host "Force recreate specified - removing existing database" -ForegroundColor Yellow
        Remove-Item $DatabasePath -Force
    }
    else {
        Write-Host "Checking existing database integrity..." -ForegroundColor Yellow
        try {
            $integrityCheck = & $Sqlite3Path $DatabasePath "PRAGMA integrity_check;" 2>&1
            if ($integrityCheck -ne "ok" -or $integrityCheck -match "Error:|error:|malformed") {
                Write-Host "Database corruption detected: $integrityCheck" -ForegroundColor Red
                Write-Host "Backing up corrupted database and creating new one..." -ForegroundColor Yellow
                
                $backupPath = $DatabasePath + ".corrupt." + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")
                Move-Item $DatabasePath $backupPath
                Write-Host "Corrupted database backed up to: $backupPath" -ForegroundColor Yellow
            }
            else {
                Write-Host "Existing database is healthy" -ForegroundColor Green
                $choice = Read-Host "Database already exists. Continue to add/update schema? (y/n)"
                if ($choice -ne 'y' -and $choice -ne 'Y') {
                    Write-Host "Initialization cancelled" -ForegroundColor Yellow
                    exit 0
                }
            }
        }
        catch {
            Write-Host "Cannot check database integrity - assuming corruption" -ForegroundColor Red
            $backupPath = $DatabasePath + ".corrupt." + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")
            Move-Item $DatabasePath $backupPath -ErrorAction SilentlyContinue
            Write-Host "Existing database backed up to: $backupPath" -ForegroundColor Yellow
        }
    }
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
    Invoke-SqliteCommand $createTableSQL "Create OLRXScans table" | Out-Null
    Write-Host "✓ Created OLRXScans table" -ForegroundColor Green
    
    # Execute index creation (one by one for better error handling)
    $indexes = @(
        'CREATE INDEX IF NOT EXISTS idx_mrn ON OLRXScans(mrn);',
        'CREATE INDEX IF NOT EXISTS idx_account ON OLRXScans(account);',
        'CREATE INDEX IF NOT EXISTS idx_last_name ON OLRXScans(last_name);',
        'CREATE INDEX IF NOT EXISTS idx_admission_date ON OLRXScans(admission_date);',
        'CREATE INDEX IF NOT EXISTS idx_discharge_date ON OLRXScans(discharge_date);',
        'CREATE INDEX IF NOT EXISTS idx_file_hash ON OLRXScans(file_hash);',
        'CREATE INDEX IF NOT EXISTS idx_date_indexed ON OLRXScans(date_indexed);'
    )
    
    foreach ($index in $indexes) {
        Invoke-SqliteCommand $index 'Create index' | Out-Null
    }
    Write-Host 'Created database indexes' -ForegroundColor Green
    
    # Execute log table creation
    Invoke-SqliteCommand $createLogTableSQL 'Create processing_log table' | Out-Null
    Write-Host 'Created processing_log table' -ForegroundColor Green
    
    # Test database functionality
    Write-Host 'Testing database functionality...' -ForegroundColor Yellow
    $testResult = Invoke-SqliteCommand 'SELECT COUNT(*) FROM OLRXScans;' 'Test query'
    Write-Host "Database is functional (contains $testResult records)" -ForegroundColor Green
    
    # Run integrity check
    $integrityResult = Invoke-SqliteCommand 'PRAGMA integrity_check;' 'Integrity check'
    if ($integrityResult -eq 'ok') {
        Write-Host 'Database integrity verified' -ForegroundColor Green
    } else {
        Write-Warning "Database integrity issue: $integrityResult"
    }
    
    # Show database info
    Write-Host "`n" + "="*50 -ForegroundColor Green
    Write-Host "DATABASE INITIALIZATION COMPLETE" -ForegroundColor Green
    Write-Host "="*50 -ForegroundColor Green
    Write-Host "Database location: $DatabasePath" -ForegroundColor White
    
    if (Test-Path $DatabasePath) {
        $dbFile = Get-Item $DatabasePath
        $dbSizeKB = [math]::Round($dbFile.Length / 1KB, 2)
        Write-Host "Database size: $dbSizeKB KB" -ForegroundColor White
    }
    
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Run: .\olrx_index_to_database.ps1 -FolderPath 'C:\Your\PDF\Folder'" -ForegroundColor Gray
    Write-Host "  2. Use: .\olrx_search_and_copy_enhanced.ps1 to search and copy files" -ForegroundColor Gray
    
} catch {
    Write-Error "Failed to initialize database: $_"
    Write-Host "Troubleshooting tips:" -ForegroundColor Yellow
    Write-Host "  - Ensure SQLite3 is properly installed" -ForegroundColor Gray
    Write-Host "  - Check that the database directory is writable" -ForegroundColor Gray
    Write-Host "  - Try running with -ForceRecreate to start fresh" -ForegroundColor Gray
    exit 1
}
