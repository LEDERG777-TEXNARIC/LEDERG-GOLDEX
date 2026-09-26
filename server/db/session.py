from pathlib import Path
from sqlalchemy import create_engine, event, text
from sqlalchemy.orm import DeclarativeBase, sessionmaker
from server.config import settings

class Base(DeclarativeBase):
    pass

Path(settings.data_dir).mkdir(parents=True, exist_ok=True)

engine = create_engine(
    f"sqlite:///{settings.db_path}",
    connect_args={"check_same_thread": False, "timeout": 30},
    pool_pre_ping=True,
)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)

@event.listens_for(engine, "connect")
def sqlite_pragmas(dbapi_connection, connection_record):
    cur = dbapi_connection.cursor()
    cur.execute("PRAGMA journal_mode=WAL")
    cur.execute("PRAGMA synchronous=NORMAL")
    cur.execute("PRAGMA foreign_keys=ON")
    cur.execute("PRAGMA busy_timeout=30000")
    cur.execute("PRAGMA temp_store=MEMORY")
    cur.close()

def _ensure_column(conn, table: str, column: str, ddl: str):
    columns = {row[1] for row in conn.execute(text(f'PRAGMA table_info("{table}")')).fetchall()}
    if column not in columns:
        conn.execute(text(f'ALTER TABLE "{table}" ADD COLUMN "{column}" {ddl}'))

def _migrate_existing_schema():
    with engine.begin() as conn:
        for column, ddl in [
            ("avatar_path", "VARCHAR(255)"),
            ("bio", "VARCHAR(160)"),
            ("online_visibility", "VARCHAR(16) NOT NULL DEFAULT 'everyone'"),
            ("avatar_visibility", "VARCHAR(16) NOT NULL DEFAULT 'everyone'"),
            ("search_visible", "BOOLEAN NOT NULL DEFAULT 1"),
            ("read_receipts", "BOOLEAN NOT NULL DEFAULT 1"),
            ("typing_visibility", "BOOLEAN NOT NULL DEFAULT 1"),
            ("session_version", "INTEGER NOT NULL DEFAULT 0"),
            ("last_seen_at", "DATETIME"),
            ("crypto_public_key", "TEXT"),
        ]:
            _ensure_column(conn, "users", column, ddl)
        for column, ddl in [
            ("is_encrypted", "BOOLEAN NOT NULL DEFAULT 0"),
            ("deleted_at", "DATETIME"),
        ]:
            _ensure_column(conn, "messages", column, ddl)

def init_db():
    from server.models import User, Chat, ChatMember, BlockedUser, ChatUserSetting, Message
    Base.metadata.create_all(bind=engine)
    _migrate_existing_schema()
