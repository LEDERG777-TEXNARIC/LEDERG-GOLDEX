from pathlib import Path
from sqlalchemy import create_engine, event
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

def _add_column_if_missing(conn, table, name, ddl):
    cols = {row[1] for row in conn.exec_driver_sql(f"PRAGMA table_info({table})").fetchall()}
    if name not in cols:
        conn.exec_driver_sql(ddl)

def _add_missing_user_columns(conn):
    additions = {
        "bio": "ALTER TABLE users ADD COLUMN bio VARCHAR(160) NOT NULL DEFAULT ''",
        "avatar_path": "ALTER TABLE users ADD COLUMN avatar_path VARCHAR(255)",
        "discoverable": "ALTER TABLE users ADD COLUMN discoverable BOOLEAN NOT NULL DEFAULT 1",
        "presence_visible": "ALTER TABLE users ADD COLUMN presence_visible BOOLEAN NOT NULL DEFAULT 1",
        "avatar_public": "ALTER TABLE users ADD COLUMN avatar_public BOOLEAN NOT NULL DEFAULT 1",
        "read_receipts": "ALTER TABLE users ADD COLUMN read_receipts BOOLEAN NOT NULL DEFAULT 1",
        "allow_messages": "ALTER TABLE users ADD COLUMN allow_messages BOOLEAN NOT NULL DEFAULT 1",
        "allow_calls": "ALTER TABLE users ADD COLUMN allow_calls BOOLEAN NOT NULL DEFAULT 1",
        "two_factor_enabled": "ALTER TABLE users ADD COLUMN two_factor_enabled BOOLEAN NOT NULL DEFAULT 0",
        "two_factor_secret": "ALTER TABLE users ADD COLUMN two_factor_secret VARCHAR(64)",
    }
    for name, sql in additions.items():
        _add_column_if_missing(conn, "users", name, sql)

def init_db():
    from server.models import User, Session, Block, Chat, ChatMember, ChatPreference, Message
    Base.metadata.create_all(bind=engine)
    with engine.begin() as conn:
        _add_missing_user_columns(conn)
        _add_column_if_missing(
            conn, "chat_preferences", "muted",
            "ALTER TABLE chat_preferences ADD COLUMN muted BOOLEAN NOT NULL DEFAULT 0"
        )
        _add_column_if_missing(
            conn, "sessions", "device_name",
            "ALTER TABLE sessions ADD COLUMN device_name VARCHAR(120) NOT NULL DEFAULT 'LEDERG device'"
        )
        _add_column_if_missing(
            conn, "sessions", "remembered",
            "ALTER TABLE sessions ADD COLUMN remembered BOOLEAN NOT NULL DEFAULT 1"
        )
        conn.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_users_discoverable_username ON users(discoverable, username)")
        conn.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_sessions_user_revoked ON sessions(user_id, revoked)")
        conn.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_sessions_user_remembered ON sessions(user_id, remembered)")
        conn.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_blocks_blocker_blocked ON blocks(blocker_id, blocked_id)")
