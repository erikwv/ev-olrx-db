# OLRX Database System

OLRX is a PDF indexing and retrieval workflow backed by SQLite. This repository now separates
the legacy PowerShell implementation from the newer Python search/copy implementation that can
be packaged as a standalone Windows executable.

## Repo Layout

```text
ev-olrx-db/
├── README.md
├── docs/
│   └── olrx_search_workflow.md
├── powershell/
│   ├── init_database.ps1
│   ├── olrx_index_to_database.ps1
│   ├── olrx_search_and_copy_enhanced.ps1
│   ├── olrx_maintenance.ps1
│   └── ...legacy and repair scripts...
└── python/
    ├── olrx_search_and_copy.py
    ├── build_olrx_search_and_copy.ps1
    └── requirements-build.txt
```

## PowerShell

The `powershell/` directory contains the original operational scripts for database setup,
indexing, search/copy, maintenance, repair, and legacy variants.

Primary entry points:

- [init_database.ps1](/Users/erik/Projects/ev-olrx-db/powershell/init_database.ps1:1)
- [olrx_index_to_database.ps1](/Users/erik/Projects/ev-olrx-db/powershell/olrx_index_to_database.ps1:1)
- [olrx_search_and_copy_enhanced.ps1](/Users/erik/Projects/ev-olrx-db/powershell/olrx_search_and_copy_enhanced.ps1:1)
- [olrx_maintenance.ps1](/Users/erik/Projects/ev-olrx-db/powershell/olrx_maintenance.ps1:1)

Typical usage:

```powershell
.\powershell\init_database.ps1
.\powershell\olrx_index_to_database.ps1 -FolderPath "C:\Path\To\PDFs"
.\powershell\olrx_search_and_copy_enhanced.ps1
```

Operational assumptions:

- Windows PowerShell 5.1 or PowerShell Core
- `sqlite3.exe` installed on the machine
- Windows Forms available for GUI flows

## Python

The `python/` directory contains the improved search/copy implementation:

- Built-in `sqlite3` instead of `sqlite3.exe`
- Parameterized SQL queries
- GUI mode and CLI mode
- Safe CSV output
- Unique filenames for copied duplicates
- Incremental database indexing from the app
- Manual update trigger based on the age of the last index run
- Packaged as a single Windows `.exe`

Primary files:

- [olrx_search_and_copy.py](/Users/erik/Projects/ev-olrx-db/python/olrx_search_and_copy.py:1)
- [build_olrx_search_and_copy.ps1](/Users/erik/Projects/ev-olrx-db/python/build_olrx_search_and_copy.ps1:1)
- [requirements-build.txt](/Users/erik/Projects/ev-olrx-db/python/requirements-build.txt:1)

Run directly with Python:

```powershell
python .\python\olrx_search_and_copy.py
```

CLI mode:

```powershell
python .\python\olrx_search_and_copy.py --no-gui --mrn SM00123456 --last-name Smith
```

Run an incremental database update from the same app:

```powershell
python .\python\olrx_search_and_copy.py --no-gui --update-db --source-folder "C:\Path\To\PDFs"
```

Force a full reprocess if needed:

```powershell
python .\python\olrx_search_and_copy.py --no-gui --update-db --force-reindex --source-folder "C:\Path\To\PDFs"
```

Build the standalone EXE:

```powershell
.\python\build_olrx_search_and_copy.ps1
```

Build output:

```text
python\dist\OLRXSearchAndCopy.exe
```

Deploy that EXE to the server. The server does not need Python installed.

The GUI now includes:

- `Search & Copy` for retrieval
- `Update DB` for manual incremental indexing
- `DB Status` to show record counts, last index run, and whether the 180-day threshold has been exceeded
- An in-app activity log so long-running operations are visible while they run
- A persistent log file at `python\olrx_app.log` during script use or beside the built EXE after packaging

During CLI database updates, progress messages are written to stdout so you can monitor scan volume,
processed files, skipped files, and failures while the update is running.

## Workflow Diagram

The Mermaid workflow diagram is checked in here:

- [olrx_search_workflow.md](/Users/erik/Projects/ev-olrx-db/docs/olrx_search_workflow.md:1)

## Database Schema

### OLRXScans

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| pdf_path | TEXT | Full path to PDF file |
| file_name | TEXT | File name only |
| file_size | INTEGER | File size in bytes |
| last_modified | DATETIME | File modification timestamp |
| last_name | TEXT | Extracted patient last name |
| first_name | TEXT | Extracted patient first name |
| mrn | TEXT | Medical record number |
| account | TEXT | Account number |
| admission_date | TEXT | Admission date |
| discharge_date | TEXT | Discharge date |
| extraction_success | INTEGER | Extraction status flag |
| date_indexed | DATETIME | Index/update timestamp |
| file_hash | TEXT | SHA-256 hash |

### processing_log

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| operation_type | TEXT | Operation type |
| files_processed | INTEGER | Files processed |
| files_successful | INTEGER | Successful operations |
| files_failed | INTEGER | Failed operations |
| start_time | DATETIME | Start time |
| end_time | DATETIME | End time |
| notes | TEXT | Extra details |
