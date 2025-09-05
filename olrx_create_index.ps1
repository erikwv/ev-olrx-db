# Load Windows Forms Assembly
Add-Type -AssemblyName System.Windows.Forms

# Function for binary-safe text extraction
function Get-BinaryText {
    Param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateScript( { Test-Path $_ -PathType Leaf } )]
        [Alias('FullName','FilePath')]
        [string]$Path
    )

    Write-Output $Path
    $Stream = New-Object System.IO.FileStream -ArgumentList $Path, 'Open', 'Read'

    # Note: Codepage 28591 returns a 1-to-1 char to byte mapping
    $Encoding     = [Text.Encoding]::GetEncoding(28591)
    $StreamReader = New-Object System.IO.StreamReader -ArgumentList $Stream, $Encoding
    $BinaryText   = $StreamReader.ReadToEnd()

    $Stream.Dispose()
    $StreamReader.Dispose()

    return $BinaryText
}

# Function to prompt user with a folder selection dialog
function Select-Folder {
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select the folder containing the PDF files:"
    $folderBrowser.ShowNewFolderButton = $false

    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    } else {
        return $null
    }
}

# Function to prompt user with a folder selection dialog for destination
function Select-DestinationFolder {
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select the destination folder to save the CSV and log files:"
    $folderBrowser.ShowNewFolderButton = $true

    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    } else {
        return $null
    }
}

# Remaining script logic goes here...
# Load Windows Forms Assembly
Add-Type -AssemblyName System.Windows.Forms

# Function for binary-safe text extraction
function Get-BinaryText {
    Param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateScript( { Test-Path $_ -PathType Leaf } )]
        [Alias('FullName','FilePath')]
        [string]$Path
    )

    Write-Output $Path
    $Stream = New-Object System.IO.FileStream -ArgumentList $Path, 'Open', 'Read'

    # Note: Codepage 28591 returns a 1-to-1 char to byte mapping
    $Encoding     = [Text.Encoding]::GetEncoding(28591)
    $StreamReader = New-Object System.IO.StreamReader -ArgumentList $Stream, $Encoding
    $BinaryText   = $StreamReader.ReadToEnd()

    $Stream.Dispose()
    $StreamReader.Dispose()

    return $BinaryText
}

# Function to prompt user with a folder selection dialog
function Select-Folder {
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select the folder containing the PDF files:"
    $folderBrowser.ShowNewFolderButton = $false

    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    } else {
        return $null
    }
}

# Function to prompt user with a folder selection dialog for destination
function Select-DestinationFolder {
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select the destination folder to save the CSV and log files:"
    $folderBrowser.ShowNewFolderButton = $true

    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    } else {
        return $null
    }
}

# Remaining script logic goes here...


# Prompt user to select the source folder
$folder_path = Select-Folder

# Validate the folder selection
if (-not $folder_path) {
    Write-Host "No folder was selected. Exiting script." -ForegroundColor Yellow
    exit
}

# Prompt user to select the destination folder for CSV and log files
$destination_folder = Select-DestinationFolder

# Validate the folder selection
if (-not $destination_folder) {
    Write-Host "No destination folder was selected. Exiting script." -ForegroundColor Yellow
    exit
}

