# OLRX Enhanced Search and Copy Script
# Searches the SQLite database and copies matching PDF files
# Enhanced with better validation, logging, and user interface

param(
    [string]$DatabasePath = "F:\olrx_scan.db",
    [string]$Sqlite3Path = "C:\sqlite3\sqlite3.exe",
    [string]$BaseLocation = "F:\MRN_matches"
)

# Load required assemblies for GUI functionality
Add-Type -AssemblyName "System.Windows.Forms"

# Ensure sqlite3 is available
if (-not (Test-Path $Sqlite3Path)) {
    [System.Windows.Forms.MessageBox]::Show("sqlite3 is not found at the specified path: $Sqlite3Path", "Error")
    exit 1
}

# Check if the database file exists
if (-not (Test-Path $DatabasePath)) {
    [System.Windows.Forms.MessageBox]::Show("SQLite database not found at $DatabasePath. Please run init_database.ps1 first.", "Error")
    exit 1
}

# Ensure the base save location exists
if (-not (Test-Path $BaseLocation)) {
    New-Item -ItemType Directory -Path $BaseLocation | Out-Null
}

# Helper function to validate account number(s)
function Validate-Accounts {
    param ([string]$accounts)
    if ([string]::IsNullOrWhiteSpace($accounts)) { return $true }  # Empty field is valid
    foreach ($account in $accounts.Split(',').Trim()) {
        if ($account -and $account -notmatch '^[a-zA-Z]{2}\d{6,9}/\d{2}$') {
            return $false
        }
    }
    return $true
}

# Helper function to validate MRN number(s)
function Validate-MRNs {
    param ([string]$mrns)
    if ([string]::IsNullOrWhiteSpace($mrns)) { return $true }  # Empty field is valid
    foreach ($mrn in $mrns.Split(',').Trim()) {
        if ($mrn -and $mrn -notmatch '^[a-zA-Z]{2}\d{8,12}$') {
            return $false
        }
    }
    return $true
}

# Enhanced date validation function
function Validate-Date {
    param ([string]$dateString)
    if ([string]::IsNullOrWhiteSpace($dateString)) {
        return $true  # Empty dates are valid
    }

    try {
        # Try parsing with "MM/dd/yy" and "MM/dd/yyyy" formats
        $valid = [datetime]::TryParseExact(
            $dateString,
            @("MM/dd/yy", "MM/dd/yyyy", "M/d/yy", "M/d/yyyy", "MM/d/yy", "M/dd/yyyy"),
            $null,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$null
        )
        return $valid
    } catch {
        return $false
    }
}

# Helper function to validate the overall query
function Validate-Query {
    # Ensure at least one of the key fields has data
    return (-not [string]::IsNullOrWhiteSpace($textBoxes[0].Text) -or 
            -not [string]::IsNullOrWhiteSpace($textBoxes[1].Text) -or
            -not [string]::IsNullOrWhiteSpace($textBoxes[2].Text) -or
            -not [string]::IsNullOrWhiteSpace($textBoxes[3].Text) -or
            -not [string]::IsNullOrWhiteSpace($textBoxes[4].Text))
}

# Function to execute database query with proper error handling
function Execute-DatabaseQuery {
    param([string]$Query)
    
    try {
        Write-Host "Executing query: $Query" -ForegroundColor Gray
        $result = & $Sqlite3Path $DatabasePath $Query 2>&1
        
        # Check if there was an error
        if ($LASTEXITCODE -ne 0) {
            throw "SQLite returned exit code $LASTEXITCODE"
        }
        
        return $result
    }
    catch {
        Write-Error "Database query failed: $_"
        return $null
    }
}

# Function to log search operations
function Add-SearchLog {
    param(
        [hashtable]$SearchParams,
        [int]$ResultCount,
        [string]$DestinationFolder
    )
    
    $searchDetails = ($SearchParams.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { "$($_.Key): $($_.Value)" }) -join "; "
    
    $logSQL = @"
INSERT INTO processing_log (operation_type, files_processed, start_time, end_time, notes)
VALUES ('SEARCH', $ResultCount, datetime('now'), datetime('now'), 'Search: $searchDetails | Destination: $DestinationFolder')
"@
    
    try {
        Execute-DatabaseQuery -Query $logSQL | Out-Null
    }
    catch {
        Write-Warning "Failed to log search operation: $_"
    }
}

