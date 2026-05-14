#!/usr/bin/env python3
"""
OLRX database search, copy, and incremental indexing utility.

This script replaces the PowerShell search/copy workflow with a Python
implementation that can be packaged into a standalone Windows executable.
It uses the Python standard library only, so the final EXE does not need
Python or sqlite3.exe installed on the target server.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import logging
import re
import shutil
import sqlite3
import sys
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from queue import Queue
from typing import Callable, Iterable

import tkinter as tk
from tkinter import filedialog, messagebox, ttk


DEFAULT_DATABASE_PATH = Path(r"C:\Omnicell\OmniLinkRx\olrx_scan.db")
DEFAULT_BASE_LOCATION = Path(r"C:\Omnicell\OmniLinkRx\MRN_matches")
DEFAULT_SOURCE_FOLDER = Path("F:\\")
DEFAULT_REBUILD_THRESHOLD_DAYS = 180
LOG_FILE_NAME = "olrx_app.log"

ACCOUNT_PATTERN = re.compile(r"^[A-Za-z]{2}\d{6,9}/\d{2}$")
MRN_PATTERN = re.compile(r"^[A-Za-z]{2}\d{8,12}$")
DATE_FORMATS = ("%m/%d/%y", "%m/%d/%Y")
SAFE_FOLDER_CHARS = re.compile(r"[^A-Za-z0-9_-]+")
VISIT_DETAILS_PATTERN = re.compile(
    r"(?s)Last Name.*?: (.*?)\).*?First Name.*?: (.*?)\).*?"
    r"MRN\/Unit#.*?: (.*?)\).*?Account#.*?: (.*?)\).*?"
    r"Admit Date.*?: (.*?)\).*?Discharge Date.*?: (.*?)\)"
)

SCHEMA_STATEMENTS = (
    """
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
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS processing_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        operation_type TEXT NOT NULL,
        files_processed INTEGER DEFAULT 0,
        files_successful INTEGER DEFAULT 0,
        files_failed INTEGER DEFAULT 0,
        start_time DATETIME,
        end_time DATETIME,
        notes TEXT
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_mrn ON OLRXScans(mrn)",
    "CREATE INDEX IF NOT EXISTS idx_account ON OLRXScans(account)",
    "CREATE INDEX IF NOT EXISTS idx_last_name ON OLRXScans(last_name)",
    "CREATE INDEX IF NOT EXISTS idx_admission_date ON OLRXScans(admission_date)",
    "CREATE INDEX IF NOT EXISTS idx_discharge_date ON OLRXScans(discharge_date)",
    "CREATE INDEX IF NOT EXISTS idx_file_hash ON OLRXScans(file_hash)",
    "CREATE INDEX IF NOT EXISTS idx_date_indexed ON OLRXScans(date_indexed)",
)


@dataclass(frozen=True)
class SearchCriteria:
    account: str = ""
    mrn: str = ""
    last_name: str = ""
    first_name: str = ""
    admission_date: str = ""
    discharge_date: str = ""
    destination_folder: Path = DEFAULT_BASE_LOCATION

    def has_search_terms(self) -> bool:
        return any(
            (
                self.account,
                self.mrn,
                self.last_name,
                self.first_name,
                self.admission_date,
                self.discharge_date,
            )
        )


@dataclass(frozen=True)
class SearchResult:
    pdf_path: str
    file_name: str
    last_name: str
    first_name: str
    mrn: str
    account: str


@dataclass(frozen=True)
class SearchSummary:
    output_folder: Path
    csv_path: Path
    matched_count: int
    copied_count: int
    failed_count: int


@dataclass(frozen=True)
class PatientData:
    success: bool
    last_name: str = ""
    first_name: str = ""
    mrn: str = ""
    account: str = ""
    admission_date: str = ""
    discharge_date: str = ""


@dataclass(frozen=True)
class IndexSummary:
    source_folder: Path
    total_files: int
    processed_files: int
    skipped_files: int
    successful_extractions: int
    failed_extractions: int
    duration_seconds: float


@dataclass(frozen=True)
class DatabaseStatus:
    exists: bool
    total_records: int
    successful_extractions: int
    recent_records: int
    last_index_time: datetime | None
    last_index_age_days: int | None
    update_due: bool
    database_path: Path


def runtime_directory() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def configure_logging() -> Path:
    log_path = runtime_directory() / LOG_FILE_NAME
    root_logger = logging.getLogger()
    root_logger.setLevel(logging.INFO)
    if not any(
        isinstance(handler, logging.FileHandler) and Path(handler.baseFilename) == log_path
        for handler in root_logger.handlers
    ):
        file_handler = logging.FileHandler(log_path, encoding="utf-8")
        file_handler.setFormatter(
            logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
        )
        root_logger.addHandler(file_handler)
    return log_path


LOG_PATH = configure_logging()


def split_csv_input(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]