# Extract the parent folder name (FHA Archive 2020)
$parent_folder_name = Split-Path -Leaf $folder_path
$timestamp = (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")

# Dynamically construct CSV and log file paths based on the parent folder
$csv_file = Join-Path -Path $destination_folder -ChildPath "olrx_doc_index_${parent_folder_name}_${timestamp}.csv"
$error_log_file = Join-Path -Path $destination_folder -ChildPath "olrx_doc_index_${parent_folder_name}_${timestamp}.log"

# Log the start of the process
Add-Content -Path $error_log_file -Value "Processing started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Content -Path $error_log_file -Value "Selected folder: $folder_path"

# Define the regex for extracting visit details
$regex_visit_details = [regex]'(?s)Last Name.*?: (.*?)\).*?First Name.*?: (.*?)\).*?MRN\/Unit#.*?: (.*?)\).*?Account#.*?: (.*?)\).*?Admit Date.*?: (.*?)\).*?Discharge Date.*?: (.*?)\)'

# Start the timer
$start_time = Get-Date

# Initialize counters for logging
$total_files = 0
$successful_extractions = 0
$failed_extractions = 0

# Check if the CSV file already exists, and if not, add the headers
if (-not (Test-Path -Path $csv_file)) {
    $csv_headers = "PdfPath,LastName,FirstName,MRN,Account,AdmissionDate,DischargeDate"
    Add-Content -Path $csv_file -Value $csv_headers
}

# Process files in the specified folder
Get-ChildItem -Path $folder_path -Recurse -Filter *.pdf | ForEach-Object {

    $pdf_path = $_.FullName
    $pdf_text = Get-BinaryText($pdf_path)

    $regex_visit_data_start = [regex]"Associated Patient"
      
    $found_visit_data = $regex_visit_data_start.Match($pdf_text)

    $total_files++

    if ($found_visit_data.Success) {
        $visit_string = $pdf_text[1].Substring($found_visit_data.Index, 500)
           
        $found_visit_details = $regex_visit_details.Match($visit_string)
        $last_name = $found_visit_details.Groups[1].Value
        $first_name = $found_visit_details.Groups[2].Value
        $mrn = $found_visit_details.Groups[3].Value
        $account = $found_visit_details.Groups[4].Value
        $admit_date = $found_visit_details.Groups[5].Value
        $discharge_date = $found_visit_details.Groups[6].Value

        $output = "$pdf_path,$first_name,$last_name,$mrn,$account,$admit_date,$discharge_date"
        Write-Output $output
        Add-Content -Path $csv_file -Value $output

        $successful_extractions++
    } else {
        $error_message = "Not found in $pdf_path"
        Write-Output $error_message
        Add-Content -Path $error_log_file -Value $error_message

        $failed_extractions++
    }
}

# Calculate total processing time
$end_time = Get-Date
$total_time = $end_time - $start_time

# Log the completion of the process
Add-Content -Path $error_log_file -Value "Processing completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Content -Path $error_log_file -Value "Total processing time: $($total_time.TotalMinutes) minutes ($($total_time.TotalSeconds) seconds)"
Add-Content -Path $error_log_file -Value "Total PDFs processed: $total_files"
Add-Content -Path $error_log_file -Value "Successful extractions: $successful_extractions"
Add-Content -Path $error_log_file -Value "Failed extractions: $failed_extractions"

# Display results on the screen
Write-Host "Processing complete!" -ForegroundColor Green
Write-Host "CSV file saved to: $csv_file" -ForegroundColor Cyan
Write-Host "Error log saved to: $error_log_file" -ForegroundColor Cyan
Write-Host "Total processing time: $($total_time.TotalMinutes) minutes ($($total_time.TotalSeconds) seconds)" -ForegroundColor Yellow
Write-Host "Total PDFs processed: $total_files" -ForegroundColor Yellow
Write-Host "Successful extractions: $successful_extractions" -ForegroundColor Green
Write-Host "Failed extractions: $failed_extractions" -ForegroundColor Red

# Function for binary-safe text extraction
function Get-BinaryText {
    Param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateScript( { Test-Path $_ -PathType Leaf } )]
        [Alias('FullName','FilePath')]
        [string]$Path
    )

    Write-Output $Path
    $Stream = New-Object System.IO.FileStream -ArgumentList $Path, 'Open', 'Read'

    # Note: Codepage 28591 returns a 1-to-1 char to byte mapping
    $Encoding     = [Text.Encoding]::GetEncoding(28591)
    $StreamReader = New-Object System.IO.StreamReader -ArgumentList $Stream, $Encoding
    $BinaryText   = $StreamReader.ReadToEnd()

    $Stream.Dispose()
    $StreamReader.Dispose()

    return $BinaryText
}