# Create a GUI form for user input
$form = New-Object System.Windows.Forms.Form
$form.Text = "OLRX Database Search"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false

# Updated field labels and order
$labels = @("Account(s)", "MRN(s)", "Last Name", "First Name", "Admission Date", "Discharge Date")
$textBoxes = @()

# Dynamically adjust window size
$fieldHeight = 50
$buttonHeight = 40
$fieldWidth = 250
$verticalSpacing = 10
$formWidth = 450
$buttonVerticalOffset = 20
$formHeight = (($labels.Count + 2) * $fieldHeight) + $buttonHeight + $verticalSpacing + $buttonVerticalOffset + 40
$form.Size = New-Object System.Drawing.Size($formWidth, $formHeight)

# Add database info label
$dbInfoLabel = New-Object System.Windows.Forms.Label
$dbInfoLabel.Text = "Database: $(Split-Path $DatabasePath -Leaf)"
$dbInfoLabel.Location = New-Object System.Drawing.Point(10, 5)
$dbInfoLabel.Size = New-Object System.Drawing.Size(400, 20)
$dbInfoLabel.ForeColor = [System.Drawing.Color]::Blue
$form.Controls.Add($dbInfoLabel)

# Create input fields
for ($i = 0; $i -lt $labels.Count; $i++) {
    $yPosition = (($i * $fieldHeight) + 30)  # Adjusted for database info label
    
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $labels[$i]
    $label.Location = New-Object System.Drawing.Point(10, $yPosition)
    $label.Size = New-Object System.Drawing.Size(150, 20)
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(170, $yPosition)
    $textBox.Size = New-Object System.Drawing.Size($fieldWidth, 20)
    $form.Controls.Add($textBox)
    $textBoxes += $textBox

    # Add hints for different field types
    $hintText = ""
    switch ($labels[$i]) {
        "Account(s)" { $hintText = "(e.g. SM012345/19, ...)" }
        "MRN(s)" { $hintText = "(e.g. SM00123456, ...)" }
        "Last Name" { $hintText = "(partial matches allowed)" }
        "First Name" { $hintText = "(partial matches allowed)" }
        { $_ -match "Date" } { $hintText = "(MM/DD/YY or MM/DD/YYYY)" }
    }

    if ($hintText) {
        $hintLabel = New-Object System.Windows.Forms.Label
        $hintLabel.Text = $hintText
        $hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(128, 128, 128)
        $hintLabel.Location = New-Object System.Drawing.Point(170, ($yPosition + 25))
        $hintLabel.Size = New-Object System.Drawing.Size($fieldWidth, 15)
        $hintLabel.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 7)
        $form.Controls.Add($hintLabel)
    }

    # Attach dynamic validation to each text box
    $textBox.Add_TextChanged({
        $runButton.Enabled = Validate-Query
    })
}

# Add Destination Folder field
$destinationYPos = (($labels.Count * $fieldHeight) + 30)
$destinationLabel = New-Object System.Windows.Forms.Label
$destinationLabel.Text = "Destination Folder"
$destinationLabel.Location = New-Object System.Drawing.Point(10, $destinationYPos)
$destinationLabel.Size = New-Object System.Drawing.Size(150, 20)
$form.Controls.Add($destinationLabel)

$destinationTextBox = New-Object System.Windows.Forms.TextBox
$destinationTextBox.Location = New-Object System.Drawing.Point(170, $destinationYPos)
$destinationTextBox.Size = New-Object System.Drawing.Size($fieldWidth, 20)
$destinationTextBox.Text = $BaseLocation
$form.Controls.Add($destinationTextBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Location = New-Object System.Drawing.Point(170, ($destinationYPos + 25))
$browseButton.Size = New-Object System.Drawing.Size(60, 23)
$browseButton.Add_Click({
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select destination folder"
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $destinationTextBox.Text = $folderBrowser.SelectedPath
    }
})
$form.Controls.Add($browseButton)

