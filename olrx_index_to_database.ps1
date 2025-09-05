# OLRX PDF Indexing Script - Database Version
# Processes PDF files and stores extracted data directly in SQLite database
# Supports incremental indexing (only processes new/changed files)

param(
    [string]$FolderPath,
    [string]$DatabasePath = "F:\olrx_scan.db",
    [string]$Sqlite3Path = "C:\sqlite3\sqlite3.exe",
    [switch]$ForceReindex = $false,
    [switch]$Recursive = $true
)

# Load Windows Forms Assembly
Add-Type -AssemblyName System.Windows.Forms

# Function for binary-safe text extraction
function Get-BinaryText {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path
    )
    
    try {
        $Stream = New-Object System.IO.FileStream -ArgumentList $Path, 'Open', 'Read'
        # Note: Codepage 28591 returns a 1-to-1 char to byte mapping
        $Encoding = [Text.Encoding]::GetEncoding(28591)
        $StreamReader = New-Object System.IO.StreamReader -ArgumentList $Stream, $Encoding
        $BinaryText = $StreamReader.ReadToEnd()
        
        $Stream.Dispose()
        $StreamReader.Dispose()
        
        return $BinaryText
    }
    catch {
        Write-Warning "Failed to read binary content from $Path: $_"
        return $null
    }
}

# Function to calculate file hash for change detection
function Get-FileHash256 {
    param([string]$FilePath)
    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm SHA256
        return $hash.Hash
    }
    catch {
        return $null
    }
}

# Function to check if file needs processing
function Test-FileNeedsProcessing {
    param(
        [string]$FilePath,
        [string]$FileHash,
        [datetime]$LastModified
    )
    
    if ($ForceReindex) { return $true }
    
    # Check if file exists in database with same hash
    $existingQuery = "SELECT id FROM OLRXScans WHERE pdf_path = '$($FilePath.Replace("'", "''"))' AND file_hash = '$FileHash'"
    try {
        $result = & $Sqlite3Path $DatabasePath $existingQuery
        return [string]::IsNullOrEmpty($result)
    }
    catch {
        return $true  # If query fails, assume we need to process
    }
}

# Function to extract patient data from PDF text
function Extract-PatientData {
    param([string]$PdfText)
    
    if ([string]::IsNullOrEmpty($PdfText)) {
        return $null
    }
    
    # Look for the "Associated Patient" marker
    $regexVisitDataStart = [regex]"Associated Patient"
    $foundVisitData = $regexVisitDataStart.Match($PdfText)
    
    if (-not $foundVisitData.Success) {
        return @{
            Success = $false
            LastName = ""
            FirstName = ""
            MRN = ""
            Account = ""
            AdmissionDate = ""
            DischargeDate = ""
        }
    }
    
    # Extract a reasonable chunk of text after the marker
    $startIndex = $foundVisitData.Index
    $extractLength = [Math]::Min(1000, $PdfText.Length - $startIndex)
    $visitString = $PdfText.Substring($startIndex, $extractLength)
    
    # Define the regex for extracting visit details
    $regexVisitDetails = [regex]'(?s)Last Name.*?: (.*?)\).*?First Name.*?: (.*?)\).*?MRN\/Unit#.*?: (.*?)\).*?Account#.*?: (.*?)\).*?Admit Date.*?: (.*?)\).*?Discharge Date.*?: (.*?)\)'
    
    $foundVisitDetails = $regexVisitDetails.Match($visitString)
    
    if ($foundVisitDetails.Success) {
        return @{
            Success = $true
            LastName = $foundVisitDetails.Groups[1].Value.Trim()
            FirstName = $foundVisitDetails.Groups[2].Value.Trim()
            MRN = $foundVisitDetails.Groups[3].Value.Trim()
            Account = $foundVisitDetails.Groups[4].Value.Trim()
            AdmissionDate = $foundVisitDetails.Groups[5].Value.Trim()
            DischargeDate = $foundVisitDetails.Groups[6].Value.Trim()
        }
    }
    else {
        return @{
            Success = $false
            LastName = ""
            FirstName = ""
            MRN = ""
            Account = ""
            AdmissionDate = ""
            DischargeDate = ""
        }
    }
}

