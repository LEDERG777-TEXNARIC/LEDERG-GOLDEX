import os
from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    secret_key: str = os.getenv("LEDERG_SECRET_KEY", "CHANGE_ME")
    host: str = os.getenv("LEDERG_HOST", "0.0.0.0")
    port: int = int(os.getenv("LEDERG_PORT", "8090"))
    data_dir: str = os.getenv("LEDERG_DATA_DIR", r"C:\LEDERG-MESSENGER-DATA")
    db_path: str = os.getenv("LEDERG_DB_PATH", r"C:\LEDERG-MESSENGER-DATA\lederg.db")
    token_minutes: int = int(os.getenv("LEDERG_TOKEN_MINUTES", "10080"))

    model_config = SettingsConfigDict(env_prefix="LEDERG_", extra="ignore")

    def ensure_dirs(self):
        base = Path(self.data_dir)
        for p in (base, base/"backups", base/"uploads", base/"logs"):
            p.mkdir(parents=True, exist_ok=True)

settings = Settings()
