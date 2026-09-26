import os
import secrets
from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict

DATA_DIR = Path(os.getenv("LEDERG_DATA_DIR", r"C:\LEDERG-MESSENGER-DATA"))
SECRET_FILE = DATA_DIR / ".secret"

def load_secret() -> str:
    configured = os.getenv("LEDERG_SECRET_KEY", "").strip()
    if configured:
        return configured
    if SECRET_FILE.exists():
        value = SECRET_FILE.read_text(encoding="utf-8").strip()
        if value:
            return value
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    value = secrets.token_urlsafe(64)
    SECRET_FILE.write_text(value, encoding="utf-8")
    return value

class Settings(BaseSettings):
    secret_key: str = load_secret()
    host: str = os.getenv("LEDERG_HOST", "0.0.0.0")
    port: int = int(os.getenv("LEDERG_PORT", "8000"))
    data_dir: str = os.getenv("LEDERG_DATA_DIR", str(DATA_DIR))
    db_path: str = os.getenv("LEDERG_DB_PATH", str(DATA_DIR / "lederg.db"))
    token_minutes: int = int(os.getenv("LEDERG_TOKEN_MINUTES", "10080"))

    model_config = SettingsConfigDict(env_prefix="LEDERG_", extra="ignore")

    def ensure_dirs(self):
        base = Path(self.data_dir)
        for p in (base, base/"backups", base/"uploads", base/"logs"):
            p.mkdir(parents=True, exist_ok=True)

settings = Settings()