def validate_accounts(value: str) -> None:
    invalid = [item for item in split_csv_input(value) if not ACCOUNT_PATTERN.fullmatch(item)]
    if invalid:
        raise ValueError(
            "Invalid account format. Use values like AB123456/19 separated by commas."
        )


def validate_mrns(value: str) -> None:
    invalid = [item for item in split_csv_input(value) if not MRN_PATTERN.fullmatch(item)]
    if invalid:
        raise ValueError("Invalid MRN format. Use values like AB12345678 separated by commas.")


def validate_date(value: str) -> None:
    if not value:
        return
    for fmt in DATE_FORMATS:
        try:
            datetime.strptime(value, fmt)
            return
        except ValueError:
            continue
    raise ValueError("Invalid date format. Use MM/DD/YY or MM/DD/YYYY.")


def validate_criteria(criteria: SearchCriteria) -> None:
    if not criteria.has_search_terms():
        raise ValueError("Enter at least one search criterion before running a search.")
    validate_accounts(criteria.account)
    validate_mrns(criteria.mrn)
    validate_date(criteria.admission_date)
    validate_date(criteria.discharge_date)


def sanitize_folder_value(value: str, prefix: str) -> str | None:
    if not value:
        return None
    cleaned = SAFE_FOLDER_CHARS.sub("_", value.strip()).strip("_")
    if not cleaned:
        return None
    return f"{prefix}_{cleaned[:40]}"


def build_output_folder(base_folder: Path, criteria: SearchCriteria) -> Path:
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    parts = [
        sanitize_folder_value(criteria.account, "acc"),
        sanitize_folder_value(criteria.mrn, "mrn"),
        sanitize_folder_value(criteria.last_name, "ln"),
        sanitize_folder_value(criteria.first_name, "fn"),
        sanitize_folder_value(criteria.admission_date, "ad"),
        sanitize_folder_value(criteria.discharge_date, "dd"),
    ]
    suffix = "_".join(part for part in parts if part)
    folder_name = f"olrx_search_{timestamp}" if not suffix else f"olrx_search_{timestamp}_{suffix}"
    return base_folder / folder_name


def parse_db_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None


def get_connection(database_path: Path, create_if_missing: bool = False) -> sqlite3.Connection:
    if not create_if_missing and not database_path.exists():
        raise FileNotFoundError(f"Database not found: {database_path}")
    database_path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(database_path)
    connection.row_factory = sqlite3.Row
    return connection


def initialize_database(database_path: Path) -> None:
    with get_connection(database_path, create_if_missing=True) as connection:
        for statement in SCHEMA_STATEMENTS:
            connection.execute(statement)
        connection.commit()


def build_query(criteria: SearchCriteria) -> tuple[str, list[str]]:
    clauses: list[str] = []
    params: list[str] = []

    def add_text_filter(column: str, raw_value: str) -> None:
        values = split_csv_input(raw_value)
        if not values:
            return
        if len(values) == 1:
            clauses.append(f"{column} LIKE ?")
            params.append(f"%{values[0]}%")
            return
        inner = []
        for item in values:
            inner.append(f"{column} LIKE ?")
            params.append(f"%{item}%")
        clauses.append("(" + " OR ".join(inner) + ")")

    add_text_filter("account", criteria.account)
    add_text_filter("mrn", criteria.mrn)
    add_text_filter("last_name", criteria.last_name)
    add_text_filter("first_name", criteria.first_name)
    add_text_filter("admission_date", criteria.admission_date)
    add_text_filter("discharge_date", criteria.discharge_date)

    where_clause = " AND ".join(clauses) if clauses else "1=1"
    query = f"""
        SELECT
            pdf_path,
            file_name,
            COALESCE(last_name, '') AS last_name,
            COALESCE(first_name, '') AS first_name,
            COALESCE(mrn, '') AS mrn,
            COALESCE(account, '') AS account
        FROM OLRXScans
        WHERE {where_clause}
        ORDER BY COALESCE(last_name, ''), COALESCE(first_name, ''), file_name
    """
    return query, params


def fetch_results(connection: sqlite3.Connection, criteria: SearchCriteria) -> list[SearchResult]:
    query, params = build_query(criteria)
    rows = connection.execute(query, params).fetchall()
    return [
        SearchResult(
            pdf_path=row["pdf_path"],
            file_name=row["file_name"],
            last_name=row["last_name"],
            first_name=row["first_name"],
            mrn=row["mrn"],
            account=row["account"],
        )
        for row in rows
    ]


def log_operation(
    connection: sqlite3.Connection,
    operation_type: str,
    files_processed: int,
    files_successful: int,
    files_failed: int,
    notes: str,
) -> None:
    connection.execute(
        """
        INSERT INTO processing_log (
            operation_type,
            files_processed,
            files_successful,
            files_failed,
            start_time,
            end_time,
            notes
        ) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?)
        """,
        (operation_type, files_processed, files_successful, files_failed, notes),
    )