# Function to insert/update record in database
function Add-DatabaseRecord {
    param(
        [string]$PdfPath,
        [string]$FileName,
        [long]$FileSize,
        [datetime]$LastModified,
        [hashtable]$PatientData,
        [string]$FileHash
    )
    
    # Escape single quotes in strings for SQL
    $escapedPath = $PdfPath.Replace("'", "''")
    $escapedFileName = $FileName.Replace("'", "''")
    $escapedLastName = $PatientData.LastName.Replace("'", "''")
    $escapedFirstName = $PatientData.FirstName.Replace("'", "''")
    $escapedMRN = $PatientData.MRN.Replace("'", "''")
    $escapedAccount = $PatientData.Account.Replace("'", "''")
    $escapedAdmissionDate = $PatientData.AdmissionDate.Replace("'", "''")
    $escapedDischargeDate = $PatientData.DischargeDate.Replace("'", "''")
    
    $lastModifiedStr = $LastModified.ToString("yyyy-MM-dd HH:mm:ss")
    
    # First, try to update existing record
    $updateSQL = @"
UPDATE OLRXScans SET 
    file_name = '$escapedFileName',
    file_size = $FileSize,
    last_modified = '$lastModifiedStr',
    last_name = '$escapedLastName',
    first_name = '$escapedFirstName',
    mrn = '$escapedMRN',
    account = '$escapedAccount',
    admission_date = '$escapedAdmissionDate',
    discharge_date = '$escapedDischargeDate',
    extraction_success = $($PatientData.Success -as [int]),
    date_indexed = datetime('now'),
    file_hash = '$FileHash'
WHERE pdf_path = '$escapedPath'
"@
    
    try {
        & $Sqlite3Path $DatabasePath $updateSQL
        
        # Check if any rows were affected
        $changesSQL = "SELECT changes()"
        $changes = & $Sqlite3Path $DatabasePath $changesSQL
        
        if ($changes -eq "0") {
            # No existing record, insert new one
            $insertSQL = @"
INSERT INTO OLRXScans (
    pdf_path, file_name, file_size, last_modified,
    last_name, first_name, mrn, account,
    admission_date, discharge_date, extraction_success,
    date_indexed, file_hash
) VALUES (
    '$escapedPath', '$escapedFileName', $FileSize, '$lastModifiedStr',
    '$escapedLastName', '$escapedFirstName', '$escapedMRN', '$escapedAccount',
    '$escapedAdmissionDate', '$escapedDischargeDate', $($PatientData.Success -as [int]),
    datetime('now'), '$FileHash'
)
"@
            & $Sqlite3Path $DatabasePath $insertSQL
        }
        return $true
    }
    catch {
        Write-Warning "Failed to add database record for $PdfPath: $_"
        return $false
    }
}

# Function to prompt user with a folder selection dialog
function Select-Folder {
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select the folder containing the PDF files:"
    $folderBrowser.ShowNewFolderButton = $false
    
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    }
    else {
        return $null
    }
}

# Main script execution starts here

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

# Get folder path from parameter or user selection
if (-not $FolderPath) {
    $FolderPath = Select-Folder
    if (-not $FolderPath) {
        Write-Host "No folder was selected. Exiting script." -ForegroundColor Yellow
        exit 0
    }
}

if (-not (Test-Path $FolderPath)) {
    Write-Error "Folder path does not exist: $FolderPath"
    exit 1
}

Write-Host "Starting PDF indexing process..." -ForegroundColor Cyan
Write-Host "Source folder: $FolderPath" -ForegroundColor Gray
Write-Host "Database: $DatabasePath" -ForegroundColor Gray
Write-Host "Force reindex: $ForceReindex" -ForegroundColor Gray

# Log the start of processing
$startTime = Get-Date
$logInsertSQL = @"
INSERT INTO processing_log (operation_type, start_time, notes)
VALUES ('INDEX', '$($startTime.ToString("yyyy-MM-dd HH:mm:ss"))', 'Started indexing: $FolderPath')
"@
& $Sqlite3Path $DatabasePath $logInsertSQL