# Add Run and Close buttons
$buttonWidth = 100
$buttonY = $formHeight - $buttonHeight - 30

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Search && Copy"
$runButton.Location = New-Object System.Drawing.Point(10, $buttonY)
$runButton.Size = New-Object System.Drawing.Size($buttonWidth, 30)
$runButton.Enabled = $false  # Initially disabled
$runButton.Add_Click({
    # Validate inputs
    if (-not (Validate-Accounts $textBoxes[0].Text)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid account number format. Please use format: AB123456/19", "Validation Error")
        return
    }
    if (-not (Validate-MRNs $textBoxes[1].Text)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid MRN format. Please use format: AB12345678", "Validation Error")
        return
    }
    if (-not (Validate-Date $textBoxes[4].Text) -or -not (Validate-Date $textBoxes[5].Text)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid date format. Please use MM/DD/YY or MM/DD/YYYY", "Validation Error")
        return
    }
    
    $form.Tag = "Run"
    $form.Close()
})
$form.Controls.Add($runButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Location = New-Object System.Drawing.Point(($formWidth - 30 - $buttonWidth), $buttonY)
$closeButton.Size = New-Object System.Drawing.Size($buttonWidth, 30)
$closeButton.Add_Click({
    $form.Tag = "Close"
    $form.Close()
})
$form.Controls.Add($closeButton)

# Show stats button
$statsButton = New-Object System.Windows.Forms.Button
$statsButton.Text = "DB Stats"
$statsButton.Location = New-Object System.Drawing.Point(120, $buttonY)
$statsButton.Size = New-Object System.Drawing.Size(80, 30)
$statsButton.Add_Click({
    try {
        $totalRecords = Execute-DatabaseQuery -Query "SELECT COUNT(*) FROM OLRXScans"
        $successfulRecords = Execute-DatabaseQuery -Query "SELECT COUNT(*) FROM OLRXScans WHERE extraction_success = 1"
        $recentRecords = Execute-DatabaseQuery -Query "SELECT COUNT(*) FROM OLRXScans WHERE date_indexed > datetime('now', '-7 days')"
        
        $statsMessage = @"
Database Statistics:

Total records: $totalRecords
Successful extractions: $successfulRecords
Records added in last 7 days: $recentRecords

Database location: $DatabasePath
"@
        [System.Windows.Forms.MessageBox]::Show($statsMessage, "Database Statistics")
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Error retrieving database statistics: $_", "Error")
    }
})
$form.Controls.Add($statsButton)

# Show the form
$form.ShowDialog()

# Check if the form was closed without running
if ($form.Tag -ne "Run") {
    exit 0
}

# Capture user inputs
$searchParams = @{
    Account = $textBoxes[0].Text.Trim()
    MRN = $textBoxes[1].Text.Trim()
    LastName = $textBoxes[2].Text.Trim()
    FirstName = $textBoxes[3].Text.Trim()
    AdmissionDate = $textBoxes[4].Text.Trim()
    DischargeDate = $textBoxes[5].Text.Trim()
    DestinationFolder = $destinationTextBox.Text.Trim()
}

# Construct folder name dynamically based on user inputs
$folderParts = @()
if ($searchParams.Account) { $folderParts += "acc_" + ($searchParams.Account -replace '[^\w]', '_') }
if ($searchParams.MRN) { $folderParts += "mrn_" + ($searchParams.MRN -replace '[^\w]', '_') }
if ($searchParams.LastName) { $folderParts += "ln_" + ($searchParams.LastName -replace '[^\w]', '_') }
if ($searchParams.FirstName) { $folderParts += "fn_" + ($searchParams.FirstName -replace '[^\w]', '_') }
if ($searchParams.AdmissionDate) { $folderParts += "ad_" + ($searchParams.AdmissionDate -replace '[^\w]', '_') }
if ($searchParams.DischargeDate) { $folderParts += "dd_" + ($searchParams.DischargeDate -replace '[^\w]', '_') }

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$folderName = if ($folderParts.Count -gt 0) {
    "olrx_search_$timestamp`_" + ($folderParts -join "_")
} else {
    "olrx_search_all_$timestamp"
}

$finalDestination = Join-Path -Path $searchParams.DestinationFolder -ChildPath $folderName

# Ensure destination folder exists
if (-not (Test-Path $finalDestination)) {
    New-Item -ItemType Directory -Path $finalDestination | Out-Null
    Write-Host "Created destination folder: $finalDestination" -ForegroundColor Green
}

# Build WHERE clause for SQLite query with proper escaping
$whereClauses = @()

if ($searchParams.Account) { 
    $escapedAccount = $searchParams.Account.Replace("'", "''")
    $whereClauses += "account LIKE '%$escapedAccount%'" 
}
if ($searchParams.MRN) { 
    $escapedMRN = $searchParams.MRN.Replace("'", "''")
    $whereClauses += "mrn LIKE '%$escapedMRN%'" 
}
if ($searchParams.LastName) { 
    $escapedLastName = $searchParams.LastName.Replace("'", "''")
    $whereClauses += "last_name LIKE '%$escapedLastName%'" 
}
if ($searchParams.FirstName) { 
    $escapedFirstName = $searchParams.FirstName.Replace("'", "''")
    $whereClauses += "first_name LIKE '%$escapedFirstName%'" 
}
if ($searchParams.AdmissionDate) { 
    $escapedAdmissionDate = $searchParams.AdmissionDate.Replace("'", "''")
    $whereClauses += "admission_date LIKE '%$escapedAdmissionDate%'" 
}
if ($searchParams.DischargeDate) { 
    $escapedDischargeDate = $searchParams.DischargeDate.Replace("'", "''")
    $whereClauses += "discharge_date LIKE '%$escapedDischargeDate%'" 
}

$whereClause = if ($whereClauses.Count -gt 0) {
    $whereClauses -join " AND "
} else {
    "1=1"  # Select all records if no criteria specified
}

# Build and execute query
$query = "SELECT pdf_path, file_name, last_name, first_name, mrn, account FROM OLRXScans WHERE $whereClause ORDER BY last_name, first_name"

Write-Host "Searching database..." -ForegroundColor Cyan
$queryResults = Execute-DatabaseQuery -Query $query

if (-not $queryResults -or $queryResults.Count -eq 0) {
    Write-Host "No matching results found." -ForegroundColor Yellow
    [System.Windows.Forms.MessageBox]::Show("No matching results found for the specified criteria.", "No Matches")
    
    # Log the search attempt
    Add-SearchLog -SearchParams $searchParams -ResultCount 0 -DestinationFolder $finalDestination
    exit 0
}

Write-Host "Found $($queryResults.Count) matching records" -ForegroundColor Green

# Copy matching files to the final destination folder
$copiedCount = 0
$failedCount = 0
$csvContent = @("FilePath,FileName,LastName,FirstName,MRN,Account,CopyStatus")

foreach ($result in $queryResults) {
    # Parse the result (format: path|filename|lastname|firstname|mrn|account)
    $parts = $result -split '\|'
    if ($parts.Count -ge 6) {
        $filePath = $parts[0]
        $fileName = $parts[1]
        $lastName = $parts[2]
        $firstName = $parts[3]
        $mrn = $parts[4]
        $account = $parts[5]
        
        if (Test-Path $filePath) {
            try {
                Copy-Item -Path $filePath -Destination $finalDestination -Force
                Write-Host "✓ Copied: $fileName" -ForegroundColor Green
                $csvContent += "$filePath,$fileName,$lastName,$firstName,$mrn,$account,Success"
                $copiedCount++
            }
            catch {
                Write-Warning "✗ Failed to copy: $fileName - $_"
                $csvContent += "$filePath,$fileName,$lastName,$firstName,$mrn,$account,Failed: $_"
                $failedCount++
            }
        }
        else {
            Write-Warning "✗ File not found: $filePath"
            $csvContent += "$filePath,$fileName,$lastName,$firstName,$mrn,$account,File not found"
            $failedCount++
        }
    }
}

# Save results to CSV
$csvPath = Join-Path -Path $finalDestination -ChildPath "search_results.csv"
$csvContent | Out-File -FilePath $csvPath -Encoding UTF8

# Log the search operation
Add-SearchLog -SearchParams $searchParams -ResultCount ($copiedCount + $failedCount) -DestinationFolder $finalDestination

# Show completion message
$resultMessage = @"
Search and copy operation completed!

Files found: $($queryResults.Count)
Files copied successfully: $copiedCount
Files failed to copy: $failedCount

Results saved to: $finalDestination
CSV log: $csvPath
"@

Write-Host "`n$resultMessage" -ForegroundColor Cyan
[System.Windows.Forms.MessageBox]::Show($resultMessage, "Operation Complete")