def log_search_operation(
    connection: sqlite3.Connection,
    criteria: SearchCriteria,
    result_count: int,
    destination_folder: Path,
) -> None:
    details = []
    for key, value in (
        ("Account", criteria.account),
        ("MRN", criteria.mrn),
        ("LastName", criteria.last_name),
        ("FirstName", criteria.first_name),
        ("AdmissionDate", criteria.admission_date),
        ("DischargeDate", criteria.discharge_date),
    ):
        if value:
            details.append(f"{key}: {value}")
    notes = f"Search: {'; '.join(details) or 'none'} | Destination: {destination_folder}"
    try:
        log_operation(connection, "SEARCH", result_count, 0, 0, notes)
        connection.commit()
    except sqlite3.DatabaseError:
        connection.rollback()


def unique_destination_path(destination_folder: Path, file_name: str) -> Path:
    candidate = destination_folder / file_name
    if not candidate.exists():
        return candidate

    stem = candidate.stem
    suffix = candidate.suffix
    counter = 2
    while True:
        alt = destination_folder / f"{stem}_{counter}{suffix}"
        if not alt.exists():
            return alt
        counter += 1


def write_csv(csv_path: Path, rows: Iterable[dict[str, str]]) -> None:
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "FilePath",
                "CopiedFile",
                "SourceFileName",
                "LastName",
                "FirstName",
                "MRN",
                "Account",
                "CopyStatus",
                "Error",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)


def run_search_and_copy(database_path: Path, criteria: SearchCriteria) -> SearchSummary:
    validate_criteria(criteria)
    criteria.destination_folder.mkdir(parents=True, exist_ok=True)
    logging.info("Starting search against %s", database_path)
    initialize_database(database_path)

    with get_connection(database_path) as connection:
        results = fetch_results(connection, criteria)
        output_folder = build_output_folder(criteria.destination_folder, criteria)
        output_folder.mkdir(parents=True, exist_ok=True)

        csv_rows: list[dict[str, str]] = []
        copied_count = 0
        failed_count = 0

        for result in results:
            source_path = Path(result.pdf_path)
            copied_name = ""
            status = "Success"
            error = ""

            try:
                if not source_path.exists():
                    raise FileNotFoundError(f"Source file not found: {source_path}")

                destination_path = unique_destination_path(output_folder, result.file_name)
                shutil.copy2(source_path, destination_path)
                copied_name = destination_path.name
                copied_count += 1
            except Exception as exc:  # pragma: no cover
                status = "Failed"
                error = str(exc)
                failed_count += 1

            csv_rows.append(
                {
                    "FilePath": result.pdf_path,
                    "CopiedFile": copied_name,
                    "SourceFileName": result.file_name,
                    "LastName": result.last_name,
                    "FirstName": result.first_name,
                    "MRN": result.mrn,
                    "Account": result.account,
                    "CopyStatus": status,
                    "Error": error,
                }
            )

        csv_path = output_folder / "search_results.csv"
        write_csv(csv_path, csv_rows)
        log_search_operation(connection, criteria, len(results), output_folder)
        logging.info(
            "Search finished: matched=%s copied=%s failed=%s output=%s",
            len(results),
            copied_count,
            failed_count,
            output_folder,
        )

    return SearchSummary(
        output_folder=output_folder,
        csv_path=csv_path,
        matched_count=len(results),
        copied_count=copied_count,
        failed_count=failed_count,
    )


def read_binary_text(path: Path) -> str:
    return path.read_text(encoding="latin-1", errors="ignore")


def file_hash_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def needs_processing(connection: sqlite3.Connection, file_path: Path, file_hash: str) -> bool:
    row = connection.execute(
        "SELECT id FROM OLRXScans WHERE pdf_path = ? AND file_hash = ?",
        (str(file_path), file_hash),
    ).fetchone()
    return row is None


def extract_patient_data(pdf_text: str) -> PatientData:
    if not pdf_text:
        return PatientData(success=False)

    marker_index = pdf_text.find("Associated Patient")
    if marker_index < 0:
        return PatientData(success=False)

    visit_chunk = pdf_text[marker_index : marker_index + 1000]
    match = VISIT_DETAILS_PATTERN.search(visit_chunk)
    if not match:
        return PatientData(success=False)

    return PatientData(
        success=True,
        last_name=match.group(1).strip(),
        first_name=match.group(2).strip(),
        mrn=match.group(3).strip(),
        account=match.group(4).strip(),
        admission_date=match.group(5).strip(),
        discharge_date=match.group(6).strip(),
    )


