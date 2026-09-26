from __future__ import annotations

import os
import shutil
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path

from server.config import settings
from server.db.session import init_db


BACKUP_INTERVAL_SECONDS = 300
MAX_BACKUPS = 20
CRITICAL = 20


def db_path() -> Path:
    return Path(settings.db_path)


def backup_dir() -> Path:
    path = Path(settings.data_dir) / "backups"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _integrity(path: Path) -> tuple[bool, list[str]]:
    if not path.exists():
        return False, ["database file does not exist"]

    errors: list[str] = []
    try:
        with sqlite3.connect(path, timeout=30) as conn:
            quick = str(conn.execute("PRAGMA quick_check").fetchone()[0])
            if quick != "ok":
                full = str(conn.execute("PRAGMA integrity_check").fetchone()[0])
                errors.append(f"quick_check={quick}")
                errors.append(f"integrity_check={full}")
            fk = conn.execute("PRAGMA foreign_key_check").fetchall()
            if fk:
                errors.append(f"foreign_key_check={len(fk)} violation(s)")
    except Exception as exc:
        errors.append(f"sqlite={exc}")

    return not errors, errors


def _latest_backup() -> Path | None:
    files = sorted(
        backup_dir().glob("lederg-db-*.db"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return files[0] if files else None


def _create_backup() -> Path:
    source = db_path()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    final = backup_dir() / f"lederg-db-{stamp}.db"
    temp = backup_dir() / f".{final.name}.tmp"

    if temp.exists():
        temp.unlink(missing_ok=True)

    src = sqlite3.connect(source, timeout=30)
    try:
        dst = sqlite3.connect(temp, timeout=30)
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()

    ok, errors = _integrity(temp)
    if not ok:
        temp.unlink(missing_ok=True)
        raise RuntimeError("backup verification failed: " + "; ".join(errors))

    os.replace(temp, final)

    backups = sorted(
        backup_dir().glob("lederg-db-*.db"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for stale in backups[MAX_BACKUPS:]:
        stale.unlink(missing_ok=True)

    return final


def _backup_if_due(force: bool = False) -> Path | None:
    latest = _latest_backup()
    if not force and latest:
        age = time.time() - latest.stat().st_mtime
        if age < BACKUP_INTERVAL_SECONDS:
            return latest
    return _create_backup()


def _repair_from_backup() -> tuple[bool, str]:
    candidates = sorted(
        backup_dir().glob("lederg-db-*.db"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    current = db_path()

    for backup in candidates:
        ok, _ = _integrity(backup)
        if not ok:
            continue

        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        quarantine = backup_dir() / f"lederg-db-corrupt-{stamp}.db"

        try:
            if current.exists():
                shutil.copy2(current, quarantine)
            shutil.copy2(backup, current)
            Path(str(current) + "-wal").unlink(missing_ok=True)
            Path(str(current) + "-shm").unlink(missing_ok=True)
            ok2, errors2 = _integrity(current)
            if ok2:
                return True, f"restored verified backup {backup.name}"
            return False, "restored backup failed verification: " + "; ".join(errors2)
        except Exception as exc:
            return False, f"restore failed: {exc}"

    return False, "no verified backup available"


def guard_database(create_backup: bool = True) -> tuple[bool, list[str]]:
    settings.ensure_dirs()

    try:
        init_db()
    except Exception as exc:
        return False, [f"schema initialization failed: {exc}"]

    ok, errors = _integrity(db_path())
    if not ok:
        return False, errors

    try:
        with sqlite3.connect(db_path(), timeout=30) as conn:
            conn.execute("PRAGMA optimize")
            conn.execute("PRAGMA wal_checkpoint(PASSIVE)")
    except Exception as exc:
        errors.append(f"maintenance warning: {exc}")

    if create_backup:
        try:
            _backup_if_due()
        except Exception as exc:
            errors.append(f"backup warning: {exc}")

    return True, errors


def repair_database() -> tuple[bool, str]:
    settings.ensure_dirs()

    try:
        init_db()
    except Exception:
        pass

    ok, _ = _integrity(db_path())
    if ok:
        try:
            _backup_if_due(force=True)
        except Exception:
            pass
        return True, "database is healthy; schema was normalized"

    restored, message = _repair_from_backup()
    if not restored:
        return False, message

    try:
        init_db()
    except Exception as exc:
        return False, f"schema rebuild after restore failed: {exc}"

    ok2, errors2 = _integrity(db_path())
    if not ok2:
        return False, "; ".join(errors2)

    try:
        _backup_if_due(force=True)
    except Exception:
        pass

    return True, message


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="LEDERG database guard")
    parser.add_argument("--repair", action="store_true")
    args = parser.parse_args(argv)

    if args.repair:
        ok, message = repair_database()
        print("[DB] " + message)
        return 0 if ok else 2

    ok, messages = guard_database(create_backup=True)
    if ok:
        print("[DB] GUARD OK")
        for item in messages:
            print("[DB] " + item)
        return 0

    print("[DB] CRITICAL: " + "; ".join(messages))
    print("[DB] Repair required.")
    return CRITICAL


if __name__ == "__main__":
    raise SystemExit(main())