# OLRX Database System

A comprehensive PowerShell-based system for indexing PDF documents and extracting patient information for medical record management. The system provides binary-safe PDF text extraction, SQLite database storage, and advanced search capabilities.

## Overview

The OLRX Database System consists of four main components:

1. **Database Initialization** - Sets up the SQLite database schema
2. **PDF Indexing** - Extracts patient data from PDF files and stores in database
3. **Search & Copy** - Searches the database and copies matching PDF files
4. **Maintenance** - Routine database maintenance and optimization

## Features

- **Binary-safe PDF text extraction** using ISO-8859-1 encoding
- **Incremental indexing** - only processes new or changed files
- **Advanced search** with multiple criteria (MRN, Account, Name, Dates)
- **File integrity tracking** with SHA-256 hashing
- **Comprehensive logging** of all operations
- **Database optimization** and maintenance tools
- **GUI interfaces** for user-friendly operation
- **Automatic folder organization** for search results

## System Requirements

- Windows PowerShell 5.1 or PowerShell Core 6+
- SQLite3 command-line tool
- Windows Forms (for GUI components)
- Sufficient disk space for database and copied files

## Installation

### 1. Install SQLite3

Download and install SQLite3 from [sqlite.org](https://www.sqlite.org/download.html):

```powershell
# Create SQLite directory (default location)
New-Item -ItemType Directory -Path "C:\sqlite3" -Force

# Download sqlite3.exe and place it in C:\sqlite3\
# Or update the $Sqlite3Path variable in scripts to match your installation
```

### 2. Prepare Directory Structure

```powershell
# Default paths (can be customized in scripts)
$DatabasePath = "F:\olrx_scan.db"          # SQLite database location
$BaseLocation = "F:\MRN_matches"            # Default search results location
```

### 3. Initialize Database

Run the database initialization script:

```powershell
.\init_database.ps1
```

Optional parameters:
```powershell
.\init_database.ps1 -DatabasePath "C:\MyPath\olrx.db" -Sqlite3Path "C:\sqlite3\sqlite3.exe"
```

## Usage

### Initial Setup Workflow

1. **Initialize Database**
   ```powershell
   .\init_database.ps1
   ```

2. **Index PDF Files**
   ```powershell
   .\olrx_index_to_database.ps1 -FolderPath "C:\Path\To\PDFs"
   ```

3. **Search and Copy Files**
   ```powershell
   .\olrx_search_and_copy_enhanced.ps1
   ```

### PDF Indexing

The indexing script extracts patient information from PDF files and stores it in the database.

#### Basic Usage
```powershell
# Interactive mode (GUI folder selection)
.\olrx_index_to_database.ps1

# Command line mode
.\olrx_index_to_database.ps1 -FolderPath "C:\PDFs\Archive2023"

# Force reindex of all files
.\olrx_index_to_database.ps1 -FolderPath "C:\PDFs" -ForceReindex

# Non-recursive (current folder only)
.\olrx_index_to_database.ps1 -FolderPath "C:\PDFs" -Recursive:$false
```

#### What it extracts:
- Last Name
- First Name  
- MRN (Medical Record Number)
- Account Number
- Admission Date
- Discharge Date
- File metadata (size, hash, modification date)

#### Incremental Processing
The system automatically detects:
- New files (not in database)
- Modified files (different hash)
- Files that need reprocessing

Only changed files are processed, making routine updates very fast.

### Searching and Copying

The enhanced search script provides a GUI interface for finding and copying files.

#### Features:
- **Multiple search criteria** (can combine any/all)
- **Partial matching** for names
- **Pattern validation** for MRN/Account numbers
- **Date range searching**
- **Automatic folder organization**
- **CSV export** of results

#### Search Patterns:
- **Account Numbers**: `SM012345/19` (2 letters + 6-9 digits + / + 2 digits)
- **MRN Numbers**: `SM00123456` (2 letters + 8-12 digits)  
- **Dates**: `MM/DD/YY` or `MM/DD/YYYY`
- **Names**: Partial matching supported

#### Example Searches:
```powershell
# Interactive GUI mode
.\olrx_search_and_copy_enhanced.ps1

# Different database/paths
.\olrx_search_and_copy_enhanced.ps1 -DatabasePath "C:\MyDB.db" -BaseLocation "C:\Results"
```

### Database Maintenance

Regular maintenance keeps the database optimized and clean.

#### Basic Maintenance:
```powershell
# Show database statistics
.\olrx_maintenance.ps1 -ShowStats

# Remove orphaned records (files no longer exist)
.\olrx_maintenance.ps1 -CleanupOrphans

# Optimize database (vacuum, analyze, reindex)
.\olrx_maintenance.ps1 -Vacuum

# Full maintenance (all operations)
.\olrx_maintenance.ps1 -FullMaintenance
```

#### Recommended Schedule:
- **Daily**: `-ShowStats` (check system health)
- **Weekly**: `-CleanupOrphans` (remove orphaned records)
- **Monthly**: `-FullMaintenance` (complete optimization)

## Database Schema

### OLRXScans Table
| Column | Type | Description |
|--------|------|--------------|
| id | INTEGER | Primary key (auto-increment) |
| pdf_path | TEXT | Full path to PDF file |
| file_name | TEXT | File name only |
| file_size | INTEGER | File size in bytes |
| last_modified | DATETIME | File modification timestamp |
| last_name | TEXT | Extracted patient last name |
| first_name | TEXT | Extracted patient first name |
| mrn | TEXT | Medical record number |
| account | TEXT | Account number |
| admission_date | TEXT | Patient admission date |
| discharge_date | TEXT | Patient discharge date |
| extraction_success | INTEGER | 1 if data extracted successfully, 0 if failed |
| date_indexed | DATETIME | When record was added/updated |
| file_hash | TEXT | SHA-256 hash for change detection |

### Processing Log Table
| Column | Type | Description |
|--------|------|--------------|
| id | INTEGER | Primary key |
| operation_type | TEXT | Type of operation (INDEX, SEARCH, CLEANUP, etc.) |
| files_processed | INTEGER | Number of files processed |
| files_successful | INTEGER | Number of successful operations |
| files_failed | INTEGER | Number of failed operations |
| start_time | DATETIME | Operation start time |
| end_time | DATETIME | Operation end time |
| notes | TEXT | Additional operation details |

## File Organization

### Project Structure
```
ev-olrx-db/
├── README.md                           # This documentation
├── init_database.ps1                   # Database initialization
├── olrx_index_to_database.ps1         # PDF indexing (improved version)
├── olrx_search_and_copy_enhanced.ps1  # Search and copy (enhanced version)
├── olrx_maintenance.ps1               # Database maintenance
├── olrx_create_index.ps1              # Original indexing script (legacy)
└── olrx_search_and_copy_v18.ps1       # Original search script (legacy)
```

## Quick Start Guide

### For New Users:

1. **Setup** (one-time):
   ```powershell
   # Initialize database
   .\init_database.ps1
   ```

2. **Index your PDFs** (run whenever you have new files):
   ```powershell
   .\olrx_index_to_database.ps1
   ```

3. **Search and copy files**:
   ```powershell
   .\olrx_search_and_copy_enhanced.ps1
   ```

4. **Maintenance** (run weekly):
   ```powershell
   .\olrx_maintenance.ps1 -ShowStats -CleanupOrphans
   ```

### Key Benefits:

- **Fast incremental updates**: Only new/changed files are processed
- **Reliable search**: Multiple criteria, partial matching, validation
- **Self-maintaining**: Automated cleanup and optimization
- **Scalable**: Handles thousands to millions of documents
- **User-friendly**: GUI interfaces for all operations

## Troubleshooting

### Common Issues:

1. **"sqlite3 not found"**: Install SQLite3 and update paths
2. **"Database not found"**: Run `init_database.ps1` first
3. **No data extracted**: Check PDF format and "Associated Patient" marker
4. **Slow performance**: Run `olrx_maintenance.ps1 -Vacuum`

### Support:

For detailed troubleshooting, configuration options, and advanced usage, see the full sections in this README above.

## License

This project is for internal use in medical record management systems. Ensure compliance with HIPAA and other healthcare data regulations when handling patient information.