def upsert_database_record(
    connection: sqlite3.Connection,
    pdf_path: Path,
    file_name: str,
    file_size: int,
    last_modified: datetime,
    patient: PatientData,
    file_hash: str,
) -> None:
    update_cursor = connection.execute(
        """
        UPDATE OLRXScans SET
            file_name = ?,
            file_size = ?,
            last_modified = ?,
            last_name = ?,
            first_name = ?,
            mrn = ?,
            account = ?,
            admission_date = ?,
            discharge_date = ?,
            extraction_success = ?,
            date_indexed = CURRENT_TIMESTAMP,
            file_hash = ?
        WHERE pdf_path = ?
        """,
        (
            file_name,
            file_size,
            last_modified.strftime("%Y-%m-%d %H:%M:%S"),
            patient.last_name,
            patient.first_name,
            patient.mrn,
            patient.account,
            patient.admission_date,
            patient.discharge_date,
            int(patient.success),
            file_hash,
            str(pdf_path),
        ),
    )

    if update_cursor.rowcount:
        return

    connection.execute(
        """
        INSERT INTO OLRXScans (
            pdf_path,
            file_name,
            file_size,
            last_modified,
            last_name,
            first_name,
            mrn,
            account,
            admission_date,
            discharge_date,
            extraction_success,
            date_indexed,
            file_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?)
        """,
        (
            str(pdf_path),
            file_name,
            file_size,
            last_modified.strftime("%Y-%m-%d %H:%M:%S"),
            patient.last_name,
            patient.first_name,
            patient.mrn,
            patient.account,
            patient.admission_date,
            patient.discharge_date,
            int(patient.success),
            file_hash,
        ),
    )


def update_database_index(
    database_path: Path,
    source_folder: Path,
    recursive: bool = True,
    force_reindex: bool = False,
    progress_callback: Callable[[str], None] | None = None,
) -> IndexSummary:
    if not source_folder.exists():
        raise FileNotFoundError(f"Source folder does not exist: {source_folder}")

    logging.info(
        "Starting database update: database=%s source=%s recursive=%s force_reindex=%s",
        database_path,
        source_folder,
        recursive,
        force_reindex,
    )
    initialize_database(database_path)
    start_time = datetime.now()
    total_files = 0
    processed_files = 0
    skipped_files = 0
    successful_extractions = 0
    failed_extractions = 0

    pdf_files = (
        sorted(source_folder.rglob("*.pdf"))
        if recursive
        else sorted(source_folder.glob("*.pdf"))
    )

    with get_connection(database_path) as connection:
        for pdf_path in pdf_files:
            total_files += 1
            if progress_callback:
                progress_callback(f"Indexing {total_files}: {pdf_path}")

            try:
                stat = pdf_path.stat()
                file_hash = file_hash_sha256(pdf_path)
                if not force_reindex and not needs_processing(connection, pdf_path, file_hash):
                    skipped_files += 1
                    if progress_callback and total_files % 100 == 0:
                        progress_callback(
                            f"Scanned {total_files} PDFs | processed={processed_files} skipped={skipped_files}"
                        )
                    continue

                patient = extract_patient_data(read_binary_text(pdf_path))
                upsert_database_record(
                    connection=connection,
                    pdf_path=pdf_path,
                    file_name=pdf_path.name,
                    file_size=stat.st_size,
                    last_modified=datetime.fromtimestamp(stat.st_mtime),
                    patient=patient,
                    file_hash=file_hash,
                )
                processed_files += 1
                if patient.success:
                    successful_extractions += 1
                else:
                    failed_extractions += 1
                if progress_callback and (processed_files % 25 == 0 or total_files == len(pdf_files)):
                    progress_callback(
                        "Scanned "
                        f"{total_files}/{len(pdf_files)} PDFs | "
                        f"processed={processed_files} skipped={skipped_files} "
                        f"success={successful_extractions} failed={failed_extractions}"
                    )
            except Exception as exc:
                failed_extractions += 1
                logging.exception("Failed to process PDF: %s", pdf_path)
                if progress_callback:
                    progress_callback(
                        f"Error processing {pdf_path} | {exc} | failed={failed_extractions}"
                    )

        notes = (
            f"Source: {source_folder} | Recursive: {recursive} | ForceReindex: {force_reindex}"
        )
        log_operation(
            connection=connection,
            operation_type="INDEX",
            files_processed=total_files,
            files_successful=successful_extractions,
            files_failed=failed_extractions,
            notes=notes,
        )
        connection.commit()

    duration_seconds = (datetime.now() - start_time).total_seconds()
    logging.info(
        "Database update finished: total=%s processed=%s skipped=%s success=%s failed=%s duration=%.1fs",
        total_files,
        processed_files,
        skipped_files,
        successful_extractions,
        failed_extractions,
        duration_seconds,
    )
    return IndexSummary(
        source_folder=source_folder,
        total_files=total_files,
        processed_files=processed_files,
        skipped_files=skipped_files,
        successful_extractions=successful_extractions,
        failed_extractions=failed_extractions,
        duration_seconds=duration_seconds,
    )


