from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pathlib import Path
from sqlalchemy import text

from server.config import settings
from server.db.session import init_db, SessionLocal
from server.routes.auth import router as auth_router
from server.routes.users import router as users_router
from server.routes.chats import router as chats_router
from server.routes.ws import router as ws_router
from server.routes.calls import router as calls_router

@asynccontextmanager
async def lifespan(app: FastAPI):
    settings.ensure_dirs()
    for folder in ("avatars", "wallpapers"):
        (Path(settings.data_dir) / "uploads" / folder).mkdir(parents=True, exist_ok=True)
    init_db()
    yield

app = FastAPI(title="LEDERG Messenger", version="0.4.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

app.include_router(auth_router, prefix="/api/auth")
app.include_router(users_router, prefix="/api/users")
app.include_router(chats_router, prefix="/api")
app.include_router(ws_router)
app.include_router(calls_router, prefix="/api/calls")

media_dir = Path(settings.data_dir) / "uploads"
media_dir.mkdir(parents=True, exist_ok=True)
app.mount("/media", StaticFiles(directory=media_dir), name="media")

web_dir = Path(__file__).resolve().parent.parent / "web"
app.mount("/", StaticFiles(directory=web_dir, html=True), name="web")

@app.get("/health")
def health():
    try:
        with SessionLocal() as db:
            db.execute(text("SELECT 1"))
            integrity = db.execute(text("PRAGMA integrity_check")).scalar()
        if integrity != "ok":
            raise RuntimeError(f"SQLite integrity_check={integrity}")
        return {
            "ok": True,
            "service": "lederg-messenger",
            "version": "0.4.0",
            "database": "ok",
        }
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail={
                "ok": False,
                "service": "lederg-messenger",
                "database": "error",
                "reason": str(exc)[:200],
            },
        )
