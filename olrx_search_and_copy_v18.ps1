# Load required assemblies for GUI functionality
Add-Type -AssemblyName "System.Windows.Forms"

# Define the path to sqlite3 and SQLite database
$sqlite3Path = "C:\sqlite3\sqlite3.exe"  # Path to sqlite3
$databasePath = "F:\olrx_scan.db"  # Path to the SQLite database
$tableName = "OLRXScans"  # Table to query from
$baseLocation = "F:\MRN_matches"  # Base save location

# Ensure sqlite3 is available
if (-not (Test-Path $sqlite3Path)) {
    [System.Windows.Forms.MessageBox]::Show("sqlite3 is not found at the specified path: $sqlite3Path", "Error")
    exit
}

# Check if the database file exists
if (-not (Test-Path $databasePath)) {
    [System.Windows.Forms.MessageBox]::Show("SQLite database not found at $databasePath. Exiting.", "Error")
    exit
}

# Ensure the base save location exists
if (-not (Test-Path $baseLocation)) {
    New-Item -ItemType Directory -Path $baseLocation | Out-Null
}

# Helper function to validate account number(s)
function Validate-Accounts {
    param ([string]$accounts)
    if ([string]::IsNullOrWhiteSpace($accounts)) { return $true }  # Empty field is valid
    foreach ($account in $accounts.Split(',')) {
        if ($account -notmatch '^[a-zA-Z]{2}\d{6,9}/\d{2}$') {
            return $false
        }
    }
    return $true
}

# Helper function to validate MRN number(s)
function Validate-MRNs {
    param ([string]$mrns)
    if ([string]::IsNullOrWhiteSpace($mrns)) { return $true }  # Empty field is valid
    foreach ($mrn in $mrns.Split(',')) {
        if ($mrn -notmatch '^[a-zA-Z]{2}\d{8,12}$') {
            return $false
        }
    }
    return $true
}

function Validate-Date {
    param ([string]$dateString)
    if ([string]::IsNullOrWhiteSpace($dateString)) {
        return $true  # Empty dates are valid
    }

    Write-Output "Validating date: '$dateString'"

    try {
        # Try parsing with "MM/dd/yy" and "MM/dd/yyyy" formats
        $valid = [datetime]::TryParseExact(
            $dateString,
            @("MM/dd/yy", "MM/dd/yyyy"),
            $null,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$null
        )
        return $valid
    } catch {
        Write-Output "Date validation failed for: $dateString"
        return $false
    }
}


# Helper function to validate the overall query
function Validate-Query {
    # Ensure at least one of the key fields has data
    return (-not [string]::IsNullOrWhiteSpace($textBoxes[0].Text) -or -not [string]::IsNullOrWhiteSpace($textBoxes[1].Text))
}

# Create a GUI form for user input
$form = New-Object System.Windows.Forms.Form
$form.Text = "Enter Query Parameters"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false

# Updated field labels and order
$labels = @("Account(s)", "MRN(s)", "Admission Date", "Discharge Date")
$textBoxes = @()

# Dynamically adjust window size
$fieldHeight = 50
$buttonHeight = 40
$fieldWidth = 200
$verticalSpacing = 10  # Additional vertical space after the last field
$formWidth = 400
$buttonVerticalOffset = 20  # Extra spacing for buttons at the bottom
$formHeight = (($labels.Count + 2) * $fieldHeight) + $buttonHeight + $verticalSpacing + $buttonVerticalOffset + 20
$form.Size = New-Object System.Drawing.Size($formWidth, $formHeight)

for ($i = 0; $i -lt $labels.Count; $i++) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $labels[$i]
    $label.Location = New-Object System.Drawing.Point -ArgumentList 10, (($i * $fieldHeight) + 10)
    $label.Size = New-Object System.Drawing.Size -ArgumentList 150, 20
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point -ArgumentList 170, (($i * $fieldHeight) + 10)
    $textBox.Size = New-Object System.Drawing.Size -ArgumentList $fieldWidth, 20
    $form.Controls.Add($textBox)
    $textBoxes += $textBox

    # Add hints for Account, MRN, and Date fields
    $hintText = ""
    if ($labels[$i] -eq "Account(s)") {
        $hintText = "(e.g. SM012345/19, ...)"  # Hint for Account(s)
    } elseif ($labels[$i] -eq "MRN(s)") {
        $hintText = "(e.g. SM00123456, ...)"  # Hint for MRN(s)
    } elseif ($labels[$i] -match "Admission Date|Discharge Date") {
        $hintText = "(MM/DD/YY)"
    }

    if ($hintText) {
        $hintLabel = New-Object System.Windows.Forms.Label
        $hintLabel.Text = $hintText
        $hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(169, 169, 169)  # Grey color
        $hintLabel.Location = New-Object System.Drawing.Point -ArgumentList 170, (($i * $fieldHeight) + 35)
        $hintLabel.Size = New-Object System.Drawing.Size -ArgumentList $fieldWidth, 15
        $form.Controls.Add($hintLabel)
    }

    # Attach dynamic validation to each text box
    $textBox.Add_TextChanged({
        $runButton.Enabled = Validate-Query
    })
}

# Add Destination Folder field
$destinationLabel = New-Object System.Windows.Forms.Label
$destinationLabel.Text = "Destination Folder"
$destinationLabel.Location = New-Object System.Drawing.Point -ArgumentList 10, (($labels.Count * $fieldHeight) + 10)
$destinationLabel.Size = New-Object System.Drawing.Size -ArgumentList 150, 20
$form.Controls.Add($destinationLabel)