def get_database_status(
    database_path: Path,
    rebuild_threshold_days: int = DEFAULT_REBUILD_THRESHOLD_DAYS,
) -> DatabaseStatus:
    if not database_path.exists():
        return DatabaseStatus(
            exists=False,
            total_records=0,
            successful_extractions=0,
            recent_records=0,
            last_index_time=None,
            last_index_age_days=None,
            update_due=True,
            database_path=database_path,
        )

    initialize_database(database_path)
    with get_connection(database_path) as connection:
        total_records = connection.execute("SELECT COUNT(*) FROM OLRXScans").fetchone()[0]
        successful_extractions = connection.execute(
            "SELECT COUNT(*) FROM OLRXScans WHERE extraction_success = 1"
        ).fetchone()[0]
        recent_records = connection.execute(
            """
            SELECT COUNT(*)
            FROM OLRXScans
            WHERE date_indexed > datetime('now', '-7 days')
            """
        ).fetchone()[0]
        last_index_row = connection.execute(
            """
            SELECT end_time
            FROM processing_log
            WHERE operation_type = 'INDEX'
            ORDER BY COALESCE(end_time, start_time) DESC
            LIMIT 1
            """
        ).fetchone()

    last_index_time = parse_db_datetime(last_index_row[0]) if last_index_row else None
    last_index_age_days = None
    update_due = True
    if last_index_time:
        last_index_age_days = max(0, (datetime.now() - last_index_time).days)
        update_due = last_index_age_days >= rebuild_threshold_days

    return DatabaseStatus(
        exists=True,
        total_records=int(total_records),
        successful_extractions=int(successful_extractions),
        recent_records=int(recent_records),
        last_index_time=last_index_time,
        last_index_age_days=last_index_age_days,
        update_due=update_due,
        database_path=database_path,
    )


def format_database_status(status: DatabaseStatus, threshold_days: int) -> str:
    lines = [
        f"Database location: {status.database_path}",
        f"Database exists: {'Yes' if status.exists else 'No'}",
        f"Total records: {status.total_records}",
        f"Successful extractions: {status.successful_extractions}",
        f"Records added in last 7 days: {status.recent_records}",
    ]
    if status.last_index_time:
        lines.append(f"Last index run: {status.last_index_time:%Y-%m-%d %H:%M:%S}")
        lines.append(f"Last index age: {status.last_index_age_days} days")
    else:
        lines.append("Last index run: never")
    lines.append(
        f"Update threshold: {threshold_days} days | Update due: {'Yes' if status.update_due else 'No'}"
    )
    return "\n".join(lines)


