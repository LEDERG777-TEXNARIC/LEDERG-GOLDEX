from sqlalchemy import text
from server.config import settings
from server.db.session import init_db, engine

def main():
    settings.ensure_dirs()
    init_db()
    with engine.begin() as conn:
        result = conn.execute(text("PRAGMA integrity_check")).scalar()
        if result != "ok":
            print("[DB] integrity_check failed:", result)
            return 2
        conn.execute(text("PRAGMA wal_checkpoint(TRUNCATE)"))
        conn.execute(text("PRAGMA optimize"))
    print("[DB] integrity OK")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