$destinationTextBox = New-Object System.Windows.Forms.TextBox
$destinationTextBox.Location = New-Object System.Drawing.Point -ArgumentList 170, (($labels.Count * $fieldHeight) + 10)
$destinationTextBox.Size = New-Object System.Drawing.Size -ArgumentList $fieldWidth, 20
$destinationTextBox.Text = $baseLocation
$form.Controls.Add($destinationTextBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Location = New-Object System.Drawing.Point -ArgumentList 170, (($labels.Count * $fieldHeight) + 40)
$browseButton.Size = New-Object System.Drawing.Size -ArgumentList 60, 20
$browseButton.Add_Click({
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $destinationTextBox.Text = $folderBrowser.SelectedPath
    }
})
$form.Controls.Add($browseButton)

# Add Run and Close buttons
$buttonWidth = 100

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run"
$runButton.Location = New-Object System.Drawing.Point -ArgumentList 10, ($formHeight - $buttonHeight - $buttonVerticalOffset - 20)
$runButton.Size = New-Object System.Drawing.Size -ArgumentList $buttonWidth, 30
$runButton.Enabled = $false  # Initially disabled
$runButton.Add_Click({
    if (-not (Validate-Accounts $textBoxes[0].Text)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid account number. Please enter a valid account number.", "Error")
    } elseif (-not (Validate-MRNs $textBoxes[1].Text)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid MRN number. Please enter a valid MRN number.", "Error")
    } elseif (-not (Validate-Date $textBoxes[2].Text) -or -not (Validate-Date $textBoxes[3].Text)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid date. Please enter a valid date in MM/DD/YY format.", "Error")
    } else {
        $form.Tag = "Run"
        $form.Close()
    }
})
$form.Controls.Add($runButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
# Align right edge of Close button with right edge of fields
$closeButton.Location = New-Object System.Drawing.Point -ArgumentList ($formWidth - 30 - $buttonWidth), ($formHeight - $buttonHeight - $buttonVerticalOffset - 20)
$closeButton.Size = New-Object System.Drawing.Size -ArgumentList $buttonWidth, 30
$closeButton.Add_Click({
    # Close immediately without requiring validation
    $form.Tag = "Close"
    $form.Close()
})
$form.Controls.Add($closeButton)

$form.ShowDialog()

# Check if the form was closed without running
if ($form.Tag -ne "Run") {
    exit
}

# Capture user inputs
$params = @{
    Account = $textBoxes[0].Text
    MRN = $textBoxes[1].Text
    AdmissionDate = $textBoxes[2].Text
    DischargeDate = $textBoxes[3].Text
    DestinationFolder = $destinationTextBox.Text
}

# Construct folder name dynamically based on user inputs
$cleanAccount = if ($params.Account) { "_s" + ($params.Account -replace '[^\w]', '_') } else { "" }
$cleanMRN = if ($params.MRN) { "_m" + ($params.MRN -replace '[^\w]', '_') } else { "" }
$cleanAdmission = if ($params.AdmissionDate) { "_a" + ($params.AdmissionDate -replace '[^\w]', '_') } else { "" }
$cleanDischarge = if ($params.DischargeDate) { "_d" + ($params.DischargeDate -replace '[^\w]', '_') } else { "" }

$folderName = "olrx_scans"
$folderParts = @($cleanAccount, $cleanMRN, $cleanAdmission, $cleanDischarge) | Where-Object { $_ -ne "" }
if ($folderParts.Count -gt 0) {
    $folderName += "_" + ($folderParts -join "_")
}

$finalDestination = Join-Path -Path $baseLocation -ChildPath $folderName

# Ensure destination folder exists
if (-not (Test-Path $finalDestination)) {
    New-Item -ItemType Directory -Path $finalDestination | Out-Null
}

# Build WHERE clause for SQLite query
$whereClause = "1=1"
if ($params.Account) { $whereClause += " AND Account LIKE '%$($params.Account)%'" }
if ($params.MRN) { $whereClause += " AND MRN LIKE '%$($params.MRN)%'" }
if ($params.AdmissionDate) { $whereClause += " AND AdmissionDate LIKE '%$($params.AdmissionDate)%'" }
if ($params.DischargeDate) { $whereClause += " AND DischargeDate LIKE '%$($params.DischargeDate)%'" }

# Build and execute query
$query = "SELECT PdfPath FROM $tableName WHERE $whereClause"
Write-Output "Executing query: $query"

try {
    $queryResult = & $sqlite3Path $databasePath $query
    if ($queryResult) {
        Write-Output "Query results: $queryResult"
    } else {
        Write-Output "No matching results found."
        [System.Windows.Forms.MessageBox]::Show("No matching results found.", "No Matches")
        exit
    }
} catch {
    Write-Output "Error executing query: $_"
    [System.Windows.Forms.MessageBox]::Show("An error occurred while executing the query: $_", "Error")
    exit
}

# Copy matching files to the final destination folder
foreach ($filePath in $queryResult) {
    if (Test-Path $filePath) {
        Copy-Item -Path $filePath -Destination $finalDestination -Force
        Write-Output "Copied file: $filePath"
    } else {
        Write-Output "File not found: $filePath"
    }
}

[System.Windows.Forms.MessageBox]::Show("Files copied to: $finalDestination", "Success")