class OLRXSearchApp:
    def __init__(
        self,
        root: tk.Tk,
        database_path: Path,
        base_location: Path,
        source_folder: Path,
        rebuild_threshold_days: int,
    ) -> None:
        self.root = root
        self.database_path = database_path
        self.base_location = base_location
        self.rebuild_threshold_days = rebuild_threshold_days
        self.root.title("OLRX Database App")
        self.root.resizable(False, False)

        self.fields: dict[str, tk.StringVar] = {
            "account": tk.StringVar(),
            "mrn": tk.StringVar(),
            "last_name": tk.StringVar(),
            "first_name": tk.StringVar(),
            "admission_date": tk.StringVar(),
            "discharge_date": tk.StringVar(),
            "destination_folder": tk.StringVar(value=str(base_location)),
            "source_folder": tk.StringVar(value=str(source_folder)),
        }
        self.status_text = tk.StringVar(value="Ready")
        self.task_queue: Queue[tuple[str, object]] = Queue()
        self.busy = False
        self.action_buttons: list[ttk.Button] = []
        self.log_widget: tk.Text | None = None

        self._build_form()
        self._bind_state()
        self._refresh_button_state()
        self._refresh_status_banner()

    def _build_form(self) -> None:
        container = ttk.Frame(self.root, padding=14)
        container.grid(sticky="nsew")

        self.db_banner = ttk.Label(container, text="", foreground="#1f5fa9")
        self.db_banner.grid(column=0, row=0, columnspan=3, sticky="w", pady=(0, 10))

        rows = [
            ("Account(s)", "account", "Example: SM012345/19, SM012346/19"),
            ("MRN(s)", "mrn", "Example: SM00123456, SM00123457"),
            ("Last Name", "last_name", "Partial match"),
            ("First Name", "first_name", "Partial match"),
            ("Admission Date", "admission_date", "MM/DD/YY or MM/DD/YYYY"),
            ("Discharge Date", "discharge_date", "MM/DD/YY or MM/DD/YYYY"),
        ]

        current_row = 1
        for label, field_name, hint in rows:
            ttk.Label(container, text=label).grid(column=0, row=current_row, sticky="w", pady=(0, 2))
            ttk.Entry(container, textvariable=self.fields[field_name], width=42).grid(
                column=1, row=current_row, columnspan=2, sticky="ew", pady=(0, 2)
            )
            ttk.Label(container, text=hint, foreground="#666666").grid(
                column=1, row=current_row + 1, columnspan=2, sticky="w", pady=(0, 8)
            )
            current_row += 2

        ttk.Label(container, text="Destination Folder").grid(
            column=0, row=current_row, sticky="w", pady=(0, 2)
        )
        ttk.Entry(container, textvariable=self.fields["destination_folder"], width=42).grid(
            column=1, row=current_row, sticky="ew", pady=(0, 2)
        )
        browse_dest = ttk.Button(container, text="Browse", command=self._browse_destination)
        browse_dest.grid(column=2, row=current_row, sticky="ew", padx=(8, 0), pady=(0, 2))
        self.action_buttons.append(browse_dest)
        current_row += 1

        ttk.Label(container, text="PDF Source Folder").grid(
            column=0, row=current_row, sticky="w", pady=(8, 2)
        )
        ttk.Entry(container, textvariable=self.fields["source_folder"], width=42).grid(
            column=1, row=current_row, sticky="ew", pady=(8, 2)
        )
        browse_src = ttk.Button(container, text="Browse", command=self._browse_source)
        browse_src.grid(column=2, row=current_row, sticky="ew", padx=(8, 0), pady=(8, 2))
        self.action_buttons.append(browse_src)
        current_row += 1

        button_row = ttk.Frame(container)
        button_row.grid(column=0, row=current_row, columnspan=3, sticky="ew", pady=(12, 0))

        self.search_button = ttk.Button(button_row, text="Search && Copy", command=self._run_search)
        self.search_button.grid(column=0, row=0, padx=(0, 8))
        self.action_buttons.append(self.search_button)

        update_button = ttk.Button(button_row, text="Update DB", command=self._run_index_update)
        update_button.grid(column=1, row=0, padx=(0, 8))
        self.action_buttons.append(update_button)

        stats_button = ttk.Button(button_row, text="DB Status", command=self._show_stats)
        stats_button.grid(column=2, row=0, padx=(0, 8))
        self.action_buttons.append(stats_button)

        close_button = ttk.Button(button_row, text="Close", command=self.root.destroy)
        close_button.grid(column=3, row=0)
        self.action_buttons.append(close_button)

        log_frame = ttk.LabelFrame(container, text="Activity Log", padding=8)
        log_frame.grid(column=0, row=current_row + 1, columnspan=3, sticky="ew", pady=(12, 0))
        self.log_widget = tk.Text(log_frame, height=12, width=84, state="disabled")
        self.log_widget.grid(column=0, row=0, sticky="ew")
        scrollbar = ttk.Scrollbar(log_frame, orient="vertical", command=self.log_widget.yview)
        scrollbar.grid(column=1, row=0, sticky="ns")
        self.log_widget.config(yscrollcommand=scrollbar.set)

        ttk.Label(container, textvariable=self.status_text).grid(
            column=0, row=current_row + 2, columnspan=3, sticky="w", pady=(10, 0)
        )

    def _bind_state(self) -> None:
        for field_name, variable in self.fields.items():
            if field_name in {"destination_folder", "source_folder"}:
                continue
            variable.trace_add("write", lambda *_args: self._refresh_button_state())

    def _set_busy(self, busy: bool) -> None:
        self.busy = busy
        for button in self.action_buttons:
            button.state(["disabled"] if busy else ["!disabled"])
        self._refresh_button_state()

    def _refresh_button_state(self) -> None:
        has_search_terms = any(
            self.fields[name].get().strip()
            for name in (
                "account",
                "mrn",
                "last_name",
                "first_name",
                "admission_date",
                "discharge_date",
            )
        )
        if self.busy:
            self.search_button.state(["disabled"])
        else:
            self.search_button.state(["!disabled"] if has_search_terms else ["disabled"])

    def _refresh_status_banner(self) -> None:
        status = get_database_status(self.database_path, self.rebuild_threshold_days)
        if not status.exists:
            banner = f"Database: {self.database_path.name} | Not created yet | Update recommended"
        elif status.last_index_age_days is None:
            banner = f"Database: {self.database_path.name} | No index run recorded | Update recommended"
        else:
            due_text = "Update due" if status.update_due else "Current"
            banner = (
                f"Database: {self.database_path.name} | Last index age: "
                f"{status.last_index_age_days} days | {due_text}"
            )
        self.db_banner.config(text=banner)
        self._append_log(
            f"Database status refreshed | exists={status.exists} "
            f"last_index_age_days={status.last_index_age_days} due={status.update_due}"
        )

    def _append_log(self, message: str) -> None:
        timestamp = datetime.now().strftime("%H:%M:%S")
        full_message = f"[{timestamp}] {message}"
        logging.info(message)
        if self.log_widget is None:
            return
        self.log_widget.config(state="normal")
        self.log_widget.insert("end", full_message + "\n")
        self.log_widget.see("end")
        self.log_widget.config(state="disabled")

    def _browse_destination(self) -> None:
        selected = filedialog.askdirectory(
            title="Select destination folder",
            mustexist=False,
            initialdir=self.fields["destination_folder"].get() or str(self.base_location),
        )
        if selected:
            self.fields["destination_folder"].set(selected)

    def _browse_source(self) -> None:
        selected = filedialog.askdirectory(
            title="Select PDF source folder",
            mustexist=True,
            initialdir=self.fields["source_folder"].get() or str(DEFAULT_SOURCE_FOLDER),
        )
        if selected:
            self.fields["source_folder"].set(selected)

    def _criteria(self) -> SearchCriteria:
        return SearchCriteria(
            account=self.fields["account"].get().strip(),
            mrn=self.fields["mrn"].get().strip(),
            last_name=self.fields["last_name"].get().strip(),
            first_name=self.fields["first_name"].get().strip(),
            admission_date=self.fields["admission_date"].get().strip(),
            discharge_date=self.fields["discharge_date"].get().strip(),
            destination_folder=Path(self.fields["destination_folder"].get().strip() or self.base_location),
        )

    def _show_stats(self) -> None:
        try:
            status = get_database_status(self.database_path, self.rebuild_threshold_days)
        except Exception as exc:
            self._append_log(f"Failed to load database status: {exc}")
            messagebox.showerror("Error", str(exc), parent=self.root)
            return

        self._append_log("Displayed database status dialog")
        messagebox.showinfo(
            "Database Status",
            format_database_status(status, self.rebuild_threshold_days)
            + f"\nLog file: {LOG_PATH}",
            parent=self.root,
        )

    def _start_background_task(
        self,
        status_message: str,
        task: Callable[[], object],
        success_handler: Callable[[object], None],
    ) -> None:
        self.status_text.set(status_message)
        self._set_busy(True)
        self._append_log(status_message)

        def runner() -> None:
            try:
                result = task()
                self.task_queue.put(("success", (result, success_handler)))
            except Exception as exc:
                logging.exception("Background task failed")
                self.task_queue.put(("error", exc))

        threading.Thread(target=runner, daemon=True).start()
        self.root.after(150, self._poll_task_queue)

    def _poll_task_queue(self) -> None:
        try:
            kind, payload = self.task_queue.get_nowait()
        except Exception:
            if self.busy:
                self.root.after(150, self._poll_task_queue)
            return

        if kind == "progress":
            self.status_text.set(str(payload))
            self._append_log(str(payload))
            if self.busy:
                self.root.after(150, self._poll_task_queue)
            return

        self._set_busy(False)
        self.status_text.set("Ready")
        self._refresh_status_banner()

        if kind == "error":
            self._append_log(f"Operation failed: {payload}")
            messagebox.showerror("Operation Failed", str(payload), parent=self.root)
            return

        result, success_handler = payload
        success_handler(result)

    def _run_search(self) -> None:
        try:
            criteria = self._criteria()
            validate_criteria(criteria)
        except Exception as exc:
            self._append_log(f"Search validation failed: {exc}")
            messagebox.showerror("Search Failed", str(exc), parent=self.root)
            return

        self._start_background_task(
            "Searching database and copying files...",
            lambda: run_search_and_copy(self.database_path, criteria),
            self._finish_search,
        )

    def _finish_search(self, summary: SearchSummary) -> None:
        if summary.matched_count == 0:
            self._append_log("Search completed with no matches")
            messagebox.showinfo(
                "No Matches",
                "No matching results were found for the specified criteria.",
                parent=self.root,
            )
            return

        self._append_log(
            "Search completed | "
            f"matched={summary.matched_count} copied={summary.copied_count} failed={summary.failed_count}"
        )
        messagebox.showinfo(
            "Operation Complete",
            "\n".join(
                (
                    "Search and copy operation completed.",
                    "",
                    f"Files found: {summary.matched_count}",
                    f"Files copied successfully: {summary.copied_count}",
                    f"Files failed to copy: {summary.failed_count}",
                    "",
                    f"Results saved to: {summary.output_folder}",
                    f"CSV log: {summary.csv_path}",
                    f"App log: {LOG_PATH}",
                )
            ),
            parent=self.root,
        )

    def _run_index_update(self) -> None:
        source_folder = Path(self.fields["source_folder"].get().strip() or DEFAULT_SOURCE_FOLDER)
        status = get_database_status(self.database_path, self.rebuild_threshold_days)
        if status.update_due:
            prompt = (
                "The database is due for an incremental update based on the last index age.\n\n"
                f"Source folder: {source_folder}\n"
                f"Threshold: {self.rebuild_threshold_days} days\n\n"
                "Continue with incremental indexing?"
            )
        else:
            prompt = (
                "The database is newer than the update threshold.\n\n"
                f"Source folder: {source_folder}\n"
                f"Last index age: {status.last_index_age_days or 0} days\n\n"
                "Run an incremental update anyway?"
            )
        if not messagebox.askyesno("Update Database", prompt, parent=self.root):
            self._append_log("Database update cancelled by user")
            return

        self._start_background_task(
            "Updating database index...",
            lambda: update_database_index(
                self.database_path,
                source_folder=source_folder,
                progress_callback=lambda message: self.task_queue.put(("progress", message)),
            ),
            self._finish_index_update,
        )

    def _finish_index_update(self, summary: IndexSummary) -> None:
        self._append_log(
            "Database update completed | "
            f"scanned={summary.total_files} processed={summary.processed_files} "
            f"skipped={summary.skipped_files} success={summary.successful_extractions} "
            f"failed={summary.failed_extractions} duration={summary.duration_seconds:.1f}s"
        )
        messagebox.showinfo(
            "Database Update Complete",
            "\n".join(
                (
                    f"Source folder: {summary.source_folder}",
                    f"Total PDFs scanned: {summary.total_files}",
                    f"Files processed: {summary.processed_files}",
                    f"Files skipped as unchanged: {summary.skipped_files}",
                    f"Successful extractions: {summary.successful_extractions}",
                    f"Failed/no-data files: {summary.failed_extractions}",
                    f"Duration: {summary.duration_seconds:.1f} seconds",
                    f"App log: {LOG_PATH}",
                )
            ),
            parent=self.root,
        )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Search, copy, and incrementally index the OLRX SQLite database."
    )
    parser.add_argument("--database", default=str(DEFAULT_DATABASE_PATH), help="Path to olrx_scan.db")
    parser.add_argument(
        "--base-location",
        default=str(DEFAULT_BASE_LOCATION),
        help="Base folder where search result folders will be created",
    )
    parser.add_argument(
        "--source-folder",
        default=str(DEFAULT_SOURCE_FOLDER),
        help="Folder containing PDFs to index",
    )
    parser.add_argument(
        "--rebuild-threshold-days",
        type=int,
        default=DEFAULT_REBUILD_THRESHOLD_DAYS,
        help="Age threshold that marks the database as due for manual update",
    )
    parser.add_argument("--account", default="", help="One or more account values, comma-separated")
    parser.add_argument("--mrn", default="", help="One or more MRN values, comma-separated")
    parser.add_argument("--last-name", default="", help="Last name partial match")
    parser.add_argument("--first-name", default="", help="First name partial match")
    parser.add_argument("--admission-date", default="", help="Admission date")
    parser.add_argument("--discharge-date", default="", help="Discharge date")
    parser.add_argument("--no-gui", action="store_true", help="Run from the command line")
    parser.add_argument(
        "--update-db",
        action="store_true",
        help="Run incremental database indexing from the source folder",
    )
    parser.add_argument(
        "--force-reindex",
        action="store_true",
        help="Reprocess all PDFs instead of only changed files",
    )
    return parser.parse_args(argv)