# Initialize counters
$totalFiles = 0
$processedFiles = 0
$successfulExtractions = 0
$failedExtractions = 0
$skippedFiles = 0

# Process PDF files
$searchPath = if ($Recursive) { "$FolderPath\*.pdf" } else { $FolderPath }
Get-ChildItem -Path $FolderPath -Recurse:$Recursive -Filter "*.pdf" | ForEach-Object {
    $pdfPath = $_.FullName
    $fileName = $_.Name
    $fileSize = $_.Length
    $lastModified = $_.LastWriteTime
    
    $totalFiles++
    Write-Host "Processing: $fileName" -ForegroundColor White
    
    # Calculate file hash
    $fileHash = Get-FileHash256 -FilePath $pdfPath
    if (-not $fileHash) {
        Write-Warning "Could not calculate hash for $pdfPath"
        $failedExtractions++
        return
    }
    
    # Check if file needs processing
    if (-not (Test-FileNeedsProcessing -FilePath $pdfPath -FileHash $fileHash -LastModified $lastModified)) {
        Write-Host "  Skipping (already indexed): $fileName" -ForegroundColor DarkGray
        $skippedFiles++
        return
    }
    
    # Extract binary text from PDF
    $pdfText = Get-BinaryText -Path $pdfPath
    if (-not $pdfText) {
        Write-Warning "  Failed to extract text from: $fileName"
        $failedExtractions++
        return
    }
    
    # Extract patient data
    $patientData = Extract-PatientData -PdfText $pdfText
    
    # Add record to database
    if (Add-DatabaseRecord -PdfPath $pdfPath -FileName $fileName -FileSize $fileSize -LastModified $lastModified -PatientData $patientData -FileHash $fileHash) {
        $processedFiles++
        if ($patientData.Success) {
            $successfulExtractions++
            Write-Host "  Success: $($patientData.LastName), $($patientData.FirstName) - $($patientData.MRN)" -ForegroundColor Green
        }
        else {
            $failedExtractions++
            Write-Host "  No patient data found" -ForegroundColor Yellow
        }
    }
    else {
        Write-Warning "  Database insert failed for: $fileName"
        $failedExtractions++
    }
}

# Calculate total processing time
$endTime = Get-Date
$totalTime = $endTime - $startTime

# Update processing log
$logUpdateSQL = @"
UPDATE processing_log SET 
    files_processed = $processedFiles,
    files_successful = $successfulExtractions,
    files_failed = $failedExtractions,
    end_time = '$($endTime.ToString("yyyy-MM-dd HH:mm:ss"))',
    notes = 'Completed indexing: $FolderPath. Total files: $totalFiles, Processed: $processedFiles, Skipped: $skippedFiles'
WHERE id = (SELECT MAX(id) FROM processing_log WHERE operation_type = 'INDEX')
"@
& $Sqlite3Path $DatabasePath $logUpdateSQL

# Display results
Write-Host "`n" + "="*60 -ForegroundColor Cyan
Write-Host "INDEXING COMPLETE" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Cyan
Write-Host "Total PDFs found: $totalFiles" -ForegroundColor White
Write-Host "Files processed: $processedFiles" -ForegroundColor White
Write-Host "Files skipped (already indexed): $skippedFiles" -ForegroundColor Gray
Write-Host "Successful data extractions: $successfulExtractions" -ForegroundColor Green
Write-Host "Failed extractions: $failedExtractions" -ForegroundColor Red
Write-Host "Total processing time: $($totalTime.TotalMinutes.ToString('F2')) minutes" -ForegroundColor Yellow
Write-Host "Database: $DatabasePath" -ForegroundColor Cyan

# Show database stats
try {
    $totalRecordsSQL = "SELECT COUNT(*) FROM OLRXScans"
    $totalRecords = & $Sqlite3Path $DatabasePath $totalRecordsSQL
    Write-Host "Total records in database: $totalRecords" -ForegroundColor Cyan
}
catch {
    Write-Warning "Could not retrieve database statistics"
}
