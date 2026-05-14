# OLRX Database System

OLRX is a Python-based PDF indexing and retrieval workflow backed by SQLite.
The repository now contains a single supported implementation: the Python app
that can search, copy, and incrementally update the database, and can also be
packaged as a standalone Windows executable.

## Repo Layout

```text
ev-olrx-db/
├── README.md
├── docs/
│   └── olrx_search_workflow.md
└── python/
    ├── olrx_search_and_copy.py
    ├── build_olrx_search_and_copy.ps1
    └── requirements-build.txt
```

## Python App

The `python/` directory contains the supported implementation:

- Built-in `sqlite3` instead of `sqlite3.exe`
- GUI mode and CLI mode
- Incremental database indexing
- Manual update trigger based on the age of the last index run
- Search and copy workflow
- Safe CSV output
- In-app activity log plus persistent file logging
- Packaged as a single Windows `.exe`

Primary files:

- [olrx_search_and_copy.py](/Users/erik/Projects/ev-olrx-db/python/olrx_search_and_copy.py:1)
- [build_olrx_search_and_copy.ps1](/Users/erik/Projects/ev-olrx-db/python/build_olrx_search_and_copy.ps1:1)
- [requirements-build.txt](/Users/erik/Projects/ev-olrx-db/python/requirements-build.txt:1)

## Usage

Run directly with Python:

```powershell
python .\python\olrx_search_and_copy.py
```

Run a search from the CLI:

```powershell
python .\python\olrx_search_and_copy.py --no-gui --mrn SM00123456 --last-name Smith
```

Run an incremental database update:

```powershell
python .\python\olrx_search_and_copy.py --no-gui --update-db --source-folder "C:\Path\To\PDFs"
```

The default source folder in the app is `F:\`, and indexing runs recursively, so PDFs stored
under archive paths such as `F:\FHA Archive 2023\2023.12.31_0` are included automatically.

Force a full reprocess if needed:

```powershell
python .\python\olrx_search_and_copy.py --no-gui --update-db --force-reindex --source-folder "C:\Path\To\PDFs"
```

## Windows EXE Build

Build the standalone executable on a Windows machine with Python installed:

```powershell
.\python\build_olrx_search_and_copy.ps1
```

Build output:

```text
python\dist\OLRXSearchAndCopy.exe
```

Deploy that EXE to the client machine. The client does not need Python installed.

## GUI Features

- `Search & Copy` for retrieval
- `Update DB` for manual incremental indexing
- `DB Status` to show record counts, last index run, and whether the age threshold has been exceeded
- In-app activity log for long-running operations

The app also writes a persistent log file at `python\olrx_app.log` during script use, or beside
the built EXE after packaging.

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