def run_cli(database_path: Path, base_location: Path, source_folder: Path, args: argparse.Namespace) -> int:
    if args.update_db:
        summary = update_database_index(
            database_path=database_path,
            source_folder=source_folder,
            force_reindex=args.force_reindex,
            progress_callback=print,
        )
        print(f"Source folder: {summary.source_folder}")
        print(f"Total PDFs scanned: {summary.total_files}")
        print(f"Files processed: {summary.processed_files}")
        print(f"Files skipped as unchanged: {summary.skipped_files}")
        print(f"Successful extractions: {summary.successful_extractions}")
        print(f"Failed/no-data files: {summary.failed_extractions}")
        print(f"Duration: {summary.duration_seconds:.1f} seconds")
        return 0

    criteria = SearchCriteria(
        account=args.account.strip(),
        mrn=args.mrn.strip(),
        last_name=args.last_name.strip(),
        first_name=args.first_name.strip(),
        admission_date=args.admission_date.strip(),
        discharge_date=args.discharge_date.strip(),
        destination_folder=base_location,
    )
    summary = run_search_and_copy(database_path, criteria)

    if summary.matched_count == 0:
        print("No matching results were found.")
        print(f"Empty results folder: {summary.output_folder}")
        print(f"CSV log: {summary.csv_path}")
        return 0

    print("Search and copy operation completed.")
    print(f"Files found: {summary.matched_count}")
    print(f"Files copied successfully: {summary.copied_count}")
    print(f"Files failed to copy: {summary.failed_count}")
    print(f"Results saved to: {summary.output_folder}")
    print(f"CSV log: {summary.csv_path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    database_path = Path(args.database)
    base_location = Path(args.base_location)
    source_folder = Path(args.source_folder)

    should_use_gui = not args.no_gui and not any(
        (
            args.account,
            args.mrn,
            args.last_name,
            args.first_name,
            args.admission_date,
            args.discharge_date,
            args.update_db,
            args.force_reindex,
        )
    )

    if should_use_gui:
        root = tk.Tk()
        app = OLRXSearchApp(
            root,
            database_path=database_path,
            base_location=base_location,
            source_folder=source_folder,
            rebuild_threshold_days=args.rebuild_threshold_days,
        )
        root.mainloop()
        return 0

    try:
        return run_cli(database_path, base_location, source_folder, args)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
